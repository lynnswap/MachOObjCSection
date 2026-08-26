//
//  ObjCFileMemberListReading.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit

internal enum ObjCFileMemberListReader {
    static func readEntrySizeList<Pointer, List>(
        from rawPointer: Pointer,
        in machO: MachOFile,
        resolve: () -> ResolvedValue?,
        makeList: (EntrySizeListHeader, Int) -> List
    ) -> ObjCMetadataReferenceRead<List> where Pointer: FixedWidthInteger {
        guard rawPointer != 0 else { return .absent }
        guard UInt64(exactly: rawPointer) != nil else {
            return .failure(
                provenance: .init(),
                reason: .invalidPointer(rawValue: 0)
            )
        }
        guard let resolved = resolve() else {
            return .failure(
                provenance: .init(),
                reason: .unresolvedListPointer
            )
        }
        guard let logicalOffset = Int(exactly: resolved.offset) else {
            return .failure(
                provenance: .init(),
                reason: .invalidFileListOffset(resolved.offset)
            )
        }
        guard let (file, fileOffset) = machO.fileHandleAndOffset(
            forResolvedValue: resolved
        ) else {
            return .failure(
                provenance: .init(logicalOffset: logicalOffset),
                reason: .missingListBackingData
            )
        }
        let provenance = ObjCMetadataTableDiagnostic.Provenance(
            logicalOffset: logicalOffset,
            fileOffset: fileOffset
        )
        guard let header: EntrySizeListHeader = file.readLayout(
            offset: fileOffset,
            as: EntrySizeListHeader.self
        ) else {
            return .failure(
                provenance: provenance,
                reason: .unreadableFileHeader(
                    offset: fileOffset,
                    byteCount: MemoryLayout<EntrySizeListHeader>.size
                )
            )
        }
        return .value(makeList(header, logicalOffset))
    }
}

extension ObjCClassRODataProtocol {
    internal func readFileMethodList(
        in machO: MachOFile
    ) -> ObjCMetadataReferenceRead<ObjCMethodList> {
        guard layout.baseMethods & 1 == 0 else { return .absent }
        return ObjCFileMemberListReader.readEntrySizeList(
            from: layout.baseMethods,
            in: machO,
            resolve: { machO.resolveRebase(unresolvedValue(of: .baseMethods)) },
            makeList: { header, offset in
                ObjCMethodList(
                    offset: offset,
                    header: header,
                    is64Bit: machO.is64Bit
                )
            }
        )
    }

    internal func readFilePropertyList(
        in machO: MachOFile
    ) -> ObjCMetadataReferenceRead<ObjCPropertyList> {
        guard layout.baseProperties & 1 == 0 else { return .absent }
        return ObjCFileMemberListReader.readEntrySizeList(
            from: layout.baseProperties,
            in: machO,
            resolve: { machO.resolveRebase(unresolvedValue(of: .baseProperties)) },
            makeList: { header, offset in
                ObjCPropertyList(
                    offset: offset,
                    header: header,
                    is64Bit: machO.is64Bit
                )
            }
        )
    }

    internal func readFileIvarList(
        in machO: MachOFile
    ) -> ObjCMetadataReferenceRead<ObjCIvarList> {
        ObjCFileMemberListReader.readEntrySizeList(
            from: layout.ivars,
            in: machO,
            resolve: { machO.resolveRebase(unresolvedValue(of: .ivars)) },
            makeList: { header, offset in
                ObjCIvarList(header: header, offset: offset)
            }
        )
    }
}

extension ObjCCategoryProtocol {
    internal func readFileMethodList(
        at pointer: Layout.Pointer,
        field: LayoutField,
        in machO: MachOFile
    ) -> ObjCMetadataReferenceRead<ObjCMethodList> {
        guard pointer == 0 || pointer & 1 == 0 else {
            return .failure(provenance: .init(), reason: .unsupportedListEncoding)
        }
        return ObjCFileMemberListReader.readEntrySizeList(
            from: pointer,
            in: machO,
            resolve: { machO.resolveRebase(unresolvedValue(of: field)) },
            makeList: { header, offset in
                ObjCMethodList(
                    offset: offset,
                    header: header,
                    is64Bit: machO.is64Bit
                )
            }
        )
    }

    internal func readFilePropertyList(
        at pointer: Layout.Pointer,
        field: LayoutField,
        in machO: MachOFile
    ) -> ObjCMetadataReferenceRead<ObjCPropertyList> {
        guard pointer == 0 || pointer & 1 == 0 else {
            return .failure(provenance: .init(), reason: .unsupportedListEncoding)
        }
        return ObjCFileMemberListReader.readEntrySizeList(
            from: pointer,
            in: machO,
            resolve: { machO.resolveRebase(unresolvedValue(of: field)) },
            makeList: { header, offset in
                ObjCPropertyList(
                    offset: offset,
                    header: header,
                    is64Bit: machO.is64Bit
                )
            }
        )
    }
}

extension ObjCProtocolProtocol {
    internal func readFileMethodList(
        field: LayoutField,
        in machO: MachOFile
    ) -> ObjCMetadataReferenceRead<ObjCMethodList> {
        let pointer = layout[keyPath: keyPath(of: field)]
        guard pointer == 0 || pointer & 1 == 0 else {
            return .failure(provenance: .init(), reason: .unsupportedListEncoding)
        }
        return ObjCFileMemberListReader.readEntrySizeList(
            from: pointer,
            in: machO,
            resolve: { machO.resolveRebase(unresolvedValue(of: field)) },
            makeList: { header, offset in
                ObjCMethodList(
                    offset: offset,
                    header: header,
                    is64Bit: machO.is64Bit
                )
            }
        )
    }

    internal func readFilePropertyList(
        field: LayoutField,
        in machO: MachOFile
    ) -> ObjCMetadataReferenceRead<ObjCPropertyList> {
        if case ._classProperties = field {
            let fieldOffset = layoutOffset(of: field)
            guard size >= fieldOffset + MemoryLayout<Layout.Pointer>.size else {
                return .absent
            }
        }
        let pointer = layout[keyPath: keyPath(of: field)]
        guard pointer == 0 || pointer & 1 == 0 else {
            return .failure(provenance: .init(), reason: .unsupportedListEncoding)
        }
        return ObjCFileMemberListReader.readEntrySizeList(
            from: pointer,
            in: machO,
            resolve: { machO.resolveRebase(unresolvedValue(of: field)) },
            makeList: { header, offset in
                ObjCPropertyList(
                    offset: offset,
                    header: header,
                    is64Bit: machO.is64Bit
                )
            }
        )
    }
}
