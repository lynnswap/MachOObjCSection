import ObjCDump
import ObjCMetadataSource

/// Diffs the ObjC API of two binaries by keying every declaration on its
/// runtime identity (class name / protocol name / category unique name /
/// selector) and computing a recursive three-way set difference.
///
/// Synchronous and Mach-O-free: it operates purely on already-materialized
/// ObjCDump info values. Build the two `ObjCAPIModule` inputs (via
/// `ObjCAPISnapshotBuilder` in `ObjCInterface`, or by hand), then call
/// ``diff(old:new:)``. Output arrays are sorted deterministically.
public struct ObjCAPIDiffer: Sendable {
    public init() {}

    // MARK: - Top level

    /// Diff two live modules. Equivalent to freezing both into snapshots and
    /// diffing those — the two entry points share one algorithm, so a live
    /// diff and a baseline diff can never disagree.
    public func diff(old: ObjCAPIModule, new: ObjCAPIModule) -> ObjCAPIDiff {
        diff(old: snapshot(of: old), new: snapshot(of: new))
    }

    /// Diff two persisted baselines, carrying each document's provenance onto
    /// the result so reports can name the binaries they describe.
    public func diff(old: ObjCAPISnapshotDocument, new: ObjCAPISnapshotDocument) -> ObjCAPIDiff {
        diff(
            old: old.snapshot,
            new: new.snapshot,
            oldProvenance: old.provenance,
            newProvenance: new.provenance
        )
    }

    /// Diff two frozen snapshots. Pure value-data computation — no model, no
    /// Mach-O — so it is fully unit-testable and runs against persisted
    /// baselines. The optional provenances are stamped onto the result
    /// verbatim (they never affect the comparison).
    public func diff(
        old: ObjCAPISnapshot,
        new: ObjCAPISnapshot,
        oldProvenance: ObjCAPIProvenance? = nil,
        newProvenance: ObjCAPIProvenance? = nil
    ) -> ObjCAPIDiff {
        let candidateDiagnostics = ObjCAPIDiffDiagnostics(
            oldSideKeyCollisions: old.keyCollisions(),
            newSideKeyCollisions: new.keyCollisions()
        )
        let diagnostics = candidateDiagnostics.isEmpty ? nil : candidateDiagnostics
        return ObjCAPIDiff(
            classes: diffContainerSnapshots(old.classes, new.classes),
            protocols: diffContainerSnapshots(old.protocols, new.protocols),
            categories: diffContainerSnapshots(old.categories, new.categories),
            oldProvenance: oldProvenance,
            newProvenance: newProvenance,
            diagnostics: diagnostics
        )
    }

    // MARK: - Freeze (ObjCAPIModule -> ObjCAPISnapshot)

    /// Freeze a live module into a persistable snapshot by projecting every
    /// declaration into its diff records. All of the model knowledge lives
    /// here; the diff above is then pure data over the result.
    public func snapshot(of module: ObjCAPIModule) -> ObjCAPISnapshot {
        ObjCAPISnapshot(
            classes: module.classes.map { classInfo in
                ObjCContainerSnapshot(
                    key: ObjCAPIKey(rawValue: "class:\(classInfo.name)"),
                    name: classInfo.name,
                    kind: .class,
                    members: memberRecords(of: classInfo)
                )
            },
            protocols: module.protocols.map { protocolInfo in
                ObjCContainerSnapshot(
                    key: ObjCAPIKey(rawValue: "protocol:\(protocolInfo.name)"),
                    name: protocolInfo.name,
                    kind: .protocol,
                    members: memberRecords(of: protocolInfo)
                )
            },
            categories: module.categories.map { categoryInfo in
                ObjCContainerSnapshot(
                    key: ObjCAPIKey(rawValue: "category:\(categoryInfo.uniqueName)"),
                    name: categoryInfo.uniqueName,
                    kind: .category,
                    targetClassName: categoryInfo.className,
                    members: memberRecords(of: categoryInfo)
                )
            }
        )
    }

    // MARK: - Member projection

    /// A class contributes its own methods, properties, ivars, its directly
    /// adopted protocols (the first level of the recursive `protocols` tree
    /// is exactly the direct adoptions — deeper levels belong to those
    /// protocols' own containers), and its superclass pseudo-member.
    func memberRecords(of classInfo: ObjCClassInfo) -> [ObjCMemberRecord] {
        var records: [ObjCMemberRecord] = []
        records.append(contentsOf: classInfo.methods.map { ObjCMemberRecord.make($0) })
        records.append(contentsOf: classInfo.classMethods.map { ObjCMemberRecord.make($0) })
        records.append(contentsOf: classInfo.properties.map { ObjCMemberRecord.make($0) })
        records.append(contentsOf: classInfo.classProperties.map { ObjCMemberRecord.make($0) })
        records.append(contentsOf: classInfo.ivars.map(ObjCMemberRecord.make))
        records.append(contentsOf: classInfo.protocols.map { ObjCMemberRecord.makeProtocolAdoption(protocolName: $0.name) })
        records.append(ObjCMemberRecord.makeSuperclass(superclassName: classInfo.superClassName))
        return records
    }

    /// A protocol contributes its required and optional member groups (the
    /// required/optional flag travels in the payload key, so a requiredness
    /// migration of the same selector reports `.modified`) and its directly
    /// referenced protocols.
    func memberRecords(of protocolInfo: ObjCProtocolInfo) -> [ObjCMemberRecord] {
        var records: [ObjCMemberRecord] = []
        records.append(contentsOf: protocolInfo.methods.map { ObjCMemberRecord.make($0, isOptionalRequirement: false) })
        records.append(contentsOf: protocolInfo.classMethods.map { ObjCMemberRecord.make($0, isOptionalRequirement: false) })
        records.append(contentsOf: protocolInfo.properties.map { ObjCMemberRecord.make($0, isOptionalRequirement: false) })
        records.append(contentsOf: protocolInfo.classProperties.map { ObjCMemberRecord.make($0, isOptionalRequirement: false) })
        records.append(contentsOf: protocolInfo.optionalMethods.map { ObjCMemberRecord.make($0, isOptionalRequirement: true) })
        records.append(contentsOf: protocolInfo.optionalClassMethods.map { ObjCMemberRecord.make($0, isOptionalRequirement: true) })
        records.append(contentsOf: protocolInfo.optionalProperties.map { ObjCMemberRecord.make($0, isOptionalRequirement: true) })
        records.append(contentsOf: protocolInfo.optionalClassProperties.map { ObjCMemberRecord.make($0, isOptionalRequirement: true) })
        records.append(contentsOf: protocolInfo.protocols.map { ObjCMemberRecord.makeProtocolAdoption(protocolName: $0.name) })
        return records
    }

    /// A category contributes its methods, properties, and directly adopted
    /// protocols (no ivars, no superclass).
    func memberRecords(of categoryInfo: ObjCCategoryInfo) -> [ObjCMemberRecord] {
        var records: [ObjCMemberRecord] = []
        records.append(contentsOf: categoryInfo.methods.map { ObjCMemberRecord.make($0) })
        records.append(contentsOf: categoryInfo.classMethods.map { ObjCMemberRecord.make($0) })
        records.append(contentsOf: categoryInfo.properties.map { ObjCMemberRecord.make($0) })
        records.append(contentsOf: categoryInfo.classProperties.map { ObjCMemberRecord.make($0) })
        records.append(contentsOf: categoryInfo.protocols.map { ObjCMemberRecord.makeProtocolAdoption(protocolName: $0.name) })
        return records
    }

    // MARK: - Snapshot diff (ObjCAPISnapshot -> ObjCAPIDiff)

    /// Match container snapshots by key, then diff each matched pair's
    /// members. One helper serves every axis — classes, protocols, and
    /// categories — since they are all `[ObjCContainerSnapshot]` once frozen.
    private func diffContainerSnapshots(_ old: [ObjCContainerSnapshot], _ new: [ObjCContainerSnapshot]) -> [ObjCContainerChange] {
        let matched = threeWayMatch(old: old, new: new) { $0.key }

        var changes: [ObjCContainerChange] = []
        changes.append(contentsOf: matched.removed.map {
            ObjCContainerChange(key: $0.key, name: $0.name, containerKind: $0.kind, status: .removed, memberChanges: [])
        })
        changes.append(contentsOf: matched.added.map {
            ObjCContainerChange(key: $0.key, name: $0.name, containerKind: $0.kind, status: .added, memberChanges: [])
        })
        for (oldContainer, newContainer) in matched.common {
            let memberChanges = diffMembers(old: oldContainer.members, new: newContainer.members)
            if !memberChanges.isEmpty {
                changes.append(ObjCContainerChange(
                    key: newContainer.key,
                    name: newContainer.name,
                    containerKind: newContainer.kind,
                    status: .modified,
                    memberChanges: memberChanges
                ))
            }
        }
        return sorted(changes, key: \.key, status: \.status)
    }

    // MARK: - Member level (test seam)

    /// Three-way set difference over member records, keyed by `identityKey`.
    /// Public so it can be unit-tested on hand-built records without any
    /// Mach-O or runtime involvement.
    public func diffMembers(old: [ObjCMemberRecord], new: [ObjCMemberRecord]) -> [ObjCMemberChange] {
        let matched = threeWayMatch(old: old, new: new) { $0.identityKey }

        var changes: [ObjCMemberChange] = []
        changes.append(contentsOf: matched.removed.map {
            ObjCMemberChange(key: $0.identityKey, kind: $0.kind, status: .removed, oldSignature: $0.signature, newSignature: nil, compatibilityOverride: ObjCMemberRecord.compatibilityOverride(old: $0, new: nil))
        })
        changes.append(contentsOf: matched.added.map {
            ObjCMemberChange(key: $0.identityKey, kind: $0.kind, status: .added, oldSignature: nil, newSignature: $0.signature, compatibilityOverride: ObjCMemberRecord.compatibilityOverride(old: nil, new: $0))
        })
        for (oldRecord, newRecord) in matched.common where oldRecord.payloadKey != newRecord.payloadKey {
            changes.append(ObjCMemberChange(key: newRecord.identityKey, kind: newRecord.kind, status: .modified, oldSignature: oldRecord.signature, newSignature: newRecord.signature, compatibilityOverride: ObjCMemberRecord.compatibilityOverride(old: oldRecord, new: newRecord)))
        }
        return sorted(changes, key: \.key, status: \.status)
    }

    // MARK: - Generic primitives

    /// The single three-way matcher every diff axis specializes: index both
    /// sides by `identity`, then partition into old-only (`removed`),
    /// new-only (`added`), and present-on-both (`common`, as old/new pairs).
    /// Callers decide how to compare each `common` pair.
    private func threeWayMatch<Element>(
        old: [Element],
        new: [Element],
        identity: (Element) -> ObjCAPIKey
    ) -> (removed: [Element], added: [Element], common: [(old: Element, new: Element)]) {
        let oldByKey = keyedFirstWins(old, by: identity)
        let newByKey = keyedFirstWins(new, by: identity)

        var removed: [Element] = []
        var added: [Element] = []
        var common: [(old: Element, new: Element)] = []

        for (elementKey, element) in oldByKey {
            if let match = newByKey[elementKey] {
                common.append((old: element, new: match))
            } else {
                removed.append(element)
            }
        }
        for (elementKey, element) in newByKey where oldByKey[elementKey] == nil {
            added.append(element)
        }

        return (removed, added, common)
    }

    /// Deterministic ordering by key string then status, so repeated runs
    /// over the same inputs produce identical output.
    private func sorted<Change>(_ changes: [Change], key: (Change) -> ObjCAPIKey, status: (Change) -> ObjCChangeStatus) -> [Change] {
        changes.sorted { lhs, rhs in
            (key(lhs).rawValue, status(lhs).sortRank) < (key(rhs).rawValue, status(rhs).sortRank)
        }
    }
}
