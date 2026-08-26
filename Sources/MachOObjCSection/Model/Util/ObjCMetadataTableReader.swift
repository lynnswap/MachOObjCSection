//
//  ObjCMetadataTableReader.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit
#if compiler(>=6.0) || (compiler(>=5.10) && hasFeature(AccessLevelOnImport))
internal import FileIO
#else
@_implementationOnly import FileIO
#endif

internal enum ObjCMetadataReadLimits {
    /// One Objective-C metadata table may contain at most this many entries.
    static let maximumListEntries = 65_536

    /// Count and stride share this complete-table budget before any read,
    /// readability probe, allocation, or decode.
    static let maximumTableByteCount = 512 * 1_024

    /// Runtime-only names referenced by one protocol table share a separate
    /// scan budget so many individually bounded malformed strings cannot
    /// multiply into unbounded work.
    static let maximumRuntimeNameTableByteCount = 16 * 1_024 * 1_024
}

internal enum ObjCMetadataTableFailure: Error, Equatable {
    case unsupportedListEncoding
    case invalidListOffset(Int)
    case invalidElementCount(UInt64)
    case invalidSignedElementCount(Int)
    case invalidElementStride(UInt64)
    case elementStrideTooSmall(advertised: Int, minimum: Int)
    case unexpectedElementStride(advertised: Int, expected: Int)
    case misalignedTableOffset(offset: Int, requiredAlignment: Int)
    case misalignedTableAddress(address: UInt, requiredAlignment: Int)
    case excessiveElementCount(actual: Int, maximum: Int)
    case excessiveByteCount(actual: Int, maximum: Int)
    case byteCountOverflow(elementCount: Int, elementSize: Int)
    case rangeOverflow(startOffset: UInt64, byteCount: Int)
    case unreadableFileRange(offset: UInt64, byteCount: Int)
    case unreadableImageRange(address: UInt, byteCount: Int)
}

internal enum ObjCMetadataTableRead<Value> {
    case success(Value)
    case failure(ObjCMetadataTableFailure)
}

internal struct ObjCMetadataTableEntry<Element> {
    let index: Int
    let value: Element
    let logicalOffset: Int?
    let fileOffset: UInt64?
    let address: UInt?
}

internal enum ObjCMetadataTableReader {
    static func readFileLayout<Layout, File: _FileIOProtocol>(
        _ file: File,
        offset: UInt64,
        logicalOffset: Int? = nil,
        as layoutType: Layout.Type
    ) -> ObjCMetadataTableRead<Layout> {
        switch readFile(
            file,
            offset: offset,
            logicalOffset: logicalOffset,
            count: 1,
            as: layoutType
        ) {
        case .success(let entries):
            guard let layout = entries.first?.value else {
                return .failure(
                    .unreadableFileRange(
                        offset: offset,
                        byteCount: MemoryLayout<Layout>.size
                    )
                )
            }
            return .success(layout)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    static func readImageLayout<Layout>(
        address: UInt,
        as layoutType: Layout.Type
    ) -> ObjCMetadataTableRead<Layout> {
        switch readImage(
            address: address,
            count: 1,
            as: layoutType
        ) {
        case .success(let entries):
            guard let layout = entries.first?.value else {
                return .failure(
                    .unreadableImageRange(
                        address: address,
                        byteCount: MemoryLayout<Layout>.size
                    )
                )
            }
            return .success(layout)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    static func exactCount(
        _ rawCount: UInt64,
        maximumIntValue: UInt64 = UInt64(Int.max)
    ) -> ObjCMetadataTableRead<Int> {
        guard rawCount <= maximumIntValue,
              let count = Int(exactly: rawCount) else {
            return .failure(.invalidElementCount(rawCount))
        }
        return .success(count)
    }

    static func exactStride(
        _ rawStride: UInt64,
        maximumIntValue: UInt64 = UInt64(Int.max)
    ) -> ObjCMetadataTableRead<Int> {
        guard rawStride <= maximumIntValue,
              let stride = Int(exactly: rawStride) else {
            return .failure(.invalidElementStride(rawStride))
        }
        return .success(stride)
    }

    static func checkedByteCount(
        count: Int,
        stride: Int
    ) -> ObjCMetadataTableRead<Int> {
        guard count >= 0 else {
            return .failure(.invalidSignedElementCount(count))
        }
        guard count > 0 else { return .success(0) }
        guard stride >= 0 else {
            return .failure(.invalidElementStride(UInt64(bitPattern: Int64(stride))))
        }
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: stride)
        guard !overflow else {
            return .failure(.byteCountOverflow(elementCount: count, elementSize: stride))
        }
        guard count <= ObjCMetadataReadLimits.maximumListEntries else {
            return .failure(
                .excessiveElementCount(
                    actual: count,
                    maximum: ObjCMetadataReadLimits.maximumListEntries
                )
            )
        }
        guard byteCount <= ObjCMetadataReadLimits.maximumTableByteCount else {
            return .failure(
                .excessiveByteCount(
                    actual: byteCount,
                    maximum: ObjCMetadataReadLimits.maximumTableByteCount
                )
            )
        }
        return .success(byteCount)
    }

    static func readFile<Element, File: _FileIOProtocol>(
        _ file: File,
        offset: UInt64,
        logicalOffset: Int? = nil,
        count: Int,
        stride: Int? = nil,
        as elementType: Element.Type
    ) -> ObjCMetadataTableRead<[ObjCMetadataTableEntry<Element>]> {
        let elementSize = MemoryLayout<Element>.size
        let stride = stride ?? elementSize
        if count > 0, stride < elementSize {
            return .failure(
                .elementStrideTooSmall(advertised: stride, minimum: elementSize)
            )
        }

        let byteCount: Int
        switch checkedByteCount(count: count, stride: stride) {
        case .success(let value): byteCount = value
        case .failure(let failure): return .failure(failure)
        }

        guard let readOffset = Int(exactly: offset), readOffset >= 0 else {
            return .failure(.unreadableFileRange(offset: offset, byteCount: byteCount))
        }
        let (_, endOverflow) = offset.addingReportingOverflow(UInt64(byteCount))
        guard !endOverflow else {
            return .failure(.rangeOverflow(startOffset: offset, byteCount: byteCount))
        }
        if let logicalOffset {
            let (_, logicalEndOverflow) = logicalOffset.addingReportingOverflow(byteCount)
            guard !logicalEndOverflow else {
                return .failure(.rangeOverflow(startOffset: offset, byteCount: byteCount))
            }
        }
        guard readOffset <= file.size,
              byteCount <= file.size - readOffset else {
            return .failure(.unreadableFileRange(offset: offset, byteCount: byteCount))
        }

        guard let data = try? file.readData(offset: readOffset, length: byteCount),
              data.count == byteCount else {
            return .failure(.unreadableFileRange(offset: offset, byteCount: byteCount))
        }

        var result: [ObjCMetadataTableEntry<Element>] = []
        result.reserveCapacity(count)
        return data.withUnsafeBytes { bytes in
            for index in 0..<count {
                let (delta, deltaOverflow) = index.multipliedReportingOverflow(by: stride)
                guard !deltaOverflow else {
                    return .failure(.rangeOverflow(startOffset: offset, byteCount: byteCount))
                }
                let (entryFileOffset, fileOffsetOverflow) = offset.addingReportingOverflow(UInt64(delta))
                let entryLogicalOffset: Int?
                if let logicalOffset {
                    let (value, overflow) = logicalOffset.addingReportingOverflow(delta)
                    guard !overflow else {
                        return .failure(.rangeOverflow(startOffset: offset, byteCount: byteCount))
                    }
                    entryLogicalOffset = value
                } else {
                    entryLogicalOffset = nil
                }
                guard !fileOffsetOverflow else {
                    return .failure(.rangeOverflow(startOffset: offset, byteCount: byteCount))
                }
                result.append(
                    .init(
                        index: index,
                        value: bytes.loadUnaligned(fromByteOffset: delta, as: elementType),
                        logicalOffset: entryLogicalOffset,
                        fileOffset: entryFileOffset,
                        address: nil
                    )
                )
            }
            return .success(result)
        }
    }

    static func readImage<Element>(
        address: UInt,
        logicalOffset: Int? = nil,
        count: Int,
        stride: Int? = nil,
        as elementType: Element.Type
    ) -> ObjCMetadataTableRead<[ObjCMetadataTableEntry<Element>]> {
        let elementSize = MemoryLayout<Element>.size
        let stride = stride ?? elementSize
        if count > 0, stride < elementSize {
            return .failure(
                .elementStrideTooSmall(advertised: stride, minimum: elementSize)
            )
        }

        let byteCount: Int
        switch checkedByteCount(count: count, stride: stride) {
        case .success(let value): byteCount = value
        case .failure(let failure): return .failure(failure)
        }
        let (_, endOverflow) = address.addingReportingOverflow(UInt(byteCount))
        guard !endOverflow else {
            return .failure(
                .rangeOverflow(startOffset: UInt64(address), byteCount: byteCount)
            )
        }
        if let logicalOffset {
            let (_, logicalEndOverflow) = logicalOffset.addingReportingOverflow(byteCount)
            guard !logicalEndOverflow else {
                return .failure(
                    .rangeOverflow(startOffset: UInt64(address), byteCount: byteCount)
                )
            }
        }
        if byteCount > 0 {
            guard let pointer = UnsafeRawPointer(bitPattern: address),
                  isPointerSafelyReadable(pointer, length: byteCount) else {
                return .failure(.unreadableImageRange(address: address, byteCount: byteCount))
            }
        }

        var result: [ObjCMetadataTableEntry<Element>] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let (delta, deltaOverflow) = index.multipliedReportingOverflow(by: stride)
            guard !deltaOverflow else {
                return .failure(
                    .rangeOverflow(startOffset: UInt64(address), byteCount: byteCount)
                )
            }
            let (entryAddress, addressOverflow) = address.addingReportingOverflow(UInt(delta))
            guard !addressOverflow,
                  let pointer = UnsafeRawPointer(bitPattern: entryAddress) else {
                return .failure(
                    .rangeOverflow(startOffset: UInt64(address), byteCount: byteCount)
                )
            }
            let entryLogicalOffset: Int?
            if let logicalOffset {
                let (value, overflow) = logicalOffset.addingReportingOverflow(delta)
                guard !overflow else {
                    return .failure(
                        .rangeOverflow(startOffset: UInt64(address), byteCount: byteCount)
                    )
                }
                entryLogicalOffset = value
            } else {
                entryLogicalOffset = nil
            }
            result.append(
                .init(
                    index: index,
                    value: pointer.loadUnaligned(as: elementType),
                    logicalOffset: entryLogicalOffset,
                    fileOffset: nil,
                    address: entryAddress
                )
            )
        }
        return .success(result)
    }
}
