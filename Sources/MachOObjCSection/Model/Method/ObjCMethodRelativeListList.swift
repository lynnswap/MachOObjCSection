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

extension ObjCMethodRelativeListList: ObjCMemberRelativeListListProtocol {
    public func lists(in machO: MachOImage) -> [(MachOImage, ObjCMethodList)] {
        resolveMemberLists(in: machO).resolvedValues
    }

    public func lists(in machO: MachOFile) -> [(MachOFile, ObjCMethodList)] {
        resolveMemberLists(in: machO).resolvedValues
    }

    internal func makeList(
        ptr: UnsafeRawPointer,
        offset: Int,
        is64Bit: Bool
    ) -> ObjCMethodList {
        .init(ptr: ptr, offset: offset, is64Bit: is64Bit)
    }

    internal func makeList(
        offset: Int,
        header: EntrySizeListHeader,
        is64Bit: Bool
    ) -> ObjCMethodList {
        .init(offset: offset, header: header, is64Bit: is64Bit)
    }

    internal func expectedEntrySize(for list: ObjCMethodList) -> Int {
        list.expectedEntrySize(is64Bit: list.is64Bit)
    }

    internal func expectedEntryAlignment(for list: ObjCMethodList) -> Int {
        list.expectedEntryAlignment(is64Bit: list.is64Bit)
    }
}

extension ObjCMethodRelativeListList {
    init(
        ptr: UnsafeRawPointer,
        offset: Int
    ) {
        self.offset = offset
        self.header = ptr.loadUnaligned(as: Header.self)
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
