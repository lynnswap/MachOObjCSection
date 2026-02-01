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
    public init(
        ptr: UnsafeRawPointer,
        offset: Int
    ) {
        self.offset = offset
        self.header = ptr.assumingMemoryBound(to: Header.self).pointee
    }

    public func list(in machO: MachOImage, for entry: Entry) -> (MachOImage, List)? {
        let offset = entry.offset + entry.listOffset
        let ptr = machO.ptr.advanced(by: offset)

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
        let offset: UInt64 = numericCast(entry.offset + entry.listOffset)

        guard let (cache, resolvedOffset) = machO.cacheAndFileOffset(fromStart: offset) else {
            return nil
        }

        guard let machO = cache._machO(at: entry.imageIndex)?.value else { return nil }

        guard let readOffset = Int(exactly: resolvedOffset),
              let data = try? cache.fileHandle.readData(
                offset: readOffset,
                length: MemoryLayout<List.Header>.size
              ) else {
            return nil
        }
        let list: List? = data.withUnsafeBytes {
            guard let ptr = $0.baseAddress else {
                return nil
            }
            guard let listOffset = Int(exactly: offset) else { return nil }
            return .init(
                ptr: ptr,
                offset: listOffset
            )
        }

        guard let list else { return nil }

        return (machO, list)
    }
}

public struct ObjCProtocolRelativeListList32: ObjCProtocolRelativeListListProtocol {
    public typealias List = ObjCProtocolList32

    public let offset: Int
    public let header: Header

    @_spi(Core)
    public init(
        ptr: UnsafeRawPointer,
        offset: Int
    ) {
        self.offset = offset
        self.header = ptr.assumingMemoryBound(to: Header.self).pointee
    }

    public func list(in machO: MachOImage, for entry: Entry) -> (MachOImage, List)? {
        let offset = entry.offset + entry.listOffset
        let ptr = machO.ptr.advanced(by: offset)

#if canImport(MachO)
        guard let cache: DyldCacheLoaded = .current else { return nil }
        guard let objcOptimization = cache.objcOptimization,
              let ro = objcOptimization.headerOptimizationRO64(in: cache) else {
            return nil
        }

        guard let header = ro.headerInfos(in: cache).first(
            where: { $0.index == entry.imageIndex }
        ),
              let machO = header.machO(in: cache) else {
            return nil
        }

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
        let offset: UInt64 = numericCast(entry.offset + entry.listOffset)

        guard let (cache, resolvedOffset) = machO.cacheAndFileOffset(fromStart: offset) else {
            return nil
        }

        guard let listMachO = cache._machO(at: entry.imageIndex)?.value else {
            return nil
        }

        guard let readOffset = Int(exactly: resolvedOffset),
              let data = try? cache.fileHandle.readData(
                offset: readOffset,
                length: MemoryLayout<List.Header>.size
              ) else {
            return nil
        }
        let list: List? = data.withUnsafeBytes {
            guard let ptr = $0.baseAddress else {
                return nil
            }
            guard let listOffset = Int(exactly: offset) else { return nil }
            return .init(
                ptr: ptr,
                offset: listOffset
            )
        }

        guard let list else { return nil }

        return (listMachO, list)
    }
}
