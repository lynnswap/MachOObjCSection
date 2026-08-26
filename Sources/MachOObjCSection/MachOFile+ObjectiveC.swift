//
//  MachOFile+ObjectiveC.swift
//
//
//  Created by p-x9 on 2024/08/01
//
//

import Foundation
@_spi(Support) import MachOKit

extension MachOFile {
    public struct ObjectiveC: ObjCSectionRepresentable {
        internal let machO: MachOFile

        init(machO: MachOFile) {
            self.machO = machO
        }
    }

    public var objc: ObjectiveC {
        .init(machO: self)
    }
}

extension MachOFile.ObjectiveC {
    public var imageInfo: ObjCImageInfo? {
        let __objc_imageinfo: any SectionProtocol
        if machO.is64Bit,
           let section = machO.findObjCSection64(for: .__objc_imageinfo) {
            __objc_imageinfo = section
        } else if let section = machO.findObjCSection32(for: .__objc_imageinfo) {
            __objc_imageinfo = section
        } else {
            return nil
        }

        guard let fileSlice = machO._fileSliceForSection(section: __objc_imageinfo) else {
            return nil
        }
        return try? fileSlice.read(offset: 0)
    }
}

extension MachOFile.ObjectiveC {
    public var methods: MachOFile.ObjCMethodLists? {
        let loadCommands = machO.loadCommands

        if let text = loadCommands.text64,
           let section = text.__objc_methlist(in: machO) {
            return methodLists(section: section, text: text)
        } else if let text = loadCommands.text,
                  let section = text.__objc_methlist(in: machO) {
            return methodLists(section: section, text: text)
        }
        return nil
    }

    private func methodLists(
        section: Section64,
        text: SegmentCommand64
    ) -> MachOFile.ObjCMethodLists? {
        guard let coordinates = checkedObjCSectionCoordinates(section, in: text) else {
            return nil
        }
        return methodLists(section: coordinates)
    }

    private func methodLists(
        section: Section,
        text: SegmentCommand
    ) -> MachOFile.ObjCMethodLists? {
        guard let coordinates = checkedObjCSectionCoordinates(section, in: text) else {
            return nil
        }
        return methodLists(section: coordinates)
    }

    private func methodLists(
        section: CheckedObjCSectionCoordinates
    ) -> MachOFile.ObjCMethodLists? {
        let offset: Int
        if let cache = machO.cache {
            guard let cacheOffset = checkedCacheOffset(
                address: section.address,
                sharedRegionStart: cache.mainCacheHeader.sharedRegionStart
            ), let exactOffset = Int(exactly: cacheOffset) else { return nil }
            offset = exactOffset
        } else {
            offset = section.fileOffset
        }
        guard let fileSlice = machO._fileSliceForCheckedSection(section: section),
              let data = try? fileSlice.readData(
                offset: 0,
                length: section.size
              ) else { return nil }

        return .init(
            data: data,
            offset: offset,
            align: section.alignmentExponent,
            is64Bit: machO.is64Bit
        )
    }
}

extension MachOFile {
    fileprivate func _fileSliceForCheckedSection(
        section: CheckedObjCSectionCoordinates
    ) -> File.FileSlice? {
        guard fileHandle.size >= 0 else { return nil }
        let isWithinFileRange = section.mappedFileOffset <= UInt64(fileHandle.size)

        // Some cache-backed section data is stored in a separate cache file.
        if isLoadedFromDyldCache && !isWithinFileRange {
            guard let fullCache,
                  let concatenatedOffset = fullCache.fileOffset(of: section.address),
                  let exactConcatenatedOffset = Int(exactly: concatenatedOffset),
                  let segment = fullCache.fileSegment(forOffset: concatenatedOffset) else {
                return nil
            }
            let (localOffset, underflow) = exactConcatenatedOffset.subtractingReportingOverflow(
                segment.offset
            )
            guard !underflow else { return nil }
            return try? segment._file.fileSlice(
                offset: localOffset,
                length: section.size
            )
        }

        let (absoluteOffset, overflow) = headerStartOffset.addingReportingOverflow(
            section.fileOffset
        )
        guard !overflow else { return nil }
        return try? fileHandle.fileSlice(
            offset: absoluteOffset,
            length: section.size
        )
    }

    fileprivate func _fileSliceForSection(
        section: any SectionProtocol
    ) -> File.FileSlice? {
        let text: (any SegmentCommandProtocol)? = loadCommands.text64 ?? loadCommands.text
        guard let text else { return nil }

        let maxFileOffsetToCheck = text.fileOffset + section.address - text.virtualMemoryAddress
        let isWithinFileRange: Bool = fileHandle.size >= maxFileOffsetToCheck

        // 1) text.vmaddr < linkedit.vmaddr
        // 2) fileoff_diff <= vmaddr_diff
        // 3) If both exist in the same file
        //    text.fileoff < linkedit.fileoff <= text.fileoff + vmaddr_diff
        // 4) if fileHandle.size < text.fileoff + vmaddr_diff
        //    both exist in the same file

        // The linkedit data in iOS is stored together in a separate, independent cache.
        // (.0x.linkeditdata)
        if isLoadedFromDyldCache && !isWithinFileRange {
            guard let fullCache = self.fullCache,
                  let fileOffset = fullCache.fileOffset(
                    of: numericCast(section.address)
                  ),
                  let segment = fullCache.fileSegment(
                    forOffset: fileOffset
                  ) else {
                return nil
            }
            return try? segment._file.fileSlice(
                offset: numericCast(fileOffset) - segment.offset,
                length: section.size
            )
        } else {
            return try? fileHandle.fileSlice(
                offset: headerStartOffset + section.offset,
                length: section.size
            )
        }
    }
}
