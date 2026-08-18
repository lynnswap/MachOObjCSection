//
//  MachOFile+.swift
//
//
//  Created by p-x9 on 2024/07/19
//
//

import Foundation
@_spi(Support) import MachOKit
#if compiler(>=6.0) || (compiler(>=5.10) && hasFeature(AccessLevelOnImport))
internal import FileIO
#else
@_implementationOnly import FileIO
#endif

@inline(__always)
internal func checkedCacheAddress(
    sharedRegionStart: UInt64,
    offset: UInt64
) -> UInt64? {
    let (address, overflow) = sharedRegionStart.addingReportingOverflow(offset)
    return overflow ? nil : address
}

@inline(__always)
internal func checkedCacheOffset(
    address: UInt64,
    sharedRegionStart: UInt64
) -> UInt64? {
    let (offset, underflow) = address.subtractingReportingOverflow(sharedRegionStart)
    return underflow ? nil : offset
}

extension MachOFile {
    internal typealias File = MemoryMappedFile

    var fileHandle: File {
        FileHandleHolder.shared.fileHandle(
            for: fileHandleIdentity,
            initialize: {
                try! .open(url: url, isWritable: false)
            }
        )
    }
}

// MARK: - dyld cache
extension MachOFile {
    func cache(for address: UInt64) -> DyldCache? {
        guard let cache else { return nil }
        if let fullCache = cache._cachedFullCache {
            return fullCache.cache(for: address)
        }
        return cache.locateValue({ $0.fileOffset(of: address) })?.cache
    }

    /// Convert an address that is not slided into the actual cache it contains and the file offset in it.
    /// - Parameter address: address (unslid)
    /// - Returns: cache and file offset
    func cacheAndFileOffset(for address: UInt64) -> (DyldCache, UInt64)? {
        guard let cache else { return nil }
        if let fullCache = cache._cachedFullCache {
            return fullCache.cacheAndFileOffset(for: address)
        }
        return cache.locateValue { $0.fileOffset(of: address) }
    }

    /// Converts the offset from the start of the main cache to the actual cache
    /// it contains and the file offset within that cache.
    /// - Parameter offset: Offset from the start of the main cache.
    /// - Returns: cache and file offset
    func cacheAndFileOffset(fromStart offset: UInt64) -> (DyldCache, UInt64)? {
        guard let cache else { return nil }
        guard let address = checkedCacheAddress(
            sharedRegionStart: cache.mainCacheHeader.sharedRegionStart,
            offset: offset
        ) else { return nil }
        return cacheAndFileOffset(for: address)
    }
}

// MARK: - FileIO
extension MachOFile {
    func fileHandleAndOffset(
        forAddress address: UInt64
    ) -> (File, UInt64)? {
        if !isLoadedFromDyldCache,
           let fileOffset = fileOffset(of: address) {
            guard let headerOffset = UInt64(exactly: headerStartOffset) else { return nil }
            let (absoluteOffset, overflow) = fileOffset.addingReportingOverflow(headerOffset)
            guard !overflow else { return nil }
            return (fileHandle, absoluteOffset)
        }

        if let cache,
           let cacheOffset = checkedCacheOffset(
            address: address,
            sharedRegionStart: cache.mainCacheHeader.sharedRegionStart
           ),
           let (_cache, fileOffset) = cacheAndFileOffset(fromStart: cacheOffset) {
            return (_cache.fileHandle, fileOffset)
        }

        return nil
    }

    func fileHandleAndOffset(
        forOffset offset: UInt64
    ) -> (File, UInt64)? {
        if !isLoadedFromDyldCache {
            guard let headerOffset = UInt64(exactly: headerStartOffset) else { return nil }
            let (absoluteOffset, overflow) = offset.addingReportingOverflow(headerOffset)
            guard !overflow else { return nil }
            return (fileHandle, absoluteOffset)
        }

        if let (_cache, fileOffset) = cacheAndFileOffset(
            fromStart: offset
           ) {
            return (_cache.fileHandle, fileOffset)
        }

        return nil
    }

    func fileHandleAndOffset(
        forResolvedValue resolved: ResolvedValue
    ) -> (File, UInt64)? {
        // ResolvedValue.offset follows fileHandleAndOffset(forOffset:)'s convention:
        // Mach-O file offset for ordinary files, main-cache-start offset for dyld cache images.
        fileHandleAndOffset(forOffset: resolved.offset)
    }

    func relativeListLocation(
        for entry: RelativeListListEntry
    ) -> (image: MachOFile, cache: DyldCache, fileOffset: UInt64)? {
        let (relativeOffset, overflow) = entry.offset.addingReportingOverflow(entry.listOffset)
        guard !overflow, let offset = UInt64(exactly: relativeOffset) else { return nil }

        guard let cache,
              let located = cache._machO(at: entry.imageIndex) else {
            return nil
        }

        guard let address = checkedCacheAddress(
            sharedRegionStart: cache.mainCacheHeader.sharedRegionStart,
            offset: offset
        ) else { return nil }
        guard let fileOffset = located.cache.fileOffset(of: address) else {
            return nil
        }

        return (located.value, located.cache, fileOffset)
    }
}

// MARK: - rebase / bind
extension MachOFile {
    func isBind(
        _ offset: Int
    ) -> Bool {
        guard let offset = UInt64(exactly: offset) else { return false }
        return resolveBind(at: offset) != nil
    }

    func isBind(
        _ unresolvedValue: UnresolvedValue
    ) -> Bool {
        isBind(unresolvedValue.fieldOffset)
    }

    /// Resolves a rebase from an `UnresolvedValue`.
    ///
    /// If the Mach-O is backed by dyld shared cache(s):
    /// - find which cache actually contains this offset
    /// - ask that cache to resolve the rebase at its local file offset
    /// - return the resolved address together with the “offset from the main cache start”
    ///
    /// Otherwise (non-cache Mach-O):
    /// - resolve against the file directly
    ///
    /// If it cannot be resolved, we still return a `ResolvedValue` that contains:
    /// - the raw input value (unrebased)
    /// - file offset resolved from that raw value
    ///
    /// - Parameter unresolvedValue: position (file offset) and raw pointer value stored in the image
    /// - Returns: resolved value and offset
    func resolveRebase(
        _ unresolvedValue: UnresolvedValue
    ) -> ResolvedValue? {
        guard let offset = UInt64(exactly: unresolvedValue.fieldOffset) else {
            return nil
        }

        if let (cache, _offset) = cacheAndFileOffset(
            fromStart: offset
        ) {
            let address = cache.resolveOptionalRebase(at: _offset) ?? unresolvedValue.value
            guard let canonicalOffset = checkedCacheOffset(
                address: address,
                sharedRegionStart: cache.mainCacheHeader.sharedRegionStart
            ) else { return nil }
            return .init(
                address: address,
                offset: canonicalOffset
            )
        }

        if let resolved = resolveOptionalRebase(
            at: offset
        ) {
            guard let resolvedFileOffset = fileOffset(of: resolved) else {
                return nil
            }
            return .init(
                address: resolved,
                offset: resolvedFileOffset
            )
        }

        guard let fallbackFileOffset = fileOffset(of: unresolvedValue.value) else {
            return nil
        }
        return .init(
            address: unresolvedValue.value,
            offset: fallbackFileOffset
        )
    }
}

// MARK: - Objective-C
extension MachOFile {
    var relativeMethodSelectorBaseAddressOffset: UInt64? {
        if let cache {
            if let fullCache = cache._cachedFullCache {
                return fullCache.relativeMethodSelectorBaseAddressOffset
            }
            return cache.locateValue(\.relativeMethodSelectorBaseAddressOffset)?.value
        }

        return nil
    }

    func findObjCSection64(for section: ObjCMachOSection) -> Section64? {
        findObjCSection64(for: section.rawValue)
    }

    func findObjCSection32(for section: ObjCMachOSection) -> Section? {
        findObjCSection32(for: section.rawValue)
    }

    // [dyld implementation](https://github.com/apple-oss-distributions/dyld/blob/66c652a1f1f6b7b5266b8bbfd51cb0965d67cc44/common/MachOFile.cpp#L3880)
    func findObjCSection64(for name: String) -> Section64? {
        let segmentNames = [
            "__DATA", "__DATA_CONST", "__DATA_DIRTY"
        ]
        let segments = segments64
        for segment in segments {
            guard segmentNames.contains(segment.segmentName) else {
                continue
            }
            if let section = segment._section(for: name, in: self) {
                return section
            }
        }
        return nil
    }

    func findObjCSection32(for name: String) -> Section? {
        let segmentNames = [
            "__DATA", "__DATA_CONST", "__DATA_DIRTY"
        ]
        let segments = segments32
        for segment in segments {
            guard segmentNames.contains(segment.segmentName) else {
                continue
            }
            if let section = segment._section(for: name, in: self) {
                return section
            }
        }
        return nil
    }
}

extension MachOFile {
    var objcImageIndex: Int? {
        guard isLoadedFromDyldCache else { return nil }
        guard let cache else { return nil }
        if let (cache, headerOptimizationRO) = cache._headerOptimizationRO64,
           let info = headerOptimizationRO.headerInfo(in: cache, for: self) {
            return info.index
        }
        if let (cache, headerOptimizationRO) = cache._headerOptimizationRO32,
           let info = headerOptimizationRO.headerInfo(in: cache, for: self) {
            return info.index
        }
        return nil
    }
}
