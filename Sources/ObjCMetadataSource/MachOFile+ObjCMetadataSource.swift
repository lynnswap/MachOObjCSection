import Foundation
import MachOKit
import MachOKitExtensions
import MachOObjCSection
import ObjCDump

extension MachOFile: ObjCMetadataSource {
    public typealias ResolvedSource = MachOFile

    public func objcClassInfo<Class: ObjCClassProtocol>(
        of objcClass: Class,
        options: ObjCInfoOptions = .recursive
    ) -> ObjCClassInfo? {
        objcClass.info(in: self, options: options)
    }

    public func objcClassName<Class: ObjCClassProtocol>(of objcClass: Class) -> String? {
        objcClass.name(in: self)
    }

    /// The superclass of `objcClass`, paired with the file it was found in.
    ///
    /// In file mode this only crosses binaries **within one dyld shared
    /// cache**: `superClass(in: MachOFile)` follows a rebase to another image
    /// in the same cache, but has nothing to follow for a standalone binary
    /// whose superclass is bound from a dependency it never opened. The chain
    /// simply stops there. Image mode has no such limit — every dependency is
    /// already mapped into the process — so a superclass chain read from a
    /// standalone file can be shorter than the one read from the same binary
    /// loaded. Anything derived from the chain inherits that, most visibly
    /// `ObjCGenerationOptions.stripOverrides`, which then strips fewer members.
    public func objcSuperClass<Class: ObjCClassProtocol>(of objcClass: Class) -> (MachOFile, Class)? {
        // Explicitly typed: `superClass(in:)` also has a deprecated overload
        // returning a bare `Self?`, and the two are otherwise ambiguous here.
        let resolved: (MachOFile, Class)? = objcClass.superClass(in: self)
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
    ) -> (MachOFile, Category.ObjCClass)? {
        // Explicitly typed for the same reason as `objcSuperClass(of:)`.
        let resolved: (MachOFile, Category.ObjCClass)? = objcCategory.class(in: self)
        return resolved
    }

    /// In file mode the raw `imp` is already an offset — `ObjCMethodList`
    /// converts it while decoding, subtracting `sharedRegionStart` for a cache
    /// image and taking the file offset for a standalone binary (see
    /// `ObjCMethodList.pointerMethod(_:in:)`). Relative method lists, which is
    /// what current arm64 binaries emit, produce an offset directly. So the
    /// value goes straight into `address(forOffset:)` with no base to subtract.
    public func objcResolvedIMPAddress(forRawValue rawValue: UInt64) -> UInt64? {
        guard rawValue != 0 else { return nil }
        return address(forOffset: Int(rawValue))
    }
}
