import Foundation
import MachOKit
import ObjCDiffing
import ObjCDump
import ObjCIndexing
import Testing
@testable import ObjCInterface

/// Smoke coverage for the indexer-to-diff bridge over a real image already
/// loaded into this process — the projection details themselves are pinned by
/// the pure-value `ObjCDiffingTests`.
@Suite("ObjCAPISnapshotBuilder")
struct ObjCAPISnapshotBuilderTests {
    private static func makeSnapshotBuilder() async throws -> ObjCAPISnapshotBuilder<MachOImage> {
        let (indexer, _) = try await ObjCInterfaceTests.SharedFixture.shared.load()
        return ObjCAPISnapshotBuilder(indexer: indexer)
    }

    @Test("Assembles a module with own-declaration classes only")
    func assemblesModule() async throws {
        let snapshotBuilder = try await Self.makeSnapshotBuilder()
        let module = snapshotBuilder.module()
        #expect(!module.classes.isEmpty)
        let sampleClass = try #require(module.classes.first { $0.name == "NSError" })
        // `info.first` is the class's own declaration, not a superclass —
        // Foundation's NSError inherits from NSObject, whose members must not
        // leak into NSError's own container.
        #expect(sampleClass.superClassName == "NSObject")
    }

    @Test("Snapshot is deterministic and diffing it against itself is empty")
    func snapshotIsDeterministicAndSelfDiffIsEmpty() async throws {
        let snapshotBuilder = try await Self.makeSnapshotBuilder()
        let firstSnapshot = snapshotBuilder.snapshot()
        let secondSnapshot = snapshotBuilder.snapshot()
        #expect(firstSnapshot == secondSnapshot)
        #expect(ObjCAPIDiffer().diff(old: firstSnapshot, new: secondSnapshot).isEmpty)
    }

    @Test("Snapshot round-trips through the persisted document format")
    func snapshotRoundTripsThroughDocument() async throws {
        let snapshotBuilder = try await Self.makeSnapshotBuilder()
        let document = ObjCAPISnapshotDocument(
            provenance: ObjCAPIProvenance(label: "smoke"),
            snapshot: snapshotBuilder.snapshot()
        )
        let decoded = try ObjCAPISnapshotDocument.decode(from: document.encoded())
        #expect(decoded == document)
    }
}
