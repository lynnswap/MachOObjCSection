//
//  ObjCProtocolList32.swift
//
//
//  Created by p-x9 on 2024/11/01
//
//

import Foundation
@_spi(Support) import MachOKit

public struct ObjCProtocolList32: ObjCProtocolListProtocol {
    public typealias Header = ObjCProtocolListHeader32
    public typealias ObjCProtocol = ObjCProtocol32

    public let offset: Int
    public let header: Header

    @_spi(Core)
    public init(offset: Int, header: Header) {
        self.offset = offset
        self.header = header
    }
}

extension ObjCProtocolList32 {
    @_spi(Core)
    public init(ptr: UnsafeRawPointer, offset: Int) {
        self.offset = offset
        self.header = ptr.loadUnaligned(as: Header.self)
    }
}

extension ObjCProtocolList32 {
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
