import ObjCDiffing
import ObjCDump
import ObjCIndexing
import ObjCMetadataSource

/// The bridge from an indexed binary to the diff engine's input (proposal
/// 0006) — the counterpart of MachOSwiftSection's
/// `SwiftDiffableInterfaceBuilder`.
///
/// Wraps a **prepared** `ObjCInterfaceIndexer` (the caller runs `prepare()`
/// first, same contract as `ObjCInterfaceBuilder`) and assembles the
/// `ObjCAPIModule` the differ freezes. Only each class's own declaration
/// (`ObjCClassGroup.info.first`) is included — the rest of the group is the
/// superclass chain, whose members belong to the superclasses' own
/// containers. Names are walked in sorted order so the assembled module (and
/// therefore the frozen snapshot) is deterministic across runs.
public struct ObjCAPISnapshotBuilder<MachO: ObjCMetadataSource> {
    private let indexer: ObjCInterfaceIndexer<MachO>

    public init(indexer: ObjCInterfaceIndexer<MachO>) {
        self.indexer = indexer
    }

    public func module() -> ObjCAPIModule {
        ObjCAPIModule(
            classes: indexer.classNames.sorted().compactMap { className in
                indexer.classGroup(forName: className)?.info.first
            },
            protocols: indexer.protocolNames.sorted().compactMap { protocolName in
                indexer.protocolGroup(forName: protocolName)?.info
            },
            categories: indexer.categoryNames.sorted().compactMap { categoryUniqueName in
                indexer.categoryGroup(forName: categoryUniqueName)?.info
            }
        )
    }

    public func snapshot() -> ObjCAPISnapshot {
        ObjCAPIDiffer().snapshot(of: module())
    }
}
