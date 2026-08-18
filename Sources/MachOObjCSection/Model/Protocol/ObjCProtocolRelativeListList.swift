//
//  ObjCProtocolRelativeListList.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2024/11/02
//  
//

import Foundation
@_spi(Support) import MachOKit

public struct ObjCProtocolRelativeListList64: ObjCProtocolRelativeListListProtocol {
    public typealias List = ObjCProtocolList64

    public let offset: Int
    public let header: Header

    @_spi(Core)
    public init(offset: Int, header: Header) {
        self.offset = offset
        self.header = header
    }
}

extension ObjCProtocolRelativeListList64 {
    @_spi(Core)
    public init(
        ptr: UnsafeRawPointer,
        offset: Int
    ) {
        self.offset = offset
        self.header = ptr.assumingMemoryBound(to: Header.self).pointee
    }

    public func list(in machO: MachOImage, for entry: Entry) -> (MachOImage, List)? {
        let (offset, offsetOverflow) = entry.offset.addingReportingOverflow(entry.listOffset)
        guard !offsetOverflow, offset >= 0 else { return nil }
        let baseAddress = UInt(bitPattern: machO.ptr)
        let (address, addressOverflow) = baseAddress.addingReportingOverflow(UInt(offset))
        guard !addressOverflow, let ptr = UnsafeRawPointer(bitPattern: address) else { return nil }

        guard isPointerSafelyReadable(ptr, length: MemoryLayout<List.Header>.size) else {
            return nil
        }

#if canImport(MachO)
        guard let cache: DyldCacheLoaded = .current else { return nil }
        guard let machO = cache.machO(at: entry.imageIndex) else { return nil }

        let list = List(
            ptr: ptr,
            offset: .init(bitPattern: ptr) - .init(bitPattern: machO.ptr)
        )

        return (machO, list)
#else
        return nil
#endif
    }

    public func list(in machO: MachOFile, for entry: Entry) -> (MachOFile, List)? {
        let (relativeOffset, overflow) = entry.offset.addingReportingOverflow(entry.listOffset)
        guard !overflow, let offset = UInt64(exactly: relativeOffset) else { return nil }

        guard let location = machO.relativeListLocation(for: entry) else {
            return nil
        }

        guard let header: List.Header = location.cache.fileHandle.readProtocolLayout(
            offset: location.fileOffset,
            as: List.Header.self
        ) else {
            return nil
        }
        let list = List(
            offset: numericCast(offset),
            header: header
        )

        return (location.image, list)
    }
}

public struct ObjCProtocolRelativeListList32: ObjCProtocolRelativeListListProtocol {
    public typealias List = ObjCProtocolList32

    public let offset: Int
    public let header: Header

    @_spi(Core)
    public init(offset: Int, header: Header) {
        self.offset = offset
        self.header = header
    }
}

extension ObjCProtocolRelativeListList32 {
    @_spi(Core)
    public init(
        ptr: UnsafeRawPointer,
        offset: Int
    ) {
        self.offset = offset
        self.header = ptr.assumingMemoryBound(to: Header.self).pointee
    }

    public func list(in machO: MachOImage, for entry: Entry) -> (MachOImage, List)? {
        let (offset, offsetOverflow) = entry.offset.addingReportingOverflow(entry.listOffset)
        guard !offsetOverflow, offset >= 0 else { return nil }
        let baseAddress = UInt(bitPattern: machO.ptr)
        let (address, addressOverflow) = baseAddress.addingReportingOverflow(UInt(offset))
        guard !addressOverflow, let ptr = UnsafeRawPointer(bitPattern: address) else { return nil }

        guard isPointerSafelyReadable(ptr, length: MemoryLayout<List.Header>.size) else {
            return nil
        }

#if canImport(MachO)
        guard let cache: DyldCacheLoaded = .current else { return nil }
        guard let machO = cache.machO(at: entry.imageIndex) else { return nil }

        let list = List(
            ptr: ptr,
            offset: .init(bitPattern: ptr) - .init(bitPattern: machO.ptr)
        )

        return (machO, list)
#else
        return nil
#endif
    }

    public func list(in machO: MachOFile, for entry: Entry) -> (MachOFile, List)? {
        let (relativeOffset, overflow) = entry.offset.addingReportingOverflow(entry.listOffset)
        guard !overflow, let offset = UInt64(exactly: relativeOffset) else { return nil }

        guard let location = machO.relativeListLocation(for: entry) else {
            return nil
        }

        guard let header: List.Header = location.cache.fileHandle.readProtocolLayout(
            offset: location.fileOffset,
            as: List.Header.self
        ) else {
            return nil
        }
        let list = List(
            offset: numericCast(offset),
            header: header
        )

        return (location.image, list)
    }
}
