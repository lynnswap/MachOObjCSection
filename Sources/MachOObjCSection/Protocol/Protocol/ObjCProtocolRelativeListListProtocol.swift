//
//  ObjCProtocolRelativeListListProtocol.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2024/12/01
//  
//

import Foundation

public protocol ObjCProtocolRelativeListListProtocol: RelativeListListProtocol where List: ObjCProtocolListProtocol {

    @_spi(Core)
    init(offset: Int, header: Header)

    @_spi(Core)
    init(ptr: UnsafeRawPointer, offset: Int)
}

extension ObjCProtocolRelativeListListProtocol {
    internal func safelyReadList(
        in machO: MachOFile,
        forImageIndex imageIndex: Int?
    ) -> (MachOFile, List)? {
        guard let imageIndex,
              offset >= 0,
              let listOffset = UInt64(exactly: offset),
              let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forOffset: listOffset) else {
            return nil
        }

        let headerSize = UInt64(MemoryLayout<Header>.size)
        let (tableOffset, overflow) = fileOffset.addingReportingOverflow(headerSize)
        guard !overflow else { return nil }

        let count = Int(header.count)
        let layouts: [Entry.Layout]
        switch fileHandle.readProtocolTable(
            offset: tableOffset,
            count: count,
            as: Entry.Layout.self
        ) {
        case .success(let value):
            layouts = value
        case .failure:
            return nil
        }

        guard let (index, layout) = layouts.enumerated().first(
            where: { _, layout in Int(layout.imageIndex) == imageIndex }
        ) else {
            return nil
        }
        let (baseOffset, baseOverflow) = offset.addingReportingOverflow(MemoryLayout<Header>.size)
        let (entryDelta, deltaOverflow) = index.multipliedReportingOverflow(
            by: MemoryLayout<Entry.Layout>.size
        )
        let (entryOffset, entryOverflow) = baseOffset.addingReportingOverflow(entryDelta)
        guard !baseOverflow, !deltaOverflow, !entryOverflow else { return nil }
        let entry = Entry(
            offset: entryOffset,
            layout: layout
        )
        return list(in: machO, for: entry)
    }

    internal func safelyReadList(
        in machO: MachOImage,
        forImageIndex imageIndex: Int?
    ) -> (MachOImage, List)? {
        guard let imageIndex, offset >= 0 else { return nil }
        let count = Int(header.count)
        let entrySize = MemoryLayout<Entry.Layout>.size
        let (byteCount, byteCountOverflow) = count.multipliedReportingOverflow(by: entrySize)
        guard !byteCountOverflow else { return nil }

        let baseAddress = UInt(bitPattern: machO.ptr)
        let (listAddress, listOverflow) = baseAddress.addingReportingOverflow(UInt(offset))
        let (tableAddress, tableOverflow) = listAddress.addingReportingOverflow(
            UInt(MemoryLayout<Header>.size)
        )
        let (_, endOverflow) = tableAddress.addingReportingOverflow(UInt(byteCount))
        guard !listOverflow, !tableOverflow, !endOverflow else { return nil }

        if byteCount > 0 {
            guard let tablePointer = UnsafeRawPointer(bitPattern: tableAddress),
                  isPointerSafelyReadable(tablePointer, length: byteCount) else {
                return nil
            }
        }

        for index in 0..<count {
            let entryAddress = tableAddress + UInt(index * entrySize)
            guard let entryPointer = UnsafeRawPointer(bitPattern: entryAddress) else { return nil }
            let layout = entryPointer.loadUnaligned(as: Entry.Layout.self)
            guard Int(layout.imageIndex) == imageIndex else { continue }
            let (baseOffset, baseOverflow) = offset.addingReportingOverflow(MemoryLayout<Header>.size)
            let (entryDelta, deltaOverflow) = index.multipliedReportingOverflow(by: entrySize)
            let (entryOffset, entryOverflow) = baseOffset.addingReportingOverflow(entryDelta)
            guard !baseOverflow, !deltaOverflow, !entryOverflow else { return nil }
            let entry = Entry(
                offset: entryOffset,
                layout: layout
            )
            return list(in: machO, for: entry)
        }
        return nil
    }
}
