//
//  ObjCProtocolArrayProtocol.swift
//
//
//  Created by p-x9 on 2024/11/01
//  
//

import Foundation
@_spi(Support) import MachOKit

public protocol ObjCProtocolArrayProtocol {
    associatedtype ObjCProtocolList: ObjCProtocolListProtocol
    associatedtype ObjCProtocolRelativeListList: ObjCProtocolRelativeListListProtocol where ObjCProtocolRelativeListList.List == ObjCProtocolList

    var offset: Int { get }

    @_spi(Core)
    init(offset: Int)

    func lists(in machO: MachOImage) -> [ObjCProtocolList]
}

extension ObjCProtocolArrayProtocol {
    public func lists(in machO: MachOImage) -> [ObjCProtocolList] {
        let result = readLists(in: machO)
        guard result.representation != .relative else { return [] }
        return result.entries.map(\.list)
    }

    public func relativeListList(in machO: MachOImage) -> ObjCProtocolRelativeListList? {
        readLists(in: machO).relativeListList
    }

    /// Reads the tagged list array without dereferencing unproved runtime memory.
    @_spi(Diagnostics)
    public func readLists(
        in machO: MachOImage
    ) -> ObjCLoadedListArrayReadResult<
        ObjCProtocolList,
        ObjCProtocolRelativeListList
    > {
        Self.readLists(
            ObjCLoadedListArrayReader.storage(
                fromTaggedOffset: offset,
                in: machO
            ),
            in: machO
        )
    }

    internal static func readLists(
        _ storageRead: ObjCLoadedListArrayStorageRead,
        in machO: MachOImage
    ) -> ObjCLoadedListArrayReadResult<
        ObjCProtocolList,
        ObjCProtocolRelativeListList
    > {
        if machO.is64Bit {
            return readLists(
                storageRead,
                in: machO,
                pointerType: UInt64.self,
                pointerWidth: .bits64
            )
        }
        return readLists(
            storageRead,
            in: machO,
            pointerType: UInt32.self,
            pointerWidth: .bits32
        )
    }

    private static func readLists<Pointer: ObjCMetadataPointer>(
        _ storageRead: ObjCLoadedListArrayStorageRead,
        in machO: MachOImage,
        pointerType: Pointer.Type,
        pointerWidth: ObjCMetadataTableDiagnostic.PointerWidth
    ) -> ObjCLoadedListArrayReadResult<
        ObjCProtocolList,
        ObjCProtocolRelativeListList
    > {
        let owner = ObjCMetadataTableDiagnostic.Owner.loadedRWExtension(
            kind: .protocol,
            pointerWidth: pointerWidth
        )
        return ObjCLoadedListArrayReader.read(
            storageRead,
            in: machO,
            pointerType: pointerType,
            owner: owner,
            readList: { pointer in
                switch ObjCLoadedImageReader.readLayout(
                    from: pointer,
                    in: machO,
                    as: ObjCProtocolList.Header.self
                ) {
                case .absent:
                    return .absent
                case let .failure(provenance, reason):
                    return .failure(provenance: provenance, reason: reason)
                case .value(let read):
                    let list = ObjCProtocolList(
                        offset: read.offset,
                        header: read.layout
                    )
                    switch list.readProtocols(in: machO) {
                    case .success:
                        return .value(list)
                    case .failure(let failure):
                        return .failure(
                            provenance: .init(
                                logicalOffset: read.offset,
                                imageAddress: read.address
                            ),
                            reason: .init(failure)
                        )
                    }
                }
            },
            readRelative: { storage in
                switch ObjCMetadataTableReader.readImageLayout(
                    address: storage.address,
                    as: EntrySizeListHeader.self
                ) {
                case .failure(let failure):
                    return ObjCLoadedListArrayReader.tableFailure(
                        representation: .relative,
                        owner: owner,
                        provenance: storage.provenance,
                        failure: .init(failure)
                    )
                case .success(let header):
                    let relative = ObjCProtocolRelativeListList(
                        offset: storage.offset,
                        header: header
                    )
                    return ObjCLoadedListArrayReader.relativeResult(
                        relative,
                        resolution: relative.resolveLoadedLists(in: machO),
                        in: machO,
                        owner: owner
                    )
                }
            }
        )
    }
}
