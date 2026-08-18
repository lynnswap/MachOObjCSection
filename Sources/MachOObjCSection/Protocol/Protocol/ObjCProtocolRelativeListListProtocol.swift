//
//  ObjCProtocolRelativeListListProtocol.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2024/12/01
//

import Foundation
@_spi(Support) import MachOKit

@inline(__always)
internal func exactRelativeListCount(
    _ rawCount: UInt32,
    maximumIntValue: UInt64 = UInt64(Int.max)
) -> Int? {
    guard UInt64(rawCount) <= maximumIntValue else { return nil }
    return Int(exactly: rawCount)
}

public protocol ObjCProtocolRelativeListListProtocol: RelativeListListProtocol where List: ObjCProtocolListProtocol {
    @_spi(Core)
    init(offset: Int, header: Header)

    @_spi(Core)
    init(ptr: UnsafeRawPointer, offset: Int)
}

internal struct ObjCProtocolRelativeFileLocation {
    let image: MachOFile
    let file: MachOFile.File
    let fileOffset: UInt64
}

extension ObjCProtocolRelativeFileLocation {
    internal static func direct(
        in machO: MachOFile,
        fileOffset: UInt64
    ) -> Self? {
        guard let (file, resolvedOffset) = machO.fileHandleAndOffset(forOffset: fileOffset) else {
            return nil
        }
        return .init(image: machO, file: file, fileOffset: resolvedOffset)
    }
}

internal func defaultRelativeFileLocation(
    in machO: MachOFile,
    for entry: RelativeListListEntry
) -> ObjCProtocolRelativeFileLocation? {
    guard let location = machO.relativeListLocation(for: entry) else { return nil }
    return .init(
        image: location.image,
        file: location.cache.fileHandle,
        fileOffset: location.fileOffset
    )
}

internal func defaultRelativeImage(at index: Int) -> MachOImage? {
#if canImport(MachO)
    guard let cache: DyldCacheLoaded = .current else { return nil }
    return cache.machO(at: index)
#else
    return nil
#endif
}

extension ObjCProtocolRelativeListListProtocol {
    private func checkedCountAndStride() -> Result<(count: Int, stride: Int), ObjCProtocolListResolutionFailure> {
        guard let count = exactRelativeListCount(header.count) else {
            return .failure(
                .init(
                    listOffset: offset,
                    failure: .invalidElementCount(UInt64(header.count))
                )
            )
        }
        let rawStride = header.entsizeAndFlags & ~Self.flagMask
        guard let stride = Int(exactly: rawStride) else {
            return .failure(
                .init(
                    listOffset: offset,
                    failure: .invalidRelativeEntrySize(
                        advertised: rawStride,
                        minimum: MemoryLayout<Entry.Layout>.size
                    )
                )
            )
        }
        let minimumStride = MemoryLayout<Entry.Layout>.size
        guard stride >= minimumStride else {
            return .failure(
                .init(
                    listOffset: offset,
                    failure: .invalidRelativeEntrySize(
                        advertised: rawStride,
                        minimum: minimumStride
                    )
                )
            )
        }
        return .success((count, stride))
    }

    private func checkedEntry(
        layouts: [Entry.Layout],
        imageIndex: Int,
        stride: Int
    ) -> Result<Entry, ObjCProtocolListResolutionFailure> {
        guard let (index, layout) = layouts.enumerated().first(
            where: { _, layout in Int(layout.imageIndex) == imageIndex }
        ) else {
            return .failure(
                .init(
                    listOffset: offset,
                    failure: .relativeEntryNotFound(imageIndex: imageIndex)
                )
            )
        }
        let (baseOffset, baseOverflow) = offset.addingReportingOverflow(MemoryLayout<Header>.size)
        let (entryDelta, deltaOverflow) = index.multipliedReportingOverflow(by: stride)
        let (entryOffset, entryOverflow) = baseOffset.addingReportingOverflow(entryDelta)
        guard !baseOverflow, !deltaOverflow, !entryOverflow else {
            return .failure(.init(listOffset: offset, failure: .invalidRelativeListLocation))
        }
        return .success(Entry(offset: entryOffset, layout: layout))
    }

    internal func resolveList(
        in machO: MachOFile,
        forImageIndex imageIndex: Int,
        locationResolver: (MachOFile, Entry) -> ObjCProtocolRelativeFileLocation? = defaultRelativeFileLocation
    ) -> ObjCProtocolListResolution<MachOFile, List> {
        guard let listOffset = UInt64(exactly: offset),
              let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forOffset: listOffset) else {
            return .failure(.init(listOffset: offset, failure: .missingListBackingData))
        }
        let (tableOffset, tableOverflow) = fileOffset.addingReportingOverflow(
            UInt64(MemoryLayout<Header>.size)
        )
        guard !tableOverflow else {
            return .failure(.init(listOffset: offset, failure: .invalidRelativeListLocation))
        }

        let countAndStride: (count: Int, stride: Int)
        switch checkedCountAndStride() {
        case .success(let value): countAndStride = value
        case .failure(let failure): return .failure(failure)
        }

        let layouts: [Entry.Layout]
        switch fileHandle.readProtocolTable(
            offset: tableOffset,
            count: countAndStride.count,
            stride: countAndStride.stride,
            as: Entry.Layout.self
        ) {
        case .success(let value):
            layouts = value
        case .failure(let failure):
            return .failure(.init(listOffset: offset, failure: failure.diagnosticFailure))
        }

        let entry: Entry
        switch checkedEntry(
            layouts: layouts,
            imageIndex: imageIndex,
            stride: countAndStride.stride
        ) {
        case .success(let value): entry = value
        case .failure(let failure): return .failure(failure)
        }

        guard let location = locationResolver(machO, entry) else {
            return .failure(.init(listOffset: entry.offset, failure: .invalidRelativeListLocation))
        }
        let (relativeOffset, relativeOverflow) = entry.offset.addingReportingOverflow(entry.listOffset)
        guard !relativeOverflow, let canonicalOffset = UInt64(exactly: relativeOffset) else {
            return .failure(.init(listOffset: entry.offset, failure: .invalidRelativeListLocation))
        }
        guard let header: List.Header = location.file.readProtocolLayout(
            offset: location.fileOffset,
            as: List.Header.self
        ) else {
            return .failure(
                .init(
                    listOffset: relativeOffset,
                    failure: .unreadableFileHeader(
                        offset: location.fileOffset,
                        byteCount: MemoryLayout<List.Header>.size
                    )
                )
            )
        }
        guard let listOffset = Int(exactly: canonicalOffset) else {
            return .failure(.init(listOffset: entry.offset, failure: .invalidRelativeListLocation))
        }
        return .resolved(location.image, List(offset: listOffset, header: header))
    }

    internal func resolveList(
        in machO: MachOImage,
        forImageIndex imageIndex: Int,
        imageResolver: (Int) -> MachOImage? = defaultRelativeImage
    ) -> ObjCProtocolListResolution<MachOImage, List> {
        let countAndStride: (count: Int, stride: Int)
        switch checkedCountAndStride() {
        case .success(let value): countAndStride = value
        case .failure(let failure): return .failure(failure)
        }
        guard countAndStride.count <= ObjCProtocolReadLimits.maximumLoadedListEntries else {
            return .failure(
                .init(
                    listOffset: offset,
                    failure: .excessiveElementCount(
                        actual: countAndStride.count,
                        maximum: ObjCProtocolReadLimits.maximumLoadedListEntries
                    )
                )
            )
        }

        let (byteCount, byteOverflow) = countAndStride.count.multipliedReportingOverflow(
            by: countAndStride.stride
        )
        guard !byteOverflow else {
            return .failure(
                .init(
                    listOffset: offset,
                    failure: .byteCountOverflow(
                        elementCount: countAndStride.count,
                        elementSize: countAndStride.stride
                    )
                )
            )
        }
        guard let listAddress = addingSignedDisplacement(offset, to: UInt(bitPattern: machO.ptr)) else {
            return .failure(.init(listOffset: offset, failure: .invalidRelativeListLocation))
        }
        let (tableAddress, tableOverflow) = listAddress.addingReportingOverflow(
            UInt(MemoryLayout<Header>.size)
        )
        let (_, endOverflow) = tableAddress.addingReportingOverflow(UInt(byteCount))
        guard !tableOverflow, !endOverflow else {
            return .failure(.init(listOffset: offset, failure: .invalidRelativeListLocation))
        }
        if byteCount > 0 {
            guard let tablePointer = UnsafeRawPointer(bitPattern: tableAddress),
                  isPointerSafelyReadable(tablePointer, length: byteCount) else {
                return .failure(
                    .init(
                        listOffset: offset,
                        failure: .unreadableImageRange(address: tableAddress, byteCount: byteCount)
                    )
                )
            }
        }

        var layouts: [Entry.Layout] = []
        layouts.reserveCapacity(countAndStride.count)
        for index in 0..<countAndStride.count {
            let entryAddress = tableAddress + UInt(index * countAndStride.stride)
            guard let pointer = UnsafeRawPointer(bitPattern: entryAddress) else {
                return .failure(.init(listOffset: offset, failure: .invalidRelativeListLocation))
            }
            layouts.append(pointer.loadUnaligned(as: Entry.Layout.self))
        }

        let entry: Entry
        switch checkedEntry(
            layouts: layouts,
            imageIndex: imageIndex,
            stride: countAndStride.stride
        ) {
        case .success(let value): entry = value
        case .failure(let failure): return .failure(failure)
        }

        let (relativeOffset, relativeOverflow) = entry.offset.addingReportingOverflow(entry.listOffset)
        guard !relativeOverflow,
              let address = addingSignedDisplacement(
                relativeOffset,
                to: UInt(bitPattern: machO.ptr)
              ),
              let pointer = UnsafeRawPointer(bitPattern: address) else {
            return .failure(.init(listOffset: entry.offset, failure: .invalidRelativeListLocation))
        }
        guard isPointerSafelyReadable(pointer, length: MemoryLayout<List.Header>.size) else {
            return .failure(
                .init(
                    listOffset: relativeOffset,
                    failure: .unreadableImageHeader(
                        address: address,
                        byteCount: MemoryLayout<List.Header>.size
                    )
                )
            )
        }
        guard let targetMachO = imageResolver(imageIndex),
              let targetOffset = signedDisplacement(
                from: UInt(bitPattern: targetMachO.ptr),
                to: address
              ) else {
            return .failure(
                .init(
                    listOffset: relativeOffset,
                    failure: .relativeImageUnavailable(imageIndex: imageIndex)
                )
            )
        }
        return .resolved(targetMachO, List(ptr: pointer, offset: targetOffset))
    }

    internal func safelyReadList(
        in machO: MachOFile,
        forImageIndex imageIndex: Int?
    ) -> (MachOFile, List)? {
        guard let imageIndex else { return nil }
        return resolveList(in: machO, forImageIndex: imageIndex).value
    }

    internal func safelyReadList(
        in machO: MachOImage,
        forImageIndex imageIndex: Int?
    ) -> (MachOImage, List)? {
        guard let imageIndex else { return nil }
        return resolveList(in: machO, forImageIndex: imageIndex).value
    }
}
