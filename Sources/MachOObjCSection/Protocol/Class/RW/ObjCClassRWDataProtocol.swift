//
//  ObjCClassRWDataProtocol.swift
//
//
//  Created by p-x9 on 2024/10/31
//  
//

import Foundation
@_spi(Support) import MachOKit

public protocol ObjCClassRWDataProtocol {
    associatedtype Layout: _ObjCClassRWDataLayoutProtocol
    associatedtype ObjCClassROData: ObjCClassRODataProtocol
    associatedtype ObjCClassRWDataExt: ObjCClassRWDataExtProtocol where ObjCClassRWDataExt.ObjCClassROData == ObjCClassROData

    var layout: Layout { get }
    var offset: Int { get }

    @_spi(Core)
    init(layout: Layout, offset: Int)

    func classROData(in machO: MachOImage) -> ObjCClassROData?
    func ext(in machO: MachOImage) -> ObjCClassRWDataExt?
}

extension ObjCClassRWDataProtocol {
    public var flags: ObjCClassRWDataFlags {
        .init(rawValue: layout.flags)
    }

    public var index: Int {
        numericCast(layout.index)
    }

    public var hasRO: Bool {
        layout.ro_or_rw_ext & 1 == 0
    }

    public var hasExt: Bool {
        layout.ro_or_rw_ext & 1 != 0
    }
}

extension ObjCClassRWDataProtocol {
    public func classROData(in machO: MachOImage) -> ObjCClassROData? {
        guard hasRO else { return nil }

        let address: Int = numericCast(layout.ro_or_rw_ext)
        guard let ptr = UnsafeRawPointer(bitPattern: address) else {
            return nil
        }
        let layout = ptr
            .assumingMemoryBound(to: ObjCClassROData.Layout.self)
            .pointee
        let classData = ObjCClassROData(
            layout: layout,
            offset: Int(bitPattern: ptr) - Int(bitPattern: machO.ptr)
        )

        return classData
    }

    public func ext(in machO: MachOImage) -> ObjCClassRWDataExt? {
        guard hasExt else { return nil }

        let address: Int = numericCast(layout.ro_or_rw_ext)
        guard let ptr = UnsafeRawPointer(bitPattern: address & ~1) else {
            return nil
        }
        let layout = ptr
            .assumingMemoryBound(to: ObjCClassRWDataExt.Layout.self)
            .pointee
        let classData = ObjCClassRWDataExt(
            layout: layout,
            offset: Int(bitPattern: ptr) - Int(bitPattern: machO.ptr)
        )

        return classData
    }
}

extension ObjCClassRWDataProtocol {
    private var roOrRWExtOffset: Int? {
        MemoryLayout<Layout>.offset(of: \.ro_or_rw_ext)
    }

    public func classROData(in machO: MachOFile) -> ObjCClassROData? {
        guard hasRO else { return nil }
        guard let fieldOffset = roOrRWExtOffset else { return nil }

        let unresolved = UnresolvedValue(
            fieldOffset: offset + fieldOffset,
            value: numericCast(layout.ro_or_rw_ext)
        )
        let resolved = machO.resolveRebase(unresolved)
        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forAddress: resolved.address) else {
            return nil
        }

        guard let layout: ObjCClassROData.Layout = fileHandle.read(offset: fileOffset) else {
            return nil
        }
        guard let resolvedOffset = Int(exactly: resolved.offset) else { return nil }
        let classData = ObjCClassROData(
            layout: layout,
            offset: resolvedOffset
        )
        return classData
    }

    public func ext(in machO: MachOFile) -> ObjCClassRWDataExt? {
        guard hasExt else { return nil }
        guard let fieldOffset = roOrRWExtOffset else { return nil }

        let rawValue: UInt64 = numericCast(layout.ro_or_rw_ext)
        let unresolved = UnresolvedValue(
            fieldOffset: offset + fieldOffset,
            value: rawValue & ~1
        )
        let resolved = machO.resolveRebase(unresolved)
        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forAddress: resolved.address) else {
            return nil
        }

        guard let layout: ObjCClassRWDataExt.Layout = fileHandle.read(offset: fileOffset) else {
            return nil
        }
        guard let resolvedOffset = Int(exactly: resolved.offset) else { return nil }
        let classData = ObjCClassRWDataExt(
            layout: layout,
            offset: resolvedOffset
        )
        return classData
    }
}
