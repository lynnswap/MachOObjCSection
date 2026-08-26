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
        self.header = ptr.loadUnaligned(as: Header.self)
    }

    public func list(in machO: MachOFile, for entry: Entry) -> (MachOFile, List)? {
        guard let relativeOffset = addingSignedDisplacement(
                entry.signedListOffset,
                to: entry.offset
              ),
              let offset = UInt64(exactly: relativeOffset) else { return nil }

        guard let location = machO.relativeListLocation(for: entry) else {
            return nil
        }

        guard let header: List.Header = location.cache.fileHandle.readLayout(
            offset: location.fileOffset,
            as: List.Header.self
        ) else {
            return nil
        }
        guard let listOffset = Int(exactly: offset) else { return nil }
        let list = List(
            offset: listOffset,
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
        self.header = ptr.loadUnaligned(as: Header.self)
    }

    public func list(in machO: MachOFile, for entry: Entry) -> (MachOFile, List)? {
        guard let relativeOffset = addingSignedDisplacement(
                entry.signedListOffset,
                to: entry.offset
              ),
              let offset = UInt64(exactly: relativeOffset) else { return nil }

        guard let location = machO.relativeListLocation(for: entry) else {
            return nil
        }

        guard let header: List.Header = location.cache.fileHandle.readLayout(
            offset: location.fileOffset,
            as: List.Header.self
        ) else {
            return nil
        }
        guard let listOffset = Int(exactly: offset) else { return nil }
        let list = List(
            offset: listOffset,
            header: header
        )

        return (location.image, list)
    }
}
