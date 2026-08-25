//
//  ObjCDump.swift
//
//
//  Created by p-x9 on 2024/09/28
//
//

import Foundation
import MachOKit
import ObjCDump

/// Options that control how Objective-C class and category metadata is converted.
public struct ObjCInfoOptions: Sendable {
    /// Options used when converting protocols referenced by classes and categories.
    public var protocolInfoOptions: ObjCProtocolInfoOptions

    /// Creates options for Objective-C class and category metadata conversion.
    ///
    /// - Parameter protocolInfoOptions: Options used for protocols referenced from
    ///   a class or category protocol list.
    public init(
        protocolInfoOptions: ObjCProtocolInfoOptions = .recursive
    ) {
        self.protocolInfoOptions = protocolInfoOptions
    }

    /// Preserves the default behavior and expands referenced protocols recursively.
    /// Expansion is cycle-safe and hard-capped at 64 reference edges; a cutoff
    /// edge is represented by a shallow name-only leaf.
    public static let recursive = ObjCInfoOptions()

    /// Uses the protocol detail level needed for Objective-C header dumps.
    ///
    /// Header declarations need the names of directly adopted protocols, but they
    /// do not need to recursively materialize those protocols' members.
    public static let headerDump = ObjCInfoOptions(
        protocolInfoOptions: .directProtocolNames
    )
}

/// Options that control how Objective-C protocol metadata is converted.
public struct ObjCProtocolInfoOptions: Sendable {
    /// Controls how far referenced protocols are followed.
    public enum Traversal: Sendable {
        /// Expands referenced protocols recursively, up to 64 reference edges.
        ///
        /// A cycle or a reference beyond that hard ceiling is represented by a
        /// shallow name-only leaf. Use the Diagnostics SPI to observe either cutoff;
        /// the compatibility `info(...)` APIs intentionally discard diagnostics.
        case recursive

        /// Expands referenced protocols up to the specified number of reference edges.
        ///
        /// A depth of `0` does not include referenced protocols. A depth of `1`
        /// includes only directly referenced protocols. Values greater than `64`
        /// still use the hard ceiling: the edge beyond 64 becomes a shallow name-only
        /// leaf and produces a Diagnostics SPI recursion-limit diagnostic. Exhausting
        /// a configured depth at or below 64 is intentional and produces no warning.
        case depth(Int)
    }

    /// Controls how much information is materialized for referenced protocols.
    public enum ReferencedProtocolInfo: Sendable {
        /// Materializes full protocol information, including members and references.
        case full

        /// Materializes only the protocol name.
        case nameOnly
    }

    /// The traversal strategy used for protocols referenced by the current protocol.
    public var traversal: Traversal

    /// The amount of information to materialize for each referenced protocol.
    public var referencedProtocolInfo: ReferencedProtocolInfo

    /// Creates options for Objective-C protocol metadata conversion.
    ///
    /// - Parameters:
    ///   - traversal: How far referenced protocols should be followed.
    ///   - referencedProtocolInfo: How much information should be materialized for
    ///     each referenced protocol that is included by `traversal`.
    public init(
        traversal: Traversal = .recursive,
        referencedProtocolInfo: ReferencedProtocolInfo = .full
    ) {
        self.traversal = traversal
        self.referencedProtocolInfo = referencedProtocolInfo
    }

    /// Preserves the default behavior and expands referenced protocols recursively.
    /// Expansion is cycle-safe and hard-capped at 64 reference edges; a cutoff
    /// edge is represented by a shallow name-only leaf.
    public static let recursive = ObjCProtocolInfoOptions()

    /// Includes direct protocol references as name-only protocol information.
    ///
    /// For a protocol, this keeps the protocol's own members but represents directly
    /// referenced protocols by name only. For a class or category, pass this value
    /// to ``ObjCInfoOptions/init(protocolInfoOptions:)`` to apply the same policy
    /// to adopted protocols.
    public static let directProtocolNames = ObjCProtocolInfoOptions(
        traversal: .depth(1),
        referencedProtocolInfo: .nameOnly
    )
}

extension ObjCProtocolInfoOptions {
    fileprivate func nextForReferencedProtocol() -> ObjCProtocolInfoOptions? {
        switch traversal {
        case .recursive:
            return self
        case let .depth(depth):
            guard depth > 0 else { return nil }
            var next = self
            next.traversal = .depth(depth - 1)
            return next
        }
    }
}

// MARK: - IVar
extension ObjCIvarProtocol {
    public func info(in machO: MachOFile) -> ObjCIvarInfo? {
        guard let name = name(in: machO),
              let type = type(in: machO),
              let offset = offset(in: machO) else {
            return nil
        }
        return .init(
            name: name,
            typeEncoding: type,
            offset: numericCast(offset)
        )
    }

    public func info(in machO: MachOImage) -> ObjCIvarInfo? {
        let name = name(in: machO)
        guard let type = type(in: machO),
              let offset = offset(in: machO) else {
            return nil
        }
        return .init(
            name: name,
            typeEncoding: type,
            offset: numericCast(offset)
        )
    }
}

// MARK: - Property
extension ObjCProperty {
    public func info(
        isClassProperty: Bool = false
    ) -> ObjCPropertyInfo {
       .init(
            name: name,
            attributesString: attributes,
            isClassProperty: isClassProperty
        )
    }
}

// MARK: - Method
extension ObjCMethod {
    public func info(
        isClassMethod: Bool = false
    ) -> ObjCMethodInfo {
        .init(
            name: name,
            typeEncoding: types,
            isClassMethod: isClassMethod,
            imp: imp,
        )
    }
}

// MARK: - Protocol
extension ObjCProtocolProtocol {
    public func info(
        in machO: MachOFile,
        options: ObjCProtocolInfoOptions = .recursive
    ) -> ObjCProtocolInfo? {
        readInfo(in: machO, options: options).value
    }

    /// Decodes this protocol and returns recoverable protocol-list/traversal diagnostics.
    /// Each call owns an independent traversal path and diagnostic sequence.
    @_spi(Diagnostics)
    public func readInfo(
        in machO: MachOFile,
        options: ObjCProtocolInfoOptions = .recursive
    ) -> ObjCMetadataReadResult<ObjCProtocolInfo> {
        let name = mangledName(in: machO)
        let identity = traversalIdentity(in: machO)
        var context = ObjCProtocolTraversalContext(
            subject: .protocol(name: name),
            rootProtocol: identity.map { ($0, name) }
        )
        if identity == nil {
            context.recordInvalidRootIdentity(protocolOffset: offset)
        }
        let effectiveOptions = identity == nil
            ? ObjCProtocolInfoOptions(
                traversal: .depth(0),
                referencedProtocolInfo: options.referencedProtocolInfo
            )
            : options
        let value = _readInfo(
            in: machO,
            name: name,
            options: effectiveOptions,
            context: &context
        )
        return .init(value: value, diagnostics: context.diagnostics)
    }

    private func _readInfo(
        in machO: MachOFile,
        name knownName: String? = nil,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> ObjCProtocolInfo? {
        let name = knownName ?? mangledName(in: machO)

        let protocols = referencedProtocolInfos(
            in: machO,
            options: options,
            context: &context
        )

        let classPropertiesList = classPropertyList(in: machO)
        let classProperties = classPropertiesList?
            .properties(in: machO)
            .compactMap { $0.info(isClassProperty: true) } ?? []

        let propertiesList = instancePropertyList(in: machO)
        let properties = propertiesList?
            .properties(in: machO)
            .compactMap { $0.info(isClassProperty: false) } ?? []

        let classMethodsList = classMethodList(in: machO)
        let classMethods = classMethodsList?
            .methods(in: machO)?
            .compactMap { $0.info(isClassMethod: true) } ?? []

        let methodsList = instanceMethodList(in: machO)
        let methods = methodsList?
            .methods(in: machO)?
            .compactMap { $0.info(isClassMethod: false) } ?? []

        let optionalClassMethodsList = optionalClassMethodList(in: machO)
        let optionalClassMethods = optionalClassMethodsList?
            .methods(in: machO)?
            .compactMap { $0.info(isClassMethod: true) } ?? []

        let optionalMethodsList = optionalInstanceMethodList(in: machO)
        let optionalMethods = optionalMethodsList?
            .methods(in: machO)?
            .compactMap { $0.info(isClassMethod: false) } ?? []

        // Note:
        // `Objective-C` protocol does not currently support optional properties
        // https://github.com/apple-oss-distributions/objc4/blob/01edf1705fbc3ff78a423cd21e03dfc21eb4d780/runtime/objc-runtime-new.mm#L5255

        return .init(
            name: name,
            protocols: protocols,
            classProperties: classProperties,
            properties: properties,
            classMethods: classMethods,
            methods: methods,
            optionalClassProperties: [],
            optionalProperties: [],
            optionalClassMethods: optionalClassMethods,
            optionalMethods: optionalMethods
        )
    }

    public func info(
        in machO: MachOImage,
        options: ObjCProtocolInfoOptions = .recursive
    ) -> ObjCProtocolInfo? {
        readInfo(in: machO, options: options).value
    }

    /// Decodes this protocol and returns recoverable protocol-list/traversal diagnostics.
    /// Each call owns an independent traversal path and diagnostic sequence.
    @_spi(Diagnostics)
    public func readInfo(
        in machO: MachOImage,
        options: ObjCProtocolInfoOptions = .recursive
    ) -> ObjCMetadataReadResult<ObjCProtocolInfo> {
        let name = mangledName(in: machO)
        let rootProtocol = traversalIdentity(in: machO).map { ($0, name) }
        var context = ObjCProtocolTraversalContext(
            subject: .protocol(name: name),
            rootProtocol: rootProtocol
        )
        if rootProtocol == nil {
            context.recordInvalidRootIdentity(protocolOffset: offset)
        }
        let effectiveOptions = rootProtocol == nil
            ? ObjCProtocolInfoOptions(
                traversal: .depth(0),
                referencedProtocolInfo: options.referencedProtocolInfo
            )
            : options
        let value = _readInfo(
            in: machO,
            name: name,
            options: effectiveOptions,
            context: &context
        )
        return .init(value: value, diagnostics: context.diagnostics)
    }

    private func _readInfo(
        in machO: MachOImage,
        name knownName: String? = nil,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> ObjCProtocolInfo? {
        let name = knownName ?? mangledName(in: machO)

        let protocols = referencedProtocolInfos(
            in: machO,
            options: options,
            context: &context
        )

        let classPropertiesList = classPropertyList(in: machO)
        let classProperties = classPropertiesList?
            .properties(in: machO)
            .compactMap { $0.info(isClassProperty: true) } ?? []

        let propertiesList = instancePropertyList(in: machO)
        let properties = propertiesList?
            .properties(in: machO)
            .compactMap { $0.info(isClassProperty: false) } ?? []

        let classMethodsList = classMethodList(in: machO)
        let classMethods = classMethodsList?
            .methods(in: machO)
            .compactMap { $0.info(isClassMethod: true) } ?? []

        let methodsList = instanceMethodList(in: machO)
        let methods = methodsList?
            .methods(in: machO)
            .compactMap { $0.info(isClassMethod: false) } ?? []

        let optionalClassMethodsList = optionalClassMethodList(in: machO)
        let optionalClassMethods = optionalClassMethodsList?
            .methods(in: machO)
            .compactMap { $0.info(isClassMethod: true) } ?? []

        let optionalMethodsList = optionalInstanceMethodList(in: machO)
        let optionalMethods = optionalMethodsList?
            .methods(in: machO)
            .compactMap { $0.info(isClassMethod: false) } ?? []

        // Note:
        // `Objective-C` protocol does not currently support optional properties
        // https://github.com/apple-oss-distributions/objc4/blob/01edf1705fbc3ff78a423cd21e03dfc21eb4d780/runtime/objc-runtime-new.mm#L5255

        return .init(
            name: name,
            protocols: protocols,
            classProperties: classProperties,
            properties: properties,
            classMethods: classMethods,
            methods: methods,
            optionalClassProperties: [],
            optionalProperties: [],
            optionalClassMethods: optionalClassMethods,
            optionalMethods: optionalMethods
        )
    }
}

private func shallowProtocolInfo(name: String) -> ObjCProtocolInfo {
    .init(
        name: name,
        protocols: [],
        classProperties: [],
        properties: [],
        classMethods: [],
        methods: [],
        optionalClassProperties: [],
        optionalProperties: [],
        optionalClassMethods: [],
        optionalMethods: []
    )
}

extension ObjCProtocolProtocol {
    fileprivate func shallowInfo(in machO: MachOFile) -> ObjCProtocolInfo {
        shallowProtocolInfo(name: mangledName(in: machO))
    }

    fileprivate func shallowInfo(in machO: MachOImage) -> ObjCProtocolInfo {
        shallowProtocolInfo(name: mangledName(in: machO))
    }

    fileprivate func referenceInfo(
        in machO: MachOFile,
        identity: ObjCProtocolIdentity,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> ObjCProtocolInfo? {
        let name = mangledName(in: machO)
        switch context.decision(for: identity, name: name) {
        case .shallowCycle, .shallowLimit:
            return shallowInfo(in: machO)
        case .descend:
            break
        }
        switch options.referencedProtocolInfo {
        case .full:
            context.enter(identity: identity, name: name)
            let info = _readInfo(
                in: machO,
                name: name,
                options: options,
                context: &context
            )
            context.leave(identity: identity)
            return info
        case .nameOnly:
            return shallowInfo(in: machO)
        }
    }

    fileprivate func referenceInfo(
        in machO: MachOImage,
        identity: ObjCProtocolIdentity,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> ObjCProtocolInfo? {
        let name = mangledName(in: machO)
        switch context.decision(for: identity, name: name) {
        case .shallowCycle, .shallowLimit:
            return shallowInfo(in: machO)
        case .descend:
            break
        }
        switch options.referencedProtocolInfo {
        case .full:
            context.enter(identity: identity, name: name)
            let info = _readInfo(
                in: machO,
                name: name,
                options: options,
                context: &context
            )
            context.leave(identity: identity)
            return info
        case .nameOnly:
            return shallowInfo(in: machO)
        }
    }

    fileprivate func referencedProtocolInfos(
        in machO: MachOFile,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> [ObjCProtocolInfo] {
        guard let nextOptions = options.nextForReferencedProtocol() else {
            return []
        }
        return protocolListResolution(in: machO)
            .protocolInfos(options: nextOptions, context: &context)
    }

    fileprivate func referencedProtocolInfos(
        in machO: MachOImage,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> [ObjCProtocolInfo] {
        guard let nextOptions = options.nextForReferencedProtocol() else {
            return []
        }
        return protocolListResolution(in: machO)
            .protocolInfos(options: nextOptions, context: &context)
    }
}

extension ObjCProtocolListProtocol {
    fileprivate func referencedProtocolInfos(
        in machO: MachOFile,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> [ObjCProtocolInfo] {
        guard let nextOptions = options.nextForReferencedProtocol() else {
            return []
        }
        return protocolInfos(in: machO, options: nextOptions, context: &context)
    }

    fileprivate func referencedProtocolInfos(
        in machO: MachOImage,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> [ObjCProtocolInfo] {
        guard let nextOptions = options.nextForReferencedProtocol() else {
            return []
        }
        return protocolInfos(in: machO, options: nextOptions, context: &context)
    }

    fileprivate func protocolInfos(
        in machO: MachOFile,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> [ObjCProtocolInfo] {
        switch readProtocols(in: machO) {
        case .failure(let failure):
            context.record(tableFailure: failure, listOffset: offset)
            return []
        case .success(let success):
            var infos: [ObjCProtocolInfo] = []
            for entry in success.entries {
                switch entry {
                case .failure(let failure):
                    context.record(entryFailure: failure, listOffset: offset)
                case .nameReference(let reference):
                    context.record(
                        entryFailure: .init(
                            index: reference.index,
                            reason: .missingBackingData
                        ),
                        listOffset: offset
                    )
                case .reference(let reference):
                    if let info = reference.value.referenceInfo(
                        in: reference.source,
                        identity: reference.identity,
                        options: options,
                        context: &context
                    ) {
                        infos.append(info)
                    }
                }
            }
            return infos
        }
    }

    fileprivate func protocolInfos(
        in machO: MachOImage,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> [ObjCProtocolInfo] {
        let runtimeResolver: ObjCProtocolRuntimeResolver?
        switch options.referencedProtocolInfo {
        case .full:
            runtimeResolver = nil
        case .nameOnly:
            runtimeResolver = .runtime
        }
        switch readProtocols(
            in: machO,
            runtimeResolver: runtimeResolver
        ) {
        case .failure(let failure):
            context.record(tableFailure: failure, listOffset: offset)
            return []
        case .success(let success):
            var infos: [ObjCProtocolInfo] = []
            for entry in success.entries {
                switch entry {
                case .failure(let failure):
                    context.record(entryFailure: failure, listOffset: offset)
                case .nameReference(let reference):
                    guard case .nameOnly = options.referencedProtocolInfo else {
                        context.record(
                            entryFailure: .init(
                                index: reference.index,
                                reason: .missingBackingData
                            ),
                            listOffset: offset
                        )
                        continue
                    }
                    _ = context.decision(
                        for: reference.identity,
                        name: reference.name
                    )
                    infos.append(shallowProtocolInfo(name: reference.name))
                case .reference(let reference):
                    if let info = reference.value.referenceInfo(
                        in: reference.source,
                        identity: reference.identity,
                        options: options,
                        context: &context
                    ) {
                        infos.append(info)
                    }
                }
            }
            return infos
        }
    }
}

extension ObjCRelativeListResolution where
    Source == MachOFile,
    List: ObjCProtocolListProtocol,
    Failure == ObjCProtocolListResolutionFailure
{
    fileprivate func referencedProtocolInfos(
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> [ObjCProtocolInfo] {
        guard let nextOptions = options.nextForReferencedProtocol() else { return [] }
        return protocolInfos(options: nextOptions, context: &context)
    }

    fileprivate func protocolInfos(
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> [ObjCProtocolInfo] {
        switch self {
        case .absent:
            return []
        case .failure(let failure):
            context.record(resolutionFailure: failure)
            return []
        case .entries(let entries):
            var infos: [ObjCProtocolInfo] = []
            for entry in entries {
                switch entry {
                case .failure(let failure):
                    context.record(resolutionFailure: failure)
                case let .resolved(source, list):
                    infos.append(
                        contentsOf: list.protocolInfos(
                            in: source,
                            options: options,
                            context: &context
                        )
                    )
                }
            }
            return infos
        }
    }
}

extension ObjCRelativeListResolution where
    Source == MachOImage,
    List: ObjCProtocolListProtocol,
    Failure == ObjCProtocolListResolutionFailure
{
    fileprivate func referencedProtocolInfos(
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> [ObjCProtocolInfo] {
        guard let nextOptions = options.nextForReferencedProtocol() else { return [] }
        return protocolInfos(options: nextOptions, context: &context)
    }

    fileprivate func protocolInfos(
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> [ObjCProtocolInfo] {
        switch self {
        case .absent:
            return []
        case .failure(let failure):
            context.record(resolutionFailure: failure)
            return []
        case .entries(let entries):
            var infos: [ObjCProtocolInfo] = []
            for entry in entries {
                switch entry {
                case .failure(let failure):
                    context.record(resolutionFailure: failure)
                case let .resolved(source, list):
                    infos.append(
                        contentsOf: list.protocolInfos(
                            in: source,
                            options: options,
                            context: &context
                        )
                    )
                }
            }
            return infos
        }
    }
}

// MARK: - Class
extension ObjCClassProtocol {
    public func info(
        in machO: MachOFile,
        options: ObjCInfoOptions = .recursive
    ) -> ObjCClassInfo? {
        readInfo(in: machO, options: options).value
    }

    /// Decodes this class and returns recoverable protocol-list/traversal diagnostics.
    /// Each call owns an independent traversal path and diagnostic sequence.
    @_spi(Diagnostics)
    public func readInfo(
        in machO: MachOFile,
        options: ObjCInfoOptions = .recursive
    ) -> ObjCMetadataReadResult<ObjCClassInfo> {
        var fieldDiagnostics: [ObjCMetadataFieldDiagnostic] = []
        let data: ClassROData
        switch readDirectClassROData(in: machO) {
        case .absent:
            return .init(value: nil, diagnostics: [])
        case .failure(let failure):
            fieldDiagnostics.append(
                classRODataDiagnostic(
                    name: nil,
                    role: .instance,
                    classObjectOffset: offset,
                    failure: failure
                )
            )
            return .init(
                value: nil,
                diagnostics: [],
                fieldDiagnostics: fieldDiagnostics
            )
        case .value(let value):
            data = value
        }
        guard let name = data.name(in: machO) else {
            return .init(value: nil, diagnostics: [])
        }

        var context = ObjCProtocolTraversalContext(subject: .class(name: name))
        let value = _readInfo(
            in: machO,
            data: data,
            name: name,
            options: options,
            context: &context,
            fieldDiagnostics: &fieldDiagnostics
        )
        return .init(
            value: value,
            diagnostics: context.diagnostics,
            memberListDiagnostics: context.memberListDiagnostics,
            fieldDiagnostics: fieldDiagnostics
        )
    }

    private func _readInfo(
        in machO: MachOFile,
        data: ClassROData,
        name: String,
        options: ObjCInfoOptions,
        context: inout ObjCProtocolTraversalContext,
        fieldDiagnostics: inout [ObjCMetadataFieldDiagnostic]
    ) -> ObjCClassInfo? {
        guard let (targetMachO, meta) = metaClass(in: machO) else { return nil }

        let metaData: ClassROData?
        switch meta.readDirectClassROData(in: targetMachO) {
        case .absent:
            return nil
        case .failure(let failure):
            fieldDiagnostics.append(
                classRODataDiagnostic(
                    name: name,
                    role: .metaclass,
                    classObjectOffset: meta.offset,
                    failure: failure
                )
            )
            metaData = nil
        case .value(let value):
            metaData = value
        }
        let imagePath = machO.imagePath
        let subject = ObjCMetadataFieldDiagnostic.Subject.namedClass(
            name: name,
            objectOffset: offset
        )

        let protocols = data
            .protocolListResolutions(in: machO)
            .referencedProtocolInfos(
                options: options.protocolInfoOptions,
                context: &context
            )

        var ivars: [ObjCIvarInfo] = []
        if let ivarList = data.ivarList(in: machO),
           let entries = ivarList.ivars(in: machO) {
            ivars.reserveCapacity(entries.count)
            for (index, ivar) in entries.enumerated() {
                guard let ivarName = ivar.name(in: machO),
                      let type = ivar.type(in: machO) else {
                    continue
                }
                switch ivar.readOffset(in: machO) {
                case .absent:
                    continue
                case .failure(let failure):
                    fieldDiagnostics.append(
                        .ivarOffset(
                            .init(
                                subject: subject,
                                index: index,
                                name: ivarName,
                                failure: failure
                            )
                        )
                    )
                case .value(let value):
                    ivars.append(
                        .init(
                            name: ivarName,
                            typeEncoding: type,
                            offset: numericCast(value)
                        )
                    )
                }
            }
        }

        // Instance
        let properties = data
            .propertyListResolutions(in: machO)
            .memberValues(
                className: name,
                kind: .instanceProperty,
                context: &context
            ) { source, list in
                list.properties(in: source).compactMap {
                    $0.info(isClassProperty: false)
                }
            }

        let methods = data
            .methodListResolutions(in: machO)
            .memberValues(
                className: name,
                kind: .instanceMethod,
                context: &context
            ) { source, list in
                (list.methods(in: source) ?? []).compactMap {
                    $0.info(isClassMethod: false)
                }
            }

        // Meta
        let classProperties: [ObjCPropertyInfo]
        let classMethods: [ObjCMethodInfo]
        if let metaData {
            classProperties = metaData
                .propertyListResolutions(in: targetMachO)
                .memberValues(
                    className: name,
                    kind: .classProperty,
                    context: &context
                ) { source, list in
                    list.properties(in: source).compactMap {
                        $0.info(isClassProperty: true)
                    }
                }
            classMethods = metaData
                .methodListResolutions(in: targetMachO)
                .memberValues(
                    className: name,
                    kind: .classMethod,
                    context: &context
                ) { source, list in
                    (list.methods(in: source) ?? []).compactMap {
                        $0.info(isClassMethod: true)
                    }
                }
        } else {
            classProperties = []
            classMethods = []
        }

        let superClassName = superClassName(in: machO)

        return .init(
            name: name,
            version: version(for: data),
            imageName: imagePath,
            instanceSize: numericCast(data.instanceSize),
            superClassName: superClassName,
            protocols: protocols,
            ivars: ivars,
            classProperties: classProperties,
            properties: properties,
            classMethods: classMethods,
            methods: methods
        )
    }

    public func name(in machO: MachOImage) -> String? {
        readClassRODataForInfo(in: machO).value?.name(in: machO)
    }

    private func readClassRODataForInfo(
        in machO: MachOImage
    ) -> ObjCMetadataFieldRead<ClassROData> {
        let direct = readDirectClassROData(in: machO)
        guard case .absent = direct else { return direct }
        guard let rw = classRWData(in: machO) else { return .absent }

        let readOnlyData = rw.readClassROData(in: machO)
        guard case .absent = readOnlyData else { return readOnlyData }
        guard let ext = rw.ext(in: machO) else { return .absent }
        return ext.readClassROData(in: machO)
    }

    public func info(
        in machO: MachOImage,
        options: ObjCInfoOptions = .recursive
    ) -> ObjCClassInfo? {
        readInfo(in: machO, options: options).value
    }

    /// Decodes this class and returns recoverable protocol-list/traversal diagnostics.
    /// Each call owns an independent traversal path and diagnostic sequence.
    @_spi(Diagnostics)
    public func readInfo(
        in machO: MachOImage,
        options: ObjCInfoOptions = .recursive
    ) -> ObjCMetadataReadResult<ObjCClassInfo> {
        var fieldDiagnostics: [ObjCMetadataFieldDiagnostic] = []
        let data: ClassROData
        switch readClassRODataForInfo(in: machO) {
        case .absent:
            return .init(value: nil, diagnostics: [])
        case .failure(let failure):
            fieldDiagnostics.append(
                classRODataDiagnostic(
                    name: nil,
                    role: .instance,
                    classObjectOffset: offset,
                    failure: failure
                )
            )
            return .init(
                value: nil,
                diagnostics: [],
                fieldDiagnostics: fieldDiagnostics
            )
        case .value(let value):
            data = value
        }
        guard let name = data.name(in: machO) else {
            return .init(value: nil, diagnostics: [])
        }

        var context = ObjCProtocolTraversalContext(subject: .class(name: name))
        let value = _readInfo(
            in: machO,
            data: data,
            name: name,
            options: options,
            context: &context,
            fieldDiagnostics: &fieldDiagnostics
        )
        return .init(
            value: value,
            diagnostics: context.diagnostics,
            memberListDiagnostics: context.memberListDiagnostics,
            fieldDiagnostics: fieldDiagnostics
        )
    }

    private func _readInfo(
        in machO: MachOImage,
        data: ClassROData,
        name: String,
        options: ObjCInfoOptions,
        context: inout ObjCProtocolTraversalContext,
        fieldDiagnostics: inout [ObjCMetadataFieldDiagnostic]
    ) -> ObjCClassInfo? {
        guard let (targetMachO, meta) = metaClass(in: machO) else { return nil }

        let metaData: ClassROData?
        switch meta.readClassRODataForInfo(in: targetMachO) {
        case .absent:
            return nil
        case .failure(let failure):
            fieldDiagnostics.append(
                classRODataDiagnostic(
                    name: name,
                    role: .metaclass,
                    classObjectOffset: meta.offset,
                    failure: failure
                )
            )
            metaData = nil
        case .value(let value):
            metaData = value
        }
        let subject = ObjCMetadataFieldDiagnostic.Subject.namedClass(
            name: name,
            objectOffset: offset
        )

        let protocols = data
            .protocolListResolutions(in: machO)
            .referencedProtocolInfos(
                options: options.protocolInfoOptions,
                context: &context
            )

        var ivars: [ObjCIvarInfo] = []
        if let ivarList = data.ivarList(in: machO),
           let entries = ivarList.ivars(in: machO) {
            ivars.reserveCapacity(entries.count)
            for (index, ivar) in entries.enumerated() {
                let ivarName = ivar.name(in: machO)
                guard let type = ivar.type(in: machO) else { continue }
                switch ivar.readOffset(in: machO) {
                case .absent:
                    continue
                case .failure(let failure):
                    fieldDiagnostics.append(
                        .ivarOffset(
                            .init(
                                subject: subject,
                                index: index,
                                name: ivarName,
                                failure: failure
                            )
                        )
                    )
                case .value(let value):
                    ivars.append(
                        .init(
                            name: ivarName,
                            typeEncoding: type,
                            offset: numericCast(value)
                        )
                    )
                }
            }
        }

        // Instance
        let properties = data
            .propertyListResolutions(in: machO)
            .memberValues(
                className: name,
                kind: .instanceProperty,
                context: &context
            ) { source, list in
                list.properties(in: source).compactMap {
                    $0.info(isClassProperty: false)
                }
            }

        let methods = data
            .methodListResolutions(in: machO)
            .memberValues(
                className: name,
                kind: .instanceMethod,
                context: &context
            ) { source, list in
                list.methods(in: source).compactMap {
                    $0.info(isClassMethod: false)
                }
            }

        // Meta
        let classProperties: [ObjCPropertyInfo]
        let classMethods: [ObjCMethodInfo]
        if let metaData {
            classProperties = metaData
                .propertyListResolutions(in: targetMachO)
                .memberValues(
                    className: name,
                    kind: .classProperty,
                    context: &context
                ) { source, list in
                    list.properties(in: source).compactMap {
                        $0.info(isClassProperty: true)
                    }
                }
            classMethods = metaData
                .methodListResolutions(in: targetMachO)
                .memberValues(
                    className: name,
                    kind: .classMethod,
                    context: &context
                ) { source, list in
                    list.methods(in: source).compactMap {
                        $0.info(isClassMethod: true)
                    }
                }
        } else {
            classProperties = []
            classMethods = []
        }

        let superClassName = superClassName(in: machO)

        return .init(
            name: name,
            version: version(in: machO),
            imageName: machO.path,
            instanceSize: numericCast(data.layout.instanceSize),
            superClassName: superClassName,
            protocols: protocols,
            ivars: ivars,
            classProperties: classProperties,
            properties: properties,
            classMethods: classMethods,
            methods: methods
        )
    }

    private func classRODataDiagnostic(
        name: String?,
        role: ObjCMetadataFieldDiagnostic.ClassRole,
        classObjectOffset: Int,
        failure: ObjCMetadataFieldDiagnostic.Failure
    ) -> ObjCMetadataFieldDiagnostic {
        let subject: ObjCMetadataFieldDiagnostic.Subject
        if let name {
            subject = .namedClass(name: name, objectOffset: offset)
        } else {
            subject = .classObject(offset: offset)
        }
        return .classROData(
            .init(
                subject: subject,
                role: role,
                classObjectOffset: classObjectOffset,
                failure: failure
            )
        )
    }
}

// MARK: Category
extension ObjCCategoryProtocol {
    public func info(
        in machO: MachOImage,
        options: ObjCInfoOptions = .recursive
    ) -> ObjCCategoryInfo? {
        readInfo(in: machO, options: options).value
    }

    /// Decodes this category and returns recoverable protocol-list/traversal diagnostics.
    /// Each call owns an independent traversal path and diagnostic sequence.
    @_spi(Diagnostics)
    public func readInfo(
        in machO: MachOImage,
        options: ObjCInfoOptions = .recursive
    ) -> ObjCMetadataReadResult<ObjCCategoryInfo> {
        let categoryName = name(in: machO) ?? "<unknown>"
        let targetClassName = className(in: machO) ?? "<unknown>"
        var context = ObjCProtocolTraversalContext(
            subject: .category(className: targetClassName, name: categoryName)
        )
        let value = _readInfo(in: machO, options: options, context: &context)
        return .init(value: value, diagnostics: context.diagnostics)
    }

    private func _readInfo(
        in machO: MachOImage,
        options: ObjCInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> ObjCCategoryInfo? {
        guard let name = name(in: machO),
              let className = className(in: machO) else {
            return nil
        }

        let protocols = protocolListResolution(in: machO)
            .referencedProtocolInfos(
                options: options.protocolInfoOptions,
                context: &context
            )

        // Instance
        let propertiesList = instancePropertyList(in: machO)
        let properties = propertiesList?
            .properties(in: machO)
            .compactMap { $0.info(isClassProperty: false) } ?? []

        let methodsList = instanceMethodList(in: machO)
        let methods = methodsList?
            .methods(in: machO)
            .compactMap { $0.info(isClassMethod: false) } ?? []

        // Meta
        let classPropertiesList = classPropertyList(in: machO)
        let classProperties = classPropertiesList?
            .properties(in: machO)
            .compactMap { $0.info(isClassProperty: true) } ?? []

        let classMethodsList = classMethodList(in: machO)
        let classMethods = classMethodsList?
            .methods(in: machO)
            .compactMap { $0.info(isClassMethod: true) } ?? []

        return .init(
            name: name,
            className: className,
            protocols: protocols,
            classProperties: classProperties,
            properties: properties,
            classMethods: classMethods,
            methods: methods
        )
    }

    public func info(
        in machO: MachOFile,
        options: ObjCInfoOptions = .recursive
    ) -> ObjCCategoryInfo? {
        readInfo(in: machO, options: options).value
    }

    /// Decodes this category and returns recoverable protocol-list/traversal diagnostics.
    /// Each call owns an independent traversal path and diagnostic sequence.
    @_spi(Diagnostics)
    public func readInfo(
        in machO: MachOFile,
        options: ObjCInfoOptions = .recursive
    ) -> ObjCMetadataReadResult<ObjCCategoryInfo> {
        let categoryName = name(in: machO) ?? "<unknown>"
        let targetClassName = className(in: machO) ?? "<unknown>"
        var context = ObjCProtocolTraversalContext(
            subject: .category(className: targetClassName, name: categoryName)
        )
        let value = _readInfo(in: machO, options: options, context: &context)
        return .init(value: value, diagnostics: context.diagnostics)
    }

    private func _readInfo(
        in machO: MachOFile,
        options: ObjCInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> ObjCCategoryInfo? {
        guard let name = name(in: machO),
              let className = className(in: machO) else {
            return nil
        }

        let protocols = protocolListResolution(in: machO)
            .referencedProtocolInfos(
                options: options.protocolInfoOptions,
                context: &context
            )

        // Instance
        let propertiesList = instancePropertyList(in: machO)
        let properties = propertiesList?
            .properties(in: machO)
            .compactMap { $0.info(isClassProperty: false) } ?? []

        let methodsList = instanceMethodList(in: machO)
        let methods = methodsList?
            .methods(in: machO)?
            .compactMap { $0.info(isClassMethod: false) } ?? []

        // Meta
        let classPropertiesList = classPropertyList(in: machO)
        let classProperties = classPropertiesList?
            .properties(in: machO)
            .compactMap { $0.info(isClassProperty: true) } ?? []

        let classMethodsList = classMethodList(in: machO)
        let classMethods = classMethodsList?
            .methods(in: machO)?
            .compactMap { $0.info(isClassMethod: true) } ?? []

        return .init(
            name: name,
            className: className,
            protocols: protocols,
            classProperties: classProperties,
            properties: properties,
            classMethods: classMethods,
            methods: methods
        )
    }
}

fileprivate extension ObjCRelativeListResolution where Failure == ObjCRelativeListFailure {
    func memberValues<Value>(
        className: String,
        kind: ObjCMemberListDiagnostic.Kind,
        context: inout ObjCProtocolTraversalContext,
        read: (Source, List) -> [Value]
    ) -> [Value] {
        switch self {
        case .absent:
            return []
        case .failure(let failure):
            context.record(
                memberListFailure: failure,
                className: className,
                kind: kind
            )
            return []
        case .entries(let entries):
            var values: [Value] = []
            for entry in entries {
                switch entry {
                case .failure(let failure):
                    context.record(
                        memberListFailure: failure,
                        className: className,
                        kind: kind
                    )
                case let .resolved(source, list):
                    values.append(contentsOf: read(source, list))
                }
            }
            return values
        }
    }
}
