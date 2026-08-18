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

internal func defaultRelativeImageLoadState(at index: Int) -> ObjCImageLoadState {
#if canImport(MachO)
    guard let cache: DyldCacheLoaded = .current else { return .unavailable }
    return cache.objcImageLoadState(at: index)
#else
    return .unavailable
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

    private func checkedEntries(
        layouts: [Entry.Layout],
        stride: Int
    ) -> Result<[Entry], ObjCProtocolListResolutionFailure> {
        let (baseOffset, baseOverflow) = offset.addingReportingOverflow(MemoryLayout<Header>.size)
        guard !baseOverflow else {
            return .failure(.init(listOffset: offset, failure: .invalidRelativeListLocation))
        }

        var entries: [Entry] = []
        entries.reserveCapacity(layouts.count)
        for (index, layout) in layouts.enumerated() {
            let (entryDelta, deltaOverflow) = index.multipliedReportingOverflow(by: stride)
            let (entryOffset, entryOverflow) = baseOffset.addingReportingOverflow(entryDelta)
            guard !deltaOverflow, !entryOverflow else {
                return .failure(.init(listOffset: offset, failure: .invalidRelativeListLocation))
            }
            entries.append(Entry(offset: entryOffset, layout: layout))
        }
        return .success(entries)
    }

    // File/debug-tool readers have no process load state. Objective-C's own
    // debug-tool path therefore treats every outer entry as loaded.
    internal func resolveLists(
        in machO: MachOFile,
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

        let entries: [Entry]
        switch checkedEntries(
            layouts: layouts,
            stride: countAndStride.stride
        ) {
        case .success(let value): entries = value
        case .failure(let failure): return .failure(failure)
        }

        var resolutions: [ObjCProtocolListResolutionEntry<MachOFile, List>] = []
        resolutions.reserveCapacity(entries.count)
        for entry in entries {
            guard let location = locationResolver(machO, entry) else {
                resolutions.append(
                    .failure(.init(listOffset: entry.offset, failure: .invalidRelativeListLocation))
                )
                continue
            }
            guard let relativeOffset = addingSignedDisplacement(
                entry.signedListOffset,
                to: entry.offset
              ),
              let canonicalOffset = UInt64(exactly: relativeOffset) else {
                resolutions.append(
                    .failure(.init(listOffset: entry.offset, failure: .invalidRelativeListLocation))
                )
                continue
            }
            let diagnosticOffset = Int(exactly: relativeOffset) ?? entry.offset
            guard let header: List.Header = location.file.readProtocolLayout(
                offset: location.fileOffset,
                as: List.Header.self
            ) else {
                resolutions.append(
                    .failure(
                        .init(
                            listOffset: diagnosticOffset,
                            failure: .unreadableFileHeader(
                                offset: location.fileOffset,
                                byteCount: MemoryLayout<List.Header>.size
                            )
                        )
                    )
                )
                continue
            }
            guard let listOffset = Int(exactly: canonicalOffset) else {
                resolutions.append(
                    .failure(.init(listOffset: entry.offset, failure: .invalidRelativeListLocation))
                )
                continue
            }
            resolutions.append(.resolved(location.image, List(offset: listOffset, header: header)))
        }
        return .entries(resolutions)
    }

    internal func resolveLists(
        in machO: MachOImage,
        imageLoadResolver: (Int) -> ObjCImageLoadState = defaultRelativeImageLoadState,
        imageResolver: (Int) -> MachOImage? = defaultRelativeImage
    ) -> ObjCProtocolListResolution<MachOImage, List> {
        let countAndStride: (count: Int, stride: Int)
        switch checkedCountAndStride() {
        case .success(let value): countAndStride = value
        case .failure(let failure): return .failure(failure)
        }
        let byteCount: Int
        switch ObjCProtocolReadLimits.checkedTableByteCount(
            count: countAndStride.count,
            stride: countAndStride.stride
        ) {
        case .success(let value): byteCount = value
        case .failure(let failure):
            return .failure(.init(listOffset: offset, failure: failure.diagnosticFailure))
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

        let entries: [Entry]
        switch checkedEntries(
            layouts: layouts,
            stride: countAndStride.stride
        ) {
        case .success(let value): entries = value
        case .failure(let failure): return .failure(failure)
        }

        var resolutions: [ObjCProtocolListResolutionEntry<MachOImage, List>] = []
        resolutions.reserveCapacity(entries.count)
        for entry in entries {
            switch imageLoadResolver(entry.imageIndex) {
            case .unavailable:
                resolutions.append(
                    .failure(
                        .init(
                            listOffset: entry.offset,
                            failure: .relativeImageUnavailable(imageIndex: entry.imageIndex)
                        )
                    )
                )
                continue
            case .unloaded:
                continue
            case .loaded:
                break
            }

            guard let relativeOffset = addingSignedDisplacement(
                entry.signedListOffset,
                to: entry.offset
              ),
              let address = addingSignedDisplacement(
                relativeOffset,
                to: UInt(bitPattern: machO.ptr)
              ),
              let pointer = UnsafeRawPointer(bitPattern: address) else {
                resolutions.append(
                    .failure(.init(listOffset: entry.offset, failure: .invalidRelativeListLocation))
                )
                continue
            }
            let diagnosticOffset = Int(exactly: relativeOffset) ?? entry.offset
            guard isPointerSafelyReadable(pointer, length: MemoryLayout<List.Header>.size) else {
                resolutions.append(
                    .failure(
                        .init(
                            listOffset: diagnosticOffset,
                            failure: .unreadableImageHeader(
                                address: address,
                                byteCount: MemoryLayout<List.Header>.size
                            )
                        )
                    )
                )
                continue
            }
            guard let targetMachO = imageResolver(entry.imageIndex),
              let targetOffset = signedDisplacement(
                from: UInt(bitPattern: targetMachO.ptr),
                to: address
              ) else {
                resolutions.append(
                    .failure(
                        .init(
                            listOffset: diagnosticOffset,
                            failure: .relativeImageUnavailable(imageIndex: entry.imageIndex)
                        )
                    )
                )
                continue
            }
            resolutions.append(.resolved(targetMachO, List(ptr: pointer, offset: targetOffset)))
        }
        return .entries(resolutions)
    }
}
