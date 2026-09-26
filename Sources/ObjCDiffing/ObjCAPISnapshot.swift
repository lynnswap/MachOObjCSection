/// Which container a snapshot or change describes.
public enum ObjCContainerKind: Sendable, Codable, Equatable {
    case `class`
    case `protocol`
    case category
}

/// One frozen container (class / protocol / category): its identity key,
/// reporting name, kind, and the projected member records the differ
/// compares.
public struct ObjCContainerSnapshot: Sendable, Codable, Equatable {
    public let key: ObjCAPIKey
    public let name: String
    public let kind: ObjCContainerKind
    /// Category containers only: the extended class's name, for reporting
    /// (the display `name` is the `ClassName(CategoryName)` unique name,
    /// which already embeds it).
    public let targetClassName: String?
    public let members: [ObjCMemberRecord]

    public init(
        key: ObjCAPIKey,
        name: String,
        kind: ObjCContainerKind,
        targetClassName: String? = nil,
        members: [ObjCMemberRecord]
    ) {
        self.key = key
        self.name = name
        self.kind = kind
        self.targetClassName = targetClassName
        self.members = members
    }
}

/// A frozen, `Codable` projection of an `ObjCAPIModule` — the diff currency
/// for persistence.
///
/// An `ObjCAPIModule` holds live ObjCDump info values (recursive protocol
/// trees, addresses, image names). An `ObjCAPISnapshot` is the same
/// declarations projected into exactly the keys and signatures the differ
/// compares — so a binary's ObjC API can be stored as a baseline and diffed
/// later without the original binary.
///
/// Build one with `ObjCAPIDiffer().snapshot(of: module)`, persist via
/// `ObjCAPISnapshotDocument`, and diff two snapshots with
/// `ObjCAPIDiffer().diff(old:new:)`. The live `diff(old:new:)` over modules
/// is exactly "freeze both, diff the snapshots", so the two entry points
/// share one algorithm.
public struct ObjCAPISnapshot: Sendable, Codable, Equatable {
    public var classes: [ObjCContainerSnapshot]
    public var protocols: [ObjCContainerSnapshot]
    public var categories: [ObjCContainerSnapshot]

    public init(
        classes: [ObjCContainerSnapshot] = [],
        protocols: [ObjCContainerSnapshot] = [],
        categories: [ObjCContainerSnapshot] = []
    ) {
        self.classes = classes
        self.protocols = protocols
        self.categories = categories
    }
}
