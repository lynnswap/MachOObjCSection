import Foundation
import MachOKit
import MachOKitExtensions
import MachOObjCSection
import ObjCDump

/// A Mach-O that Objective-C metadata can be extracted from, whether it is a
/// file on disk (`MachOFile`) or an image already mapped into this process
/// (`MachOImage`).
///
/// ## Why this protocol exists
///
/// `MachOObjCSection` parses both kinds of Mach-O, but it expresses that as two
/// parallel sets of named overloads — `info(in: MachOFile)` next to
/// `info(in: MachOImage)`, `superClass(in: MachOFile)` next to
/// `superClass(in: MachOImage)`, and so on. Overloads are not a generic
/// requirement: inside `func walk<MachO: MachOObjCSectionRepresentable>(machO: MachO)`
/// the call `objcClass.info(in: machO)` does not compile, because no protocol
/// declares a member taking `Self`.
///
/// This protocol is the missing requirement set, restated with `Self` in the
/// parameter position. Every conformance is pure forwarding to the overload
/// that already exists, so nothing here re-implements parsing — it only makes
/// the existing parsing reachable from generic code. Enumerating the sections
/// themselves was already generic through
/// ``MachOObjCSection/MachOObjCSectionRepresentable``; this fills in the other
/// half, "given one record, how do I decode it".
///
/// ## Not for external conformance
///
/// The intended conformers are `MachOFile` and `MachOImage`, both provided by
/// this module. The requirement set will grow as the indexing layer needs more
/// of the underlying parser, and growing it breaks outside conformers — so
/// treat this as a closed protocol even though it is not spelled `@_spi`.
///
/// ## What is deliberately absent
///
/// `classRWData(in:)` and `hasRWPointer(in:)` have no place here. RW data is
/// written by the Objective-C runtime when it realizes a class, so it does not
/// exist in a file on disk at all. Surfacing them generically would create an
/// interface that silently returns `nil` in file mode — a lie that is worse
/// than their absence. Callers that need them keep to the `MachOImage`-only
/// path.
public protocol ObjCMetadataSource: MachOObjCSectionRepresentable, MachORepresentableWithCache {
    /// The kind of source a cross-binary reference resolves into — always the
    /// conforming type itself.
    ///
    /// This exists only to work around a language restriction, and both
    /// conformances below simply spell it as themselves. Following a
    /// superclass or a category's target class can land in a *different*
    /// binary of the same kind, so the natural return type is `(Self, Class)`.
    /// But `MachOFile` is a non-final class, and Swift refuses a requirement
    /// that mentions `Self` anywhere other than the top level of a parameter or
    /// result — inside a tuple counts as "anywhere other" — because a subclass
    /// could not satisfy it. Naming the type separately sidesteps that while
    /// keeping the result concrete.
    ///
    /// The `where` clause pins the type down after one hop, so walking a
    /// superclass chain in a loop stays at one type instead of nesting
    /// `ResolvedSource.ResolvedSource.…` forever.
    associatedtype ResolvedSource: ObjCMetadataSource where ResolvedSource.ResolvedSource == ResolvedSource

    /// The full class information for `objcClass`, or `nil` when the record
    /// cannot be decoded.
    func objcClassInfo<Class: ObjCClassProtocol>(
        of objcClass: Class,
        options: ObjCInfoOptions
    ) -> ObjCClassInfo?

    /// The name of `objcClass`, or `nil` when the record carries none.
    func objcClassName<Class: ObjCClassProtocol>(of objcClass: Class) -> String?

    /// The superclass of `objcClass` paired with the Mach-O that superclass
    /// lives in, which is not necessarily this one.
    ///
    /// Cross-binary resolution behaves differently in the two modes, and the
    /// difference is visible to callers — see
    /// ``ObjCMetadataSource/objcSuperClass(of:)`` on each conformance.
    func objcSuperClass<Class: ObjCClassProtocol>(of objcClass: Class) -> (ResolvedSource, Class)?

    /// The full protocol information for `objcProtocol`, or `nil` when the
    /// record cannot be decoded.
    func objcProtocolInfo<ObjCProtocol: ObjCProtocolProtocol>(
        of objcProtocol: ObjCProtocol,
        options: ObjCProtocolInfoOptions
    ) -> ObjCProtocolInfo?

    /// The full category information for `objcCategory`, or `nil` when the
    /// record cannot be decoded.
    func objcCategoryInfo<Category: ObjCCategoryProtocol>(
        of objcCategory: Category,
        options: ObjCInfoOptions
    ) -> ObjCCategoryInfo?

    /// The class `objcCategory` extends, paired with the Mach-O that class
    /// lives in — usually a different binary, since extending another
    /// framework's class is the common case.
    func objcCategoryTargetClass<Category: ObjCCategoryProtocol>(
        of objcCategory: Category
    ) -> (ResolvedSource, Category.ObjCClass)?

    /// Resolves the raw `imp` field of a method record into a virtual address,
    /// or `nil` when the field holds no usable implementation pointer.
    ///
    /// **The raw value does not mean the same thing in both modes**, which is
    /// why this is a protocol requirement rather than a shared default built on
    /// `address(forOffset:)`. In image mode `imp` is the live function pointer,
    /// an absolute runtime address that still carries the image slide. In file
    /// mode `MachOObjCSection` has already converted it to an offset while
    /// decoding the method list — a file offset for a standalone binary, or an
    /// offset from `sharedRegionStart` for an image inside a dyld shared cache.
    /// Each conformance normalizes its own spelling before handing the result
    /// to `address(forOffset:)`.
    func objcResolvedIMPAddress(forRawValue rawValue: UInt64) -> UInt64?
}

extension ObjCMetadataSource {
    /// The full class information for `objcClass`, expanding referenced
    /// protocols recursively.
    public func objcClassInfo<Class: ObjCClassProtocol>(of objcClass: Class) -> ObjCClassInfo? {
        objcClassInfo(of: objcClass, options: .recursive)
    }

    /// The full protocol information for `objcProtocol`, expanding referenced
    /// protocols recursively.
    public func objcProtocolInfo<ObjCProtocol: ObjCProtocolProtocol>(of objcProtocol: ObjCProtocol) -> ObjCProtocolInfo? {
        objcProtocolInfo(of: objcProtocol, options: .recursive)
    }

    /// The full category information for `objcCategory`, expanding referenced
    /// protocols recursively.
    public func objcCategoryInfo<Category: ObjCCategoryProtocol>(of objcCategory: Category) -> ObjCCategoryInfo? {
        objcCategoryInfo(of: objcCategory, options: .recursive)
    }
}
