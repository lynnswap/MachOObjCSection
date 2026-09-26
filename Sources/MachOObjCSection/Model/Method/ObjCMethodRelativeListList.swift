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
        guard case let .resolved(source, list) = resolveMemberList(
            in: machO,
            for: entry
        ) else { return nil }
        return (source, list)
    }
}

extension ObjCMethodRelativeListList {
    public func list(in machO: MachOFile, for entry: Entry) -> (MachOFile, List)? {
        guard case let .resolved(source, list) = resolveMemberList(
            in: machO,
            for: entry
        ) else { return nil }
        return (source, list)
    }
}
