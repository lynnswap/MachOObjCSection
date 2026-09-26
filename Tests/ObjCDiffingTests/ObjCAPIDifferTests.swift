import ObjCDump
import Testing
@testable import ObjCDiffing

@Suite("ObjCAPIDiffer")
struct ObjCAPIDifferTests {
    private let differ = ObjCAPIDiffer()

    // MARK: - Member level

    @Test func identicalSidesProduceNoChanges() {
        let members = [Fixtures.record(identity: "method:-run", payload: "enc:v16@0:8")]
        #expect(differ.diffMembers(old: members, new: members).isEmpty)
    }

    @Test func addedAndRemovedMembersAreClassifiedByIdentity() {
        let changes = differ.diffMembers(
            old: [Fixtures.record(identity: "method:-legacy")],
            new: [Fixtures.record(identity: "method:-replacement")]
        )
        #expect(changes.count == 2)
        #expect(changes.contains { $0.key.rawValue == "method:-legacy" && $0.status == .removed })
        #expect(changes.contains { $0.key.rawValue == "method:-replacement" && $0.status == .added })
    }

    @Test func payloadChangeAtSameIdentityReportsModified() {
        let changes = differ.diffMembers(
            old: [Fixtures.record(identity: "method:-run", payload: "enc:v16@0:8", signature: "- (void)run;")],
            new: [Fixtures.record(identity: "method:-run", payload: "enc:q16@0:8", signature: "- (long long)run;")]
        )
        #expect(changes.count == 1)
        #expect(changes[0].status == .modified)
        #expect(changes[0].oldSignature == "- (void)run;")
        #expect(changes[0].newSignature == "- (long long)run;")
    }

    @Test func requiredProtocolMemberAdditionIsBreakingOverride() {
        let changes = differ.diffMembers(
            old: [],
            new: [Fixtures.record(identity: "method:-render", isOptionalRequirement: false)]
        )
        #expect(changes.count == 1)
        #expect(changes[0].status == .added)
        #expect(changes[0].compatibilityOverride == .breaking)
        #expect(changes[0].compatibility == .breaking)
    }

    @Test func optionalProtocolMemberAdditionStaysAdditive() {
        let changes = differ.diffMembers(
            old: [],
            new: [Fixtures.record(identity: "method:-render", isOptionalRequirement: true)]
        )
        #expect(changes[0].compatibilityOverride == nil)
        #expect(changes[0].compatibility == .additive)
    }

    // MARK: - Container level

    @Test func addedAndRemovedContainersCarryNoMemberChanges() {
        let oldSnapshot = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:OldOnly", members: [Fixtures.record(identity: "method:-run")]),
        ])
        let newSnapshot = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:NewOnly", members: [Fixtures.record(identity: "method:-run")]),
        ])
        let diff = differ.diff(old: oldSnapshot, new: newSnapshot)
        #expect(diff.classes.count == 2)
        let everyChangeCarriesNoMembers = diff.classes.allSatisfy { $0.memberChanges.isEmpty }
        #expect(everyChangeCarriesNoMembers)
        #expect(diff.classes.contains { $0.status == .removed && $0.name == "class:OldOnly" })
        #expect(diff.classes.contains { $0.status == .added && $0.name == "class:NewOnly" })
    }

    @Test func modifiedContainerAggregatesMemberChanges() {
        let oldSnapshot = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Stable", members: [
                Fixtures.record(identity: "method:-keep"),
                Fixtures.record(identity: "method:-drop"),
            ]),
        ])
        let newSnapshot = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Stable", members: [
                Fixtures.record(identity: "method:-keep"),
                Fixtures.record(identity: "method:-gain"),
            ]),
        ])
        let diff = differ.diff(old: oldSnapshot, new: newSnapshot)
        #expect(diff.classes.count == 1)
        #expect(diff.classes[0].status == .modified)
        #expect(diff.classes[0].memberChanges.count == 2)
    }

    @Test func unchangedContainerDoesNotAppear() {
        let snapshot = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Stable", members: [Fixtures.record(identity: "method:-run")]),
        ])
        #expect(differ.diff(old: snapshot, new: snapshot).isEmpty)
    }

    // MARK: - Model projection end to end

    @Test func liveModuleDiffEqualsFrozenSnapshotDiff() {
        let oldModule = ObjCAPIModule(classes: [Fixtures.classInfo(name: "Widget", methods: [Fixtures.methodInfo(name: "draw")])])
        let newModule = ObjCAPIModule(classes: [Fixtures.classInfo(name: "Widget", methods: [Fixtures.methodInfo(name: "draw"), Fixtures.methodInfo(name: "layout")])])
        let liveDiff = differ.diff(old: oldModule, new: newModule)
        let frozenDiff = differ.diff(old: differ.snapshot(of: oldModule), new: differ.snapshot(of: newModule))
        #expect(liveDiff == frozenDiff)
        #expect(liveDiff.classes.count == 1)
        #expect(liveDiff.classes[0].memberChanges.count == 1)
        #expect(liveDiff.classes[0].memberChanges[0].key.rawValue == "method:-layout")
    }

    @Test func superclassChangeReportsModifiedNotRemovedPlusAdded() {
        let oldModule = ObjCAPIModule(classes: [Fixtures.classInfo(name: "Widget", superClassName: "NSObject")])
        let newModule = ObjCAPIModule(classes: [Fixtures.classInfo(name: "Widget", superClassName: "NSView")])
        let diff = differ.diff(old: oldModule, new: newModule)
        #expect(diff.classes.count == 1)
        #expect(diff.classes[0].status == .modified)
        let memberChanges = diff.classes[0].memberChanges
        #expect(memberChanges.count == 1)
        #expect(memberChanges[0].kind == .superclass)
        #expect(memberChanges[0].status == .modified)
    }

    @Test func directProtocolAdoptionChangeIsVisible() {
        let copying = Fixtures.protocolInfo(name: "NSCopying")
        let oldModule = ObjCAPIModule(classes: [Fixtures.classInfo(name: "Widget")])
        let newModule = ObjCAPIModule(classes: [Fixtures.classInfo(name: "Widget", protocols: [copying])])
        let diff = differ.diff(old: oldModule, new: newModule)
        let memberChanges = diff.classes[0].memberChanges
        #expect(memberChanges.count == 1)
        #expect(memberChanges[0].key.rawValue == "adopts:NSCopying")
        #expect(memberChanges[0].status == .added)
    }

    @Test func onlyDirectProtocolsAreProjected() {
        let base = Fixtures.protocolInfo(name: "Base")
        let derived = Fixtures.protocolInfo(name: "Derived", protocols: [base])
        let snapshot = differ.snapshot(of: ObjCAPIModule(classes: [Fixtures.classInfo(name: "Widget", protocols: [derived])]))
        let adoptionKeys = snapshot.classes[0].members.filter { $0.kind == .protocolAdoption }.map(\.identityKey.rawValue)
        #expect(adoptionKeys == ["adopts:Derived"])
    }

    @Test func requirednessMigrationReportsModified() {
        let oldModule = ObjCAPIModule(protocols: [Fixtures.protocolInfo(name: "Drawing", methods: [Fixtures.methodInfo(name: "draw")])])
        let newModule = ObjCAPIModule(protocols: [Fixtures.protocolInfo(name: "Drawing", optionalMethods: [Fixtures.methodInfo(name: "draw")])])
        let diff = differ.diff(old: oldModule, new: newModule)
        #expect(diff.protocols.count == 1)
        let memberChanges = diff.protocols[0].memberChanges
        #expect(memberChanges.count == 1)
        #expect(memberChanges[0].status == .modified)
    }

    @Test func categoryIsKeyedByUniqueName() {
        let onString = Fixtures.categoryInfo(name: "Additions", className: "NSString")
        let onData = Fixtures.categoryInfo(name: "Additions", className: "NSData")
        let snapshot = differ.snapshot(of: ObjCAPIModule(categories: [onString, onData]))
        #expect(snapshot.categories.map(\.key.rawValue).sorted() == ["category:NSData(Additions)", "category:NSString(Additions)"])
        #expect(snapshot.categories.allSatisfy { $0.targetClassName != nil })
    }

    // MARK: - Diagnostics & determinism

    @Test func duplicateClassSurfacesAsKeyCollision() throws {
        let snapshotWithDuplicates = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Twin", name: "Twin"),
            Fixtures.containerSnapshot(key: "class:Twin", name: "Twin"),
        ])
        let cleanSnapshot = ObjCAPISnapshot()
        let diff = differ.diff(old: snapshotWithDuplicates, new: cleanSnapshot)
        let diagnostics = try #require(diff.diagnostics)
        #expect(diagnostics.oldSideKeyCollisions.count == 1)
        #expect(diagnostics.newSideKeyCollisions.isEmpty)
        #expect(diagnostics.oldSideKeyCollisions[0].droppedSignatures == ["Twin"])
    }

    @Test func duplicateMemberSurfacesAsKeyCollisionScopedToContainer() {
        let snapshot = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Widget", name: "Widget", members: [
                Fixtures.record(identity: "method:-run", signature: "- (void)run; (first)"),
                Fixtures.record(identity: "method:-run", signature: "- (void)run; (second)"),
            ]),
        ])
        let collisions = snapshot.keyCollisions()
        #expect(collisions.count == 1)
        #expect(collisions[0].containerName == "Widget")
        #expect(collisions[0].droppedSignatures == ["- (void)run; (second)"])
    }

    @Test func outputOrderingIsDeterministic() {
        let oldSnapshot = ObjCAPISnapshot(classes: [
            Fixtures.containerSnapshot(key: "class:Beta"),
            Fixtures.containerSnapshot(key: "class:Alpha"),
        ])
        let newSnapshot = ObjCAPISnapshot()
        let firstRun = differ.diff(old: oldSnapshot, new: newSnapshot)
        let secondRun = differ.diff(old: oldSnapshot, new: newSnapshot)
        #expect(firstRun == secondRun)
        #expect(firstRun.classes.map(\.key.rawValue) == ["class:Alpha", "class:Beta"])
    }
}
