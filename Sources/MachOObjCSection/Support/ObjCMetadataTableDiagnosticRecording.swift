//
//  ObjCMetadataTableDiagnosticRecording.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit

internal protocol ObjCMetadataTableSource {
    func metadataTableProvenance(
        at logicalOffset: Int
    ) -> ObjCMetadataTableDiagnostic.Provenance
}

extension MachOFile: ObjCMetadataTableSource {
    internal func metadataTableProvenance(
        at logicalOffset: Int
    ) -> ObjCMetadataTableDiagnostic.Provenance {
        guard let offset = UInt64(exactly: logicalOffset),
              let (_, fileOffset) = fileHandleAndOffset(forOffset: offset) else {
            return .init(logicalOffset: logicalOffset)
        }
        return .init(
            logicalOffset: logicalOffset,
            fileOffset: fileOffset
        )
    }
}

extension MachOImage: ObjCMetadataTableSource {
    internal func metadataTableProvenance(
        at logicalOffset: Int
    ) -> ObjCMetadataTableDiagnostic.Provenance {
        .init(
            logicalOffset: logicalOffset,
            imageAddress: addingSignedDisplacement(
                logicalOffset,
                to: UInt(bitPattern: ptr)
            )
        )
    }
}

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

internal enum ObjCMetadataTableDiagnosticRecorder {
    static func memberValues<Source, List, Value, Output>(
        from listRead: ObjCMetadataReferenceRead<List>,
        in source: Source,
        subject: ObjCMetadataTableDiagnostic.MetadataSubject,
        kind: ObjCMetadataTableDiagnostic.MemberKind,
        context: inout ObjCProtocolTraversalContext,
        entryStride: (List) -> Int,
        read: (List) -> ObjCMemberTableReadOutcome<Value>,
        transform: (Value) -> Output?
    ) -> [Output] where Source: ObjCMetadataTableSource, List: EntrySizeListProtocol {
        switch listRead {
        case .absent:
            return []
        case let .failure(provenance, reason):
            context.record(
                tableDiagnostic: .init(
                    owner: .member(subject: subject, kind: kind),
                    site: .table(provenance),
                    failure: reason
                )
            )
            return []
        case .value(let list):
            return memberValues(
                from: read(list),
                list: list,
                in: source,
                subject: subject,
                kind: kind,
                context: &context,
                entryStride: entryStride(list),
                transform: transform
            )
        }
    }

    static func memberValues<Source, List, Value, Output>(
        from outcome: ObjCMemberTableReadOutcome<Value>,
        list: List,
        in source: Source,
        subject: ObjCMetadataTableDiagnostic.MetadataSubject,
        kind: ObjCMetadataTableDiagnostic.MemberKind,
        context: inout ObjCProtocolTraversalContext,
        entryStride: Int,
        transform: (Value) -> Output?
    ) -> [Output] where Source: ObjCMetadataTableSource, List: EntrySizeListProtocol {
        let owner = ObjCMetadataTableDiagnostic.Owner.member(
            subject: subject,
            kind: kind
        )
        switch outcome {
        case .failure(let failure):
            context.record(
                tableDiagnostic: .init(
                    owner: owner,
                    site: .table(source.metadataTableProvenance(at: list.offset)),
                    failure: .init(failure)
                )
            )
            return []
        case .success(let success):
            for failure in success.failures {
                context.record(
                    tableDiagnostic: .init(
                        owner: owner,
                        site: .entry(
                            index: failure.index,
                            provenance: entryProvenance(
                                listOffset: list.offset,
                                index: failure.index,
                                stride: entryStride,
                                source: source
                            )
                        ),
                        failure: .init(failure.reason)
                    )
                )
            }
            return success.values.compactMap(transform)
        }
    }

    static func recordLoadedRelationshipFailure(
        provenance: ObjCMetadataTableDiagnostic.Provenance,
        reason: ObjCMetadataTableDiagnostic.Failure,
        subject: ObjCMetadataTableDiagnostic.MetadataSubject,
        role: ObjCMetadataTableDiagnostic.LoadedRelationshipRole,
        context: inout ObjCProtocolTraversalContext
    ) {
        context.record(
            tableDiagnostic: .init(
                owner: .loadedRelationship(subject: subject, role: role),
                site: .relationship(provenance),
                failure: reason
            )
        )
    }

    private static func entryProvenance(
        listOffset: Int,
        index: Int,
        stride: Int,
        source: some ObjCMetadataTableSource
    ) -> ObjCMetadataTableDiagnostic.Provenance {
        guard let tableOffset = checkedEntrySizeListTableOffset(listOffset) else {
            return source.metadataTableProvenance(at: listOffset)
        }
        let (delta, deltaOverflow) = index.multipliedReportingOverflow(by: stride)
        let (entryOffset, entryOverflow) = tableOffset.addingReportingOverflow(delta)
        guard !deltaOverflow, !entryOverflow else {
            return source.metadataTableProvenance(at: listOffset)
        }
        return source.metadataTableProvenance(at: entryOffset)
    }
}

extension ObjCMetadataTableDiagnostic.Failure {
    internal init(_ reason: ObjCMetadataTableEntryFailureReason) {
        switch reason {
        case .invalidLogicalOffset:
            self = .invalidEntryLogicalOffset
        case .invalidImplementationOffset:
            self = .invalidMethodImplementationOffset
        case .invalidRelativeDisplacement:
            self = .invalidRelativeDisplacement
        case let .unreadableFileRange(offset, byteCount):
            self = .unreadableFileRange(offset: offset, byteCount: byteCount)
        }
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
