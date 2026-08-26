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

private extension ObjCProtocolTraversalContext {
    mutating func methodInfos(
        from listRead: ObjCMetadataReferenceRead<ObjCMethodList>,
        in source: MachOFile,
        subject: ObjCMetadataTableDiagnostic.MetadataSubject,
        kind: ObjCMetadataTableDiagnostic.MemberKind,
        isClassMethod: Bool
    ) -> [ObjCMethodInfo] {
        ObjCMetadataTableDiagnosticRecorder.memberValues(
            from: listRead,
            in: source,
            subject: subject,
            kind: kind,
            context: &self,
            entryStride: { $0.expectedEntrySize(is64Bit: source.is64Bit) },
            read: { $0.readMethods(in: source) },
            transform: { $0.info(isClassMethod: isClassMethod) }
        )
    }

    mutating func methodInfos(
        from listRead: ObjCMetadataReferenceRead<ObjCMethodList>,
        in source: MachOImage,
        subject: ObjCMetadataTableDiagnostic.MetadataSubject,
        kind: ObjCMetadataTableDiagnostic.MemberKind,
        isClassMethod: Bool
    ) -> [ObjCMethodInfo] {
        ObjCMetadataTableDiagnosticRecorder.memberValues(
            from: listRead,
            in: source,
            subject: subject,
            kind: kind,
            context: &self,
            entryStride: { $0.expectedEntrySize(is64Bit: source.is64Bit) },
            read: { $0.readMethods(in: source) },
            transform: { $0.info(isClassMethod: isClassMethod) }
        )
    }

    mutating func propertyInfos(
        from listRead: ObjCMetadataReferenceRead<ObjCPropertyList>,
        in source: MachOFile,
        subject: ObjCMetadataTableDiagnostic.MetadataSubject,
        kind: ObjCMetadataTableDiagnostic.MemberKind,
        isClassProperty: Bool
    ) -> [ObjCPropertyInfo] {
        ObjCMetadataTableDiagnosticRecorder.memberValues(
            from: listRead,
            in: source,
            subject: subject,
            kind: kind,
            context: &self,
            entryStride: { $0.expectedEntrySize(is64Bit: source.is64Bit) },
            read: { $0.readProperties(in: source) },
            transform: { $0.info(isClassProperty: isClassProperty) }
        )
    }

    mutating func propertyInfos(
        from listRead: ObjCMetadataReferenceRead<ObjCPropertyList>,
        in source: MachOImage,
        subject: ObjCMetadataTableDiagnostic.MetadataSubject,
        kind: ObjCMetadataTableDiagnostic.MemberKind,
        isClassProperty: Bool
    ) -> [ObjCPropertyInfo] {
        ObjCMetadataTableDiagnosticRecorder.memberValues(
            from: listRead,
            in: source,
            subject: subject,
            kind: kind,
            context: &self,
            entryStride: { $0.expectedEntrySize(is64Bit: source.is64Bit) },
            read: { $0.readProperties(in: source) },
            transform: { $0.info(isClassProperty: isClassProperty) }
        )
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
        return .init(
            value: value,
            diagnostics: context.diagnostics,
            tableDiagnostics: context.tableDiagnostics
        )
    }

    private func _readInfo(
        in machO: MachOFile,
        name knownName: String? = nil,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> ObjCProtocolInfo? {
        let name = knownName ?? mangledName(in: machO)
        let tableSubject = ObjCMetadataTableDiagnostic.MetadataSubject.protocol(
            name: name
        )

        let protocols = referencedProtocolInfos(
            in: machO,
            options: options,
            context: &context
        )

        let classProperties = context.propertyInfos(
            from: readFilePropertyList(field: ._classProperties, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .classProperty,
            isClassProperty: true
        )

        let properties = context.propertyInfos(
            from: readFilePropertyList(field: .instanceProperties, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .instanceProperty,
            isClassProperty: false
        )

        let classMethods = context.methodInfos(
            from: readFileMethodList(field: .classMethods, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .classMethod,
            isClassMethod: true
        )

        let methods = context.methodInfos(
            from: readFileMethodList(field: .instanceMethods, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .instanceMethod,
            isClassMethod: false
        )

        let optionalClassMethods = context.methodInfos(
            from: readFileMethodList(field: .optionalClassMethods, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .optionalClassMethod,
            isClassMethod: true
        )

        let optionalMethods = context.methodInfos(
            from: readFileMethodList(field: .optionalInstanceMethods, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .optionalInstanceMethod,
            isClassMethod: false
        )

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
        return .init(
            value: value,
            diagnostics: context.diagnostics,
            tableDiagnostics: context.tableDiagnostics
        )
    }

    private func _readInfo(
        in machO: MachOImage,
        name knownName: String? = nil,
        options: ObjCProtocolInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> ObjCProtocolInfo? {
        let name = knownName ?? mangledName(in: machO)
        let tableSubject = ObjCMetadataTableDiagnostic.MetadataSubject.protocol(
            name: name
        )

        let protocols = referencedProtocolInfos(
            in: machO,
            options: options,
            context: &context
        )

        let classProperties = context.propertyInfos(
            from: readLoadedPropertyList(field: ._classProperties, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .classProperty,
            isClassProperty: true
        )

        let properties = context.propertyInfos(
            from: readLoadedPropertyList(field: .instanceProperties, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .instanceProperty,
            isClassProperty: false
        )

        let classMethods = context.methodInfos(
            from: readLoadedMethodList(field: .classMethods, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .classMethod,
            isClassMethod: true
        )

        let methods = context.methodInfos(
            from: readLoadedMethodList(field: .instanceMethods, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .instanceMethod,
            isClassMethod: false
        )

        let optionalClassMethods = context.methodInfos(
            from: readLoadedMethodList(field: .optionalClassMethods, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .optionalClassMethod,
            isClassMethod: true
        )

        let optionalMethods = context.methodInfos(
            from: readLoadedMethodList(field: .optionalInstanceMethods, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .optionalInstanceMethod,
            isClassMethod: false
        )

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
            fieldDiagnostics: fieldDiagnostics,
            tableDiagnostics: context.tableDiagnostics
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
        let tableSubject = ObjCMetadataTableDiagnostic.MetadataSubject.class(
            name: name
        )
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
        let ivarEntries = ObjCMetadataTableDiagnosticRecorder.memberValues(
            from: data.readFileIvarList(in: machO),
            in: machO,
            subject: tableSubject,
            kind: .ivar,
            context: &context,
            entryStride: { $0.entrySize },
            read: { $0.readIvars(in: machO) },
            transform: { Optional($0) }
        )
        ivars.reserveCapacity(ivarEntries.count)
        for (index, ivar) in ivarEntries.enumerated() {
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

        // Instance
        let properties: [ObjCPropertyInfo]
        if data.layout.baseProperties & 1 == 1 {
            properties = data
                .propertyListResolutions(in: machO)
                .memberValues(
                    className: name,
                    kind: .instanceProperty,
                    context: &context,
                    tableKind: .instanceProperty,
                    entryStride: { source, list in
                        list.expectedEntrySize(is64Bit: source.is64Bit)
                    },
                    read: { source, list in list.readProperties(in: source) },
                    transform: { $0.info(isClassProperty: false) }
                )
        } else {
            properties = context.propertyInfos(
                from: data.readFilePropertyList(in: machO),
                in: machO,
                subject: tableSubject,
                kind: .instanceProperty,
                isClassProperty: false
            )
        }

        let methods: [ObjCMethodInfo]
        if data.layout.baseMethods & 1 == 1 {
            methods = data
                .methodListResolutions(in: machO)
                .memberValues(
                    className: name,
                    kind: .instanceMethod,
                    context: &context,
                    tableKind: .instanceMethod,
                    entryStride: { source, list in
                        list.expectedEntrySize(is64Bit: source.is64Bit)
                    },
                    read: { source, list in list.readMethods(in: source) },
                    transform: { $0.info(isClassMethod: false) }
                )
        } else {
            methods = context.methodInfos(
                from: data.readFileMethodList(in: machO),
                in: machO,
                subject: tableSubject,
                kind: .instanceMethod,
                isClassMethod: false
            )
        }

        // Meta
        let classProperties: [ObjCPropertyInfo]
        let classMethods: [ObjCMethodInfo]
        if let metaData {
            if metaData.layout.baseProperties & 1 == 1 {
                classProperties = metaData
                    .propertyListResolutions(in: targetMachO)
                    .memberValues(
                        className: name,
                        kind: .classProperty,
                        context: &context,
                        tableKind: .classProperty,
                        entryStride: { source, list in
                            list.expectedEntrySize(is64Bit: source.is64Bit)
                        },
                        read: { source, list in list.readProperties(in: source) },
                        transform: { $0.info(isClassProperty: true) }
                    )
            } else {
                classProperties = context.propertyInfos(
                    from: metaData.readFilePropertyList(in: targetMachO),
                    in: targetMachO,
                    subject: tableSubject,
                    kind: .classProperty,
                    isClassProperty: true
                )
            }
            if metaData.layout.baseMethods & 1 == 1 {
                classMethods = metaData
                    .methodListResolutions(in: targetMachO)
                    .memberValues(
                        className: name,
                        kind: .classMethod,
                        context: &context,
                        tableKind: .classMethod,
                        entryStride: { source, list in
                            list.expectedEntrySize(is64Bit: source.is64Bit)
                        },
                        read: { source, list in list.readMethods(in: source) },
                        transform: { $0.info(isClassMethod: true) }
                    )
            } else {
                classMethods = context.methodInfos(
                    from: metaData.readFileMethodList(in: targetMachO),
                    in: targetMachO,
                    subject: tableSubject,
                    kind: .classMethod,
                    isClassMethod: true
                )
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
            fieldDiagnostics: fieldDiagnostics,
            tableDiagnostics: context.tableDiagnostics
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
        let tableSubject = ObjCMetadataTableDiagnostic.MetadataSubject.class(
            name: name
        )
        let targetMachO: MachOImage
        let meta: Self
        switch readLoadedRelatedClass(field: .isa, in: machO) {
        case .absent:
            return nil
        case let .failure(provenance, reason):
            ObjCMetadataTableDiagnosticRecorder.recordLoadedRelationshipFailure(
                provenance: provenance,
                reason: reason,
                subject: tableSubject,
                role: .metaclass,
                context: &context
            )
            return nil
        case .value(let value):
            (targetMachO, meta) = value
        }

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
        let ivarEntries = ObjCMetadataTableDiagnosticRecorder.memberValues(
            from: data.readLoadedIvarList(in: machO),
            in: machO,
            subject: tableSubject,
            kind: .ivar,
            context: &context,
            entryStride: { $0.entrySize },
            read: { $0.readIvars(in: machO) },
            transform: { Optional($0) }
        )
        ivars.reserveCapacity(ivarEntries.count)
        for (index, ivar) in ivarEntries.enumerated() {
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

        // Instance
        let properties: [ObjCPropertyInfo]
        if data.layout.baseProperties & 1 == 1 {
            properties = data
                .propertyListResolutions(in: machO)
                .memberValues(
                    className: name,
                    kind: .instanceProperty,
                    context: &context,
                    tableKind: .instanceProperty,
                    entryStride: { source, list in
                        list.expectedEntrySize(is64Bit: source.is64Bit)
                    },
                    read: { source, list in list.readProperties(in: source) },
                    transform: { $0.info(isClassProperty: false) }
                )
        } else {
            properties = context.propertyInfos(
                from: data.readLoadedPropertyList(in: machO),
                in: machO,
                subject: tableSubject,
                kind: .instanceProperty,
                isClassProperty: false
            )
        }

        let methods: [ObjCMethodInfo]
        if data.layout.baseMethods & 1 == 1 {
            methods = data
                .methodListResolutions(in: machO)
                .memberValues(
                    className: name,
                    kind: .instanceMethod,
                    context: &context,
                    tableKind: .instanceMethod,
                    entryStride: { source, list in
                        list.expectedEntrySize(is64Bit: source.is64Bit)
                    },
                    read: { source, list in list.readMethods(in: source) },
                    transform: { $0.info(isClassMethod: false) }
                )
        } else {
            methods = context.methodInfos(
                from: data.readLoadedMethodList(in: machO),
                in: machO,
                subject: tableSubject,
                kind: .instanceMethod,
                isClassMethod: false
            )
        }

        // Meta
        let classProperties: [ObjCPropertyInfo]
        let classMethods: [ObjCMethodInfo]
        if let metaData {
            if metaData.layout.baseProperties & 1 == 1 {
                classProperties = metaData
                    .propertyListResolutions(in: targetMachO)
                    .memberValues(
                        className: name,
                        kind: .classProperty,
                        context: &context,
                        tableKind: .classProperty,
                        entryStride: { source, list in
                            list.expectedEntrySize(is64Bit: source.is64Bit)
                        },
                        read: { source, list in list.readProperties(in: source) },
                        transform: { $0.info(isClassProperty: true) }
                    )
            } else {
                classProperties = context.propertyInfos(
                    from: metaData.readLoadedPropertyList(in: targetMachO),
                    in: targetMachO,
                    subject: tableSubject,
                    kind: .classProperty,
                    isClassProperty: true
                )
            }
            if metaData.layout.baseMethods & 1 == 1 {
                classMethods = metaData
                    .methodListResolutions(in: targetMachO)
                    .memberValues(
                        className: name,
                        kind: .classMethod,
                        context: &context,
                        tableKind: .classMethod,
                        entryStride: { source, list in
                            list.expectedEntrySize(is64Bit: source.is64Bit)
                        },
                        read: { source, list in list.readMethods(in: source) },
                        transform: { $0.info(isClassMethod: true) }
                    )
            } else {
                classMethods = context.methodInfos(
                    from: metaData.readLoadedMethodList(in: targetMachO),
                    in: targetMachO,
                    subject: tableSubject,
                    kind: .classMethod,
                    isClassMethod: true
                )
            }
        } else {
            classProperties = []
            classMethods = []
        }

        let superClassName: String?
        switch readLoadedRelatedClass(field: .superclass, in: machO) {
        case .absent:
            superClassName = nil
        case let .failure(provenance, reason):
            ObjCMetadataTableDiagnosticRecorder.recordLoadedRelationshipFailure(
                provenance: provenance,
                reason: reason,
                subject: tableSubject,
                role: .superclass,
                context: &context
            )
            superClassName = nil
        case .value(let value):
            superClassName = loadedRelatedClassName(value)
        }

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

    private func loadedRelatedClassName(
        _ relation: (MachOImage, Self)
    ) -> String? {
        let (machO, cls) = relation
        var data: ClassROData?
        if let direct = cls.classROData(in: machO) {
            data = direct
        }
        if let rw = cls.classRWData(in: machO) {
            if let readOnly = rw.classROData(in: machO) {
                data = readOnly
            }
            if let ext = rw.ext(in: machO),
               let readOnly = ext.classROData(in: machO) {
                data = readOnly
            }
        }
        return data?.name(in: machO)
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
        let categoryName = name(in: machO)
        let targetClassName: String?
        let relationshipFailure: (
            provenance: ObjCMetadataTableDiagnostic.Provenance,
            reason: ObjCMetadataTableDiagnostic.Failure
        )?
        if isCatlist2 {
            switch readLoadedStubClass(in: machO) {
            case .absent, .value:
                relationshipFailure = nil
            case let .failure(provenance, reason):
                relationshipFailure = (provenance, reason)
            }
            targetClassName = categorySymbolClassName(in: machO)
        } else {
            switch readLoadedClass(in: machO) {
            case .absent:
                targetClassName = categorySymbolClassName(in: machO)
                relationshipFailure = nil
            case let .failure(provenance, reason):
                targetClassName = categorySymbolClassName(in: machO)
                relationshipFailure = (provenance, reason)
            case .value(let value):
                targetClassName = loadedCategoryClassName(value)
                relationshipFailure = nil
            }
        }
        let tableSubject = ObjCMetadataTableDiagnostic.MetadataSubject.category(
            className: targetClassName ?? "<unknown>",
            name: categoryName ?? "<unknown>"
        )
        var context = ObjCProtocolTraversalContext(
            subject: .category(
                className: targetClassName ?? "<unknown>",
                name: categoryName ?? "<unknown>"
            )
        )
        if let relationshipFailure {
            ObjCMetadataTableDiagnosticRecorder.recordLoadedRelationshipFailure(
                provenance: relationshipFailure.provenance,
                reason: relationshipFailure.reason,
                subject: tableSubject,
                role: isCatlist2 ? .categoryStubClass : .categoryClass,
                context: &context
            )
        }
        let value = _readInfo(
            in: machO,
            name: categoryName,
            className: targetClassName,
            options: options,
            context: &context
        )
        return .init(
            value: value,
            diagnostics: context.diagnostics,
            tableDiagnostics: context.tableDiagnostics
        )
    }

    private func _readInfo(
        in machO: MachOImage,
        name: String?,
        className: String?,
        options: ObjCInfoOptions,
        context: inout ObjCProtocolTraversalContext
    ) -> ObjCCategoryInfo? {
        guard let name, let className else {
            return nil
        }
        let tableSubject = ObjCMetadataTableDiagnostic.MetadataSubject.category(
            className: className,
            name: name
        )

        let protocols = protocolListResolution(in: machO)
            .referencedProtocolInfos(
                options: options.protocolInfoOptions,
                context: &context
            )

        // Instance
        let properties = context.propertyInfos(
            from: readLoadedPropertyList(at: layout.instanceProperties, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .instanceProperty,
            isClassProperty: false
        )

        let methods = context.methodInfos(
            from: readLoadedMethodList(at: layout.instanceMethods, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .instanceMethod,
            isClassMethod: false
        )

        // Meta
        let classProperties = context.propertyInfos(
            from: readLoadedPropertyList(at: layout._classProperties, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .classProperty,
            isClassProperty: true
        )

        let classMethods = context.methodInfos(
            from: readLoadedMethodList(at: layout.classMethods, in: machO),
            in: machO,
            subject: tableSubject,
            kind: .classMethod,
            isClassMethod: true
        )

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
        return .init(
            value: value,
            diagnostics: context.diagnostics,
            tableDiagnostics: context.tableDiagnostics
        )
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
        let tableSubject = ObjCMetadataTableDiagnostic.MetadataSubject.category(
            className: className,
            name: name
        )

        let protocols = protocolListResolution(in: machO)
            .referencedProtocolInfos(
                options: options.protocolInfoOptions,
                context: &context
            )

        // Instance
        let properties = context.propertyInfos(
            from: readFilePropertyList(
                at: layout.instanceProperties,
                field: .instanceProperties,
                in: machO
            ),
            in: machO,
            subject: tableSubject,
            kind: .instanceProperty,
            isClassProperty: false
        )

        let methods = context.methodInfos(
            from: readFileMethodList(
                at: layout.instanceMethods,
                field: .instanceMethods,
                in: machO
            ),
            in: machO,
            subject: tableSubject,
            kind: .instanceMethod,
            isClassMethod: false
        )

        // Meta
        let classProperties = context.propertyInfos(
            from: readFilePropertyList(
                at: layout._classProperties,
                field: ._classProperties,
                in: machO
            ),
            in: machO,
            subject: tableSubject,
            kind: .classProperty,
            isClassProperty: true
        )

        let classMethods = context.methodInfos(
            from: readFileMethodList(
                at: layout.classMethods,
                field: .classMethods,
                in: machO
            ),
            in: machO,
            subject: tableSubject,
            kind: .classMethod,
            isClassMethod: true
        )

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

private extension ObjCCategoryProtocol {
    func categorySymbolClassName(in machO: MachOImage) -> String? {
        guard let section = machO.sectionNumber(for: .__objc_const),
              let symbol = machO.symbol(for: offset, inSection: section),
              symbol.name.starts(with: "__CATEGORY_") else {
            return nil
        }
        return symbol.name
            .replacingOccurrences(of: "__CATEGORY_", with: "")
            .components(separatedBy: "_$_")
            .first
    }

    func loadedCategoryClassName(
        _ relation: (MachOImage, ObjCClass)
    ) -> String? {
        let (machO, cls) = relation
        var data: ObjCClass.ClassROData?
        if let direct = cls.classROData(in: machO) {
            data = direct
        }
        if let rw = cls.classRWData(in: machO) {
            if let readOnly = rw.classROData(in: machO) {
                data = readOnly
            }
            if let ext = rw.ext(in: machO),
               let readOnly = ext.classROData(in: machO) {
                data = readOnly
            }
        }
        return data?.name(in: machO)
    }
}

extension ObjCRelativeListResolution where
    Failure == ObjCRelativeListFailure,
    Source: ObjCMetadataTableSource,
    List: EntrySizeListProtocol
{
    func memberValues<Value, Output>(
        className: String,
        kind: ObjCMemberListDiagnostic.Kind,
        context: inout ObjCProtocolTraversalContext,
        tableKind: ObjCMetadataTableDiagnostic.MemberKind,
        entryStride: (Source, List) -> Int,
        read: (Source, List) -> ObjCMemberTableReadOutcome<Value>,
        transform: (Value) -> Output?
    ) -> [Output] {
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
            var values: [Output] = []
            for entry in entries {
                switch entry {
                case .failure(let failure):
                    context.record(
                        memberListFailure: failure,
                        className: className,
                        kind: kind
                    )
                case let .resolved(source, list):
                    values.append(
                        contentsOf: ObjCMetadataTableDiagnosticRecorder.memberValues(
                            from: read(source, list),
                            list: list,
                            in: source,
                            subject: .class(name: className),
                            kind: tableKind,
                            context: &context,
                            entryStride: entryStride(source, list),
                            transform: transform
                        )
                    )
                }
            }
            return values
        }
    }
}
