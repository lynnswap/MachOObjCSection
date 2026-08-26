//
//  ObjCProtocolRelativeListListProtocol.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2024/12/01
//

import Foundation
@_spi(Support) import MachOKit

@inline(__always)
internal func exactRelativeListCount(
    _ rawCount: UInt32,
    maximumIntValue: UInt64 = UInt64(Int.max)
) -> Int? {
    guard UInt64(rawCount) <= maximumIntValue else { return nil }
    return Int(exactly: rawCount)
}

public protocol ObjCProtocolRelativeListListProtocol: RelativeListListProtocol where List: ObjCProtocolListProtocol {
    @_spi(Core)
    init(offset: Int, header: Header)

    @_spi(Core)
    init(ptr: UnsafeRawPointer, offset: Int)
}

extension ObjCRelativeListFailure.Reason {
    fileprivate var protocolDiagnosticFailure: ObjCProtocolDiagnostic.UnreadableList.Failure {
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
            // Protocol adapters never emit this member-list-only failure. Keep
            // the shared-core mapping total without expanding the protocol SPI.
            return .invalidRelativeEntrySize(
                advertised: UInt32(clamping: advertised),
                minimum: expected
            )
        case .misalignedListOffset, .misalignedListAddress:
            // Alignment validation belongs to method/property adapters.
            return .invalidRelativeListLocation
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

extension ObjCProtocolRelativeListListProtocol {
    public func lists(in machO: MachOImage) -> [(MachOImage, List)] {
        resolveLists(in: machO).resolvedValues
    }

    public func lists(in machO: MachOFile) -> [(MachOFile, List)] {
        resolveLists(in: machO).resolvedValues
    }

    internal func resolveLists(
        in machO: MachOFile,
        locationResolver: (MachOFile, Entry) -> ObjCProtocolRelativeFileLocation? = defaultRelativeFileLocation
    ) -> ObjCProtocolListResolution<MachOFile, List> {
        resolveRelativeLists(
            in: machO,
            locationResolver: locationResolver,
            makeList: { location, _, listOffset in
                guard let header: List.Header = location.file.readLayout(
                    offset: location.fileOffset,
                    as: List.Header.self
                ) else {
                    return .failure(
                        .unreadableFileHeader(
                            offset: location.fileOffset,
                            byteCount: MemoryLayout<List.Header>.size
                        )
                    )
                }
                return .success(List(offset: listOffset, header: header))
            }
        ).mapFailure {
            .init(
                listOffset: $0.diagnosticOffset,
                failure: $0.reason.protocolDiagnosticFailure
            )
        }
    }

    internal func resolveLists(
        in machO: MachOImage,
        imageLoadResolver: (Int) -> ObjCImageLoadState = defaultRelativeImageLoadState,
        imageResolver: (Int) -> MachOImage? = defaultRelativeImage
    ) -> ObjCProtocolListResolution<MachOImage, List> {
        resolveLoadedLists(
            in: machO,
            imageLoadResolver: imageLoadResolver,
            imageResolver: imageResolver
        ).mapFailure {
            .init(
                listOffset: $0.diagnosticOffset,
                failure: $0.reason.protocolDiagnosticFailure
            )
        }
    }

    internal func resolveLoadedLists(
        in machO: MachOImage,
        imageLoadResolver: (Int) -> ObjCImageLoadState = defaultRelativeImageLoadState,
        imageResolver: (Int) -> MachOImage? = defaultRelativeImage
    ) -> ObjCRelativeListResolution<MachOImage, List, ObjCRelativeListFailure> {
        resolveRelativeLists(
            in: machO,
            imageLoadResolver: imageLoadResolver,
            imageResolver: imageResolver,
            makeList: { targetMachO, pointer, listOffset, _ in
                let address = UInt(bitPattern: pointer)
                let header: List.Header
                switch ObjCMetadataTableReader.readImageLayout(
                    address: address,
                    as: List.Header.self
                ) {
                case .success(let value):
                    header = value
                case .failure:
                    return .failure(
                        .unreadableImageHeader(
                            address: address,
                            byteCount: MemoryLayout<List.Header>.size
                        )
                    )
                }
                let list = List(offset: listOffset, header: header)
                switch list.readProtocols(in: targetMachO) {
                case .success:
                    return .success(list)
                case .failure(let failure):
                    return .failure(failure.relativeListReason)
                }
            }
        )
    }
}
