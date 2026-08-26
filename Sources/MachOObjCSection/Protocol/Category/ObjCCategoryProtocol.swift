//
//  ObjCCategoryProtocol.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2024/12/06
//
//

import Foundation
@_spi(Support) import MachOKit

public protocol ObjCCategoryProtocol: _FixupResolvable
where LayoutField == ObjCCategoryLayoutField,
      Layout: _ObjCCategoryLayoutProtocol
{
    associatedtype ObjCClass: ObjCClassProtocol
    associatedtype ObjCStubClass: ObjCStubClassProtocol
    typealias ObjCProtocolList = ObjCClass.ClassROData.ObjCProtocolList

    // var layout: Layout { get }
    var offset: Int { get }

    var isCatlist2: Bool { get }

    @_spi(Core)
    init(layout: Layout, offset: Int, isCatlist2: Bool)

    func name(in machO: MachOFile) -> String?
    func `class`(in machO: MachOFile) -> (MachOFile, ObjCClass)?
    func stubClass(in machO: MachOFile) -> (MachOFile, ObjCStubClass)?
    func className(in machO: MachOFile) -> String?
    func instanceMethodList(in machO: MachOFile) -> ObjCMethodList?
    func classMethodList(in machO: MachOFile) -> ObjCMethodList?
    func instancePropertyList(in machO: MachOFile) -> ObjCPropertyList?
    func classPropertyList(in machO: MachOFile) -> ObjCPropertyList?
    func protocolList(in machO: MachOFile) -> ObjCProtocolList?

    func name(in machO: MachOImage) -> String?
    func `class`(in machO: MachOImage) -> (MachOImage, ObjCClass)?
    func stubClass(in machO: MachOImage) -> (MachOImage, ObjCStubClass)?
    func className(in machO: MachOImage) -> String?
    func instanceMethodList(in machO: MachOImage) -> ObjCMethodList?
    func classMethodList(in machO: MachOImage) -> ObjCMethodList?
    func instancePropertyList(in machO: MachOImage) -> ObjCPropertyList?
    func classPropertyList(in machO: MachOImage) -> ObjCPropertyList?
    func protocolList(in machO: MachOImage) -> ObjCProtocolList?
}

extension ObjCCategoryProtocol {
    public func name(in machO: MachOFile) -> String? {
        let unresolved = unresolvedValue(of: .name)
        guard let resolved = machO.resolveRebase(unresolved) else { return nil }

        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
            return nil
        }

        return fileHandle.readString(
            offset: fileOffset
        )
    }

    public func `class`(in machO: MachOFile) -> (MachOFile, ObjCClass)? {
        guard let (machO, cls) = _readClass(
            field: .cls,
            in: machO
        ) else { return nil }

        if cls.isStubClass { return nil }

        return (machO, cls)
    }

    public func stubClass(in machO: MachOFile) -> (MachOFile, ObjCStubClass)? {
        guard let (machO, cls) = _readStubClass(
            field: .cls,
            in: machO
        ) else { return nil }

        guard cls.isStubClass else { return nil }

        return (machO, cls)
    }

    public func className(in machO: MachOFile) -> String? {
        if let name = _readClassName(
            field: .cls,
            in: machO
        ) {
            return name
        }

        var offset = offset
        if let cache = machO.cache {
            offset += numericCast(
                cache.mainCacheHeader.sharedRegionStart
            )
        }

        if let section = machO.sectionNumber(for: .__objc_const),
           let symbol = machO.symbol(for: offset, inSection: section),
           symbol.name.starts(with: "__CATEGORY_"){
            let className = symbol.name
                .replacingOccurrences(of: "__CATEGORY_", with: "")
                .components(separatedBy: "_$_")
                .first
            return className
        }

        return nil
    }

    public func instanceMethodList(in machO: MachOFile) -> ObjCMethodList? {
        _readMethodList(
            field: .instanceMethods,
            in: machO
        )
    }

    public func classMethodList(in machO: MachOFile) -> ObjCMethodList? {
        _readMethodList(
            field: .classMethods,
            in: machO
        )
    }

    public func instancePropertyList(in machO: MachOFile) -> ObjCPropertyList? {
        _readPropertyList(
            field: .instanceProperties,
            in: machO
        )
    }

    public func classPropertyList(in machO: MachOFile) -> ObjCPropertyList? {
        _readPropertyList(
            field: ._classProperties,
            in: machO
        )
    }

    public func protocolList(in machO: MachOFile) -> ObjCProtocolList? {
        _readProtocolList(
            field: .protocols,
            in: machO
        )
    }
}

extension ObjCCategoryProtocol {
    public func name(in machO: MachOImage) -> String? {
        guard layout.name > 0 else { return nil }
        let strippedAddress = machO.stripPointerTags(of: numericCast(layout.name))
        guard let ptr = UnsafeRawPointer(bitPattern: UInt(strippedAddress)) else {
            return nil
        }
        return .init(
            cString: ptr.assumingMemoryBound(to: CChar.self),
            encoding: .utf8
        )
    }

    public func `class`(in machO: MachOImage) -> (MachOImage, ObjCClass)? {
        readLoadedClass(in: machO).value
    }

    public func stubClass(in machO: MachOImage) -> (MachOImage, ObjCStubClass)? {
        readLoadedStubClass(in: machO).value
    }

    public func className(in machO: MachOImage) -> String? {
        guard let (machO, cls) = `class`(in: machO) else {
            if let section = machO.sectionNumber(for: .__objc_const),
               let symbol = machO.symbol(
                for: offset, inSection: section
               ),
               symbol.name.starts(with: "__CATEGORY_") {
                let className = symbol.name
                    .replacingOccurrences(of: "__CATEGORY_", with: "")
                    .components(separatedBy: "_$_")
                    .first
                return className
            }
            return nil
        }

        var data: ObjCClass.ClassROData?
        if let _data = cls.classROData(in: machO) {
            data = _data
        }
        if let rw = cls.classRWData(in: machO) {
            if let _data = rw.classROData(in: machO) {
                data = _data
            }
            if let ext = rw.ext(in: machO),
               let _data = ext.classROData(in: machO) {
                data = _data
            }
        }
        return data?.name(in: machO)
    }

    public func instanceMethodList(in machO: MachOImage) -> ObjCMethodList? {
        readLoadedMethodList(at: layout.instanceMethods, in: machO).value
    }

    public func classMethodList(in machO: MachOImage) -> ObjCMethodList? {
        readLoadedMethodList(at: layout.classMethods, in: machO).value
    }

    public func instancePropertyList(in machO: MachOImage) -> ObjCPropertyList? {
        readLoadedPropertyList(at: layout.instanceProperties, in: machO).value
    }

    public func classPropertyList(in machO: MachOImage) -> ObjCPropertyList? {
        readLoadedPropertyList(at: layout._classProperties, in: machO).value
    }

    public func protocolList(in machO: MachOImage) -> ObjCProtocolList? {
        _readProtocolList(
            at: numericCast(layout.protocols),
            in: machO
        )
    }
}

extension ObjCCategoryProtocol {
    internal func readLoadedClass(
        in machO: MachOImage
    ) -> ObjCMetadataReferenceRead<(MachOImage, ObjCClass)> {
        switch ObjCLoadedImageReader.readRelatedLayout(
            from: layout.cls,
            in: machO,
            as: ObjCClass.Layout.self
        ) {
        case .absent:
            return .absent
        case let .failure(provenance, reason):
            return .failure(provenance: provenance, reason: reason)
        case .value(let read):
            let cls = ObjCClass(layout: read.layout, offset: read.offset)
            guard !cls.isStubClass else { return .absent }
            return .value((read.image, cls))
        }
    }

    internal func readLoadedStubClass(
        in machO: MachOImage
    ) -> ObjCMetadataReferenceRead<(MachOImage, ObjCStubClass)> {
        switch ObjCLoadedImageReader.readRelatedLayout(
            from: layout.cls,
            in: machO,
            as: ObjCStubClass.Layout.self
        ) {
        case .absent:
            return .absent
        case let .failure(provenance, reason):
            return .failure(provenance: provenance, reason: reason)
        case .value(let read):
            let cls = ObjCStubClass(layout: read.layout, offset: read.offset)
            guard cls.isStubClass else { return .absent }
            return .value((read.image, cls))
        }
    }
}

extension ObjCCategoryProtocol {
    @available(*, deprecated, renamed: "class(in:)", message: "Use `class(in:)` that returns machO that contains class")
    public func `class`(in machO: MachOFile) -> ObjCClass? {
        guard let (_, cls) = self.class(in: machO) else {
            return nil
        }
        return cls
    }

    @available(*, deprecated, renamed: "stubClass(in:)", message: "Use `stubCclass(in:)` that returns machO that contains class")
    public func stubClass(in machO: MachOFile) -> ObjCStubClass? {
        guard let (_, cls) = self.stubClass(in: machO) else {
            return nil
        }
        return cls
    }

    @available(*, deprecated, renamed: "class(in:)", message: "Use `class(in:)` that returns machO that contains class")
    func `class`(in machO: MachOImage) -> ObjCClass? {
        guard let (targetMachO, cls) = self.class(in: machO) else { return nil }
        let diff = Int(bitPattern: targetMachO.ptr) - Int(bitPattern: machO.ptr)
        return .init(
            layout: cls.layout,
            offset: cls.offset + diff
        )
    }

    @available(*, deprecated, renamed: "stubClass(in:)", message: "Use `stubCclass(in:)` that returns machO that contains class")
    func stubClass(in machO: MachOImage) -> ObjCStubClass? {
        guard let (targetMachO, cls) = self.stubClass(in: machO) else { return nil }
        let diff = Int(bitPattern: targetMachO.ptr) - Int(bitPattern: machO.ptr)
        return .init(
            layout: cls.layout,
            offset: cls.offset + diff
        )
    }
}

extension ObjCCategoryProtocol {
    private func _readClass(
        field: LayoutField,
        in machO: MachOFile
    ) -> (MachOFile, ObjCClass)? {
        let unresolved = unresolvedValue(of: field)
        guard unresolved.value > 0 else { return nil }

        if isBind(field, in: machO) { return nil }

        guard let resolved = machO.resolveRebase(unresolved) else { return nil }

        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
            return nil
        }

        var targetMachO = machO
        if !targetMachO.contains(unslidAddress: resolved.address),
           let cache = machO.cache(for: resolved.address),
           let machO = cache.machO(containing: resolved.address) {
            targetMachO = machO
        }

        guard let layout = fileHandle.readLayout(
            offset: fileOffset,
            as: ObjCClass.Layout.self
        ) else {
            return nil
        }
        let cls: ObjCClass = .init(
            layout: layout,
            offset: numericCast(resolved.offset)
        )
        return (targetMachO, cls)
    }

    func _readStubClass(
        field: LayoutField,
        in machO: MachOFile
    ) -> (MachOFile, ObjCStubClass)? {
        let unresolved = unresolvedValue(of: field)
        guard unresolved.value > 0 else { return nil }

        if isBind(field, in: machO) { return nil }

        guard let resolved = machO.resolveRebase(unresolved) else { return nil }

        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
            return nil
        }

        var targetMachO = machO
        if !targetMachO.contains(unslidAddress: resolved.address),
           let cache = machO.cache(for: resolved.address),
           let machO = cache.machO(containing: resolved.address) {
            targetMachO = machO
        }

        guard let layout = fileHandle.readLayout(
            offset: fileOffset,
            as: ObjCStubClass.Layout.self
        ) else {
            return nil
        }
        let cls: ObjCStubClass = .init(
            layout: layout,
            offset: numericCast(resolved.offset)
        )
        return (targetMachO, cls)
    }

    private func _readClassName(
        field: LayoutField,
        in machO: MachOFile
    ) -> String? {
        let unresolved = unresolvedValue(of: field)
        guard unresolved.value > 0 else { return nil }

        if !isBind(field, in: machO),
           let resolved = machO.resolveRebase(unresolved) {
            if let name = ObjCClass._readClassName(
                resolved: resolved,
                in: machO,
                allowsStubClass: false
            ) {
                return name
            }
        }

        if let bindSymbolName = resolveBind(field, in: machO) {
            return bindSymbolName
                .replacingOccurrences(of: "_OBJC_CLASS_$_", with: "")
        }

        return nil
    }

    private func _readMethodList(
        field: LayoutField,
        in machO: MachOFile
    ) -> ObjCMethodList? {
        let unresolved = unresolvedValue(of: field)
        guard unresolved.value > 0 else { return nil }
        guard unresolved.value & 1 == 0 else { return nil }

        guard let resolved = machO.resolveRebase(unresolved) else { return nil }

        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
            return nil
        }

        guard let header = fileHandle.readLayout(
            offset: fileOffset,
            as: ObjCMethodList.Header.self
        ) else {
            return nil
        }
        let list = ObjCMethodList(
            offset: numericCast(resolved.offset),
            header: header,
            is64Bit: machO.is64Bit
        )
        if list.isValidEntrySize(is64Bit: machO.is64Bit) == false {
            // FIXME: Check
            return nil
        }
        return list
    }

    private func _readPropertyList(
        field: LayoutField,
        in machO: MachOFile
    ) -> ObjCPropertyList? {
        let unresolved = unresolvedValue(of: field)
        guard unresolved.value > 0 else { return nil }
        guard unresolved.value & 1 == 0 else { return nil }

        guard let resolved = machO.resolveRebase(unresolved) else { return nil }

        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
            return nil
        }

        guard let header = fileHandle.readLayout(
            offset: fileOffset,
            as: ObjCPropertyList.Header.self
        ) else {
            return nil
        }
        let list = ObjCPropertyList(
            offset: numericCast(resolved.offset),
            header: header,
            is64Bit: machO.is64Bit
        )
        if list.isValidEntrySize(is64Bit: machO.is64Bit) == false {
            // FIXME: Check
            return nil
        }
        return list
    }

    private func _readProtocolList(
        field: LayoutField,
        in machO: MachOFile
    ) -> ObjCProtocolList? {
        let unresolved = unresolvedValue(of: field)
        guard unresolved.value > 0 else { return nil }
        guard unresolved.value & 1 == 0 else { return nil }

        guard let resolved = machO.resolveRebase(unresolved) else { return nil }

        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
            return nil
        }

        guard let header: ObjCProtocolList.Header = fileHandle.readLayout(
            offset: fileOffset,
            as: ObjCProtocolList.Header.self
        ) else {
            return nil
        }
        let list = ObjCProtocolList(
            offset: numericCast(resolved.offset),
            header: header
        )
        return list
    }
}

extension ObjCCategoryProtocol {
    internal func readLoadedMethodList(
        at pointer: Layout.Pointer,
        in machO: MachOImage
    ) -> ObjCMetadataReferenceRead<ObjCMethodList> {
        guard pointer != 0 else { return .absent }
        guard pointer & 1 == 0 else {
            return .failure(
                provenance: ObjCLoadedImageReader.provenance(
                    for: pointer & ~1,
                    in: machO
                ),
                reason: .unsupportedListEncoding
            )
        }
        return ObjCLoadedImageReader.readEntrySizeList(
            from: pointer,
            in: machO,
            validateList: { list in
                ObjCLoadedImageReader.entrySizeFailure(
                    for: list,
                    expected: list.expectedEntrySize(is64Bit: machO.is64Bit)
                )
            },
            makeList: { header, offset in
                ObjCMethodList(
                    offset: offset,
                    header: header,
                    is64Bit: machO.is64Bit
                )
            }
        )
    }

    internal func readLoadedPropertyList(
        at pointer: Layout.Pointer,
        in machO: MachOImage
    ) -> ObjCMetadataReferenceRead<ObjCPropertyList> {
        guard pointer != 0 else { return .absent }
        guard pointer & 1 == 0 else {
            return .failure(
                provenance: ObjCLoadedImageReader.provenance(
                    for: pointer & ~1,
                    in: machO
                ),
                reason: .unsupportedListEncoding
            )
        }
        return ObjCLoadedImageReader.readEntrySizeList(
            from: pointer,
            in: machO,
            validateList: { list in
                ObjCLoadedImageReader.entrySizeFailure(
                    for: list,
                    expected: list.expectedEntrySize(is64Bit: machO.is64Bit)
                )
            },
            makeList: { header, offset in
                ObjCPropertyList(
                    offset: offset,
                    header: header,
                    is64Bit: machO.is64Bit
                )
            }
        )
    }

    private func _readProtocolList(
        at offset: UInt64,
        in machO: MachOImage
    ) -> ObjCProtocolList? {
        guard offset > 0 else { return nil }
        guard offset & 1 == 0 else { return nil }

        let strippedAddress = UInt(machO.stripPointerTags(of: offset))
        guard let ptr = UnsafeRawPointer(
            bitPattern: strippedAddress
        ) else {
            return nil
        }
        guard isPointerSafelyReadable(ptr, length: MemoryLayout<ObjCProtocolList.Header>.size) else {
            return nil
        }
        let list = ObjCProtocolList(
            ptr: ptr,
            offset: Int(bitPattern: ptr) - Int(bitPattern: machO.ptr)
        )

        return list
    }
}
