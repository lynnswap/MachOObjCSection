import Testing
import Foundation
import MachO
import MachOKit
import MachOObjCSection
import ObjCDeclarationRendering
import ObjCDump
import ObjCTypeDecodeKit
import ObjectiveC
import Semantic
@testable import ObjCIndexing

/// Anchors the test bundle's own Mach-O image so a test can index it.
///
/// `class_getImageName` on this class hands back the path of whichever image
/// the test code was linked into, which is more robust than guessing the
/// bundle's product name.
@objc(ObjCIndexingFixtureHost)
final class ObjCIndexingFixtureHost: NSObject {}

/// Adopted by the category fixture below. `@objc` so it lands in the emitted
/// category's protocol list, which is what makes the indexer report a
/// conformance for it.
///
/// The explicit runtime name matters: without it Swift exposes the protocol to
/// the Objective-C runtime under a mangled name (`_TtP<module><name>_`), and
/// the metadata the indexer reads carries that mangled spelling, not the Swift
/// one the tests below look for.
@objc(ObjCIndexingFixtureProtocol)
protocol ObjCIndexingFixtureProtocol {
    func objcIndexingFixtureMethod()
}

/// The category fixture: extending a class that belongs to *another* module
/// forces the compiler to emit an `__objc_catlist` entry, because it cannot
/// rewrite Foundation's already-compiled `NSString` record. An extension on a
/// class defined in this same module would instead be folded straight into
/// that class's method list and produce no category at all.
///
/// Two things about the resulting event are worth pinning down, and the tests
/// below do: the category is reported at all, and its `imagePath` is the test
/// bundle rather than Foundation, where the target class actually lives.
extension NSString: ObjCIndexingFixtureProtocol {
    public func objcIndexingFixtureMethod() {}
}

/// Indexes an image that is already loaded into this very process, so the
/// tests need no fixture binary on disk.
@Suite("ObjC interface indexing")
struct ObjCIndexingTests {
    @Test("Nested C definitions are harvested through wrappers and aggregate fields")
    func nestedCDefinitions() {
        let bar = ObjCType.union(name: "Bar", fields: [.init(type: .int)])
        let foo = ObjCType.struct(name: "Foo", fields: [.init(type: .pointer(type: bar), name: "child")])
        let root = ObjCType.block(return: .pointer(type: foo), args: [.array(type: foo, size: 2)])
        var structs: [String: ObjCInterfaceIndexer<MachOImage>.CStructOrUnion] = [:]
        var unions: [String: ObjCInterfaceIndexer<MachOImage>.CStructOrUnion] = [:]
        ObjCInterfaceIndexer<MachOImage>.collectTypes(root, structsByName: &structs, unionsByName: &unions)
        #expect(Set(structs.keys) == ["Foo"])
        #expect(Set(unions.keys) == ["Bar"])
        #expect(structs["Foo"]?.fields.first?.name == "child")
    }

    /// Builds and prepares an indexer over Foundation, collecting every event
    /// it emits along the way.
    private static func makeIndexer(
        collectingInto collector: EventCollector? = nil
    ) async throws -> ObjCInterfaceIndexer<MachOImage> {
        let machO = try #require(MachOImage(name: "Foundation"))
        var handler: (@Sendable (ObjCIndexingEvent) -> Void)?
        if let collector {
            handler = { event in collector.record(event) }
        }
        let indexer = ObjCInterfaceIndexer(
            machO: machO,
            imagePath: machO.imagePath,
            eventHandler: handler
        )
        try await indexer.prepare()
        return indexer
    }

    /// The Mach-O image this test bundle itself was linked into — the one
    /// carrying the fixtures declared above.
    private static func fixtureImage() throws -> (machO: MachOImage, path: String) {
        let imageNameC = try #require(class_getImageName(ObjCIndexingFixtureHost.self))
        let imagePath = String(cString: imageNameC)

        for index in 0 ..< _dyld_image_count() {
            guard let pathC = _dyld_get_image_name(index),
                  String(cString: pathC) == imagePath,
                  let header = _dyld_get_image_header(index)
            else { continue }
            return (MachOImage(ptr: header), imagePath)
        }

        Issue.record("Could not locate the test bundle's own image at \(imagePath)")
        throw CocoaError(.fileNoSuchFile)
    }

    /// Event sink shared with the indexer's `@Sendable` handler.
    final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ObjCIndexingEvent] = []

        func record(_ event: ObjCIndexingEvent) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(event)
        }

        var events: [ObjCIndexingEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// The consumer-side accumulation this library deliberately no longer does
    /// for you: keep the relationship events in arrival order, then fold them
    /// into the two reverse tables it used to expose directly.
    ///
    /// Deliberately mirrors the shape a real consumer needs, so that the tests
    /// below prove the capability survived the move rather than merely that
    /// events were emitted.
    struct RelationshipTables {
        struct ClassReference: Hashable {
            let className: String
            let imagePath: String
            let isSwiftStable: Bool
        }

        private var subclassesByClassName: [String: [ClassReference]] = [:]
        private var conformingClassesByProtocolName: [String: [ClassReference]] = [:]

        init(events: [ObjCIndexingEvent]) {
            for event in events {
                switch event {
                case .progress:
                    continue

                case .subclassIndexed(let className, let superclass, let imagePath, let isSwiftStable):
                    subclassesByClassName[superclass, default: []].append(
                        ClassReference(className: className, imagePath: imagePath, isSwiftStable: isSwiftStable)
                    )

                case .conformanceIndexed(let className, let protocolName, let imagePath, let isSwiftStable):
                    conformingClassesByProtocolName[protocolName, default: []].append(
                        ClassReference(className: className, imagePath: imagePath, isSwiftStable: isSwiftStable)
                    )

                case .categoryConformanceIndexed(let targetClassName, let protocolName, let imagePath, let targetIsSwiftStable):
                    conformingClassesByProtocolName[protocolName, default: []].append(
                        ClassReference(className: targetClassName, imagePath: imagePath, isSwiftStable: targetIsSwiftStable)
                    )
                }
            }
        }

        func subclasses(of className: String) -> [ClassReference] {
            Self.deduplicatingPreservingOrder(subclassesByClassName[className] ?? [])
        }

        func conformingClasses(toProtocol protocolName: String) -> [ClassReference] {
            Self.deduplicatingPreservingOrder(conformingClassesByProtocolName[protocolName] ?? [])
        }

        /// Matches what the library's `OrderedSet` storage used to do: a repeat
        /// reference collapses into its first occurrence.
        private static func deduplicatingPreservingOrder(_ references: [ClassReference]) -> [ClassReference] {
            var seen: Set<ClassReference> = []
            return references.filter { seen.insert($0).inserted }
        }
    }

    @Test("Indexes classes, protocols and categories from a real image")
    func indexesTopLevelDeclarations() async throws {
        let indexer = try await Self.makeIndexer()

        #expect(indexer.classNames.contains("NSString"))
        #expect(indexer.protocolNames.contains("NSCopying"))
        #expect(!indexer.categoryNames.isEmpty)
    }

    @Test("Class groups carry the superclass chain, class first")
    func classGroupCarriesSuperclassChain() async throws {
        let indexer = try await Self.makeIndexer()

        let group = try #require(indexer.classGroup(forName: "NSMutableString"))
        #expect(group.info.first?.name == "NSMutableString")
        // NSMutableString inherits from NSString.
        #expect(group.info.dropFirst().contains { $0.name == "NSString" })
    }

    @Test("C struct definitions are harvested and renderable")
    func harvestsStructDefinitions() async throws {
        let machO = try #require(MachOImage(name: "Foundation"))
        let indexer = try await Self.makeIndexer()

        let structName = try #require(indexer.structNames.first)
        #expect(indexer.containsStruct(named: structName))

        let context = ObjCRenderingContext(machO: machO)
        let rendered = try #require(indexer.structSemanticString(forName: structName, context: context))
        #expect(rendered.string.hasPrefix("struct "))
    }

    @Test("Emits progress and relationship events on one channel")
    func emitsUnifiedEvents() async throws {
        let collector = EventCollector()
        _ = try await Self.makeIndexer(collectingInto: collector)

        let events = collector.events
        #expect(!events.isEmpty)

        var seenPhases: Set<ObjCIndexingEvent.Phase> = []
        var sawSubclass = false
        var sawConformance = false
        var sawSwiftStableSubclass = false
        for event in events {
            switch event {
            case .progress(let phase, _, _, _):
                seenPhases.insert(phase)
            case .subclassIndexed(_, _, _, let isSwiftStable):
                sawSubclass = true
                if isSwiftStable { sawSwiftStableSubclass = true }
            case .conformanceIndexed, .categoryConformanceIndexed:
                sawConformance = true
            }
        }

        // Both the progress stream and the relationship events must arrive
        // through the single merged handler.
        #expect(seenPhases.contains(.indexingSubclasses))
        #expect(seenPhases.contains(.loadingClasses))
        #expect(sawSubclass)
        #expect(sawConformance)

        // Foundation ships Swift classes, which appear in `__objc_classlist`
        // through the same `class_t` record format. The flag riding along in
        // the payload is the whole reason a consumer can label them as Swift
        // without re-deriving anything.
        #expect(sawSwiftStableSubclass)
    }

    @Test("The event stream still supports rebuilding the subclass table")
    func rebuildsSubclassTableFromEventStream() async throws {
        let collector = EventCollector()
        _ = try await Self.makeIndexer(collectingInto: collector)

        let tables = RelationshipTables(events: collector.events)

        // The assertion the library's own `subclasses(of:)` test used to make,
        // now reached through the consumer-side path. The capability moved; it
        // did not disappear.
        #expect(tables.subclasses(of: "NSString").contains { $0.className == "NSMutableString" })
        #expect(!tables.conformingClasses(toProtocol: "NSCopying").isEmpty)
    }

    @Test("Category conformances report the declaring image, not the target's")
    func categoryConformanceCarriesDeclaringImagePath() async throws {
        let (machO, fixturePath) = try Self.fixtureImage()

        let collector = EventCollector()
        let indexer = ObjCInterfaceIndexer(
            machO: machO,
            imagePath: fixturePath,
            eventHandler: { event in collector.record(event) }
        )
        try await indexer.prepare()

        var fixtureConformance: (targetClassName: String, imagePath: String, targetIsSwiftStable: Bool)?
        for case .categoryConformanceIndexed(let targetClassName, let protocolName, let imagePath, let targetIsSwiftStable)
        in collector.events where protocolName == "ObjCIndexingFixtureProtocol" {
            fixtureConformance = (targetClassName, imagePath, targetIsSwiftStable)
            break
        }

        let conformance = try #require(
            fixtureConformance,
            "The NSString fixture category was not reported. Either the compiler stopped emitting a category for a cross-module @objc extension, or the category walk regressed — check which before touching the assertion."
        )

        #expect(conformance.targetClassName == "NSString")

        // The point of this test: `imagePath` names the image declaring the
        // *category*, which here is the test bundle. NSString itself lives in
        // Foundation, and the indexer never claims otherwise.
        #expect(conformance.imagePath == fixturePath)
        #expect(!indexer.classNames.contains("NSString"))

        // Rebuilt tables must carry the same asymmetry through.
        let tables = RelationshipTables(events: collector.events)
        let conformers = tables.conformingClasses(toProtocol: "ObjCIndexingFixtureProtocol")
        #expect(conformers.contains { $0.className == "NSString" && $0.imagePath == fixturePath })
    }

    @Test("Emission order is deterministic across runs")
    func emissionOrderIsDeterministic() async throws {
        let firstCollector = EventCollector()
        _ = try await Self.makeIndexer(collectingInto: firstCollector)

        let secondCollector = EventCollector()
        _ = try await Self.makeIndexer(collectingInto: secondCollector)

        let firstKeys = firstCollector.events.map(Self.orderingKey(for:))
        let secondKeys = secondCollector.events.map(Self.orderingKey(for:))

        // Consumers accumulate this stream in arrival order to reproduce the
        // binary's declaration order, so the order is part of the contract.
        // This asserts determinism without hardcoding any particular class
        // order, which would only make the test brittle against SDK changes.
        #expect(firstKeys == secondKeys)
    }

    @Test("Every class-phase relationship event precedes the category phase")
    func classPhasePrecedesCategoryPhase() async throws {
        let collector = EventCollector()
        _ = try await Self.makeIndexer(collectingInto: collector)

        let events = collector.events
        var lastClassPhaseIndex: Int?
        var firstCategoryPhaseIndex: Int?

        for (index, event) in events.enumerated() {
            switch event {
            case .subclassIndexed, .conformanceIndexed:
                lastClassPhaseIndex = index
            case .categoryConformanceIndexed:
                if firstCategoryPhaseIndex == nil { firstCategoryPhaseIndex = index }
            case .progress:
                continue
            }
        }

        let lastClassPhase = try #require(lastClassPhaseIndex)
        let firstCategoryPhase = try #require(firstCategoryPhaseIndex)

        // The one cross-phase ordering property consumers depend on: inline
        // adoptions land in a protocol's conformer list ahead of every
        // category-contributed one.
        #expect(lastClassPhase < firstCategoryPhase)
    }

    /// A comparable stand-in for an event, so two runs can be diffed without
    /// requiring `ObjCIndexingEvent` itself to be `Equatable`.
    private static func orderingKey(for event: ObjCIndexingEvent) -> String {
        switch event {
        case .progress(let phase, let itemDescription, let currentCount, let totalCount):
            return "progress|\(phase.rawValue)|\(itemDescription)|\(currentCount)|\(totalCount)"
        case .subclassIndexed(let className, let superclass, let imagePath, let isSwiftStable):
            return "subclass|\(className)|\(superclass)|\(imagePath)|\(isSwiftStable)"
        case .conformanceIndexed(let className, let protocolName, let imagePath, let isSwiftStable):
            return "conformance|\(className)|\(protocolName)|\(imagePath)|\(isSwiftStable)"
        case .categoryConformanceIndexed(let targetClassName, let protocolName, let imagePath, let targetIsSwiftStable):
            return "categoryConformance|\(targetClassName)|\(protocolName)|\(imagePath)|\(targetIsSwiftStable)"
        }
    }
}
