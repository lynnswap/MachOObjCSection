import Foundation

/// Whether an Objective-C declaration's linker symbol has an entry in the
/// image's export trie — the fact that separates a framework's public classes
/// from its internal implementation ones.
///
/// ## This is a symbol-table fact, not an access level
///
/// Objective-C has no `public` / `private` to recover, and this type does not
/// pretend otherwise. ``exported`` means exactly "dyld can resolve this symbol
/// from another image", nothing more. A class can be absent from a framework's
/// public headers and still be exported; a class can be exported and still be
/// documented as internal. What the trie answers is linkage, and linkage is
/// what this reports.
///
/// ## Only classes and ivars can be judged
///
/// There is deliberately no protocol or category case, because neither can be
/// judged at all:
///
/// - **Protocols** carry `__OBJC_PROTOCOL_$_<name>`, which clang always emits
///   as `.private_extern`. Measured on AppKit and on `DVTKit.framework`, the
///   count of protocol symbols in the export trie is zero in both — DVTKit's
///   82 protocol symbols are every one of them
///   `non-external (was a private external)`. This is compiler behaviour, not
///   a stripped binary: the runtime finds protocols by name through
///   `objc_getProtocol`, never through symbol resolution.
/// - **Categories** have no symbol of their own at all.
///
/// So rather than an entry point that would forever answer "not applicable",
/// there is no entry point, and a caller that needs to represent those in a
/// uniform list spells that with `Optional<ObjCExportStatus>` of its own.
public enum ObjCExportStatus: Sendable, Hashable {
    /// The symbol is in the image's export trie.
    case exported

    /// The image has export information, and this symbol is provably not in it.
    case notExported

    /// No verdict is available for **any** symbol of this image, because the
    /// image yielded no export information — a `.o` object file or a static
    /// library product with no export trie at all, or an export trie this
    /// reader could not get data out of.
    ///
    /// This is an image-level fact, unrelated to whatever was being asked
    /// about. A consumer must never read it as ``notExported``: doing so would
    /// report every single class of such an image as internal.
    case imageHasNoExportInformation
}

extension ObjCExportStatus {
    /// The tri-state projection: `nil` for the non-verdict case.
    ///
    /// Use it where the caller only distinguishes "provably not exported" from
    /// everything else.
    public var isExported: Bool? {
        switch self {
        case .exported: true
        case .notExported: false
        case .imageHasNoExportInformation: nil
        }
    }

    /// The one condition a consumer may act on — filtering a list, greying out
    /// a row: a definite negative verdict. Every other case means "no evidence",
    /// and no-evidence must never be turned into an action.
    public var isDefinitelyNotExported: Bool {
        self == .notExported
    }
}
