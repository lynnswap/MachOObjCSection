import ObjCDump

/// The fully-materialized, Mach-O-free input `ObjCAPIDiffer.snapshot(of:)`
/// consumes: one binary's ObjC declarations as plain ObjCDump info values.
///
/// A pure pass-through structure — build one from a prepared
/// `ObjCInterfaceIndexer` via `ObjCAPISnapshotBuilder` (in `ObjCInterface`),
/// or assemble it by hand in tests. Each class entry must be the class's
/// *own* declaration only (`ObjCClassGroup.info.first`), not the superclass
/// chain — inherited members belong to the superclass's own container, and
/// including them here would double-report every superclass change.
///
/// Not persistable: the info values hold recursively materialized protocol
/// trees. `ObjCAPIDiffer.snapshot(of:)` projects them into the flat,
/// `Codable` `ObjCAPISnapshot` (direct protocol names only).
public struct ObjCAPIModule {
    public let classes: [ObjCClassInfo]
    public let protocols: [ObjCProtocolInfo]
    public let categories: [ObjCCategoryInfo]

    public init(
        classes: [ObjCClassInfo] = [],
        protocols: [ObjCProtocolInfo] = [],
        categories: [ObjCCategoryInfo] = []
    ) {
        self.classes = classes
        self.protocols = protocols
        self.categories = categories
    }
}
