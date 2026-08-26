//
//  ObjCPropertyArray.swift
//  
//
//  Created by p-x9 on 2024/10/31
//  
//

import Foundation
@_spi(Support) import MachOKit

public struct ObjCPropertyArray {
    public let offset: Int
    public let is64Bit: Bool
}

extension ObjCPropertyArray {
    public func lists(in machO: MachOImage) -> [ObjCPropertyList] {
        let result = readLists(in: machO)
        guard result.representation != .relative else { return [] }
        return result.entries.map(\.list)
    }

    public func relativeListList(in machO: MachOImage) -> ObjCPropertyRelativeListList? {
        readLists(in: machO).relativeListList
    }

    /// Reads the tagged list array without dereferencing unproved runtime memory.
    @_spi(Diagnostics)
    public func readLists(
        in machO: MachOImage
    ) -> ObjCLoadedListArrayReadResult<
        ObjCPropertyList,
        ObjCPropertyRelativeListList
    > {
        if is64Bit {
            return readLists(
                in: machO,
                pointerType: UInt64.self,
                pointerWidth: .bits64
            )
        }
        return readLists(
            in: machO,
            pointerType: UInt32.self,
            pointerWidth: .bits32
        )
    }

    private func readLists<Pointer: ObjCMetadataPointer>(
        in machO: MachOImage,
        pointerType: Pointer.Type,
        pointerWidth: ObjCMetadataTableDiagnostic.PointerWidth
    ) -> ObjCLoadedListArrayReadResult<
        ObjCPropertyList,
        ObjCPropertyRelativeListList
    > {
        let owner = ObjCMetadataTableDiagnostic.Owner.loadedRWExtension(
            kind: .property,
            pointerWidth: pointerWidth
        )
        return ObjCLoadedListArrayReader.read(
            ObjCLoadedListArrayReader.storage(
                fromTaggedOffset: offset,
                in: machO
            ),
            in: machO,
            pointerType: pointerType,
            owner: owner,
            readList: { pointer in
                ObjCLoadedImageReader.readEntrySizeList(
                    from: pointer,
                    in: machO,
                    validateList: { list in
                        guard case .failure(let failure) = list.readProperties(
                            in: machO
                        ) else { return nil }
                        return failure
                    },
                    makeList: { header, offset in
                        ObjCPropertyList(
                            offset: offset,
                            header: header,
                            is64Bit: is64Bit
                        )
                    }
                )
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
                    let relative = ObjCPropertyRelativeListList(
                        offset: storage.offset,
                        header: header
                    )
                    return ObjCLoadedListArrayReader.relativeResult(
                        relative,
                        resolution: relative.resolveMemberLists(in: machO),
                        in: machO,
                        owner: owner
                    )
                }
            }
        )
    }
}
