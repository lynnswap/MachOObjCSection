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
