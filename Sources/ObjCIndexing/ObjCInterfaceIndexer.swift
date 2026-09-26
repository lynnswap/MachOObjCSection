import Foundation
import MachOKit
import MachOObjCSection
import ObjCDeclarationRendering
import ObjCDump
import ObjCMetadataSource
import ObjCTypeDecodeKit
import Semantic
import SwiftStdlibToolbox

/// Per-image Objective-C interface index: the parsed data store for one
/// Mach-O binary's classes, protocols, categories and C struct/union
/// definitions.
///
/// Construct it with a Mach-O, call ``prepare()`` once, then query. All the
/// raw `MachOObjCSection` / `ObjCDump` extraction happens inside `prepare()`,
/// so callers deal only in names and the grouped info types.
///
/// ## File mode and image mode
///
/// `MachO` is either a `MachOFile` — a binary read off disk, of any
/// architecture or platform, inside a dyld shared cache or standalone — or a
/// `MachOImage`, an image already mapped into this process. The parameter is
/// inferred from the `machO` argument at `init`, so call sites written before
/// this type was generic keep compiling unchanged.
///
/// The two modes are not perfectly interchangeable, and the difference shows
/// up in superclass chains: file mode can only follow a superclass into
/// another binary of the same dyld shared cache, so for a standalone file the
/// chain stops at the first superclass defined elsewhere. See
/// ``ObjCMetadataSource/objcSuperClass(of:)``.
///
/// This index answers "what is in this binary". It deliberately does not
/// answer "what subclasses what" — inheritance and protocol adoption are
/// broadcast through ``ObjCIndexingEvent`` as the walk discovers them, and
/// accumulating them is the caller's business. Building those reverse tables
/// eagerly costs time and memory proportional to the binary's class and
/// category count, which every caller paid whether or not it wanted them.
///
/// `@unchecked Sendable`: the stored `ObjCDump` / `MachOObjCSection` values are
/// not themselves `Sendable`, but `machO` is an immutable `let` and every
/// dictionary is mutex-guarded and immutable once `prepare()` returns.
public final class ObjCInterfaceIndexer<MachO: ObjCMetadataSource>: @unchecked Sendable {

    // MARK: - Group Types

    /// A class paired with its own `ObjCClassInfo` plus the `ObjCClassInfo`
    /// of every superclass (resolved across images), `info.first` being the
    /// class itself.
    public typealias ObjCClassGroup = (objcClass: any ObjCClassProtocol, info: [ObjCClassInfo])

    public typealias ObjCProtocolGroup = (objcProtocol: any ObjCProtocolProtocol, info: ObjCProtocolInfo)

    public typealias ObjCCategoryGroup = (objcCategory: any ObjCCategoryProtocol, info: ObjCCategoryInfo)

    // MARK: - C Struct / Union

    /// A C `struct` / `union` definition harvested from the ivar / method /
    /// property type encodings of the image's ObjC metadata.
    struct CStructOrUnion: Hashable {
        let name: String

        let fields: [ObjCField]

        var hasBitFieldOnly: Bool {
            fields.allSatisfy { $0.bitWidth != nil }
        }

        var numberOfHasNameFields: Int {
            fields.count { $0.name != nil }
        }

        @SemanticStringBuilder
        func semanticString(isStruct: Bool, context: ObjCRenderingContext<MachO>) -> SemanticString {
            Keyword(isStruct ? "struct" : "union")
            Space()
            TypeName(kind: .other, name)
            Joined {
                MemberList(level: 1) {
                    for (index, field) in fields.enumerated() {
                        field.semanticString(fallbackName: "x\(index)", level: 1, context: context)
                    }
                }
            } prefix: {
                " {"
            } suffix: {
                Indent(level: 0)
                "}"
            }
        }
    }

    // MARK: - Indexed Image

    /// The Mach-O this indexer parses. Bound at `init` and never
    /// reassigned; `prepare()` reads it to populate the data store below.
    private let machO: MachO

    /// The image path recorded into every emitted event. Passed
    /// explicitly rather than derived from `machO.imagePath`: an indexer may
    /// be constructed from a path that differs from the resolved image own
    /// path — e.g. in Debug builds a main-executable stub path resolves to a
    /// sibling `.debug.dylib` image whose `imagePath` is not the stub one.
    private let imagePath: String

    // MARK: - Interface Data Store

    // `@Mutex` (FrameworkToolbox) expands each store below into an
    // `os_unfair_lock`-backed box named `_classes` and so on, plus get / set /
    // `_modify` accessors. `_modify` is why the macro is used rather than a
    // hand-written box: it makes `classes[name] = group` one read-modify-write
    // under a single lock acquisition, where a get/set-only property would
    // release the lock in between.
    //
    // That lock is not reentrant, so a `_modify` on one of these must not
    // reach back into the same property — every access here is a plain
    // read or write of one key.

    @Mutex
    private var classes: [String: ObjCClassGroup] = [:]

    @Mutex
    private var protocols: [String: ObjCProtocolGroup] = [:]

    @Mutex
    private var categories: [String: ObjCCategoryGroup] = [:]

    @Mutex
    private var structs: [String: CStructOrUnion] = [:]

    @Mutex
    private var unions: [String: CStructOrUnion] = [:]

    private let eventHandler: (@Sendable (ObjCIndexingEvent) -> Void)?

    /// Creates an indexer over `machO`, recording `imagePath` into every event
    /// it emits.
    ///
    /// - Parameters:
    ///   - machO: The Mach-O to parse — a file on disk or a loaded image. Read
    ///     during ``prepare()``, never after.
    ///   - imagePath: The path recorded into emitted events. Passed explicitly
    ///     rather than derived from the image, because the two can legitimately
    ///     differ — see the `imagePath` stored property.
    ///   - eventHandler: Receives progress and relationship events during
    ///     ``prepare()``.
    ///
    ///     **Relationship data is delivered only through this handler.** An
    ///     indexer built without one keeps no record of inheritance or protocol
    ///     adoption in any form — that is this library's boundary, not a
    ///     degraded mode. A caller that needs relationships must install the
    ///     handler here, at construction; there is no way to attach one after
    ///     ``prepare()`` and recover what was discovered. Passing `nil` while
    ///     expecting relationship data fails silently: the code compiles, the
    ///     walk runs, and the relationships are simply gone.
    ///
    ///     The handler must tolerate being called from any execution context.
    ///     Today the walk is single-threaded and the handler runs synchronously
    ///     on `prepare()`'s own context, but that is the current implementation
    ///     rather than a promise — the parameter is `@Sendable` precisely so the
    ///     walk can be parallelised later. Synchronise your own state; do not
    ///     drop a lock because today's walk happens not to need it.
    public init(
        machO: MachO,
        imagePath: String,
        eventHandler: (@Sendable (ObjCIndexingEvent) -> Void)? = nil
    ) {
        self.machO = machO
        self.imagePath = imagePath
        self.eventHandler = eventHandler
    }

    // MARK: - Preparation

    /// Parse this indexer's Mach-O image (`machO`, bound at `init`) into the
    /// data store: every class / protocol / category, plus the C struct /
    /// union definitions harvested from their type encodings.
    ///
    /// Call once after construction, after which the store is immutable.
    ///
    /// Progress and relationship events are delivered to the `eventHandler`
    /// supplied at `init`, as the walk discovers them. Three properties of
    /// that stream are worth relying on — and one is worth not relying on:
    ///
    /// - **Emission order is deterministic.** For one image and one version of
    ///   this library, two runs emit exactly the same sequence. Every
    ///   class-phase event precedes every category-phase event; within the
    ///   class phase classes follow the `__objc_classlist` walk, each emitting
    ///   its `subclassIndexed` before its `conformanceIndexed` events in
    ///   declaration order; the category phase walks its list the same way.
    ///   Accumulating the stream in arrival order therefore reproduces the
    ///   binary's declaration order, which is what this library's own reverse
    ///   tables used to guarantee. Changing this order is a breaking change.
    ///
    /// - **There is no idempotence guard.** Calling this twice walks the image
    ///   twice and replays the whole event stream. The parsed store is
    ///   overwritten wholesale so it survives that, but a consumer accumulating
    ///   events will see every relationship a second time. Deduplicate, or
    ///   call this once per indexer.
    ///
    /// - **Relationship data only exists while this runs.** Nothing is retained
    ///   afterwards, so a consumer's tables are being filled *during* this
    ///   call, not sitting ready before it. Queries against them belong after
    ///   this returns.
    ///
    /// - **The handler's execution context is not promised.** See the
    ///   `eventHandler` parameter of ``init(machO:imagePath:eventHandler:)``.
    public func prepare() async throws {
        var classByName: [String: ObjCClassGroup] = [:]
        var protocolByName: [String: ObjCProtocolGroup] = [:]
        var categoryByName: [String: ObjCCategoryGroup] = [:]
        var structsByName: [String: CStructOrUnion] = [:]
        var unionsByName: [String: CStructOrUnion] = [:]
        var classInfoCache: [String: ObjCClassInfo] = [:]

        func setObjCType(_ type: ObjCType) {
            Self.collectTypes(type, structsByName: &structsByName, unionsByName: &unionsByName)
        }

        func setObjCTypeFromMethods(_ methods: [ObjCMethodInfo]) {
            for method in methods {
                if let returnType = method.returnType {
                    setObjCType(returnType)
                }

                if let argumentInfos = method.argumentInfos {
                    for argumentInfo in argumentInfos {
                        setObjCType(argumentInfo.type)
                    }
                }
            }
        }

        func setObjCTypeFromProperties(_ properties: [ObjCPropertyInfo]) {
            for property in properties {
                for attribute in property.attributes {
                    if let type = attribute.type {
                        setObjCType(type)
                    }
                }
            }
        }

        let objcClasses: [any ObjCClassProtocol] = machO.objc.classes64.orEmpty + machO.objc.classes32.orEmpty + machO.objc.nonLazyClasses64.orEmpty + machO.objc.nonLazyClasses32.orEmpty

        // One-shot progress marker so the loading indicator can surface
        // "Indexing Objective-C subclasses…" before the per-class loop
        // starts pushing `.loadingObjCClasses` updates. Inheritance and
        // protocol-adoption events are emitted inline below — every class in
        // `__objc_classlist` (including Swift-derived ones via the same
        // record format) is reported as we walk the list.
        eventHandler?(ObjCIndexingEvent.progress(
            phase: .indexingSubclasses,
            itemDescription: "",
            currentCount: 0,
            totalCount: objcClasses.count
        ))

        for objcClass in objcClasses {
            let objcClassGroup: ObjCClassGroup = (objcClass, infoWithSuperclasses(class: objcClass, in: machO, cache: &classInfoCache))
            guard let objcClassInfo = objcClassGroup.info.first else { continue }
            classByName[objcClassInfo.name] = objcClassGroup
            eventHandler?(ObjCIndexingEvent.progress(
                phase: .loadingClasses,
                itemDescription: objcClassInfo.name,
                currentCount: classByName.count,
                totalCount: objcClasses.count
            ))

            // Report the relationships this record carries. The class info is
            // already extracted — `superClassName` was resolved through
            // MachO's bind/rebase walking by `infoWithSuperclasses`, so we
            // don't redo that work here. `isSwiftStable` comes off the raw
            // class_t record itself, so consumers can label bridged classes as
            // Swift without any string-name bridging.
            //
            // Superclass first, then adopted protocols in declaration order:
            // consumers accumulating in arrival order depend on this, see
            // `prepare()`'s ordering guarantee.
            if let superClassName = objcClassInfo.superClassName, !superClassName.isEmpty {
                eventHandler?(
                    ObjCIndexingEvent.subclassIndexed(
                        className: objcClassInfo.name,
                        superclass: superClassName,
                        imagePath: imagePath,
                        isSwiftStable: objcClass.isSwiftStable
                    )
                )
            }

            for adoptedProtocol in objcClassInfo.protocols {
                eventHandler?(
                    ObjCIndexingEvent.conformanceIndexed(
                        className: objcClassInfo.name,
                        protocolName: adoptedProtocol.name,
                        imagePath: imagePath,
                        isSwiftStable: objcClass.isSwiftStable
                    )
                )
            }

            for ivar in objcClassInfo.ivars {
                if let type = ivar.type {
                    setObjCType(type)
                }
            }

            setObjCTypeFromProperties(objcClassInfo.properties + objcClassInfo.classProperties)
            setObjCTypeFromMethods(objcClassInfo.methods + objcClassInfo.classMethods)
        }

        // `__objc_protolist` carries a full `protocol_t` record for *every*
        // protocol whose `@protocol` declaration was in scope at compile
        // time — including ones merely imported from dependencies (`NSObject`,
        // `NSCopying`, …), not just this image's own. We list all of them:
        // there is no authoritative "defining image" recorded for a protocol
        // (unlike classes, which are emitted exactly once in their own image's
        // `__objc_classlist`), so every attempt at attributing ownership is a
        // heuristic that can silently *drop* an image's real protocols. A
        // previous dependency-closure heuristic did exactly that — see
        // `Documentations/ResolvedIssues/2026-08-05-objc-protocol-ownership-filter.md`.
        let objcProtocols: [any ObjCProtocolProtocol] = machO.objc.protocols64.orEmpty + machO.objc.protocols32.orEmpty

        for objcProtocol in objcProtocols {
            guard let objcProtocolInfo = machO.objcProtocolInfo(of: objcProtocol) else { continue }
            protocolByName[objcProtocolInfo.name] = (objcProtocol, objcProtocolInfo)
            eventHandler?(ObjCIndexingEvent.progress(
                phase: .loadingProtocols,
                itemDescription: objcProtocolInfo.name,
                currentCount: protocolByName.count,
                totalCount: objcProtocols.count
            ))
            setObjCTypeFromProperties(objcProtocolInfo.properties + objcProtocolInfo.classProperties)
            setObjCTypeFromMethods(objcProtocolInfo.methods + objcProtocolInfo.classMethods)
        }

        var objcCategories: [any ObjCCategoryProtocol] = []

        objcCategories.append(contentsOf: machO.objc.categories64.orEmpty)
        objcCategories.append(contentsOf: machO.objc.categories32.orEmpty)
        objcCategories.append(contentsOf: machO.objc.nonLazyCategories64.orEmpty)
        objcCategories.append(contentsOf: machO.objc.nonLazyCategories32.orEmpty)
        objcCategories.append(contentsOf: machO.objc.categories2_64.orEmpty)
        objcCategories.append(contentsOf: machO.objc.categories2_32.orEmpty)

        // One-shot marker that conformance indexing starts; each category
        // extends the conformer set of its target class for every protocol
        // the category adopts.
        eventHandler?(ObjCIndexingEvent.progress(
            phase: .indexingConformances,
            itemDescription: "",
            currentCount: 0,
            totalCount: objcCategories.count
        ))

        for objcCategory in objcCategories {
            guard let objcCategoryInfo = machO.objcCategoryInfo(of: objcCategory) else { continue }
            categoryByName[objcCategoryInfo.uniqueName] = (objcCategory, objcCategoryInfo)
            eventHandler?(ObjCIndexingEvent.progress(
                phase: .loadingCategories,
                itemDescription: objcCategoryInfo.uniqueName,
                currentCount: categoryByName.count,
                totalCount: objcCategories.count
            ))
            setObjCTypeFromProperties(objcCategoryInfo.properties + objcCategoryInfo.classProperties)
            setObjCTypeFromMethods(objcCategoryInfo.methods + objcCategoryInfo.classMethods)

            // Report the conformances this category contributes. Categories
            // extend the conformer set of their target class: every protocol
            // the category adopts makes the target a conformer.
            //
            // The target's Swift stable flag is read from the resolved class
            // record — that resolution crosses image boundaries, since a
            // category's target usually lives in another binary — so category
            // adoptions on bridged classes (e.g. NSError extending Swift error
            // protocols) carry `targetIsSwiftStable == true` and can be
            // surfaced as Swift. An unresolvable target reports `false`,
            // indistinguishable from a resolved non-Swift class.
            //
            // `imagePath` here is *this* image, the one declaring the
            // category — not the image declaring the target class. The two
            // differ for the common case of extending another framework's
            // class. Consumers have always seen it this way; changing it would
            // be a behaviour change, not a fix.
            let targetIsSwiftStable: Bool
            if let (_, targetClass) = machO.objcCategoryTargetClass(of: objcCategory) {
                targetIsSwiftStable = targetClass.isSwiftStable
            } else {
                targetIsSwiftStable = false
            }

            for adoptedProtocol in objcCategoryInfo.protocols {
                eventHandler?(
                    ObjCIndexingEvent.categoryConformanceIndexed(
                        targetClassName: objcCategoryInfo.className,
                        protocolName: adoptedProtocol.name,
                        imagePath: imagePath,
                        targetIsSwiftStable: targetIsSwiftStable
                    )
                )
            }
        }

        classes = classByName
        protocols = protocolByName
        categories = categoryByName
        structs = structsByName
        unions = unionsByName
    }

    static func collectTypes(
        _ type: ObjCType,
        structsByName: inout [String: CStructOrUnion],
        unionsByName: inout [String: CStructOrUnion]
    ) {
        switch type {
        case .struct(let name, let fields):
            for field in fields ?? [] { collectTypes(field.type, structsByName: &structsByName, unionsByName: &unionsByName) }
            if let name {
                let newStruct = CStructOrUnion(name: name, fields: fields ?? [])
                guard !newStruct.hasBitFieldOnly else { return }
                if let existStruct = structsByName[name] {
                    if existStruct.numberOfHasNameFields < newStruct.numberOfHasNameFields {
                        structsByName[name] = newStruct
                    }
                } else {
                    structsByName[name] = newStruct
                }
            }
        case .union(let name, let fields):
            for field in fields ?? [] { collectTypes(field.type, structsByName: &structsByName, unionsByName: &unionsByName) }
            if let name {
                let newUnion = CStructOrUnion(name: name, fields: fields ?? [])
                guard !newUnion.hasBitFieldOnly else { return }
                if let existUnion = unionsByName[name] {
                    if existUnion.numberOfHasNameFields < newUnion.numberOfHasNameFields {
                        unionsByName[name] = newUnion
                    }
                } else {
                    unionsByName[name] = newUnion
                }
            }
        case .pointer(let type), .array(let type, _), .modified(_, let type):
            collectTypes(type, structsByName: &structsByName, unionsByName: &unionsByName)
        case .block(let result, let arguments):
            if let result { collectTypes(result, structsByName: &structsByName, unionsByName: &unionsByName) }
            for argument in arguments ?? [] { collectTypes(argument, structsByName: &structsByName, unionsByName: &unionsByName) }
        default:
            break
        }
    }

    /// Resolve `cls` to its own `ObjCClassInfo` followed by the
    /// `ObjCClassInfo` of every superclass, walking
    /// ``ObjCMetadataSource/objcSuperClass(of:)`` across binary boundaries.
    /// `cache` memoizes info extraction so a deep inheritance chain shared by
    /// many classes is decoded only once.
    ///
    /// How far the walk gets depends on the mode. In image mode every
    /// dependency is mapped into the process, so the chain runs to the root
    /// class. In file mode it can only cross into another binary of the same
    /// dyld shared cache, so a standalone file's chain stops at the first
    /// superclass defined elsewhere — a shorter chain here, and consequently a
    /// `stripOverrides` that strips less.
    ///
    /// The loop walks `MachO.ResolvedSource` rather than `MachO` because one
    /// hop can land in a different binary; the protocol pins that type to
    /// itself, so the type stays put no matter how long the chain runs.
    private func infoWithSuperclasses<Class: ObjCClassProtocol>(class cls: Class, in machO: MachO, cache: inout [String: ObjCClassInfo]) -> [ObjCClassInfo] {
        guard let className = machO.objcClassName(of: cls) else { return [] }

        var currentInfo: ObjCClassInfo?

        if let cacheInfo = cache[className] {
            currentInfo = cacheInfo
        } else {
            let info = machO.objcClassInfo(of: cls)
            currentInfo = info
            cache[className] = info
        }

        guard let currentInfo else { return [] }

        var resultInfos: [ObjCClassInfo] = [currentInfo]

        var visited = [AnyHashable(machO.identifier): Set([cls.offset])]
        var machOAndSuperclass: (MachO.ResolvedSource, Class)? = machO.objcSuperClass(of: cls)

        while let currentMachOAndSuperclass = machOAndSuperclass {
            let currentMachO = currentMachOAndSuperclass.0
            let currentSuperclass = currentMachOAndSuperclass.1
            let identity = AnyHashable(currentMachO.identifier)
            guard visited[identity, default: []].insert(currentSuperclass.offset).inserted else { break }

            machOAndSuperclass = currentMachO.objcSuperClass(of: currentSuperclass)

            guard let superClassName = currentMachO.objcClassName(of: currentSuperclass) else { continue }

            var superclassInfo: ObjCClassInfo?
            if let cacheInfo = cache[superClassName] {
                superclassInfo = cacheInfo
            } else {
                let info = currentMachO.objcClassInfo(of: currentSuperclass)
                superclassInfo = info
                cache[superClassName] = info
            }
            if let superclassInfo {
                resultInfos.append(superclassInfo)
            }
        }

        return resultInfos
    }

    // MARK: - Interface Query

    /// The class plus its superclass chain for `name`, or `nil` if `name` is
    /// not a class in this image. `info.first` is the class itself.
    public func classGroup(forName name: String) -> ObjCClassGroup? {
        classes[name]
    }

    /// The protocol record for `name`, or `nil` if `name` is not a protocol
    /// in this image.
    public func protocolGroup(forName name: String) -> ObjCProtocolGroup? {
        protocols[name]
    }

    /// The category record for `uniqueName`, or `nil` if absent.
    public func categoryGroup(forName uniqueName: String) -> ObjCCategoryGroup? {
        categories[uniqueName]
    }

    /// Names of every class in this image (`__objc_classlist` order is not
    /// preserved — dictionary iteration order).
    public var classNames: [String] {
        Array(classes.keys)
    }

    public var protocolNames: [String] {
        Array(protocols.keys)
    }

    public var categoryNames: [String] {
        Array(categories.keys)
    }

    public var structNames: [String] {
        Array(structs.keys)
    }

    public var unionNames: [String] {
        Array(unions.keys)
    }

    /// Whether a C `struct` named `name` was harvested from this image —
    /// used by `ObjCRenderingContext` to decide whether a referenced struct
    /// should be emitted inline or left as a forward declaration.
    public func containsStruct(named name: String) -> Bool {
        structs[name] != nil
    }

    public func containsUnion(named name: String) -> Bool {
        unions[name] != nil
    }

    /// The rendered interface of the C `struct` named `name`, or `nil` if
    /// absent. The `context` is supplied by the caller because it depends on
    /// per-request generation options.
    public func structSemanticString(forName name: String, context: ObjCRenderingContext<MachO>) -> SemanticString? {
        structs[name]?.semanticString(isStruct: true, context: context)
    }

    public func unionSemanticString(forName name: String, context: ObjCRenderingContext<MachO>) -> SemanticString? {
        unions[name]?.semanticString(isStruct: false, context: context)
    }

}
