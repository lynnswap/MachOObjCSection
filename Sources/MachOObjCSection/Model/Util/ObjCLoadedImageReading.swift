//
//  ObjCLoadedImageReading.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit

internal enum ObjCLoadedImageRead<Value> {
    case absent
    case value(Value)
    case failure(
        provenance: ObjCMetadataTableDiagnostic.Provenance,
        reason: ObjCMetadataTableDiagnostic.Failure
    )

    var value: Value? {
        guard case .value(let value) = self else { return nil }
        return value
    }
}

internal enum ObjCLoadedImageReader {
    static func entrySizeFailure<List: EntrySizeListProtocol>(
        for list: List,
        expected: Int
    ) -> ObjCMetadataTableFailure? {
        guard list.header.layout.count > 0 else { return nil }
        let rawStride = UInt64(list.header.layout.entsizeAndFlags & ~List.flagMask)
        let stride: Int
        switch ObjCMetadataTableReader.exactStride(rawStride) {
        case .success(let value):
            stride = value
        case .failure(let failure):
            return failure
        }
        guard stride == expected else {
            return .unexpectedElementStride(advertised: stride, expected: expected)
        }
        return nil
    }

    static func canonicalAddress<Pointer: FixedWidthInteger>(
        _ rawPointer: Pointer,
        in machO: MachOImage
    ) -> UInt? {
        guard let rawValue = UInt64(exactly: rawPointer), rawValue != 0 else {
            return nil
        }
        let strippedAddress = machO.stripPointerTags(of: rawValue)
        guard strippedAddress != 0 else { return nil }
        return UInt(exactly: strippedAddress)
    }

    static func logicalOffset(
        of address: UInt,
        in machO: MachOImage
    ) -> Int? {
        signedDisplacement(
            from: UInt(bitPattern: machO.ptr),
            to: address
        )
    }

    static func provenance<Pointer: FixedWidthInteger>(
        for rawPointer: Pointer,
        in machO: MachOImage
    ) -> ObjCMetadataTableDiagnostic.Provenance {
        guard let address = canonicalAddress(rawPointer, in: machO) else {
            return .init()
        }
        return .init(
            logicalOffset: logicalOffset(of: address, in: machO),
            imageAddress: address
        )
    }

    static func readLayout<Layout, Pointer: FixedWidthInteger>(
        from rawPointer: Pointer,
        in machO: MachOImage,
        as layoutType: Layout.Type
    ) -> ObjCLoadedImageRead<(layout: Layout, offset: Int, address: UInt)> {
        guard rawPointer != 0 else { return .absent }
        guard let address = canonicalAddress(rawPointer, in: machO) else {
            let rawValue = UInt64(exactly: rawPointer) ?? 0
            return .failure(
                provenance: .init(),
                reason: .invalidPointer(rawValue: rawValue)
            )
        }
        let offset = logicalOffset(of: address, in: machO)
        let provenance = ObjCMetadataTableDiagnostic.Provenance(
            logicalOffset: offset,
            imageAddress: address
        )
        guard let offset else {
            return .failure(
                provenance: provenance,
                reason: .invalidEntryArithmetic(
                    baseAddress: UInt(bitPattern: machO.ptr),
                    targetAddress: address
                )
            )
        }
        switch ObjCMetadataTableReader.readImageLayout(
            address: address,
            as: layoutType
        ) {
        case .success(let layout):
            return .value((layout, offset, address))
        case .failure:
            return .failure(
                provenance: provenance,
                reason: .unreadableReferencedLayout(
                    address: address,
                    byteCount: MemoryLayout<Layout>.size
                )
            )
        }
    }

    static func readEntrySizeList<List, Pointer: FixedWidthInteger>(
        from rawPointer: Pointer,
        in machO: MachOImage,
        validateList: (List) -> ObjCMetadataTableFailure?,
        makeList: (EntrySizeListHeader, Int) -> List
    ) -> ObjCLoadedImageRead<List> {
        switch readLayout(
            from: rawPointer,
            in: machO,
            as: EntrySizeListHeader.self
        ) {
        case .absent:
            return .absent
        case let .failure(provenance, reason):
            return .failure(provenance: provenance, reason: reason)
        case .value(let read):
            let list = makeList(read.layout, read.offset)
            if let failure = validateList(list) {
                return .failure(
                    provenance: .init(
                        logicalOffset: read.offset,
                        imageAddress: read.address
                    ),
                    reason: .init(failure)
                )
            }
            return .value(list)
        }
    }

    static func readRelatedLayout<Layout, Pointer: FixedWidthInteger>(
        from rawPointer: Pointer,
        in machO: MachOImage,
        as layoutType: Layout.Type
    ) -> ObjCLoadedImageRead<(
        image: MachOImage,
        layout: Layout,
        offset: Int,
        address: UInt
    )> {
        guard rawPointer != 0 else { return .absent }
        guard let address = canonicalAddress(rawPointer, in: machO),
              let pointer = UnsafeRawPointer(bitPattern: address) else {
            return .failure(
                provenance: .init(),
                reason: .invalidPointer(
                    rawValue: UInt64(exactly: rawPointer) ?? 0
                )
            )
        }

        let targetMachO: MachOImage
        if machO.contains(ptr: pointer) {
            targetMachO = machO
        } else if let resolved = machO.resolveImage(containing: pointer) {
            targetMachO = resolved
        } else {
            return .failure(
                provenance: .init(imageAddress: address),
                reason: .missingReferencedImage(address: address)
            )
        }

        let targetBase = UInt(bitPattern: targetMachO.ptr)
        guard let offset = signedDisplacement(from: targetBase, to: address) else {
            return .failure(
                provenance: .init(imageAddress: address),
                reason: .invalidEntryArithmetic(
                    baseAddress: targetBase,
                    targetAddress: address
                )
            )
        }
        let provenance = ObjCMetadataTableDiagnostic.Provenance(
            logicalOffset: offset,
            imageAddress: address
        )
        switch ObjCMetadataTableReader.readImageLayout(
            address: address,
            as: layoutType
        ) {
        case .success(let layout):
            return .value((targetMachO, layout, offset, address))
        case .failure:
            return .failure(
                provenance: provenance,
                reason: .unreadableReferencedLayout(
                    address: address,
                    byteCount: MemoryLayout<Layout>.size
                )
            )
        }
    }
}
