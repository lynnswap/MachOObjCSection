import Foundation
import MachOKit
import MachOKitExtensions
import MachOObjCSection
import ObjCDump

extension MachOImage: ObjCMetadataSource {
    public typealias ResolvedSource = MachOImage

    public func objcClassInfo<Class: ObjCClassProtocol>(
        of objcClass: Class,
        options: ObjCInfoOptions = .recursive
    ) -> ObjCClassInfo? {
        objcClass.info(in: self, options: options)
    }

    public func objcClassName<Class: ObjCClassProtocol>(of objcClass: Class) -> String? {
        objcClass.name(in: self)
    }

    /// The superclass of `objcClass`, paired with the image it was found in.
    ///
    /// Unlike the file-mode counterpart this resolves across every image mapped
    /// into the process, so the chain runs all the way to the root class.
    public func objcSuperClass<Class: ObjCClassProtocol>(of objcClass: Class) -> (MachOImage, Class)? {
        // Explicitly typed: `superClass(in:)` also has a deprecated overload
        // returning a bare `Self?`, and the two are otherwise ambiguous here.
        let resolved: (MachOImage, Class)? = objcClass.superClass(in: self)
        return resolved
    }

    public func objcProtocolInfo<ObjCProtocol: ObjCProtocolProtocol>(
        of objcProtocol: ObjCProtocol,
        options: ObjCProtocolInfoOptions = .recursive
    ) -> ObjCProtocolInfo? {
        objcProtocol.info(in: self, options: options)
    }

    public func objcCategoryInfo<Category: ObjCCategoryProtocol>(
        of objcCategory: Category,
        options: ObjCInfoOptions = .recursive
    ) -> ObjCCategoryInfo? {
        objcCategory.info(in: self, options: options)
    }

    public func objcCategoryTargetClass<Category: ObjCCategoryProtocol>(
        of objcCategory: Category
    ) -> (MachOImage, Category.ObjCClass)? {
        // Explicitly typed for the same reason as `objcSuperClass(of:)`.
        let resolved: (MachOImage, Category.ObjCClass)? = objcCategory.class(in: self)
        return resolved
    }

    /// In image mode the raw `imp` is the live function pointer: an absolute
    /// runtime address that includes the slide. Rebasing it onto the image's
    /// own start turns it into an offset, which `address(forOffset:)` then
    /// reports as an unslid virtual address — the spelling a disassembler
    /// shows. A value below the image start is not an implementation pointer
    /// at all and is rejected.
    public func objcResolvedIMPAddress(forRawValue rawValue: UInt64) -> UInt64? {
        let value = UInt(rawValue)
        let baseAddress = UInt(bitPattern: ptr)
        guard value != 0, value >= baseAddress else { return nil }
        return address(forOffset: Int(value &- baseAddress))
    }
}
