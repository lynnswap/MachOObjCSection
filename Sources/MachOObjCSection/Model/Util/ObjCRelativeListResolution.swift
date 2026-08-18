//
//  ObjCRelativeListResolution.swift
//  MachOObjCSection
//

import Foundation

internal enum ObjCRelativeListResolutionEntry<Source, List, Failure> {
    case resolved(Source, List)
    case failure(Failure)
}

internal enum ObjCRelativeListResolution<Source, List, Failure> {
    case absent
    case failure(Failure)
    case entries([ObjCRelativeListResolutionEntry<Source, List, Failure>])

    func mapFailure<MappedFailure>(
        _ transform: (Failure) -> MappedFailure
    ) -> ObjCRelativeListResolution<Source, List, MappedFailure> {
        switch self {
        case .absent:
            return .absent
        case .failure(let failure):
            return .failure(transform(failure))
        case .entries(let entries):
            return .entries(
                entries.map { entry in
                    switch entry {
                    case let .resolved(source, list):
                        return .resolved(source, list)
                    case .failure(let failure):
                        return .failure(transform(failure))
                    }
                }
            )
        }
    }

    var resolvedValues: [(Source, List)] {
        guard case .entries(let entries) = self else { return [] }
        return entries.compactMap { entry in
            guard case let .resolved(source, list) = entry else { return nil }
            return (source, list)
        }
    }
}

internal struct ObjCRelativeListFailure: Error, Equatable {
    let outerListOffset: Int
    let location: Location
    let diagnosticOffset: Int
    let reason: Reason

    enum Location: Equatable {
        case table
        case entry(index: Int, imageIndex: Int, offset: Int)
    }

    enum Reason: Error, Equatable {
        case unsupportedListEncoding
        case invalidListOffset(Int)
        case invalidElementCount(UInt64)
        case invalidSignedElementCount(Int)
        case excessiveElementCount(actual: Int, maximum: Int)
        case excessiveByteCount(actual: Int, maximum: Int)
        case invalidRelativeEntrySize(advertised: UInt32, minimum: Int)
        case invalidListEntrySize(advertised: Int, expected: Int)
        case misalignedListOffset(offset: Int, requiredAlignment: Int)
        case misalignedListAddress(address: UInt, requiredAlignment: Int)
        case unresolvedListPointer
        case missingListBackingData
        case unreadableFileHeader(offset: UInt64, byteCount: Int)
        case unreadableImageHeader(address: UInt, byteCount: Int)
        case invalidRelativeListLocation
        case relativeImageUnavailable(imageIndex: Int)
        case byteCountOverflow(elementCount: Int, elementSize: Int)
        case rangeOverflow(startOffset: UInt64, byteCount: Int)
        case unreadableFileRange(offset: UInt64, byteCount: Int)
        case unreadableImageRange(address: UInt, byteCount: Int)
    }
}

extension ObjCRelativeListFailure {
    static func table(
        outerListOffset: Int,
        diagnosticOffset: Int? = nil,
        reason: Reason
    ) -> Self {
        .init(
            outerListOffset: outerListOffset,
            location: .table,
            diagnosticOffset: diagnosticOffset ?? outerListOffset,
            reason: reason
        )
    }

    static func entry(
        outerListOffset: Int,
        index: Int,
        entry: RelativeListListEntry,
        diagnosticOffset: Int? = nil,
        reason: Reason
    ) -> Self {
        .init(
            outerListOffset: outerListOffset,
            location: .entry(
                index: index,
                imageIndex: entry.imageIndex,
                offset: entry.offset
            ),
            diagnosticOffset: diagnosticOffset ?? entry.offset,
            reason: reason
        )
    }
}

extension ObjCRelativeListFailure.Location {
    var memberDiagnosticLocation: ObjCMemberListDiagnostic.Location {
        switch self {
        case .table:
            return .table
        case let .entry(index, imageIndex, offset):
            return .entry(index: index, imageIndex: imageIndex, offset: offset)
        }
    }
}

extension ObjCRelativeListFailure.Reason {
    var memberDiagnosticFailure: ObjCMemberListDiagnostic.Failure {
        switch self {
        case .unsupportedListEncoding:
            return .unsupportedListEncoding
        case .invalidListOffset(let offset):
            return .invalidListOffset(offset)
        case .invalidElementCount(let count):
            return .invalidElementCount(count)
        case .invalidSignedElementCount(let count):
            return .invalidSignedElementCount(count)
        case let .excessiveElementCount(actual, maximum):
            return .excessiveElementCount(actual: actual, maximum: maximum)
        case let .excessiveByteCount(actual, maximum):
            return .excessiveByteCount(actual: actual, maximum: maximum)
        case let .invalidRelativeEntrySize(advertised, minimum):
            return .invalidRelativeEntrySize(advertised: advertised, minimum: minimum)
        case let .invalidListEntrySize(advertised, expected):
            return .invalidListEntrySize(advertised: advertised, expected: expected)
        case let .misalignedListOffset(offset, alignment):
            return .misalignedListOffset(offset: offset, requiredAlignment: alignment)
        case let .misalignedListAddress(address, alignment):
            return .misalignedListAddress(address: address, requiredAlignment: alignment)
        case .unresolvedListPointer:
            return .unresolvedListPointer
        case .missingListBackingData:
            return .missingListBackingData
        case let .unreadableFileHeader(offset, byteCount):
            return .unreadableFileHeader(offset: offset, byteCount: byteCount)
        case let .unreadableImageHeader(address, byteCount):
            return .unreadableImageHeader(address: address, byteCount: byteCount)
        case .invalidRelativeListLocation:
            return .invalidRelativeListLocation
        case .relativeImageUnavailable(let imageIndex):
            return .relativeImageUnavailable(imageIndex: imageIndex)
        case let .byteCountOverflow(count, size):
            return .byteCountOverflow(elementCount: count, elementSize: size)
        case let .rangeOverflow(offset, byteCount):
            return .rangeOverflow(startOffset: offset, byteCount: byteCount)
        case let .unreadableFileRange(offset, byteCount):
            return .unreadableFileRange(offset: offset, byteCount: byteCount)
        case let .unreadableImageRange(address, byteCount):
            return .unreadableImageRange(address: address, byteCount: byteCount)
        }
    }
}
