//
//  ObjCMemberTableReading.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit

internal enum ObjCMetadataTableEntryFailureReason: Error, Equatable {
    case invalidLogicalOffset
    case invalidImplementationOffset
    case invalidRelativeDisplacement
    case unreadableFileRange(offset: UInt64, byteCount: Int)
}

internal struct ObjCMetadataTableEntryFailure: Equatable {
    let index: Int
    let reason: ObjCMetadataTableEntryFailureReason
}

internal struct ObjCMemberTableReadSuccess<Value> {
    let values: [Value]
    let failures: [ObjCMetadataTableEntryFailure]
}

internal enum ObjCMemberTableReadOutcome<Value> {
    case success(ObjCMemberTableReadSuccess<Value>)
    case failure(ObjCMetadataTableFailure)

    var values: [Value]? {
        guard case .success(let success) = self else { return nil }
        return success.values
    }
}

extension EntrySizeListProtocol {
    private func checkedCount() -> ObjCMetadataTableRead<Int> {
        ObjCMetadataTableReader.exactCount(UInt64(header.count))
    }

    private func checkedStride(
        count: Int,
        expected: Int
    ) -> ObjCMetadataTableRead<Int> {
        guard count > 0 else { return .success(expected) }
        let rawStride = UInt64(header.entsizeAndFlags & ~Self.flagMask)
        let stride: Int
        switch ObjCMetadataTableReader.exactStride(rawStride) {
        case .success(let value): stride = value
        case .failure(let failure): return .failure(failure)
        }
        guard stride == expected else {
            return .failure(
                .unexpectedElementStride(advertised: stride, expected: expected)
            )
        }
        return .success(stride)
    }

    internal func readFileTable<Element>(
        in machO: MachOFile,
        expectedStride: Int,
        requiredAlignment: Int,
        as elementType: Element.Type
    ) -> ObjCMetadataTableRead<[ObjCMetadataTableEntry<Element>]> {
        guard offset >= 0, let listOffset = UInt64(exactly: offset) else {
            return .failure(.invalidListOffset(offset))
        }
        guard let (file, fileListOffset) = machO.fileHandleAndOffset(
            forOffset: listOffset
        ) else {
            return .failure(
                .unreadableFileRange(
                    offset: listOffset,
                    byteCount: MemoryLayout<Header>.size
                )
            )
        }

        let count: Int
        switch checkedCount() {
        case .success(let value): count = value
        case .failure(let failure): return .failure(failure)
        }
        guard count > 0 else { return .success([]) }
        guard requiredAlignment > 0, offset.isMultiple(of: requiredAlignment) else {
            return .failure(
                .misalignedTableOffset(
                    offset: offset,
                    requiredAlignment: requiredAlignment
                )
            )
        }
        let stride: Int
        switch checkedStride(count: count, expected: expectedStride) {
        case .success(let value): stride = value
        case .failure(let failure): return .failure(failure)
        }

        let headerSize = MemoryLayout<Header>.size
        let (logicalTableOffset, logicalOverflow) = offset.addingReportingOverflow(headerSize)
        let (fileTableOffset, fileOverflow) = fileListOffset.addingReportingOverflow(
            UInt64(headerSize)
        )
        guard !logicalOverflow, !fileOverflow else {
            return .failure(
                .rangeOverflow(startOffset: fileListOffset, byteCount: 0)
            )
        }
        return ObjCMetadataTableReader.readFile(
            file,
            offset: fileTableOffset,
            logicalOffset: logicalTableOffset,
            count: count,
            stride: stride,
            as: elementType
        )
    }

    internal func readImageTable<Element>(
        in machO: MachOImage,
        expectedStride: Int,
        requiredAlignment: Int,
        as elementType: Element.Type
    ) -> ObjCMetadataTableRead<[ObjCMetadataTableEntry<Element>]> {
        let imageAddress = UInt(bitPattern: machO.ptr)
        guard let listAddress = addingSignedDisplacement(offset, to: imageAddress) else {
            return .failure(.invalidListOffset(offset))
        }

        let count: Int
        switch checkedCount() {
        case .success(let value): count = value
        case .failure(let failure): return .failure(failure)
        }
        guard count > 0 else { return .success([]) }
        guard requiredAlignment > 0,
              listAddress.isMultiple(of: UInt(requiredAlignment)) else {
            return .failure(
                .misalignedTableAddress(
                    address: listAddress,
                    requiredAlignment: requiredAlignment
                )
            )
        }
        let stride: Int
        switch checkedStride(count: count, expected: expectedStride) {
        case .success(let value): stride = value
        case .failure(let failure): return .failure(failure)
        }

        let headerSize = MemoryLayout<Header>.size
        let (logicalTableOffset, logicalOverflow) = offset.addingReportingOverflow(headerSize)
        let (tableAddress, addressOverflow) = listAddress.addingReportingOverflow(
            UInt(headerSize)
        )
        guard !logicalOverflow, !addressOverflow else {
            return .failure(
                .rangeOverflow(startOffset: UInt64(listAddress), byteCount: 0)
            )
        }
        return ObjCMetadataTableReader.readImage(
            address: tableAddress,
            logicalOffset: logicalTableOffset,
            count: count,
            stride: stride,
            as: elementType
        )
    }
}
