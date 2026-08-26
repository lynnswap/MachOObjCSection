//
//  ObjCLoadedListArrayReading.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit

/// The active runtime representation of a loaded Objective-C list array.
@_spi(Diagnostics)
public enum ObjCLoadedListArrayRepresentation: Sendable, Equatable {
    case single
    case array
    case relative
}

/// One readable list and the loaded image used to resolve it.
@_spi(Diagnostics)
public struct ObjCLoadedListArrayEntry<List> {
    public let image: MachOImage
    public let list: List

    internal init(image: MachOImage, list: List) {
        self.image = image
        self.list = list
    }
}

/// A checked projection of one tagged `class_rw_ext_t` list array.
@_spi(Diagnostics)
public struct ObjCLoadedListArrayReadResult<List, RelativeList> {
    /// `nil` when the field is absent or its tag is unsupported.
    public let representation: ObjCLoadedListArrayRepresentation?
    /// Readable lists in source order. Invalid entries are omitted independently.
    public let entries: [ObjCLoadedListArrayEntry<List>]
    /// The checked relative wrapper when `representation == .relative`.
    public let relativeListList: RelativeList?
    /// Recoverable table and entry failures in discovery order.
    public let tableDiagnostics: [ObjCMetadataTableDiagnostic]

    internal init(
        representation: ObjCLoadedListArrayRepresentation?,
        entries: [ObjCLoadedListArrayEntry<List>] = [],
        relativeListList: RelativeList? = nil,
        tableDiagnostics: [ObjCMetadataTableDiagnostic] = []
    ) {
        self.representation = representation
        self.entries = entries
        self.relativeListList = relativeListList
        self.tableDiagnostics = tableDiagnostics
    }
}

internal struct ObjCLoadedListArrayStorage {
    let representation: ObjCLoadedListArrayRepresentation
    let taggedOffset: Int
    let offset: Int
    let address: UInt
    let provenance: ObjCMetadataTableDiagnostic.Provenance
}

internal enum ObjCLoadedListArrayReader {
    private static let tagMask: UInt64 = 3

    static func representation(
        forRawValue rawValue: UInt64,
        in machO: MachOImage
    ) -> ObjCLoadedListArrayRepresentation? {
        guard rawValue != 0 else { return nil }
        return representation(
            forTag: machO.stripPointerTags(of: rawValue) & tagMask
        )
    }

    static func storage<Pointer: ObjCMetadataPointer>(
        from rawPointer: Pointer,
        in machO: MachOImage
    ) -> ObjCMetadataReferenceRead<ObjCLoadedListArrayStorage> {
        let rawValue = rawPointer.metadataPointerValue
        guard rawValue != 0 else { return .absent }

        let strippedValue = machO.stripPointerTags(of: rawValue)
        let rawTag = strippedValue & tagMask
        guard let representation = representation(forTag: rawTag) else {
            return .failure(
                provenance: .init(),
                reason: .unsupportedListEncoding
            )
        }

        let payload = strippedValue & ~tagMask
        guard payload != 0,
              let address = UInt(exactly: payload) else {
            return .failure(
                provenance: .init(),
                reason: .invalidPointer(rawValue: rawValue)
            )
        }
        let imageBase = UInt(bitPattern: machO.ptr)
        guard address.isMultiple(of: 4),
              let offset = signedDisplacement(from: imageBase, to: address),
              offset.isMultiple(of: 4),
              let tag = Int(exactly: rawTag) else {
            return .failure(
                provenance: .init(imageAddress: address),
                reason: .invalidEntryArithmetic(
                    baseAddress: imageBase,
                    targetAddress: address
                )
            )
        }
        return .value(
            .init(
                representation: representation,
                taggedOffset: offset | tag,
                offset: offset,
                address: address,
                provenance: .init(
                    logicalOffset: offset,
                    imageAddress: address
                )
            )
        )
    }

    static func storage(
        fromTaggedOffset taggedOffset: Int,
        in machO: MachOImage
    ) -> ObjCMetadataReferenceRead<ObjCLoadedListArrayStorage> {
        let tag = taggedOffset & Int(tagMask)
        guard let representation = representation(forTag: UInt64(tag)) else {
            return .failure(
                provenance: .init(logicalOffset: taggedOffset),
                reason: .unsupportedListEncoding
            )
        }
        let offset = taggedOffset & ~Int(tagMask)
        let imageBase = UInt(bitPattern: machO.ptr)
        guard let address = addingSignedDisplacement(offset, to: imageBase),
              address != 0,
              address.isMultiple(of: 4) else {
            return .failure(
                provenance: .init(logicalOffset: offset),
                reason: .invalidListOffset(offset)
            )
        }
        return .value(
            .init(
                representation: representation,
                taggedOffset: taggedOffset,
                offset: offset,
                address: address,
                provenance: .init(
                    logicalOffset: offset,
                    imageAddress: address
                )
            )
        )
    }

    static func read<Pointer, List, RelativeList>(
        _ storageRead: ObjCMetadataReferenceRead<ObjCLoadedListArrayStorage>,
        in machO: MachOImage,
        pointerType: Pointer.Type,
        owner: ObjCMetadataTableDiagnostic.Owner,
        readList: (Pointer) -> ObjCMetadataReferenceRead<List>,
        readRelative: (
            ObjCLoadedListArrayStorage
        ) -> ObjCLoadedListArrayReadResult<List, RelativeList>
    ) -> ObjCLoadedListArrayReadResult<List, RelativeList>
    where Pointer: ObjCMetadataPointer {
        switch storageRead {
        case .absent:
            return .init(representation: nil)
        case let .failure(provenance, reason):
            return .init(
                representation: nil,
                tableDiagnostics: [
                    .init(
                        owner: owner,
                        site: .table(provenance),
                        failure: reason
                    )
                ]
            )
        case .value(let storage):
            switch storage.representation {
            case .single:
                return readSingle(
                    storage,
                    in: machO,
                    pointerType: pointerType,
                    owner: owner,
                    readList: readList
                )
            case .array:
                return readArray(
                    storage,
                    in: machO,
                    pointerType: pointerType,
                    owner: owner,
                    readList: readList
                )
            case .relative:
                return readRelative(storage)
            }
        }
    }

    private static func readSingle<Pointer, List, RelativeList>(
        _ storage: ObjCLoadedListArrayStorage,
        in machO: MachOImage,
        pointerType: Pointer.Type,
        owner: ObjCMetadataTableDiagnostic.Owner,
        readList: (Pointer) -> ObjCMetadataReferenceRead<List>
    ) -> ObjCLoadedListArrayReadResult<List, RelativeList>
    where Pointer: ObjCMetadataPointer {
        guard let rawPointer = Pointer(exactly: storage.address) else {
            return tableFailure(
                representation: .single,
                owner: owner,
                provenance: storage.provenance,
                failure: .invalidPointer(rawValue: UInt64(storage.address))
            )
        }
        switch readList(rawPointer) {
        case .absent:
            return tableFailure(
                representation: .single,
                owner: owner,
                provenance: storage.provenance,
                failure: .invalidPointer(rawValue: 0)
            )
        case let .failure(provenance, reason):
            return tableFailure(
                representation: .single,
                owner: owner,
                provenance: provenance,
                failure: reason
            )
        case .value(let list):
            return .init(
                representation: .single,
                entries: [.init(image: machO, list: list)]
            )
        }
    }

    private static func readArray<Pointer, List, RelativeList>(
        _ storage: ObjCLoadedListArrayStorage,
        in machO: MachOImage,
        pointerType: Pointer.Type,
        owner: ObjCMetadataTableDiagnostic.Owner,
        readList: (Pointer) -> ObjCMetadataReferenceRead<List>
    ) -> ObjCLoadedListArrayReadResult<List, RelativeList>
    where Pointer: ObjCMetadataPointer {
        let pointerSize = MemoryLayout<Pointer>.size
        guard storage.address.isMultiple(of: UInt(pointerSize)) else {
            return tableFailure(
                representation: .array,
                owner: owner,
                provenance: storage.provenance,
                failure: .misalignedTableAddress(
                    address: storage.address,
                    requiredAlignment: pointerSize
                )
            )
        }

        let headerEntries: [ObjCMetadataTableEntry<UInt32>]
        switch ObjCMetadataTableReader.readImage(
            address: storage.address,
            logicalOffset: storage.offset,
            count: 1,
            stride: pointerSize,
            as: UInt32.self
        ) {
        case .success(let entries):
            headerEntries = entries
        case .failure(let failure):
            return tableFailure(
                representation: .array,
                owner: owner,
                provenance: storage.provenance,
                failure: .init(failure)
            )
        }
        guard let rawCount = headerEntries.first?.value else {
            return tableFailure(
                representation: .array,
                owner: owner,
                provenance: storage.provenance,
                failure: .unreadableImageRange(
                    address: storage.address,
                    byteCount: pointerSize
                )
            )
        }
        let count: Int
        switch ObjCMetadataTableReader.exactCount(UInt64(rawCount)) {
        case .success(let value):
            count = value
        case .failure(let failure):
            return tableFailure(
                representation: .array,
                owner: owner,
                provenance: storage.provenance,
                failure: .init(failure)
            )
        }
        let (tableAddress, addressOverflow) = storage.address.addingReportingOverflow(
            UInt(pointerSize)
        )
        let (tableOffset, offsetOverflow) = storage.offset.addingReportingOverflow(
            pointerSize
        )
        guard !addressOverflow, !offsetOverflow else {
            return tableFailure(
                representation: .array,
                owner: owner,
                provenance: storage.provenance,
                failure: .rangeOverflow(
                    startOffset: UInt64(storage.address),
                    byteCount: pointerSize
                )
            )
        }

        let pointerEntries: [ObjCMetadataTableEntry<Pointer>]
        switch ObjCMetadataTableReader.readImage(
            address: tableAddress,
            logicalOffset: tableOffset,
            count: count,
            stride: pointerSize,
            as: pointerType
        ) {
        case .success(let entries):
            pointerEntries = entries
        case .failure(let failure):
            return tableFailure(
                representation: .array,
                owner: owner,
                provenance: storage.provenance,
                failure: .init(failure)
            )
        }

        var entries: [ObjCLoadedListArrayEntry<List>] = []
        var diagnostics: [ObjCMetadataTableDiagnostic] = []
        entries.reserveCapacity(pointerEntries.count)
        for pointerEntry in pointerEntries {
            let provenance = ObjCMetadataTableDiagnostic.Provenance(
                logicalOffset: pointerEntry.logicalOffset,
                imageAddress: pointerEntry.address
            )
            let rawValue = pointerEntry.value.metadataPointerValue
            guard rawValue != 0 else {
                diagnostics.append(
                    entryFailure(
                        owner: owner,
                        index: pointerEntry.index,
                        provenance: provenance,
                        failure: .invalidPointer(rawValue: rawValue)
                    )
                )
                continue
            }
            switch readList(pointerEntry.value) {
            case .absent:
                diagnostics.append(
                    entryFailure(
                        owner: owner,
                        index: pointerEntry.index,
                        provenance: provenance,
                        failure: .invalidPointer(rawValue: rawValue)
                    )
                )
            case let .failure(_, reason):
                diagnostics.append(
                    entryFailure(
                        owner: owner,
                        index: pointerEntry.index,
                        provenance: provenance,
                        failure: reason
                    )
                )
            case .value(let list):
                entries.append(.init(image: machO, list: list))
            }
        }
        return .init(
            representation: .array,
            entries: entries,
            tableDiagnostics: diagnostics
        )
    }

    private static func representation(
        forTag tag: UInt64
    ) -> ObjCLoadedListArrayRepresentation? {
        switch tag {
        case 0: .single
        case 1: .array
        case 2: .relative
        default: nil
        }
    }

    static func relativeResult<List, RelativeList>(
        _ relativeListList: RelativeList,
        resolution: ObjCRelativeListResolution<
            MachOImage,
            List,
            ObjCRelativeListFailure
        >,
        in machO: MachOImage,
        owner: ObjCMetadataTableDiagnostic.Owner
    ) -> ObjCLoadedListArrayReadResult<List, RelativeList> {
        switch resolution {
        case .absent:
            return .init(
                representation: .relative,
                relativeListList: relativeListList
            )
        case .failure(let failure):
            return .init(
                representation: .relative,
                relativeListList: relativeListList,
                tableDiagnostics: [
                    relativeDiagnostic(failure, in: machO, owner: owner)
                ]
            )
        case .entries(let resolutions):
            var entries: [ObjCLoadedListArrayEntry<List>] = []
            var diagnostics: [ObjCMetadataTableDiagnostic] = []
            entries.reserveCapacity(resolutions.count)
            for resolution in resolutions {
                switch resolution {
                case let .resolved(image, list):
                    entries.append(.init(image: image, list: list))
                case .failure(let failure):
                    diagnostics.append(
                        relativeDiagnostic(failure, in: machO, owner: owner)
                    )
                }
            }
            return .init(
                representation: .relative,
                entries: entries,
                relativeListList: relativeListList,
                tableDiagnostics: diagnostics
            )
        }
    }

    static func tableFailure<List, RelativeList>(
        representation: ObjCLoadedListArrayRepresentation?,
        owner: ObjCMetadataTableDiagnostic.Owner,
        provenance: ObjCMetadataTableDiagnostic.Provenance,
        failure: ObjCMetadataTableDiagnostic.Failure
    ) -> ObjCLoadedListArrayReadResult<List, RelativeList> {
        .init(
            representation: representation,
            tableDiagnostics: [
                .init(owner: owner, site: .table(provenance), failure: failure)
            ]
        )
    }

    static func entryFailure(
        owner: ObjCMetadataTableDiagnostic.Owner,
        index: Int,
        provenance: ObjCMetadataTableDiagnostic.Provenance,
        failure: ObjCMetadataTableDiagnostic.Failure
    ) -> ObjCMetadataTableDiagnostic {
        .init(
            owner: owner,
            site: .entry(index: index, provenance: provenance),
            failure: failure
        )
    }

    private static func relativeDiagnostic(
        _ failure: ObjCRelativeListFailure,
        in machO: MachOImage,
        owner: ObjCMetadataTableDiagnostic.Owner
    ) -> ObjCMetadataTableDiagnostic {
        let provenance = machO.metadataTableProvenance(
            at: failure.diagnosticOffset
        )
        let site: ObjCMetadataTableDiagnostic.Site
        switch failure.location {
        case .table:
            site = .table(provenance)
        case .entry(let index, _, _):
            site = .entry(index: index, provenance: provenance)
        }
        return .init(
            owner: owner,
            site: site,
            failure: .init(failure.reason)
        )
    }
}

extension ObjCMetadataTableDiagnostic.Failure {
    internal init(_ reason: ObjCRelativeListFailure.Reason) {
        switch reason {
        case .unsupportedListEncoding:
            self = .unsupportedListEncoding
        case .invalidListOffset(let offset):
            self = .invalidListOffset(offset)
        case .invalidElementCount(let count):
            self = .invalidElementCount(count)
        case .invalidSignedElementCount(let count):
            self = .invalidSignedElementCount(count)
        case let .excessiveElementCount(actual, maximum):
            self = .excessiveElementCount(actual: actual, maximum: maximum)
        case let .excessiveByteCount(actual, maximum):
            self = .excessiveByteCount(actual: actual, maximum: maximum)
        case let .invalidRelativeEntrySize(advertised, minimum):
            self = .elementStrideTooSmall(
                advertised: Int(advertised),
                minimum: minimum
            )
        case let .invalidListEntrySize(advertised, expected):
            self = .unexpectedElementStride(
                advertised: advertised,
                expected: expected
            )
        case let .misalignedListOffset(offset, requiredAlignment):
            self = .misalignedTableOffset(
                offset: offset,
                requiredAlignment: requiredAlignment
            )
        case let .misalignedListAddress(address, requiredAlignment):
            self = .misalignedTableAddress(
                address: address,
                requiredAlignment: requiredAlignment
            )
        case .unresolvedListPointer:
            self = .unresolvedListPointer
        case .missingListBackingData:
            self = .missingListBackingData
        case let .unreadableFileHeader(offset, byteCount):
            self = .unreadableFileHeader(offset: offset, byteCount: byteCount)
        case let .unreadableImageHeader(address, byteCount):
            self = .unreadableReferencedLayout(
                address: address,
                byteCount: byteCount
            )
        case .invalidRelativeListLocation:
            self = .invalidRelativeDisplacement
        case .relativeImageUnavailable(let imageIndex):
            self = .relativeImageUnavailable(imageIndex: imageIndex)
        case let .byteCountOverflow(elementCount, elementSize):
            self = .byteCountOverflow(
                elementCount: elementCount,
                elementSize: elementSize
            )
        case let .rangeOverflow(startOffset, byteCount):
            self = .rangeOverflow(
                startOffset: startOffset,
                byteCount: byteCount
            )
        case let .unreadableFileRange(offset, byteCount):
            self = .unreadableFileRange(offset: offset, byteCount: byteCount)
        case let .unreadableImageRange(address, byteCount):
            self = .unreadableImageRange(address: address, byteCount: byteCount)
        }
    }
}
