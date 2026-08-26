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
        readMethodArray(in: machO).value
    }

    public func propertyList(in machO: MachOImage) -> ObjCPropertyArray? {
        readPropertyArray(in: machO).value
    }

    public func protocolList(in machO: MachOImage) -> ObjCProtocolArray? {
        readProtocolArray(in: machO).value
    }

    /// Reads the method list-array field and retains recoverable diagnostics.
    @_spi(Diagnostics)
    public func readMethodLists(
        in machO: MachOImage
    ) -> ObjCLoadedListArrayReadResult<
        ObjCMethodList,
        ObjCMethodRelativeListList
    > {
        let owner = loadedListArrayOwner(kind: .method, in: machO)
        switch readMethodArray(in: machO) {
        case .absent:
            return .init(representation: nil)
        case let .failure(provenance, reason):
            return ObjCLoadedListArrayReader.tableFailure(
                representation: listArrayRepresentation(
                    layout.methods,
                    in: machO
                ),
                owner: owner,
                provenance: provenance,
                failure: reason
            )
        case .value(let array):
            return array.readLists(in: machO)
        }
    }

    /// Reads the property list-array field and retains recoverable diagnostics.
    @_spi(Diagnostics)
    public func readPropertyLists(
        in machO: MachOImage
    ) -> ObjCLoadedListArrayReadResult<
        ObjCPropertyList,
        ObjCPropertyRelativeListList
    > {
        let owner = loadedListArrayOwner(kind: .property, in: machO)
        switch readPropertyArray(in: machO) {
        case .absent:
            return .init(representation: nil)
        case let .failure(provenance, reason):
            return ObjCLoadedListArrayReader.tableFailure(
                representation: listArrayRepresentation(
                    layout.properties,
                    in: machO
                ),
                owner: owner,
                provenance: provenance,
                failure: reason
            )
        case .value(let array):
            return array.readLists(in: machO)
        }
    }

    /// Reads the protocol list-array field and retains recoverable diagnostics.
    @_spi(Diagnostics)
    public func readProtocolLists(
        in machO: MachOImage
    ) -> ObjCLoadedListArrayReadResult<
        ObjCProtocolArray.ObjCProtocolList,
        ObjCProtocolArray.ObjCProtocolRelativeListList
    > {
        let owner = loadedListArrayOwner(kind: .protocol, in: machO)
        switch readProtocolArray(in: machO) {
        case .absent:
            return .init(representation: nil)
        case let .failure(provenance, reason):
            return ObjCLoadedListArrayReader.tableFailure(
                representation: listArrayRepresentation(
                    layout.protocols,
                    in: machO
                ),
                owner: owner,
                provenance: provenance,
                failure: reason
            )
        case .value(let array):
            return array.readLists(in: machO)
        }
    }

    private func readMethodArray(
        in machO: MachOImage
    ) -> ObjCMetadataReferenceRead<ObjCMethodArray> {
        readListArrayStorage(layout.methods, in: machO).map { storage in
            ObjCMethodArray(
                offset: storage.taggedOffset,
                is64Bit: machO.is64Bit
            )
        }
    }

    private func readPropertyArray(
        in machO: MachOImage
    ) -> ObjCMetadataReferenceRead<ObjCPropertyArray> {
        readListArrayStorage(layout.properties, in: machO).map { storage in
            ObjCPropertyArray(
                offset: storage.taggedOffset,
                is64Bit: machO.is64Bit
            )
        }
    }

    private func readProtocolArray(
        in machO: MachOImage
    ) -> ObjCMetadataReferenceRead<ObjCProtocolArray> {
        readListArrayStorage(layout.protocols, in: machO).map { storage in
            ObjCProtocolArray(offset: storage.taggedOffset)
        }
    }

    private func readListArrayStorage(
        _ rawPointer: Layout.Pointer,
        in machO: MachOImage
    ) -> ObjCMetadataReferenceRead<ObjCLoadedListArrayStorage> {
        let diagnosticRawValue = UInt64(truncatingIfNeeded: rawPointer)
        guard let rawValue = UInt64(exactly: rawPointer) else {
            return .failure(
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
                provenance: .init(),
                reason: .invalidPointer(rawValue: rawValue)
            )
        }
        return ObjCLoadedListArrayReader.storage(
            from: rawValue32,
            in: machO
        )
    }

    private func listArrayRepresentation(
        _ rawPointer: Layout.Pointer,
        in machO: MachOImage
    ) -> ObjCLoadedListArrayRepresentation? {
        guard let rawValue = UInt64(exactly: rawPointer) else { return nil }
        return ObjCLoadedListArrayReader.representation(
            forRawValue: rawValue,
            in: machO
        )
    }

    private func loadedListArrayOwner(
        kind: ObjCMetadataTableDiagnostic.RWExtensionListKind,
        in machO: MachOImage
    ) -> ObjCMetadataTableDiagnostic.Owner {
        .loadedRWExtension(
            kind: kind,
            pointerWidth: machO.is64Bit ? .bits64 : .bits32
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

extension ObjCMetadataReferenceRead {
    fileprivate func map<MappedValue>(
        _ transform: (Value) -> MappedValue
    ) -> ObjCMetadataReferenceRead<MappedValue> {
        switch self {
        case .absent:
            return .absent
        case .value(let value):
            return .value(transform(value))
        case let .failure(provenance, reason):
            return .failure(provenance: provenance, reason: reason)
        }
    }
}
