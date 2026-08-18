//
//  ObjCMethodRelativeListList.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2024/11/02
//
//

import Foundation
@_spi(Support) import MachOKit

public struct ObjCMethodRelativeListList: RelativeListListProtocol {
    public typealias List = ObjCMethodList

    public let offset: Int
    public let header: Header
}

extension ObjCMethodRelativeListList {
    init(
        ptr: UnsafeRawPointer,
        offset: Int
    ) {
        self.offset = offset
        self.header = ptr.assumingMemoryBound(to: Header.self).pointee
    }

    public func list(in machO: MachOImage, for entry: Entry) -> (MachOImage, List)? {
        guard let offset = addingSignedDisplacement(entry.signedListOffset, to: entry.offset),
              let address = addingSignedDisplacement(offset, to: UInt(bitPattern: machO.ptr)),
              let ptr = UnsafeRawPointer(bitPattern: address) else { return nil }

#if canImport(MachO)
        guard let cache: DyldCacheLoaded = .current else { return nil }
        guard let machO = cache.machO(at: entry.imageIndex) else { return nil }
        guard let listOffset = signedDisplacement(
            from: UInt(bitPattern: machO.ptr),
            to: address
        ) else { return nil }

        let list = List(
            ptr: ptr,
            offset: listOffset,
            is64Bit: machO.is64Bit
        )

        return (machO, list)
#else
        return nil
#endif
    }
}

extension ObjCMethodRelativeListList {
    public func list(in machO: MachOFile, for entry: Entry) -> (MachOFile, List)? {
        guard let relativeOffset = addingSignedDisplacement(
                entry.signedListOffset,
                to: entry.offset
              ),
              let offset = UInt64(exactly: relativeOffset),
              let listOffset = Int(exactly: offset) else { return nil }

        guard let location = machO.relativeListLocation(for: entry) else {
            return nil
        }

        let header: List.Header = location.cache.fileHandle.read(offset: location.fileOffset)
        let list = List(
            offset: listOffset,
            header: header,
            is64Bit: location.image.is64Bit
        )

        return (location.image, list)
    }
}
