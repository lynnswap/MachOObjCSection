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
    // class_rw_ext_t pointer fields (`ro`, `methods`, `properties`, `protocols`,
    // `demangledName`) are PAC-signed on arm64e at runtime — strip the PAC bits
    // before dereferencing.

    public func classROData(in machO: MachOImage) -> ObjCClassROData? {
        readClassROData(in: machO).value
    }

    internal func readClassROData(
        in machO: MachOImage
    ) -> ObjCMetadataFieldRead<ObjCClassROData> {
        let strippedAddress = machO.stripPointerTags(of: numericCast(layout.ro))
        guard strippedAddress != 0 else { return .absent }
        guard let address = UInt(exactly: strippedAddress),
              let ptr = UnsafeRawPointer(bitPattern: address) else {
            return .failure(.missingBackingData)
        }
        let byteCount = MemoryLayout<ObjCClassROData.Layout>.size
        guard isPointerSafelyReadable(ptr, length: byteCount) else {
            return .failure(
                .unreadableImageRange(address: address, byteCount: byteCount)
            )
        }
        return .value(
            ObjCClassROData(
                layout: ptr.loadUnaligned(as: ObjCClassROData.Layout.self),
                offset: Int(bitPattern: ptr) - Int(bitPattern: machO.ptr)
            )
        )
    }

    public func methodList(in machO: MachOImage) -> ObjCMethodArray? {
        guard layout.methods > 0 else { return nil }
        let strippedAddress = machO.stripPointerTags(of: numericCast(layout.methods))
        guard let ptr = UnsafeRawPointer(
            bitPattern: UInt(strippedAddress)
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
        let strippedAddress = machO.stripPointerTags(of: numericCast(layout.properties))
        guard let ptr = UnsafeRawPointer(
            bitPattern: UInt(strippedAddress)
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
        let strippedAddress = machO.stripPointerTags(of: numericCast(layout.protocols))
        guard let ptr = UnsafeRawPointer(
            bitPattern: UInt(strippedAddress)
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
        let strippedAddress = machO.stripPointerTags(of: numericCast(layout.demangledName))
        guard let ptr = UnsafeRawPointer(bitPattern: UInt(strippedAddress)) else {
            return nil
        }
        return .init(
            cString: ptr.assumingMemoryBound(to: CChar.self),
            encoding: .utf8
        )
    }
}
