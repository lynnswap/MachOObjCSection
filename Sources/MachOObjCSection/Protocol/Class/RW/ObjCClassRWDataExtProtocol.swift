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
        guard let storage = readListArrayStorage(layout.methods, in: machO).value else {
            return nil
        }
        return ObjCMethodArray(
            offset: storage.taggedOffset,
            is64Bit: machO.is64Bit
        )
    }

    public func propertyList(in machO: MachOImage) -> ObjCPropertyArray? {
        guard let storage = readListArrayStorage(layout.properties, in: machO).value else {
            return nil
        }
        return ObjCPropertyArray(
            offset: storage.taggedOffset,
            is64Bit: machO.is64Bit
        )
    }

    public func protocolList(in machO: MachOImage) -> ObjCProtocolArray? {
        guard let storage = readListArrayStorage(layout.protocols, in: machO).value else {
            return nil
        }
        return ObjCProtocolArray(offset: storage.taggedOffset)
    }

    /// Reads the method list-array field and retains recoverable diagnostics.
    @_spi(Diagnostics)
    public func readMethodLists(
        in machO: MachOImage
    ) -> ObjCLoadedListArrayReadResult<
        ObjCMethodList,
        ObjCMethodRelativeListList
    > {
        ObjCMethodArray.readLists(
            readListArrayStorage(layout.methods, in: machO),
            in: machO,
            is64Bit: machO.is64Bit
        )
    }

    /// Reads the property list-array field and retains recoverable diagnostics.
    @_spi(Diagnostics)
    public func readPropertyLists(
        in machO: MachOImage
    ) -> ObjCLoadedListArrayReadResult<
        ObjCPropertyList,
        ObjCPropertyRelativeListList
    > {
        ObjCPropertyArray.readLists(
            readListArrayStorage(layout.properties, in: machO),
            in: machO,
            is64Bit: machO.is64Bit
        )
    }

    /// Reads the protocol list-array field and retains recoverable diagnostics.
    @_spi(Diagnostics)
    public func readProtocolLists(
        in machO: MachOImage
    ) -> ObjCLoadedListArrayReadResult<
        ObjCProtocolArray.ObjCProtocolList,
        ObjCProtocolArray.ObjCProtocolRelativeListList
    > {
        ObjCProtocolArray.readLists(
            readListArrayStorage(layout.protocols, in: machO),
            in: machO
        )
    }

    private func readListArrayStorage(
        _ rawPointer: Layout.Pointer,
        in machO: MachOImage
    ) -> ObjCLoadedListArrayStorageRead {
        let diagnosticRawValue = UInt64(truncatingIfNeeded: rawPointer)
        guard let rawValue = UInt64(exactly: rawPointer) else {
            return .failure(
                representation: nil,
                provenance: .init(),
                reason: .invalidPointer(rawValue: diagnosticRawValue)
            )
        }
        if machO.is64Bit {
            return ObjCLoadedListArrayReader.storage(
                from: rawValue,
                in: machO
            )
        }
        guard let rawValue32 = UInt32(exactly: rawValue) else {
            return .failure(
                representation: nil,
                provenance: .init(),
                reason: .invalidPointer(rawValue: rawValue)
            )
        }
        return ObjCLoadedListArrayReader.storage(
            from: rawValue32,
            in: machO
        )
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
