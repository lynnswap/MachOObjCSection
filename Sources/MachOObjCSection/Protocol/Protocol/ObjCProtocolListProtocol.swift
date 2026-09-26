//
//  ObjCProtocolListProtocol.swift
//
//
//  Created by p-x9 on 2024/07/19
//
//

import Foundation
@_spi(Support) import MachOKit

public protocol ObjCProtocolListHeaderProtocol {
    var count: Int { get }
}

public protocol ObjCProtocolListProtocol {
    associatedtype Header: ObjCProtocolListHeaderProtocol
    associatedtype ObjCProtocol: ObjCProtocolProtocol

    var offset: Int { get }
    var header: Header { get }

    @_spi(Core)
    init(offset: Int, header: Header)

    @_spi(Core)
    init(ptr: UnsafeRawPointer, offset: Int)

    func protocols(in machO: MachOImage) -> [(MachOImage, ObjCProtocol)]?
    func protocols(in machO: MachOFile) -> [(MachOFile, ObjCProtocol)]?
}

extension ObjCProtocolListProtocol {
    public var isListOfLists: Bool {
        offset & 1 == 1
    }
}
