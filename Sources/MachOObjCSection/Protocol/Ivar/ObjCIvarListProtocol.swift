//
//  ObjCIvarListProtocol.swift
//
//
//  Created by p-x9 on 2024/08/25
//
//

import Foundation
@_spi(Support) import MachOKit

public protocol ObjCIvarListProtocol: EntrySizeListProtocol where Entry == ObjCIvar {
    associatedtype ObjCIvar: ObjCIvarProtocol

    var offset: Int { get }
    var header: Header { get }

    @_spi(Core)
    init(header: Header, offset: Int)

    func ivars(in machO: MachOImage) -> [ObjCIvar]?
    func ivars(in machO: MachOFile) -> [ObjCIvar]?
}

extension ObjCIvarListProtocol {
    public static var flagMask: UInt32 { 0 }
}

extension ObjCIvarListProtocol {
    func isValidEntrySize(is64Bit: Bool) -> Bool {
        MemoryLayout<ObjCIvar.Layout>.size == entrySize
    }
}

extension ObjCIvarListProtocol where ObjCIvar: LayoutWrapper {
    public func ivars(in machO: MachOImage) -> [ObjCIvar]? {
        readIvars(in: machO).values
    }

    public func ivars(in machO: MachOFile) -> [ObjCIvar]? {
        readIvars(in: machO).values
    }

    internal func readIvars(
        in machO: MachOImage
    ) -> ObjCMemberTableReadOutcome<ObjCIvar> {
        switch readImageTable(
            in: machO,
            expectedStride: ObjCIvar.layoutSize,
            requiredAlignment: MemoryLayout<ObjCIvar.Layout>.alignment,
            as: ObjCIvar.Layout.self
        ) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let entries):
            let ivars = entries.compactMap { entry -> ObjCIvar? in
                guard let offset = entry.logicalOffset else { return nil }
                return ObjCIvar(layout: entry.value, offset: offset)
            }
            return .success(.init(values: ivars, failures: []))
        }
    }

    internal func readIvars(
        in machO: MachOFile
    ) -> ObjCMemberTableReadOutcome<ObjCIvar> {
        switch readFileTable(
            in: machO,
            expectedStride: ObjCIvar.layoutSize,
            requiredAlignment: MemoryLayout<ObjCIvar.Layout>.alignment,
            as: ObjCIvar.Layout.self
        ) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let entries):
            let ivars = entries.compactMap { entry -> ObjCIvar? in
                guard let offset = entry.logicalOffset else { return nil }
                return ObjCIvar(layout: entry.value, offset: offset)
            }
            return .success(.init(values: ivars, failures: []))
        }
    }
}
