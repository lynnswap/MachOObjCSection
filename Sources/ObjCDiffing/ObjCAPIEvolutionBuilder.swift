/// Builds an `ObjCAPIEvolution` from N ≥ 2 ordered snapshots by computing a
/// key → per-version presence/payload matrix directly — not by joining N−1
/// pairwise diffs. The matrix makes cross-version stories ("removed in v2,
/// re-added in v4") natural products rather than join special-cases, while
/// every per-transition comparison uses exactly the two-sided differ's
/// semantics (identity match on `identityKey`, change detection on
/// `payloadKey`, first-wins key collisions), so for N == 2 the events are
/// the two-sided `ObjCAPIDiff` verbatim.
public struct ObjCAPIEvolutionBuilder: Sendable {
    public init() {}

    /// Track a binary's ObjC API across ordered persisted baselines (oldest
    /// first).
    ///
    /// Label resolution per version: the explicit `labels` entry if
    /// provided, else the document's `provenance.label`, else a positional
    /// `"v<n>"`.
    public func evolution(of documents: [ObjCAPISnapshotDocument], labels: [String]? = nil) throws -> ObjCAPIEvolution {
        if let labels, labels.count != documents.count {
            throw ObjCAPIEvolutionError.labelCountMismatch(labelCount: labels.count, versionCount: documents.count)
        }
        let versions = documents.enumerated().map { index, document in
            ObjCAPIVersionDescriptor(
                label: labels?[index] ?? document.provenance?.label ?? "v\(index + 1)",
                provenance: document.provenance
            )
        }
        return try evolution(of: documents.map(\.snapshot), versions: versions)
    }

    /// Track a binary's ObjC API across ordered snapshots (oldest first)
    /// under an explicit version axis.
    public func evolution(of snapshots: [ObjCAPISnapshot], versions: [ObjCAPIVersionDescriptor]) throws -> ObjCAPIEvolution {
        guard snapshots.count >= 2 else {
            throw ObjCAPIEvolutionError.fewerThanTwoVersions(versionCount: snapshots.count)
        }
        guard snapshots.count == versions.count else {
            throw ObjCAPIEvolutionError.labelCountMismatch(labelCount: versions.count, versionCount: snapshots.count)
        }
        let keyCollisionsByVersion = snapshots.map { $0.keyCollisions() }
        return ObjCAPIEvolution(
            versions: versions,
            classes: containerLineages(snapshots.map(\.classes)),
            protocols: containerLineages(snapshots.map(\.protocols)),
            categories: containerLineages(snapshots.map(\.categories)),
            keyCollisionsByVersion: keyCollisionsByVersion.allSatisfy(\.isEmpty) ? nil : keyCollisionsByVersion
        )
    }

    // MARK: - Container axis

    /// One container bucket (classes, protocols, or categories) across all
    /// versions: `perVersionContainers[i]` is that bucket in version `i`.
    private func containerLineages(_ perVersionContainers: [[ObjCContainerSnapshot]]) -> [ObjCContainerLineage] {
        let keyedPerVersion = perVersionContainers.map { keyedFirstWins($0, by: \.key) }
        let orderedKeys = unionOfKeys(keyedPerVersion)

        var lineages: [ObjCContainerLineage] = []
        for containerKey in orderedKeys {
            let perVersion = keyedPerVersion.map { $0[containerKey] }
            let presence = perVersion.map { $0 != nil }
            let containerEvents = presenceTransitionEvents(presence)
            let members = memberLineages(perVersionMembers: perVersion.map { $0?.members })
            guard !containerEvents.isEmpty || !members.isEmpty else { continue }
            // Name/kind from the latest appearance, so a report shows the
            // most recent spelling of the container.
            let latest = perVersion.reversed().compactMap { $0 }.first!
            lineages.append(ObjCContainerLineage(
                key: containerKey,
                name: latest.name,
                containerKind: latest.kind,
                presence: presence,
                events: containerEvents,
                memberLineages: members
            ))
        }
        return lineages.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    // MARK: - Member axis

    /// Member lifelines across versions. `perVersionMembers[i] == nil` means
    /// the owning container is absent in version `i`. Member events are
    /// computed only for transitions where both adjacent versions have the
    /// container — a container-level appearance/disappearance is the
    /// container's own event, and enumerating members across the gap would
    /// diverge from the two-sided differ (which leaves an added/removed
    /// container's `memberChanges` empty).
    private func memberLineages(perVersionMembers: [[ObjCMemberRecord]?]) -> [ObjCMemberLineage] {
        let keyedPerVersion = perVersionMembers.map { members in
            members.map { keyedFirstWins($0, by: \.identityKey) }
        }
        let orderedKeys = unionOfKeys(keyedPerVersion.map { $0 ?? [:] })

        var lineages: [ObjCMemberLineage] = []
        for memberKey in orderedKeys {
            let perVersion = keyedPerVersion.map { $0?[memberKey] }
            let presence = perVersion.map { $0 != nil }

            var events: [ObjCLineageEvent] = []
            for versionIndex in 1 ..< perVersion.count {
                guard keyedPerVersion[versionIndex - 1] != nil, keyedPerVersion[versionIndex] != nil else {
                    continue
                }
                let oldRecord = perVersion[versionIndex - 1]
                let newRecord = perVersion[versionIndex]
                switch (oldRecord, newRecord) {
                case (nil, let newRecord?):
                    events.append(ObjCLineageEvent(versionIndex: versionIndex, status: .added, newSignature: newRecord.signature, compatibilityOverride: ObjCMemberRecord.compatibilityOverride(old: nil, new: newRecord)))
                case (let oldRecord?, nil):
                    events.append(ObjCLineageEvent(versionIndex: versionIndex, status: .removed, oldSignature: oldRecord.signature, compatibilityOverride: ObjCMemberRecord.compatibilityOverride(old: oldRecord, new: nil)))
                case (let oldRecord?, let newRecord?) where oldRecord.payloadKey != newRecord.payloadKey:
                    events.append(ObjCLineageEvent(
                        versionIndex: versionIndex,
                        status: .modified,
                        oldSignature: oldRecord.signature,
                        newSignature: newRecord.signature,
                        compatibilityOverride: ObjCMemberRecord.compatibilityOverride(old: oldRecord, new: newRecord)
                    ))
                default:
                    break
                }
            }
            guard !events.isEmpty else { continue }
            // The record must exist somewhere on the axis for an event to
            // have been produced, so the latest appearance always resolves a
            // kind.
            let kind = perVersion.reversed().compactMap { $0 }.first!.kind
            lineages.append(ObjCMemberLineage(
                key: memberKey,
                kind: kind,
                presence: presence,
                events: events
            ))
        }
        return lineages.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    // MARK: - Primitives

    /// `.added` / `.removed` events at every adjacent presence flip.
    private func presenceTransitionEvents(_ presence: [Bool]) -> [ObjCLineageEvent] {
        var events: [ObjCLineageEvent] = []
        for versionIndex in 1 ..< presence.count {
            switch (presence[versionIndex - 1], presence[versionIndex]) {
            case (false, true):
                events.append(ObjCLineageEvent(versionIndex: versionIndex, status: .added))
            case (true, false):
                events.append(ObjCLineageEvent(versionIndex: versionIndex, status: .removed))
            default:
                break
            }
        }
        return events
    }

    /// The union of every version's keys, in stable sorted order.
    private func unionOfKeys<Value>(_ keyedPerVersion: [[ObjCAPIKey: Value]]) -> [ObjCAPIKey] {
        var seen: Set<ObjCAPIKey> = []
        var union: [ObjCAPIKey] = []
        for keyed in keyedPerVersion {
            for key in keyed.keys where !seen.contains(key) {
                seen.insert(key)
                union.append(key)
            }
        }
        return union.sorted { $0.rawValue < $1.rawValue }
    }
}

/// Input-shape failures of `ObjCAPIEvolutionBuilder`.
public enum ObjCAPIEvolutionError: Error, Equatable, CustomStringConvertible {
    case fewerThanTwoVersions(versionCount: Int)
    case labelCountMismatch(labelCount: Int, versionCount: Int)

    public var description: String {
        switch self {
        case .fewerThanTwoVersions(let versionCount):
            return "ObjC API evolution needs at least 2 versions, got \(versionCount)."
        case .labelCountMismatch(let labelCount, let versionCount):
            return "Got \(labelCount) labels for \(versionCount) versions; the counts must match."
        }
    }
}
