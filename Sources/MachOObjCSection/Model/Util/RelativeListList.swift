//
//  RelativeListList.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2024/11/02
//  
//

import Foundation
@_spi(Support) import MachOKit

// https://github.com/apple-oss-distributions/objc4/blob/89543e2c0f67d38ca5211cea33f42c51500287d5/runtime/objc-runtime-new.h#L1482

public struct RelativeListListEntry: LayoutWrapper {
    public typealias Layout = relative_list_list_entry_t

    public let offset: Int
    public var layout: Layout

    public var imageIndex: Int { numericCast(layout.imageIndex) }
    public var listOffset: Int { numericCast(layout.listOffset) }

    /// The signed 48-bit displacement without narrowing to the host `Int` width.
    internal var signedListOffset: Int64 { layout.listOffset }
}

public protocol RelativeListListProtocol: EntrySizeListProtocol where Entry == RelativeListListEntry {
    associatedtype List

    var offset: Int { get }
    var header: EntrySizeListHeader { get }

    func lists(in machO: MachOImage) -> [(MachOImage, List)]
    func list(in machO: MachOImage, for entry: Entry) -> (MachOImage, List)?

    func lists(in machO: MachOFile) -> [(MachOFile, List)]
    func list(in machO: MachOFile, for entry: Entry) -> (MachOFile, List)?
}

extension RelativeListListProtocol {
    public static var flagMask: UInt32 { 0 }
}

internal struct ObjCRelativeFileLocation {
    let image: MachOFile
    let file: MachOFile.File
    let fileOffset: UInt64
}

extension ObjCRelativeFileLocation {
    static func direct(
        in machO: MachOFile,
        fileOffset: UInt64
    ) -> Self? {
        guard let (file, resolvedOffset) = machO.fileHandleAndOffset(forOffset: fileOffset) else {
            return nil
        }
        return .init(image: machO, file: file, fileOffset: resolvedOffset)
    }
}

internal typealias ObjCProtocolRelativeFileLocation = ObjCRelativeFileLocation

internal func defaultRelativeFileLocation(
    in machO: MachOFile,
    for entry: RelativeListListEntry
) -> ObjCRelativeFileLocation? {
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

extension ObjCMetadataTableFailure {
    internal var relativeListReason: ObjCRelativeListFailure.Reason {
        switch self {
        case .unsupportedListEncoding:
            return .unsupportedListEncoding
        case .invalidListOffset(let offset):
            return .invalidListOffset(offset)
        case .invalidElementCount(let count):
            return .invalidElementCount(count)
        case .invalidSignedElementCount(let count):
            return .invalidSignedElementCount(count)
        case .invalidElementStride:
            return .invalidRelativeListLocation
        case let .elementStrideTooSmall(advertised, minimum):
            return .invalidRelativeEntrySize(
                advertised: UInt32(clamping: advertised),
                minimum: minimum
            )
        case let .unexpectedElementStride(advertised, expected):
            return .invalidListEntrySize(advertised: advertised, expected: expected)
        case let .misalignedTableOffset(offset, alignment):
            return .misalignedListOffset(offset: offset, requiredAlignment: alignment)
        case let .misalignedTableAddress(address, alignment):
            return .misalignedListAddress(address: address, requiredAlignment: alignment)
        case let .excessiveElementCount(actual, maximum):
            return .excessiveElementCount(actual: actual, maximum: maximum)
        case let .excessiveByteCount(actual, maximum):
            return .excessiveByteCount(actual: actual, maximum: maximum)
        case let .byteCountOverflow(count, size):
            return .byteCountOverflow(elementCount: count, elementSize: size)
        case let .rangeOverflow(offset, byteCount):
            return .rangeOverflow(startOffset: offset, byteCount: byteCount)
        case let .unreadableFileRange(offset, byteCount):
            return .unreadableFileRange(offset: offset, byteCount: byteCount)
        case let .unreadableImageRange(address, byteCount):
            return .unreadableImageRange(address: address, byteCount: byteCount)
        }
    }
}

extension RelativeListListProtocol {
    private func checkedRelativeCountAndStride() -> Result<
        (count: Int, stride: Int),
        ObjCRelativeListFailure
    > {
        guard let count = Int(exactly: header.count) else {
            return .failure(
                .table(
                    outerListOffset: offset,
                    reason: .invalidElementCount(UInt64(header.count))
                )
            )
        }
        let rawStride = header.entsizeAndFlags & ~Self.flagMask
        guard let stride = Int(exactly: rawStride) else {
            return .failure(
                .table(
                    outerListOffset: offset,
                    reason: .invalidRelativeEntrySize(
                        advertised: rawStride,
                        minimum: MemoryLayout<Entry.Layout>.size
                    )
                )
            )
        }
        let minimumStride = MemoryLayout<Entry.Layout>.size
        guard stride >= minimumStride else {
            return .failure(
                .table(
                    outerListOffset: offset,
                    reason: .invalidRelativeEntrySize(
                        advertised: rawStride,
                        minimum: minimumStride
                    )
                )
            )
        }
        return .success((count, stride))
    }

    private func checkedRelativeEntries(
        layouts: [Entry.Layout],
        stride: Int
    ) -> Result<[(index: Int, entry: Entry)], ObjCRelativeListFailure> {
        guard let baseOffset = checkedEntrySizeListTableOffset(offset) else {
            return .failure(
                .table(outerListOffset: offset, reason: .invalidRelativeListLocation)
            )
        }

        var entries: [(index: Int, entry: Entry)] = []
        entries.reserveCapacity(layouts.count)
        for (index, layout) in layouts.enumerated() {
            let (entryDelta, deltaOverflow) = index.multipliedReportingOverflow(by: stride)
            let (entryOffset, entryOverflow) = baseOffset.addingReportingOverflow(entryDelta)
            guard !deltaOverflow, !entryOverflow else {
                return .failure(
                    .table(outerListOffset: offset, reason: .invalidRelativeListLocation)
                )
            }
            entries.append((index, Entry(offset: entryOffset, layout: layout)))
        }
        return .success(entries)
    }

    private func checkedRelativeEntries(
        in machO: MachOFile
    ) -> Result<[(index: Int, entry: Entry)], ObjCRelativeListFailure> {
        guard let listOffset = UInt64(exactly: offset),
              let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forOffset: listOffset) else {
            return .failure(
                .table(outerListOffset: offset, reason: .missingListBackingData)
            )
        }
        let (tableOffset, tableOverflow) = fileOffset.addingReportingOverflow(
            UInt64(MemoryLayout<Header>.size)
        )
        guard !tableOverflow else {
            return .failure(
                .table(outerListOffset: offset, reason: .invalidRelativeListLocation)
            )
        }

        let countAndStride: (count: Int, stride: Int)
        switch checkedRelativeCountAndStride() {
        case .success(let value): countAndStride = value
        case .failure(let failure): return .failure(failure)
        }
        guard let logicalTableOffset = checkedEntrySizeListTableOffset(offset) else {
            return .failure(
                .table(outerListOffset: offset, reason: .invalidRelativeListLocation)
            )
        }

        let layouts: [Entry.Layout]
        switch ObjCMetadataTableReader.readFile(
            fileHandle,
            offset: tableOffset,
            logicalOffset: logicalTableOffset,
            count: countAndStride.count,
            stride: countAndStride.stride,
            as: Entry.Layout.self
        ) {
        case .success(let value):
            layouts = value.map(\.value)
        case .failure(let failure):
            return .failure(
                .table(
                    outerListOffset: offset,
                    reason: failure.relativeListReason
                )
            )
        }
        return checkedRelativeEntries(layouts: layouts, stride: countAndStride.stride)
    }

    private func checkedRelativeEntries(
        in machO: MachOImage
    ) -> Result<[(index: Int, entry: Entry)], ObjCRelativeListFailure> {
        let countAndStride: (count: Int, stride: Int)
        switch checkedRelativeCountAndStride() {
        case .success(let value): countAndStride = value
        case .failure(let failure): return .failure(failure)
        }
        guard let listAddress = addingSignedDisplacement(offset, to: UInt(bitPattern: machO.ptr)) else {
            return .failure(
                .table(outerListOffset: offset, reason: .invalidRelativeListLocation)
            )
        }
        let (tableAddress, tableOverflow) = listAddress.addingReportingOverflow(
            UInt(MemoryLayout<Header>.size)
        )
        guard !tableOverflow else {
            return .failure(
                .table(outerListOffset: offset, reason: .invalidRelativeListLocation)
            )
        }

        let tableEntries: [ObjCMetadataTableEntry<Entry.Layout>]
        guard let logicalTableOffset = checkedEntrySizeListTableOffset(offset) else {
            return .failure(
                .table(outerListOffset: offset, reason: .invalidRelativeListLocation)
            )
        }
        switch ObjCMetadataTableReader.readImage(
            address: tableAddress,
            logicalOffset: logicalTableOffset,
            count: countAndStride.count,
            stride: countAndStride.stride,
            as: Entry.Layout.self
        ) {
        case .success(let value): tableEntries = value
        case .failure(let failure):
            return .failure(
                .table(
                    outerListOffset: offset,
                    reason: failure.relativeListReason
                )
            )
        }
        return checkedRelativeEntries(
            layouts: tableEntries.map(\.value),
            stride: countAndStride.stride
        )
    }

    internal func resolveRelativeLists(
        in machO: MachOFile,
        locationResolver: (MachOFile, Entry) -> ObjCRelativeFileLocation? = defaultRelativeFileLocation,
        makeList: (
            ObjCRelativeFileLocation,
            Entry,
            Int
        ) -> Result<List, ObjCRelativeListFailure.Reason>
    ) -> ObjCRelativeListResolution<MachOFile, List, ObjCRelativeListFailure> {
        let entries: [(index: Int, entry: Entry)]
        switch checkedRelativeEntries(in: machO) {
        case .success(let value): entries = value
        case .failure(let failure): return .failure(failure)
        }

        var resolutions: [
            ObjCRelativeListResolutionEntry<MachOFile, List, ObjCRelativeListFailure>
        ] = []
        resolutions.reserveCapacity(entries.count)
        for indexedEntry in entries {
            let entry = indexedEntry.entry
            guard let location = locationResolver(machO, entry) else {
                resolutions.append(
                    .failure(
                        .entry(
                            outerListOffset: offset,
                            index: indexedEntry.index,
                            entry: entry,
                            reason: .invalidRelativeListLocation
                        )
                    )
                )
                continue
            }
            guard let relativeOffset = addingSignedDisplacement(
                entry.signedListOffset,
                to: entry.offset
            ), let canonicalOffset = Int(exactly: relativeOffset) else {
                resolutions.append(
                    .failure(
                        .entry(
                            outerListOffset: offset,
                            index: indexedEntry.index,
                            entry: entry,
                            reason: .invalidRelativeListLocation
                        )
                    )
                )
                continue
            }
            switch makeList(location, entry, canonicalOffset) {
            case .success(let list):
                resolutions.append(.resolved(location.image, list))
            case .failure(let reason):
                resolutions.append(
                    .failure(
                        .entry(
                            outerListOffset: offset,
                            index: indexedEntry.index,
                            entry: entry,
                            diagnosticOffset: canonicalOffset,
                            reason: reason
                        )
                    )
                )
            }
        }
        return .entries(resolutions)
    }

    internal func resolveRelativeLists(
        in machO: MachOImage,
        imageLoadResolver: (Int) -> ObjCImageLoadState = defaultRelativeImageLoadState,
        imageResolver: (Int) -> MachOImage? = defaultRelativeImage,
        makeList: (
            MachOImage,
            UnsafeRawPointer,
            Int,
            Entry
        ) -> Result<List, ObjCRelativeListFailure.Reason>
    ) -> ObjCRelativeListResolution<MachOImage, List, ObjCRelativeListFailure> {
        let entries: [(index: Int, entry: Entry)]
        switch checkedRelativeEntries(in: machO) {
        case .success(let value): entries = value
        case .failure(let failure): return .failure(failure)
        }

        var resolutions: [
            ObjCRelativeListResolutionEntry<MachOImage, List, ObjCRelativeListFailure>
        ] = []
        resolutions.reserveCapacity(entries.count)
        for indexedEntry in entries {
            let entry = indexedEntry.entry
            switch imageLoadResolver(entry.imageIndex) {
            case .unavailable:
                resolutions.append(
                    .failure(
                        .entry(
                            outerListOffset: offset,
                            index: indexedEntry.index,
                            entry: entry,
                            reason: .relativeImageUnavailable(imageIndex: entry.imageIndex)
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
            ), let address = addingSignedDisplacement(
                relativeOffset,
                to: UInt(bitPattern: machO.ptr)
            ), let pointer = UnsafeRawPointer(bitPattern: address) else {
                resolutions.append(
                    .failure(
                        .entry(
                            outerListOffset: offset,
                            index: indexedEntry.index,
                            entry: entry,
                            reason: .invalidRelativeListLocation
                        )
                    )
                )
                continue
            }
            let diagnosticOffset = Int(exactly: relativeOffset) ?? entry.offset
            guard let targetMachO = imageResolver(entry.imageIndex),
                  let targetOffset = signedDisplacement(
                    from: UInt(bitPattern: targetMachO.ptr),
                    to: address
                  ) else {
                resolutions.append(
                    .failure(
                        .entry(
                            outerListOffset: offset,
                            index: indexedEntry.index,
                            entry: entry,
                            diagnosticOffset: diagnosticOffset,
                            reason: .relativeImageUnavailable(imageIndex: entry.imageIndex)
                        )
                    )
                )
                continue
            }
            switch makeList(targetMachO, pointer, targetOffset, entry) {
            case .success(let list):
                resolutions.append(.resolved(targetMachO, list))
            case .failure(let reason):
                resolutions.append(
                    .failure(
                        .entry(
                            outerListOffset: offset,
                            index: indexedEntry.index,
                            entry: entry,
                            diagnosticOffset: diagnosticOffset,
                            reason: reason
                        )
                    )
                )
            }
        }
        return .entries(resolutions)
    }
}

extension RelativeListListProtocol {
    public func entries(in machO: MachOImage) -> [Entry] {
        guard case .success(let entries) = checkedRelativeEntries(in: machO) else {
            return []
        }
        return entries.map(\.entry)
    }

    public func lists(in machO: MachOImage) -> [(MachOImage, List)] {
        entries(in: machO)
            .compactMap {
                list(in: machO, for: $0)
            }
    }

    public func list(
        in machO: MachOImage,
        forImageIndex imageIndex: Int?
    ) -> (MachOImage, List)? {
        guard let imageIndex else { return nil }
        guard let entry = entries(in: machO).first(
            where: { $0.imageIndex == imageIndex }
        ) else { return nil }
        return list(in: machO, for: entry)
    }
}

extension RelativeListListProtocol {
    public func entries(in machO: MachOFile) -> [Entry] {
        guard case .success(let entries) = checkedRelativeEntries(in: machO) else {
            return []
        }
        return entries.map(\.entry)
    }

    public func lists(in machO: MachOFile) -> [(MachOFile, List)] {
        entries(in: machO)
            .compactMap {
                list(in: machO, for: $0)
            }
    }

    public func list(
        in machO: MachOFile,
        forImageIndex imageIndex: Int?
    ) -> (MachOFile, List)? {
        guard let imageIndex else { return nil }
        guard let entry = entries(in: machO).first(
            where: { $0.imageIndex == imageIndex }
        ) else { return nil }
        return list(in: machO, for: entry)
    }
}
