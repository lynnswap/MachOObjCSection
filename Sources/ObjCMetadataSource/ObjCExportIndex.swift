import Foundation
import MachOKit
import MachOKitExtensions

/// One image's Objective-C export symbol index: build it once, then ask it
/// about every class in that image.
///
/// ```swift
/// let exportIndex = ObjCExportIndex(machO: machO)
/// for className in indexer.classNames {
///     let status = exportIndex.exportStatus(ofClassNamed: className)
///     // …mark the row
/// }
/// ```
///
/// ## Built for the whole-image sweep
///
/// The shape here follows the one consumption pattern this exists for:
/// labelling *every* class of an image, hundreds to thousands at a time. So
/// the cost is paid once in ``init(machO:)`` — a single pass over the export
/// trie — and every query after it is a hash lookup.
///
/// That is also why there is no `machO.objcExportStatus(ofClassNamed:)`
/// convenience on ``ObjCMetadataSource`` itself. Such a call would have to
/// re-reach for `exportTrie` each time (on a `MachOFile` that means walking
/// the load commands, which is file I/O) and walk the trie again — turning
/// the sweep into O(n) I/O. A shortcut whose only plausible use is the one
/// that makes it quadratic is better left unwritten.
///
/// ## Lifetime is the caller's
///
/// This is a value holding two `Set<String>`, so it is `Sendable` without
/// ceremony: build it on the background pass that indexes the image, read it
/// from wherever renders. There is no process-wide cache behind it — a host
/// keeps it alive alongside whatever else it holds for that image, and drops
/// it with them.
public struct ObjCExportIndex: Sendable {
    /// The linker symbol a class's metadata is published under. Note the
    /// leading underscore: the export trie stores the linker's own spelling,
    /// and MachOKit hands the trie labels back verbatim.
    ///
    /// A Swift class needs no special handling — its symbol is this prefix
    /// plus the mangled runtime name exactly as the ObjC metadata already
    /// spells it (`_OBJC_CLASS_$__TtC6DVTKit35DVTPathControlNavigationPopoverItem`),
    /// so the concatenation below matches without any remangling step.
    private static let classSymbolPrefix = "_OBJC_CLASS_$_"

    /// The linker symbol an ivar's offset variable is published under, whose
    /// suffix is `<class name>.<ivar name>`.
    private static let ivarSymbolPrefix = "_OBJC_IVAR_$_"

    /// Exported class names, prefix already stripped (`NSAlert`, not
    /// `_OBJC_CLASS_$_NSAlert`). Stripping at build time rather than
    /// concatenating at query time saves one string construction per lookup,
    /// which over a whole-image sweep is one per class.
    private let exportedClassNames: Set<String>

    /// Exported ivars keyed `<class name>.<ivar name>`, prefix stripped. The
    /// separator is safe to key on: neither an ObjC class name nor a Swift
    /// mangled runtime name contains a `.`.
    private let exportedIvarQualifiedNames: Set<String>

    /// Whether this image yielded any export information at all. Drives the
    /// ``ObjCExportStatus/imageHasNoExportInformation`` answer.
    private let hasExportInformation: Bool

    /// Walks the image's export trie once and keeps the Objective-C entries.
    ///
    /// ## Why the whole trie, and not a prefix search
    ///
    /// MachOKit offers `ExportTrie.search(byKeyPrefix:)`, which looks like
    /// exactly the right tool for "give me everything under
    /// `_OBJC_CLASS_$_`". It is not used, on correctness grounds:
    /// `TrieTreeProtocol._search(byKeyPrefix:)` descends with
    /// `children.first(where:)`, so once the prefix is consumed, if *several*
    /// children still begin with it, only one branch is taken and the rest are
    /// silently dropped. Whether it returns everything depends on the trie
    /// happening to have a node boundary right at the prefix — which the usual
    /// export-trie writers do produce, but "usually correct" is not something
    /// to build a verdict on. A missed branch would report a batch of exported
    /// classes as internal, with nothing to show for it.
    ///
    /// A full pass costs one traversal per image (AppKit: 8774 entries in,
    /// 667 class names and 230 ivar names out) and is what
    /// `MachOSwiftSection`'s `SymbolIndexStore` does for the same purpose.
    public init(machO: some ObjCMetadataSource) {
        let exportedSymbols = machO.exportedSymbols

        var exportedClassNames: Set<String> = []
        var exportedIvarQualifiedNames: Set<String> = []

        for exportedSymbol in exportedSymbols {
            let symbolName = exportedSymbol.name
            if symbolName.hasPrefix(Self.classSymbolPrefix) {
                exportedClassNames.insert(
                    String(symbolName.dropFirst(Self.classSymbolPrefix.count))
                )
            } else if symbolName.hasPrefix(Self.ivarSymbolPrefix) {
                exportedIvarQualifiedNames.insert(
                    String(symbolName.dropFirst(Self.ivarSymbolPrefix.count))
                )
            }
        }

        // An empty result is treated as "no information", never as "nothing is
        // exported". The two are indistinguishable from here — a `.o` file
        // with no trie, a dyld shared cache image whose linkedit this reader
        // failed to reach, and a dylib genuinely built with an empty export
        // list all arrive as zero symbols — and the failure modes are wildly
        // asymmetric. Calling it "no information" costs a caller the ability
        // to judge an image that exports nothing, which is close to
        // hypothetical. Calling it "not exported" would silently label every
        // class in the image as internal, which is a wrong answer delivered
        // confidently.
        self.hasExportInformation = !exportedSymbols.isEmpty
        self.exportedClassNames = exportedClassNames
        self.exportedIvarQualifiedNames = exportedIvarQualifiedNames
    }

    /// Whether `_OBJC_CLASS_$_<className>` is in the export trie **of the
    /// image this index was built from**.
    ///
    /// `className` is the name as the Objective-C metadata spells it — which
    /// for a Swift class is its mangled runtime name, and needs no
    /// preprocessing.
    ///
    /// ## Only ask about classes this image defines
    ///
    /// The answer is per-image, and there is no "defined elsewhere" case to
    /// tell you when you have strayed: a class this image does not define
    /// comes back ``ObjCExportStatus/notExported``, indistinguishable from one
    /// it defines and keeps internal. `NSArray` asked of Foundation is
    /// `notExported`, because the class belongs to CoreFoundation (toll-free
    /// bridging; `NSDate`, `NSURL` and `NSDictionary` are the same story) —
    /// a true answer to the question asked, and a badly misleading one if the
    /// question meant "is NSArray public".
    ///
    /// So drive this from the image's own class list. A superclass name or an
    /// adopted class read out of some class's metadata routinely names another
    /// image's class, and passing those in produces a stream of meaningless
    /// negatives.
    public func exportStatus(ofClassNamed className: String) -> ObjCExportStatus {
        exportStatus(ofSymbolSuffix: className, in: exportedClassNames)
    }

    /// Whether `_OBJC_IVAR_$_<className>.<ivarName>` is in the image's export
    /// trie.
    ///
    /// `className` must be the class that *declares* the ivar, not a subclass
    /// that inherits it: the offset variable is published under the declaring
    /// class's name, so passing a subclass produces a symbol name that exists
    /// nowhere and reads back as ``ObjCExportStatus/notExported``. Taking both
    /// from the same `ObjCClassInfo` is correct — its `ivars` are the class's
    /// own, straight out of `class_ro_t`.
    public func exportStatus(
        ofIvarNamed ivarName: String,
        inClassNamed className: String
    ) -> ObjCExportStatus {
        exportStatus(
            ofSymbolSuffix: "\(className).\(ivarName)",
            in: exportedIvarQualifiedNames
        )
    }

    private func exportStatus(
        ofSymbolSuffix symbolSuffix: String,
        in exportedNames: Set<String>
    ) -> ObjCExportStatus {
        guard hasExportInformation else { return .imageHasNoExportInformation }
        return exportedNames.contains(symbolSuffix) ? .exported : .notExported
    }
}
