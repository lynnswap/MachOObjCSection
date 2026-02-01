//
//  ObjCClassRWDataExtProtocol.swift
//
//
//  Created by p-x9 on 2024/10/31
//
//

import Foundation
import MachOKit

public protocol ObjCClassRWDataExtProtocol {
    associatedtype Layout: _ObjCClassRWDataExtLayoutProtocol
    associatedtype ObjCClassROData: ObjCClassRODataProtocol
    associatedtype ObjCProtocolArray: ObjCProtocolArrayProtocol

    var layout: Layout { get }
    var offset: Int { get }

    @_spi(Core)
    init(layout: Layout, offset: Int)

    func classROData(in machO: MachOImage) -> ObjCClassROData?

    func methodList(in machO: MachOImage) -> ObjCMethodArray?
    func propertyList(in machO: MachOImage) -> ObjCPropertyArray?
    func protocolList(in machO: MachOImage) -> ObjCProtocolArray?
    func demangledName(in machO: MachOImage) -> String?
}

extension ObjCClassRWDataExtProtocol {
    public func classROData(in machO: MachOImage) -> ObjCClassROData? {
        let address: Int = numericCast(layout.ro)
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

    public func methodList(in machO: MachOImage) -> ObjCMethodArray? {
        guard layout.methods > 0 else { return nil }
        guard let ptr = UnsafeRawPointer(
            bitPattern: UInt(layout.methods)
        ) else {
            return nil
        }

        let lists = ObjCMethodArray(
            offset: Int(bitPattern: ptr) - Int(bitPattern: machO.ptr),
            is64Bit: machO.is64Bit
        )

        return lists
    }

    public func propertyList(in machO: MachOImage) -> ObjCPropertyArray? {
        guard layout.properties > 0 else { return nil }
        guard let ptr = UnsafeRawPointer(
            bitPattern: UInt(layout.properties)
        ) else {
            return nil
        }
        let lists = ObjCPropertyArray(
            offset: Int(bitPattern: ptr) - Int(bitPattern: machO.ptr),
            is64Bit: machO.is64Bit
        )
        return lists
    }

    public func protocolList(in machO: MachOImage) -> ObjCProtocolArray? {
        guard layout.protocols > 0 else { return nil }
        guard let ptr = UnsafeRawPointer(
            bitPattern: UInt(layout.protocols)
        ) else {
            return nil
        }
        let lists = ObjCProtocolArray(
            offset: Int(bitPattern: ptr) - Int(bitPattern: machO.ptr)
        )

        return lists
    }


    public func demangledName(in machO: MachOImage) -> String? {
        guard layout.demangledName > 0 else { return nil }
        guard let ptr = UnsafeRawPointer(bitPattern: UInt(layout.demangledName)) else {
            return nil
        }
        return .init(
            cString: ptr.assumingMemoryBound(to: CChar.self),
            encoding: .utf8
        )
    }
}

extension ObjCClassRWDataExtProtocol {
    private var roOffset: Int? {
        MemoryLayout<Layout>.offset(of: \.ro)
    }

    public func classROData(in machO: MachOFile) -> ObjCClassROData? {
        guard let fieldOffset = roOffset else { return nil }

        let unresolved = UnresolvedValue(
            fieldOffset: offset + fieldOffset,
            value: numericCast(layout.ro)
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
}
