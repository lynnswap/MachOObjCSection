import Foundation
import MachOKit
import MachOObjCSection
import ObjCDeclarationRendering
import ObjCDump
import ObjCIndexing
import Semantic

/// Turns an indexed image into rendered Objective-C declarations.
///
/// This is the layer where ``ObjCGenerationOptions`` actually bites: the strip
/// switches are applied here, by building a filtered copy of the metadata
/// before handing it to the renderer, while the comment switches are passed
/// through to the renderer untouched.
///
/// ```swift
/// let indexer = ObjCInterfaceIndexer(machO: image, imagePath: image.imagePath)
/// try await indexer.prepare()
///
/// let builder = ObjCInterfaceBuilder(indexer: indexer, machO: image)
/// let declaration = builder.classInterface(named: "NSString", options: .default)
/// ```
public struct ObjCInterfaceBuilder {
    private let indexer: ObjCInterfaceIndexer
    private let machO: MachOImage

    public init(indexer: ObjCInterfaceIndexer, machO: MachOImage) {
        self.indexer = indexer
        self.machO = machO
    }

    // MARK: - Rendering Context

    /// Builds the renderer context, wiring up the struct/union expansion rule:
    /// a named struct that this image also defines separately is referenced by
    /// name rather than expanded inline, so the declaration does not repeat a
    /// definition the caller can look up on its own.
    private func makeContext(
        options: ObjCGenerationOptions,
        cTypeReplacements: [ObjCPrimitiveTypePattern: String],
        ivarOffsetCommentBuilder: (@Sendable (Int) -> String)?
    ) -> ObjCRenderingContext {
        let indexer = self.indexer
        return ObjCRenderingContext(
            machO: machO,
            options: options,
            cTypeReplacements: cTypeReplacements,
            ivarOffsetCommentBuilder: ivarOffsetCommentBuilder,
            isExpandHandler: { name, isStruct in
                guard let name else { return true }
                return isStruct
                    ? !indexer.containsStruct(named: name)
                    : !indexer.containsUnion(named: name)
            }
        )
    }

    // MARK: - Class

    /// The rendered `@interface` for the class named `name`, or `nil` when the
    /// indexed image has no such class.
    public func classInterface(
        named name: String,
        options: ObjCGenerationOptions = .default,
        cTypeReplacements: [ObjCPrimitiveTypePattern: String] = [:],
        ivarOffsetCommentBuilder: (@Sendable (Int) -> String)? = nil
    ) -> SemanticString? {
        guard let classGroup = indexer.classGroup(forName: name),
              let currentClassInfo = classGroup.info.first
        else { return nil }

        let context = makeContext(
            options: options,
            cTypeReplacements: cTypeReplacements,
            ivarOffsetCommentBuilder: ivarOffsetCommentBuilder
        )

        let superclassInfos = classGroup.info.dropFirst()
        var needsStripClassProperties: Set<String> = []
        var needsStripProperties: Set<String> = []
        var needsStripClassMethods: Set<String> = []
        var needsStripMethods: Set<String> = []
        var needsStripIvars: Set<String> = []

        if options.stripCtorMethod {
            needsStripMethods.insert(".cxx_construct")
        }

        if options.stripDtorMethod {
            needsStripMethods.insert(".cxx_destruct")
        }

        if options.stripOverrides {
            for superclassInfo in superclassInfos {
                needsStripClassProperties.insert(contentsOf: superclassInfo.classProperties.map(\.name))
                needsStripProperties.insert(contentsOf: superclassInfo.properties.map(\.name))
                needsStripClassMethods.insert(contentsOf: superclassInfo.classMethods.map(\.name))
                needsStripMethods.insert(contentsOf: superclassInfo.methods.map(\.name))
            }
        }

        if options.stripProtocolConformance {
            for protocolInfo in protocolHierarchy(currentClassInfo.protocols) {
                needsStripClassProperties.insert(contentsOf: (protocolInfo.classProperties + protocolInfo.optionalClassProperties).map(\.name))
                needsStripProperties.insert(contentsOf: (protocolInfo.properties + protocolInfo.optionalProperties).map(\.name))
                needsStripClassMethods.insert(contentsOf: (protocolInfo.classMethods + protocolInfo.optionalClassMethods).map(\.name))
                needsStripMethods.insert(contentsOf: (protocolInfo.methods + protocolInfo.optionalMethods).map(\.name))
            }
        }

        if options.stripSynthesizedIvars || options.stripSynthesizedMethods {
            var needsStripIvarNames: Set<String> = []

            for property in currentClassInfo.properties + currentClassInfo.classProperties {
                if options.stripSynthesizedMethods {
                    collectAccessorSelectors(
                        of: property,
                        intoClassMethods: &needsStripClassMethods,
                        intoMethods: &needsStripMethods
                    )
                }

                if options.stripSynthesizedIvars, !property.isClassProperty {
                    if let ivar = property.ivar {
                        needsStripIvarNames.insert(ivar)
                    }
                }
            }

            if options.stripSynthesizedIvars {
                for ivar in currentClassInfo.ivars where needsStripIvarNames.contains(ivar.name) {
                    needsStripIvars.insert(ivar.name)
                }
            }
        }

        let finalClassInfo = ObjCClassInfo(
            name: currentClassInfo.name,
            version: currentClassInfo.version,
            imageName: currentClassInfo.imageName,
            instanceSize: currentClassInfo.instanceSize,
            superClassName: currentClassInfo.superClassName,
            protocols: options.stripProtocolConformance ? [] : currentClassInfo.protocols,
            ivars: currentClassInfo.ivars.removingAll { needsStripIvars.contains($0.name) },
            classProperties: currentClassInfo.classProperties.removingAll { needsStripClassProperties.contains($0.name) },
            properties: currentClassInfo.properties.removingAll { needsStripProperties.contains($0.name) },
            classMethods: currentClassInfo.classMethods.removingAll { needsStripClassMethods.contains($0.name) },
            methods: currentClassInfo.methods.removingAll { needsStripMethods.contains($0.name) }
        )

        // IMP addresses are collected from the *unfiltered* metadata so that a
        // stripped accessor still contributes its address to the property it
        // belongs to.
        if options.addPropertyAccessorAddressComments {
            for method in currentClassInfo.methods where method.imp != 0 {
                context.methodIMPs[method.name] = method.imp
            }
            for method in currentClassInfo.classMethods where method.imp != 0 {
                context.classMethodIMPs[method.name] = method.imp
            }
        }

        return finalClassInfo.semanticString(using: context)
    }

    // MARK: - Protocol

    /// The rendered `@protocol` for the protocol named `name`, or `nil` when
    /// the indexed image has no such protocol.
    public func protocolInterface(
        named name: String,
        options: ObjCGenerationOptions = .default,
        cTypeReplacements: [ObjCPrimitiveTypePattern: String] = [:],
        ivarOffsetCommentBuilder: (@Sendable (Int) -> String)? = nil
    ) -> SemanticString? {
        guard let currentProtocolInfo = indexer.protocolGroup(forName: name)?.info else { return nil }

        let context = makeContext(
            options: options,
            cTypeReplacements: cTypeReplacements,
            ivarOffsetCommentBuilder: ivarOffsetCommentBuilder
        )

        var needsStripClassProperties: Set<String> = []
        var needsStripClassMethods: Set<String> = []
        var needsStripProperties: Set<String> = []
        var needsStripMethods: Set<String> = []

        if options.stripCtorMethod {
            needsStripMethods.insert(".cxx_construct")
        }

        if options.stripDtorMethod {
            needsStripMethods.insert(".cxx_destruct")
        }

        if options.stripProtocolConformance {
            for protocolInfo in protocolHierarchy(currentProtocolInfo.protocols) {
                needsStripClassProperties.insert(contentsOf: protocolInfo.classProperties.map(\.name))
                needsStripProperties.insert(contentsOf: protocolInfo.properties.map(\.name))
                needsStripClassMethods.insert(contentsOf: protocolInfo.classMethods.map(\.name))
                needsStripMethods.insert(contentsOf: protocolInfo.methods.map(\.name))

                needsStripClassProperties.insert(contentsOf: protocolInfo.optionalClassProperties.map(\.name))
                needsStripProperties.insert(contentsOf: protocolInfo.optionalProperties.map(\.name))
                needsStripClassMethods.insert(contentsOf: protocolInfo.optionalClassMethods.map(\.name))
                needsStripMethods.insert(contentsOf: protocolInfo.optionalMethods.map(\.name))
            }
        }

        if options.stripSynthesizedMethods {
            let allProperties = currentProtocolInfo.properties
                + currentProtocolInfo.classProperties
                + currentProtocolInfo.optionalProperties
                + currentProtocolInfo.optionalClassProperties
            for property in allProperties {
                collectAccessorSelectors(
                    of: property,
                    intoClassMethods: &needsStripClassMethods,
                    intoMethods: &needsStripMethods
                )
            }
        }

        let finalProtocolInfo = ObjCProtocolInfo(
            name: currentProtocolInfo.name,
            protocols: options.stripProtocolConformance ? [] : currentProtocolInfo.protocols,
            classProperties: currentProtocolInfo.classProperties.removingAll { needsStripClassProperties.contains($0.name) },
            properties: currentProtocolInfo.properties.removingAll { needsStripProperties.contains($0.name) },
            classMethods: currentProtocolInfo.classMethods.removingAll { needsStripClassMethods.contains($0.name) },
            methods: currentProtocolInfo.methods.removingAll { needsStripMethods.contains($0.name) },
            optionalClassProperties: currentProtocolInfo.optionalClassProperties.removingAll { needsStripClassProperties.contains($0.name) },
            optionalProperties: currentProtocolInfo.optionalProperties.removingAll { needsStripProperties.contains($0.name) },
            optionalClassMethods: currentProtocolInfo.optionalClassMethods.removingAll { needsStripClassMethods.contains($0.name) },
            optionalMethods: currentProtocolInfo.optionalMethods.removingAll { needsStripMethods.contains($0.name) }
        )

        return finalProtocolInfo.semanticString(using: context)
    }

    // MARK: - Category

    /// The rendered `@interface` for the category identified by `uniqueName`
    /// (`ClassName(CategoryName)`), or `nil` when the indexed image has no
    /// such category.
    ///
    /// Categories carry no strip switches of their own — the switches all
    /// describe class or protocol members — so only the comment options apply.
    public func categoryInterface(
        uniqueName: String,
        options: ObjCGenerationOptions = .default,
        cTypeReplacements: [ObjCPrimitiveTypePattern: String] = [:],
        ivarOffsetCommentBuilder: (@Sendable (Int) -> String)? = nil
    ) -> SemanticString? {
        guard let categoryInfo = indexer.categoryGroup(forName: uniqueName)?.info else { return nil }

        let context = makeContext(
            options: options,
            cTypeReplacements: cTypeReplacements,
            ivarOffsetCommentBuilder: ivarOffsetCommentBuilder
        )

        if options.addPropertyAccessorAddressComments {
            for method in categoryInfo.methods where method.imp != 0 {
                context.methodIMPs[method.name] = method.imp
            }
            for method in categoryInfo.classMethods where method.imp != 0 {
                context.classMethodIMPs[method.name] = method.imp
            }
        }

        return categoryInfo.semanticString(using: context)
    }

    // MARK: - C Struct / Union

    /// The rendered definition of the C `struct` named `name`, or `nil` when
    /// the indexed image's type encodings never mentioned it.
    public func structInterface(
        named name: String,
        options: ObjCGenerationOptions = .default,
        cTypeReplacements: [ObjCPrimitiveTypePattern: String] = [:],
        ivarOffsetCommentBuilder: (@Sendable (Int) -> String)? = nil
    ) -> SemanticString? {
        indexer.structSemanticString(
            forName: name,
            context: makeContext(
                options: options,
                cTypeReplacements: cTypeReplacements,
                ivarOffsetCommentBuilder: ivarOffsetCommentBuilder
            )
        )
    }

    /// The rendered definition of the C `union` named `name`, or `nil` when
    /// the indexed image's type encodings never mentioned it.
    public func unionInterface(
        named name: String,
        options: ObjCGenerationOptions = .default,
        cTypeReplacements: [ObjCPrimitiveTypePattern: String] = [:],
        ivarOffsetCommentBuilder: (@Sendable (Int) -> String)? = nil
    ) -> SemanticString? {
        indexer.unionSemanticString(
            forName: name,
            context: makeContext(
                options: options,
                cTypeReplacements: cTypeReplacements,
                ivarOffsetCommentBuilder: ivarOffsetCommentBuilder
            )
        )
    }

    // MARK: - Shared Stripping

    func protocolHierarchy(_ roots: [ObjCProtocolInfo]) -> [ObjCProtocolInfo] {
        var pending = Array(roots.reversed())
        var visited: Set<String> = []
        var result: [ObjCProtocolInfo] = []
        while let current = pending.popLast() {
            guard visited.insert(current.name).inserted else { continue }
            result.append(current)
            pending.append(contentsOf: current.protocols.reversed())
        }
        return result
    }


    /// Records the selectors the compiler would synthesize for `property`, so
    /// that `stripSynthesizedMethods` can remove them.
    ///
    /// A property contributes its getter (its own name unless `G` overrides
    /// it) and, unless read-only in practice, a `setName:` setter (unless `S`
    /// overrides it).
    func collectAccessorSelectors(
        of property: ObjCPropertyInfo,
        intoClassMethods classMethods: inout Set<String>,
        intoMethods methods: inout Set<String>
    ) {
        let propertyName = property.name

        let getterName = property.customGetter ?? propertyName
        if property.isClassProperty {
            classMethods.insert(getterName)
        } else {
            methods.insert(getterName)
        }

        // The trailing colon is not cosmetic: these names are matched against
        // `ObjCMethodInfo.name`, which holds the full selector. A setter takes
        // an argument, so its selector is `setFoo:` — building `setFoo` here
        // both failed to strip the real accessor and risked stripping an
        // unrelated zero-argument method that happened to be named that way.
        // `customSetter` already carries its own colon, as it comes straight
        // from the property's `S` attribute.
        guard !property.attributes.contains(.readonly) else { return }
        let setterName = property.customSetter ?? "set\(propertyName.uppercasedFirst):"
        if property.isClassProperty {
            classMethods.insert(setterName)
        } else {
            methods.insert(setterName)
        }
    }
}
