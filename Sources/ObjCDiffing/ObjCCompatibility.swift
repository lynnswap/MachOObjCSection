/// A change's backward-compatibility verdict.
///
/// Heuristic: a new declaration is `.additive` (callers built against the old
/// API keep working), anything removed or modified is `.breaking`; a modified
/// container is breaking iff any of its member changes is breaking. One
/// record-level refinement layers on top (`compatibilityOverride`, computed
/// by `ObjCMemberRecord.compatibilityOverride(old:new:)`): a protocol member
/// added as **required** is breaking — existing conformers lack the
/// implementation.
///
/// Known limitation — ObjC has no access control, so the binary cannot
/// distinguish public API from private implementation. Every removed or
/// modified selector is reported breaking, including renames of what a human
/// would call a private helper; the reader applies that judgment themselves.
/// (The same honest-over-clever stance as SwiftDiffing's "`@frozen` is not
/// recoverable, treat everything as resilient".)
public enum ObjCCompatibility: Sendable, Codable, Equatable {
    case additive
    case breaking
}

extension ObjCChangeStatus {
    var compatibility: ObjCCompatibility {
        switch self {
        case .added: return .additive
        case .removed, .modified: return .breaking
        }
    }
}

extension ObjCMemberChange {
    /// Whether this member-level change keeps the old API working: the
    /// record-level refinement when present, else the status rule.
    public var compatibility: ObjCCompatibility { compatibilityOverride ?? status.compatibility }
}

extension ObjCLineageEvent {
    /// Whether this transition keeps the old API working: the record-level
    /// refinement when present, else the status rule.
    public var compatibility: ObjCCompatibility { compatibilityOverride ?? status.compatibility }
}

extension ObjCContainerChange {
    /// Whether this container-level change keeps the old API working. A
    /// removed container is breaking; an added one is additive; a modified
    /// one is breaking iff any of its member changes is breaking.
    public var compatibility: ObjCCompatibility {
        switch status {
        case .added: return .additive
        case .removed: return .breaking
        case .modified: return memberChanges.contains { $0.compatibility == .breaking } ? .breaking : .additive
        }
    }
}

extension ObjCAPIDiff {
    /// Every container change classified as breaking.
    public var breakingContainerChanges: [ObjCContainerChange] {
        allContainerChanges.filter { $0.compatibility == .breaking }
    }

    /// `true` when at least one change is breaking.
    public var hasBreakingChange: Bool {
        !breakingContainerChanges.isEmpty
    }

    /// `true` when the diff is non-empty but every change is additive — old
    /// callers keep working. An empty diff is trivially backward-compatible.
    public var isBackwardCompatible: Bool {
        !hasBreakingChange
    }
}

extension ObjCAPIEvolution {
    /// The verdict for each adjacent transition on the axis
    /// (`versions.count - 1` entries; entry `i` covers
    /// `versions[i] → versions[i+1]`). A transition is breaking iff any
    /// lineage carries a breaking event there.
    public var transitionCompatibilities: [ObjCCompatibility] {
        var breakingTransitions = Set<Int>()
        for lineage in allContainerLineages {
            for event in lineage.events where event.compatibility == .breaking {
                breakingTransitions.insert(event.versionIndex)
            }
            for memberLineage in lineage.memberLineages {
                for event in memberLineage.events where event.compatibility == .breaking {
                    breakingTransitions.insert(event.versionIndex)
                }
            }
        }
        return (1 ..< versions.count).map {
            breakingTransitions.contains($0) ? .breaking : .additive
        }
    }

    /// `true` when at least one transition on the axis is breaking.
    public var hasBreakingChange: Bool {
        transitionCompatibilities.contains(.breaking)
    }

    /// The `versionIndex` of the earliest breaking transition (the version
    /// the break landed in), or `nil` when the whole axis is additive.
    public var firstBreakingVersionIndex: Int? {
        transitionCompatibilities.firstIndex(of: .breaking).map { $0 + 1 }
    }
}
