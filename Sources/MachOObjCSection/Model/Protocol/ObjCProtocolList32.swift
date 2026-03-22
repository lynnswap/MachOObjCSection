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
    public init(ptr: UnsafeRawPointer, offset: Int) {
        self.offset = offset
        self.header = ptr.assumingMemoryBound(to: Header.self).pointee
    }
}

extension ObjCProtocolList32 {
    public func protocols(
        in machO: MachOImage
    ) -> [(MachOImage, ObjCProtocol)]? {
        _readProtocols(in: machO, pointerType: UInt32.self)
    }

    public func protocols(
        in machO: MachOFile
    ) -> [(MachOFile, ObjCProtocol)]? {
        _readProtocols(in: machO, pointerType: UInt32.self)
    }
}
