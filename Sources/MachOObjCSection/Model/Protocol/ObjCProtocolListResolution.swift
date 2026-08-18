//
//  ObjCProtocolListResolution.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit

internal struct ObjCProtocolListResolutionFailure: Error, Equatable {
    let listOffset: Int
    let failure: ObjCProtocolDiagnostic.UnreadableList.Failure
}

internal enum ObjCProtocolListResolution<Source, List> {
    case absent
    case resolved(Source, List)
    case failure(ObjCProtocolListResolutionFailure)

    var value: (Source, List)? {
        guard case let .resolved(source, list) = self else { return nil }
        return (source, list)
    }
}

@inline(__always)
private func checkedFieldOffset(_ base: Int, _ fieldOffset: Int) -> Int? {
    let (offset, overflow) = base.addingReportingOverflow(fieldOffset)
    return overflow ? nil : offset
}

private func resolveRegularProtocolListFile<List: ObjCProtocolListProtocol, Pointer: FixedWidthInteger>(
    rawPointer: Pointer,
    fieldOffset: Int?,
    ownerOffset: Int,
    in machO: MachOFile,
    as listType: List.Type
) -> ObjCProtocolListResolution<MachOFile, List> {
    guard rawPointer != 0 else { return .absent }
    guard let fieldOffset,
          let rawValue = UInt64(exactly: rawPointer) else {
        return .failure(.init(listOffset: ownerOffset, failure: .unresolvedListPointer))
    }
    let unresolved = UnresolvedValue(fieldOffset: fieldOffset, value: rawValue)
    guard let resolved = machO.resolveRebase(unresolved),
          let listOffset = Int(exactly: resolved.offset) else {
        return .failure(.init(listOffset: fieldOffset, failure: .unresolvedListPointer))
    }
    guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
        return .failure(.init(listOffset: listOffset, failure: .missingListBackingData))
    }
    guard let header: List.Header = fileHandle.readProtocolLayout(
        offset: fileOffset,
        as: List.Header.self
    ) else {
        return .failure(
            .init(
                listOffset: listOffset,
                failure: .unreadableFileHeader(
                    offset: fileOffset,
                    byteCount: MemoryLayout<List.Header>.size
                )
            )
        )
    }
    return .resolved(machO, List(offset: listOffset, header: header))
}

private func resolveRegularProtocolListImage<List: ObjCProtocolListProtocol, Pointer: FixedWidthInteger>(
    rawPointer: Pointer,
    ownerOffset: Int,
    in machO: MachOImage,
    as listType: List.Type
) -> ObjCProtocolListResolution<MachOImage, List> {
    guard rawPointer != 0 else { return .absent }
    guard let rawValue = UInt64(exactly: rawPointer),
          let address = UInt(exactly: machO.stripPointerTags(of: rawValue)),
          let pointer = UnsafeRawPointer(bitPattern: address),
          let listOffset = signedDisplacement(
            from: UInt(bitPattern: machO.ptr),
            to: address
          ) else {
        return .failure(.init(listOffset: ownerOffset, failure: .unresolvedListPointer))
    }
    guard isPointerSafelyReadable(pointer, length: MemoryLayout<List.Header>.size) else {
        return .failure(
            .init(
                listOffset: listOffset,
                failure: .unreadableImageHeader(
                    address: address,
                    byteCount: MemoryLayout<List.Header>.size
                )
            )
        )
    }
    return .resolved(machO, List(ptr: pointer, offset: listOffset))
}

extension ObjCProtocolProtocol {
    internal func protocolListResolution(
        in machO: MachOFile
    ) -> ObjCProtocolListResolution<MachOFile, ObjCProtocolList> {
        resolveRegularProtocolListFile(
            rawPointer: layout.protocols,
            fieldOffset: checkedFieldOffset(offset, layoutOffset(of: .protocols)),
            ownerOffset: offset,
            in: machO,
            as: ObjCProtocolList.self
        )
    }

    internal func protocolListResolution(
        in machO: MachOImage
    ) -> ObjCProtocolListResolution<MachOImage, ObjCProtocolList> {
        resolveRegularProtocolListImage(
            rawPointer: layout.protocols,
            ownerOffset: offset,
            in: machO,
            as: ObjCProtocolList.self
        )
    }
}

extension ObjCCategoryProtocol {
    internal func protocolListResolution(
        in machO: MachOFile
    ) -> ObjCProtocolListResolution<MachOFile, ObjCProtocolList> {
        resolveRegularProtocolListFile(
            rawPointer: layout.protocols,
            fieldOffset: checkedFieldOffset(offset, layoutOffset(of: .protocols)),
            ownerOffset: offset,
            in: machO,
            as: ObjCProtocolList.self
        )
    }

    internal func protocolListResolution(
        in machO: MachOImage
    ) -> ObjCProtocolListResolution<MachOImage, ObjCProtocolList> {
        resolveRegularProtocolListImage(
            rawPointer: layout.protocols,
            ownerOffset: offset,
            in: machO,
            as: ObjCProtocolList.self
        )
    }
}

extension ObjCClassRODataProtocol {
    internal func protocolListResolution(
        in machO: MachOFile,
        imageIndex: @autoclosure () -> Int?
    ) -> ObjCProtocolListResolution<MachOFile, ObjCProtocolList> {
        guard layout.baseProtocols != 0 else { return .absent }
        if layout.baseProtocols & 1 == 0 {
            return resolveRegularProtocolListFile(
                rawPointer: layout.baseProtocols,
                fieldOffset: checkedFieldOffset(offset, layoutOffset(of: .baseProtocols)),
                ownerOffset: offset,
                in: machO,
                as: ObjCProtocolList.self
            )
        }

        guard let imageIndex = imageIndex() else {
            return .failure(.init(listOffset: offset, failure: .missingRelativeImageIndex))
        }
        var rawPointer = layout.baseProtocols
        rawPointer &= ~1
        guard let fieldOffset = checkedFieldOffset(offset, layoutOffset(of: .baseProtocols)),
              let rawValue = UInt64(exactly: rawPointer) else {
            return .failure(.init(listOffset: offset, failure: .unresolvedListPointer))
        }
        let unresolved = UnresolvedValue(fieldOffset: fieldOffset, value: rawValue)
        guard let resolved = machO.resolveRebase(unresolved),
              let relativeOffset = Int(exactly: resolved.offset) else {
            return .failure(.init(listOffset: fieldOffset, failure: .unresolvedListPointer))
        }
        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
            return .failure(.init(listOffset: relativeOffset, failure: .missingListBackingData))
        }
        guard let header: ObjCProtocolRelativeListList.Header = fileHandle.readProtocolLayout(
            offset: fileOffset,
            as: ObjCProtocolRelativeListList.Header.self
        ) else {
            return .failure(
                .init(
                    listOffset: relativeOffset,
                    failure: .unreadableFileHeader(
                        offset: fileOffset,
                        byteCount: MemoryLayout<ObjCProtocolRelativeListList.Header>.size
                    )
                )
            )
        }
        let relative = ObjCProtocolRelativeListList(offset: relativeOffset, header: header)
        return relative.resolveList(in: machO, forImageIndex: imageIndex)
    }

    internal func protocolListResolution(
        in machO: MachOImage,
        imageIndex: @autoclosure () -> Int?
    ) -> ObjCProtocolListResolution<MachOImage, ObjCProtocolList> {
        guard layout.baseProtocols != 0 else { return .absent }
        if layout.baseProtocols & 1 == 0 {
            return resolveRegularProtocolListImage(
                rawPointer: layout.baseProtocols,
                ownerOffset: offset,
                in: machO,
                as: ObjCProtocolList.self
            )
        }

        guard let imageIndex = imageIndex() else {
            return .failure(.init(listOffset: offset, failure: .missingRelativeImageIndex))
        }
        let clearedPointer = layout.baseProtocols & ~1
        guard let rawValue = UInt64(exactly: clearedPointer),
              let address = UInt(exactly: machO.stripPointerTags(of: rawValue)),
              let pointer = UnsafeRawPointer(bitPattern: address),
              let relativeOffset = signedDisplacement(
                from: UInt(bitPattern: machO.ptr),
                to: address
              ) else {
            return .failure(.init(listOffset: offset, failure: .unresolvedListPointer))
        }
        guard isPointerSafelyReadable(
            pointer,
            length: MemoryLayout<ObjCProtocolRelativeListList.Header>.size
        ) else {
            return .failure(
                .init(
                    listOffset: relativeOffset,
                    failure: .unreadableImageHeader(
                        address: address,
                        byteCount: MemoryLayout<ObjCProtocolRelativeListList.Header>.size
                    )
                )
            )
        }
        let relative = ObjCProtocolRelativeListList(ptr: pointer, offset: relativeOffset)
        return relative.resolveList(in: machO, forImageIndex: imageIndex)
    }
}
