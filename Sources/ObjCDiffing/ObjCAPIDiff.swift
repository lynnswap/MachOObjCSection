/// The three-valued lattice every diff entity lives in, shared by all levels
/// (containers, members) so the vocabulary stays consistent.
public enum ObjCChangeStatus: Sendable, Codable, Equatable {
    /// Present only on the new side.
    case added
    /// Present only on the old side.
    case removed
    /// Matched on both sides under the same identity, but the comparable
    /// payload differs.
    case modified
}

extension ObjCChangeStatus {
    /// Stable ordering rank, used to make diff output deterministic.
    var sortRank: Int {
        switch self {
        case .removed: return 0
        case .added: return 1
        case .modified: return 2
        }
    }
}

/// One member-level delta within a container.
///
/// `status` is derived from identity matching on `identityKey`:
/// - `.added` / `.removed` — the member's identity exists on only one side.
/// - `.modified` — the identity matches on both sides but the comparable
///   payload differs (a method keeps its selector but changes type encoding,
///   a property changes attributes, a protocol member flips requiredness).
public struct ObjCMemberChange: Sendable, Codable, Equatable {
    public let key: ObjCAPIKey
    public let kind: ObjCMemberKind
    public let status: ObjCChangeStatus
    /// Human-readable rendering of the old member, when present.
    public let oldSignature: String?
    /// Human-readable rendering of the new member, when present.
    public let newSignature: String?
    /// Set when record-level facts refine the status-derived verdict — a
    /// required protocol-member addition is breaking (see
    /// `ObjCMemberRecord.compatibilityOverride(old:new:)`). `nil` means the
    /// plain status rule applies.
    public let compatibilityOverride: ObjCCompatibility?

    public init(
        key: ObjCAPIKey,
        kind: ObjCMemberKind,
        status: ObjCChangeStatus,
        oldSignature: String?,
        newSignature: String?,
        compatibilityOverride: ObjCCompatibility? = nil
    ) {
        self.key = key
        self.kind = kind
        self.status = status
        self.oldSignature = oldSignature
        self.newSignature = newSignature
        self.compatibilityOverride = compatibilityOverride
    }
}

/// One container-level delta — a class, a protocol, or a category.
///
/// - `.added` / `.removed` — the container exists on only one side;
///   `memberChanges` is left empty (the whole container is the change).
/// - `.modified` — the container exists on both sides and at least one member
///   changed; `memberChanges` carries the per-member deltas.
public struct ObjCContainerChange: Sendable, Codable, Equatable {
    public let key: ObjCAPIKey
    /// The container's reporting name (a category's `ClassName(CategoryName)`
    /// unique name).
    public let name: String
    public let containerKind: ObjCContainerKind
    public let status: ObjCChangeStatus
    public let memberChanges: [ObjCMemberChange]

    public init(
        key: ObjCAPIKey,
        name: String,
        containerKind: ObjCContainerKind,
        status: ObjCChangeStatus,
        memberChanges: [ObjCMemberChange]
    ) {
        self.key = key
        self.name = name
        self.containerKind = containerKind
        self.status = status
        self.memberChanges = memberChanges
    }
}

/// The structured result of diffing two ObjC API snapshots.
///
/// A pure value type (no Mach-O, no model references) — it is `Codable` and
/// `Equatable`, so a diff can be persisted and two diffs compared directly.
/// All arrays are sorted deterministically (by key then status), so encoding
/// the same diff twice is byte-stable.
public struct ObjCAPIDiff: Sendable, Codable, Equatable {
    public let classes: [ObjCContainerChange]
    public let protocols: [ObjCContainerChange]
    public let categories: [ObjCContainerChange]
    /// Where the old side came from, when known. Descriptive metadata for
    /// reports only — never part of the diff computation or of `isEmpty`.
    public let oldProvenance: ObjCAPIProvenance?
    /// Where the new side came from, when known.
    public let newProvenance: ObjCAPIProvenance?
    /// What the comparison had to resolve silently (identity-key collisions),
    /// `nil` when nothing. Not part of `isEmpty` — a clean diff with
    /// collisions still warns, because a dropped record can hide a change.
    public let diagnostics: ObjCAPIDiffDiagnostics?

    public init(
        classes: [ObjCContainerChange] = [],
        protocols: [ObjCContainerChange] = [],
        categories: [ObjCContainerChange] = [],
        oldProvenance: ObjCAPIProvenance? = nil,
        newProvenance: ObjCAPIProvenance? = nil,
        diagnostics: ObjCAPIDiffDiagnostics? = nil
    ) {
        self.classes = classes
        self.protocols = protocols
        self.categories = categories
        self.oldProvenance = oldProvenance
        self.newProvenance = newProvenance
        self.diagnostics = diagnostics
    }

    public var allContainerChanges: [ObjCContainerChange] {
        classes + protocols + categories
    }

    public var isEmpty: Bool {
        classes.isEmpty && protocols.isEmpty && categories.isEmpty
    }
}
