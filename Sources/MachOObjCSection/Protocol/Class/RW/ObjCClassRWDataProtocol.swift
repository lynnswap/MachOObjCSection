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
        readClassROData(in: machO).value
    }

    internal func readClassROData(
        in machO: MachOImage
    ) -> ObjCMetadataFieldRead<ObjCClassROData> {
        guard hasRO else { return .absent }

        // ro_or_rw_ext is PAC-signed on arm64e (objc4 stores it as a
        // PtrauthAuthAndStrip pointer). Strip the PAC bits before dereferencing.
        let strippedAddress = machO.stripPointerTags(of: numericCast(layout.ro_or_rw_ext))
        guard strippedAddress != 0 else { return .absent }
        guard let address = UInt(exactly: strippedAddress),
              let ptr = UnsafeRawPointer(bitPattern: address) else {
            return .failure(.missingBackingData)
        }
        // Foreign-platform binaries loaded standalone (e.g. an iOS simulator
        // framework `dlopen`'d on macOS) may carry stale preopt offsets here
        // that point to unmapped memory; probe before the load to avoid a
        // segfault inside the implicit memcpy of `.pointee`.
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

    public func ext(in machO: MachOImage) -> ObjCClassRWDataExt? {
        guard hasExt else { return nil }

        // The low bit is the hasExt flag — clear it before stripping PAC bits
        // from the upper portion of the pointer.
        let rawAddress = numericCast(layout.ro_or_rw_ext) & ~UInt64(1)
        let strippedAddress = machO.stripPointerTags(of: rawAddress)
        guard let ptr = UnsafeRawPointer(bitPattern: UInt(strippedAddress)) else {
            return nil
        }
        // Foreign-platform binaries loaded standalone (e.g. an iOS simulator
        // framework `dlopen`'d on macOS) may carry stale preopt offsets here
        // that point to unmapped memory; probe before the load to avoid a
        // segfault inside the implicit memcpy of `.pointee`.
        guard isPointerSafelyReadable(ptr, length: MemoryLayout<ObjCClassRWDataExt.Layout>.size) else {
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
