/// One position on an evolution's ordered version axis.
public struct ObjCAPIVersionDescriptor: Sendable, Codable, Equatable {
    /// The human-readable axis name (e.g. `"26.0"`). Always present —
    /// resolved by `ObjCAPIEvolutionBuilder` from explicit labels, snapshot
    /// provenance, or a positional fallback.
    public let label: String
    public let provenance: ObjCAPIProvenance?

    public init(label: String, provenance: ObjCAPIProvenance? = nil) {
        self.label = label
        self.provenance = provenance
    }
}

/// One transition on a lineage: what happened between the *previous* version
/// and `versions[versionIndex]`.
///
/// `versionIndex` is always ≥ 1 — an event at index `i` describes the
/// `versions[i-1] → versions[i]` step. Presence at the first version is not
/// an event; it is the lineage's `presence[0]` baseline.
public struct ObjCLineageEvent: Sendable, Codable, Equatable {
    public let versionIndex: Int
    public let status: ObjCChangeStatus
    /// Human-readable rendering on the pre-transition side, when present.
    public let oldSignature: String?
    /// Human-readable rendering on the post-transition side, when present.
    public let newSignature: String?
    /// Record-level verdict refinement, same rule as
    /// `ObjCMemberChange.compatibilityOverride` (shared via
    /// `ObjCMemberRecord.compatibilityOverride(old:new:)`); `nil` means the
    /// plain status rule applies. Always `nil` on container-level events.
    public let compatibilityOverride: ObjCCompatibility?

    public init(versionIndex: Int, status: ObjCChangeStatus, oldSignature: String? = nil, newSignature: String? = nil, compatibilityOverride: ObjCCompatibility? = nil) {
        self.versionIndex = versionIndex
        self.status = status
        self.oldSignature = oldSignature
        self.newSignature = newSignature
        self.compatibilityOverride = compatibilityOverride
    }
}

/// The lifeline of one member identity across the version axis.
///
/// Only lineages with at least one event are materialized — an API that
/// never changes never appears, mirroring `ObjCAPIDiff`'s "changes only"
/// contract.
public struct ObjCMemberLineage: Sendable, Codable, Equatable {
    public let key: ObjCAPIKey
    public let kind: ObjCMemberKind
    /// Per-version existence, one entry per version on the axis. For a
    /// member of a container this means "container present AND member
    /// present", so a container-level disappearance turns every member's bit
    /// off too.
    public let presence: [Bool]
    /// Adjacent-version transitions, ordered by `versionIndex`. Member
    /// events exist only for transitions where the owning container is
    /// present on both sides — when the container itself appears/disappears,
    /// the container's own event is the change (same rule as `ObjCAPIDiff`,
    /// whose added/removed containers carry no `memberChanges`).
    public let events: [ObjCLineageEvent]

    public init(key: ObjCAPIKey, kind: ObjCMemberKind, presence: [Bool], events: [ObjCLineageEvent]) {
        self.key = key
        self.kind = kind
        self.presence = presence
        self.events = events
    }
}

/// The lifeline of one container (class / protocol / category) across the
/// version axis.
public struct ObjCContainerLineage: Sendable, Codable, Equatable {
    public let key: ObjCAPIKey
    /// The container's reporting name, taken from its latest appearance on
    /// the axis.
    public let name: String
    public let containerKind: ObjCContainerKind
    /// Per-version existence, one entry per version on the axis.
    public let presence: [Bool]
    /// Container-level presence transitions only (`.added` / `.removed`).
    /// "Modified at version i" is not a container event — it is derivable as
    /// "has a member event at i", so it is not stored twice.
    public let events: [ObjCLineageEvent]
    /// Member lifelines with at least one event, sorted by key.
    public let memberLineages: [ObjCMemberLineage]

    public init(
        key: ObjCAPIKey,
        name: String,
        containerKind: ObjCContainerKind,
        presence: [Bool],
        events: [ObjCLineageEvent],
        memberLineages: [ObjCMemberLineage]
    ) {
        self.key = key
        self.name = name
        self.containerKind = containerKind
        self.presence = presence
        self.events = events
        self.memberLineages = memberLineages
    }
}

/// The structured result of tracking one binary's ObjC API across N ≥ 2
/// ordered versions — the N-way generalization of `ObjCAPIDiff`.
///
/// Buckets mirror `ObjCAPIDiff` one-for-one. A pure value type (`Codable` +
/// `Equatable`), deterministically sorted, so an evolution can be persisted
/// and two evolutions compared directly. For N == 2 the events at
/// `versionIndex == 1` correspond exactly to `ObjCAPIDiffer.diff(old:new:)`'s
/// changes — the two paths cannot disagree.
public struct ObjCAPIEvolution: Sendable, Codable, Equatable {
    /// The ordered version axis every `presence` array and `versionIndex`
    /// refers into.
    public let versions: [ObjCAPIVersionDescriptor]
    public let classes: [ObjCContainerLineage]
    public let protocols: [ObjCContainerLineage]
    public let categories: [ObjCContainerLineage]
    /// Identity-key collisions per version (one entry per version on the
    /// axis, aligned with `versions`), `nil` when no version has any. A
    /// collision means first-wins keying dropped a record there, so that
    /// version's transitions can be quietly weaker than reported — the
    /// reporters surface these as warnings.
    public let keyCollisionsByVersion: [[ObjCAPIKeyCollision]]?

    public init(
        versions: [ObjCAPIVersionDescriptor],
        classes: [ObjCContainerLineage] = [],
        protocols: [ObjCContainerLineage] = [],
        categories: [ObjCContainerLineage] = [],
        keyCollisionsByVersion: [[ObjCAPIKeyCollision]]? = nil
    ) {
        self.versions = versions
        self.classes = classes
        self.protocols = protocols
        self.categories = categories
        self.keyCollisionsByVersion = keyCollisionsByVersion
    }

    public var allContainerLineages: [ObjCContainerLineage] {
        classes + protocols + categories
    }

    /// `true` when nothing changed anywhere across the whole axis.
    public var isEmpty: Bool {
        allContainerLineages.isEmpty
    }
}
