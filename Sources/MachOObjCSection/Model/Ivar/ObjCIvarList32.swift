//
//  ObjCIvarList32.swift
//
//
//  Created by p-x9 on 2024/08/25
//  
//

import Foundation
@_spi(Support) import MachOKit

public struct ObjCIvarList32: ObjCIvarListProtocol {
    public typealias ObjCIvar = ObjCIvar32
    public typealias Entry = ObjCIvar

    /// Offset from machO header start
    public let offset: Int
    public let header: Header

    @_spi(Core)
    public init(
        header: Header,
        offset: Int
    ) {
        self.header = header
        self.offset = offset
    }
}
