import Testing
@testable import ObjCDiffing

@Suite("ObjCAPIEvolutionBuilder")
struct ObjCAPIEvolutionTests {
    private let builder = ObjCAPIEvolutionBuilder()
    private let differ = ObjCAPIDiffer()

    private func versions(_ labels: [String]) -> [ObjCAPIVersionDescriptor] {
        labels.map { ObjCAPIVersionDescriptor(label: $0) }
    }

    // MARK: - Input validation

    @Test func fewerThanTwoVersionsIsRejected() {
        #expect(throws: ObjCAPIEvolutionError.fewerThanTwoVersions(versionCount: 1)) {
            try builder.evolution(of: [ObjCAPISnapshot()], versions: versions(["1"]))
        }
    }

    @Test func labelCountMismatchIsRejected() {
        #expect(throws: ObjCAPIEvolutionError.labelCountMismatch(labelCount: 1, versionCount: 2)) {
            try builder.evolution(
                of: [ObjCAPISnapshotDocument(snapshot: ObjCAPISnapshot()), ObjCAPISnapshotDocument(snapshot: ObjCAPISnapshot())],
                labels: ["only-one"]
            )
        }
    }

    @Test func labelResolutionPrefersExplicitThenProvenanceThenPositional() throws {
        var labeledDocument = ObjCAPISnapshotDocument(snapshot: ObjCAPISnapshot())
        labeledDocument.provenance = ObjCAPIProvenance(label: "from-provenance")
        let unlabeledDocument = ObjCAPISnapshotDocument(snapshot: ObjCAPISnapshot())

        let withExplicitLabels = try builder.evolution(of: [labeledDocument, unlabeledDocument], labels: ["explicit-1", "explicit-2"])
        #expect(withExplicitLabels.versions.map(\.label) == ["explicit-1", "explicit-2"])

        let withoutExplicitLabels = try builder.evolution(of: [labeledDocument, unlabeledDocument])
        #expect(withoutExplicitLabels.versions.map(\.label) == ["from-provenance", "v2"])
    }

    // MARK: - Lineage shapes

    @Test func removalAndReturnProducePresenceGapAndBothEvents() throws {
        let present = ObjCAPISnapshot(classes: [Fixtures.containerSnapshot(key: "class:Comeback", name: "Comeback")])
        let absent = ObjCAPISnapshot()
        let evolution = try builder.evolution(of: [present, absent, present], versions: versions(["1", "2", "3"]))

        #expect(evolution.classes.count == 1)
        let lineage = evolution.classes[0]
        #expect(lineage.presence == [true, false, true])
        #expect(lineage.events.count == 2)
        #expect(lineage.events[0].status == .removed)
        #expect(lineage.events[0].versionIndex == 1)
        #expect(lineage.events[1].status == .added)
        #expect(lineage.events[1].versionIndex == 2)
    }

    @Test func memberEventsAreSuppressedAcrossContainerGaps() throws {
        let oldPayload = Fixtures.containerSnapshot(key: "class:Widget", name: "Widget", members: [
            Fixtures.record(identity: "method:-run", payload: "enc:v16@0:8"),
        ])
        let newPayload = Fixtures.containerSnapshot(key: "class:Widget", name: "Widget", members: [
            Fixtures.record(identity: "method:-run", payload: "enc:q16@0:8"),
        ])
        let withOld = ObjCAPISnapshot(classes: [oldPayload])
        let gap = ObjCAPISnapshot()
        let withNew = ObjCAPISnapshot(classes: [newPayload])
        let evolution = try builder.evolution(of: [withOld, gap, withNew], versions: versions(["1", "2", "3"]))

        let lineage = evolution.classes[0]
        // The container-level removed/added tells the story; the member's
        // retype across the gap is deliberately not a member event (the
        // two-sided differ cannot see it either).
        #expect(lineage.events.count == 2)
        #expect(lineage.memberLineages.isEmpty)
    }

    @Test func unchangedLineagesAreNotMaterialized() throws {
        let snapshot = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Stable", name: "Stable", members: [Fixtures.record(identity: "method:-run")]),
        ])
        let evolution = try builder.evolution(of: [snapshot, snapshot], versions: versions(["1", "2"]))
        #expect(evolution.isEmpty)
    }

    @Test func twoVersionEventsMatchTwoSidedDiff() throws {
        let oldSnapshot = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Widget", name: "Widget", members: [
                Fixtures.record(identity: "method:-keep"),
                Fixtures.record(identity: "method:-drop"),
                Fixtures.record(identity: "method:-retype", payload: "enc:v16@0:8"),
            ]),
        ])
        let newSnapshot = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Widget", name: "Widget", members: [
                Fixtures.record(identity: "method:-keep"),
                Fixtures.record(identity: "method:-gain"),
                Fixtures.record(identity: "method:-retype", payload: "enc:q16@0:8"),
            ]),
        ])

        let diff = differ.diff(old: oldSnapshot, new: newSnapshot)
        let evolution = try builder.evolution(of: [oldSnapshot, newSnapshot], versions: versions(["1", "2"]))

        let diffKeysByStatus = Dictionary(grouping: diff.classes[0].memberChanges, by: \.status)
            .mapValues { changes in changes.map(\.key).sorted() }
        let lineageEvents = evolution.classes[0].memberLineages.flatMap { lineage in
            lineage.events.map { event in (key: lineage.key, status: event.status) }
        }
        let evolutionKeysByStatus = Dictionary(grouping: lineageEvents, by: \.status)
            .mapValues { events in events.map(\.key).sorted() }
        #expect(diffKeysByStatus == evolutionKeysByStatus)
    }

    // MARK: - Compatibility across the axis

    @Test func transitionCompatibilitiesAndFirstBreakingIndex() throws {
        let baseline = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Widget", name: "Widget", members: [Fixtures.record(identity: "method:-run")]),
        ])
        let withAddition = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Widget", name: "Widget", members: [
                Fixtures.record(identity: "method:-run"),
                Fixtures.record(identity: "method:-extra"),
            ]),
        ])
        let withRemoval = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Widget", name: "Widget", members: [Fixtures.record(identity: "method:-extra")]),
        ])
        let evolution = try builder.evolution(of: [baseline, withAddition, withRemoval], versions: versions(["1", "2", "3"]))
        #expect(evolution.transitionCompatibilities == [.additive, .breaking])
        #expect(evolution.hasBreakingChange)
        #expect(evolution.firstBreakingVersionIndex == 2)
    }

    @Test func keyCollisionsAreReportedPerVersion() throws {
        let cleanSnapshot = ObjCAPISnapshot(classes: [Fixtures.containerSnapshot(key: "class:Widget", name: "Widget")])
        let collidingSnapshot = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Widget", name: "Widget"),
            Fixtures.containerSnapshot(key: "class:Widget", name: "Widget"),
        ])
        let evolution = try builder.evolution(of: [cleanSnapshot, collidingSnapshot], versions: versions(["1", "2"]))
        let keyCollisionsByVersion = try #require(evolution.keyCollisionsByVersion)
        #expect(keyCollisionsByVersion.count == 2)
        #expect(keyCollisionsByVersion[0].isEmpty)
        #expect(keyCollisionsByVersion[1].count == 1)
    }
}
