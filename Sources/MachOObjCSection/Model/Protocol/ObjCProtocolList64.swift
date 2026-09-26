//
//  ObjCProtocolList.swift
//
//
//  Created by p-x9 on 2024/05/25
//
//

import Foundation
@_spi(Support) import MachOKit

public struct ObjCProtocolList64: ObjCProtocolListProtocol {
    public typealias Header = ObjCProtocolListHeader64
    public typealias ObjCProtocol = ObjCProtocol64

    public let offset: Int
    public let header: Header

    @_spi(Core)
    public init(offset: Int, header: Header) {
        self.offset = offset
        self.header = header
    }
}

extension ObjCProtocolList64 {
    @_spi(Core)
    public init(ptr: UnsafeRawPointer, offset: Int) {
        self.offset = offset
        self.header = ptr.loadUnaligned(as: Header.self)
    }
}

extension ObjCProtocolList64 {
    public func protocols(
        in machO: MachOImage
    ) -> [(MachOImage, ObjCProtocol)]? {
        readProtocols(in: machO).values
    }

    public func protocols(
        in machO: MachOFile
    ) -> [(MachOFile, ObjCProtocol)]? {
        readProtocols(in: machO).values
    }
}
