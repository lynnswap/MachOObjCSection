import Foundation
import Testing
@testable import ObjCDiffing

@Suite("ObjCAPISnapshotDocument")
struct ObjCAPISnapshotDocumentTests {
    private func sampleDocument() -> ObjCAPISnapshotDocument {
        ObjCAPISnapshotDocument(
            provenance: ObjCAPIProvenance(
                label: "26.0",
                binaryPath: "/tmp/Sample",
                generatorVersion: "1.0.0",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            snapshot: ObjCAPISnapshot(classes: [
                Fixtures.containerSnapshot(key: "class:Widget", name: "Widget", members: [
                    Fixtures.record(identity: "method:-run", payload: "enc:v16@0:8", signature: "- (void)run;"),
                ]),
            ])
        )
    }

    @Test func roundTripPreservesEverything() throws {
        let document = sampleDocument()
        let decoded = try ObjCAPISnapshotDocument.decode(from: document.encoded())
        #expect(decoded == document)
        #expect(decoded.formatVersion == ObjCAPISnapshotDocument.currentFormatVersion)
    }

    @Test func encodingIsByteStable() throws {
        let document = sampleDocument()
        #expect(try document.encoded() == document.encoded())
    }

    @Test func missingFormatVersionIsRejected() {
        let jsonWithoutVersion = Data(#"{"snapshot":{"classes":[],"protocols":[],"categories":[]}}"#.utf8)
        #expect(throws: ObjCAPISnapshotDocumentError.missingFormatVersion) {
            try ObjCAPISnapshotDocument.decode(from: jsonWithoutVersion)
        }
    }

    @Test func unsupportedFormatVersionIsRejected() {
        let jsonWithFutureVersion = Data(#"{"formatVersion":99,"snapshot":{"classes":[],"protocols":[],"categories":[]}}"#.utf8)
        #expect(throws: ObjCAPISnapshotDocumentError.unsupportedFormatVersion(found: 99, supported: ObjCAPISnapshotDocument.currentFormatVersion)) {
            try ObjCAPISnapshotDocument.decode(from: jsonWithFutureVersion)
        }
    }

    @Test func provenanceNeverAffectsComparison() {
        let firstDocument = sampleDocument()
        var secondDocument = sampleDocument()
        secondDocument.provenance = ObjCAPIProvenance(label: "different")
        let diff = ObjCAPIDiffer().diff(old: firstDocument, new: secondDocument)
        #expect(diff.isEmpty)
        #expect(diff.oldProvenance?.label == "26.0")
        #expect(diff.newProvenance?.label == "different")
    }
}
