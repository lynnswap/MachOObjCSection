//
//  ObjCPropertyRelativeListList.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2024/11/02
//
//

import Foundation
@_spi(Support) import MachOKit

public struct ObjCPropertyRelativeListList: RelativeListListProtocol {
    public typealias List = ObjCPropertyList

    public let offset: Int
    public let header: Header
}

extension ObjCPropertyRelativeListList: ObjCMemberRelativeListListProtocol {
    public func lists(in machO: MachOImage) -> [(MachOImage, ObjCPropertyList)] {
        resolveMemberLists(in: machO).resolvedValues
    }

    public func lists(in machO: MachOFile) -> [(MachOFile, ObjCPropertyList)] {
        resolveMemberLists(in: machO).resolvedValues
    }

    internal func makeList(
        ptr: UnsafeRawPointer,
        offset: Int,
        is64Bit: Bool
    ) -> ObjCPropertyList {
        .init(ptr: ptr, offset: offset, is64Bit: is64Bit)
    }

    internal func makeList(
        offset: Int,
        header: EntrySizeListHeader,
        is64Bit: Bool
    ) -> ObjCPropertyList {
        .init(offset: offset, header: header, is64Bit: is64Bit)
    }

    internal func expectedEntrySize(for list: ObjCPropertyList) -> Int {
        list.expectedEntrySize(is64Bit: list.is64Bit)
    }

    internal func expectedEntryAlignment(for list: ObjCPropertyList) -> Int {
        list.expectedEntryAlignment(is64Bit: list.is64Bit)
    }
}

extension ObjCPropertyRelativeListList {
    init(
        ptr: UnsafeRawPointer,
        offset: Int
    ) {
        self.offset = offset
        self.header = ptr.loadUnaligned(as: Header.self)
    }

    public func list(in machO: MachOImage, for entry: Entry) -> (MachOImage, List)? {
        guard case let .resolved(source, list) = resolveMemberList(
            in: machO,
            for: entry
        ) else { return nil }
        return (source, list)
    }

    public func list(in machO: MachOFile, for entry: Entry) -> (MachOFile, List)? {
        guard case let .resolved(source, list) = resolveMemberList(
            in: machO,
            for: entry
        ) else { return nil }
        return (source, list)
    }
}
