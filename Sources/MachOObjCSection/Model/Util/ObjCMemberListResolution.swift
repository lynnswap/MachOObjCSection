//
//  ObjCMemberListResolution.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit

internal typealias ObjCMemberListResolutionEntry<Source, List> =
    ObjCRelativeListResolutionEntry<Source, List, ObjCRelativeListFailure>

internal typealias ObjCMemberListResolution<Source, List> =
    ObjCRelativeListResolution<Source, List, ObjCRelativeListFailure>

internal protocol ObjCMemberRelativeListListProtocol: RelativeListListProtocol where List: EntrySizeListProtocol {
    func makeList(
        ptr: UnsafeRawPointer,
        offset: Int,
        is64Bit: Bool
    ) -> List

    func makeList(
        offset: Int,
        header: EntrySizeListHeader,
        is64Bit: Bool
    ) -> List

    func expectedEntrySize(for list: List) -> Int
    func expectedEntryAlignment(for list: List) -> Int
}

extension ObjCMemberRelativeListListProtocol {
    private func checkedElementCount(
        for list: List
    ) -> Result<Int, ObjCRelativeListFailure.Reason> {
        let rawCount = UInt64(list.header.layout.count)
        guard let count = Int(exactly: rawCount) else {
            return .failure(.invalidElementCount(rawCount))
        }
        return .success(count)
    }

    private func checkedEntrySize(
        of list: List
    ) -> Result<Int, ObjCRelativeListFailure.Reason> {
        let expected = expectedEntrySize(for: list)
        let rawStride = UInt64(list.header.layout.entsizeAndFlags & ~List.flagMask)
        guard let stride = Int(exactly: rawStride) else {
            return .failure(
                .invalidListEntrySize(
                    advertised: Int.max,
                    expected: expected
                )
            )
        }
        guard stride == expected else {
            return .failure(
                .invalidListEntrySize(
                    advertised: stride,
                    expected: expected
                )
            )
        }
        return .success(stride)
    }

    private func readMemberList(
        at location: ObjCRelativeFileLocation,
        listOffset: Int
    ) -> Result<List, ObjCRelativeListFailure.Reason> {
        guard let header: EntrySizeListHeader = location.file.readLayout(
            offset: location.fileOffset,
            as: EntrySizeListHeader.self
        ) else {
            return .failure(
                .unreadableFileHeader(
                    offset: location.fileOffset,
                    byteCount: MemoryLayout<EntrySizeListHeader>.size
                )
            )
        }
        let list = makeList(
            offset: listOffset,
            header: header,
            is64Bit: location.image.is64Bit
        )
        let count: Int
        switch checkedElementCount(for: list) {
        case .success(let value): count = value
        case .failure(let failure): return .failure(failure)
        }
        guard count > 0 else { return .success(list) }
        let requiredAlignment = expectedEntryAlignment(for: list)
        guard listOffset.isMultiple(of: requiredAlignment) else {
            return .failure(
                .misalignedListOffset(
                    offset: listOffset,
                    requiredAlignment: requiredAlignment
                )
            )
        }
        let stride: Int
        switch checkedEntrySize(of: list) {
        case .success(let value): stride = value
        case .failure(let failure): return .failure(failure)
        }
        let (tableOffset, overflow) = location.fileOffset.addingReportingOverflow(
            UInt64(MemoryLayout<EntrySizeListHeader>.size)
        )
        let (logicalTableOffset, logicalOverflow) = listOffset.addingReportingOverflow(
            MemoryLayout<EntrySizeListHeader>.size
        )
        guard !overflow, !logicalOverflow else {
            return .failure(
                .rangeOverflow(
                    startOffset: location.fileOffset,
                    byteCount: MemoryLayout<EntrySizeListHeader>.size
                )
            )
        }
        guard let logicalTableOffset = checkedEntrySizeListTableOffset(listOffset) else {
            return .failure(.invalidRelativeListLocation)
        }
        switch ObjCMetadataTableReader.readFile(
            location.file,
            offset: tableOffset,
            logicalOffset: logicalTableOffset,
            count: count,
            stride: stride,
            as: UInt8.self
        ) {
        case .success:
            return .success(list)
        case .failure(let failure):
            return .failure(failure.relativeListReason)
        }
    }

    private func readMemberList(
        in targetMachO: MachOImage,
        pointer: UnsafeRawPointer,
        listOffset: Int
    ) -> Result<List, ObjCRelativeListFailure.Reason> {
        guard isPointerSafelyReadable(
            pointer,
            length: MemoryLayout<EntrySizeListHeader>.size
        ) else {
            return .failure(
                .unreadableImageHeader(
                    address: UInt(bitPattern: pointer),
                    byteCount: MemoryLayout<EntrySizeListHeader>.size
                )
            )
        }
        let list = makeList(
            ptr: pointer,
            offset: listOffset,
            is64Bit: targetMachO.is64Bit
        )
        let count: Int
        switch checkedElementCount(for: list) {
        case .success(let value): count = value
        case .failure(let failure): return .failure(failure)
        }
        guard count > 0 else { return .success(list) }
        let requiredAlignment = expectedEntryAlignment(for: list)
        let listAddress = UInt(bitPattern: pointer)
        guard listAddress.isMultiple(of: UInt(requiredAlignment)) else {
            return .failure(
                .misalignedListAddress(
                    address: listAddress,
                    requiredAlignment: requiredAlignment
                )
            )
        }
        let stride: Int
        switch checkedEntrySize(of: list) {
        case .success(let value): stride = value
        case .failure(let failure): return .failure(failure)
        }
        let (tableAddress, overflow) = listAddress.addingReportingOverflow(
            UInt(MemoryLayout<EntrySizeListHeader>.size)
        )
        guard !overflow else {
            return .failure(.invalidRelativeListLocation)
        }
        guard let logicalTableOffset = checkedEntrySizeListTableOffset(listOffset) else {
            return .failure(.invalidRelativeListLocation)
        }
        switch ObjCMetadataTableReader.readImage(
            address: tableAddress,
            logicalOffset: logicalTableOffset,
            count: count,
            stride: stride,
            as: UInt8.self
        ) {
        case .success:
            return .success(list)
        case .failure(let failure):
            return .failure(failure.relativeListReason)
        }
    }

    internal func resolveMemberLists(
        in machO: MachOFile,
        locationResolver: (MachOFile, Entry) -> ObjCRelativeFileLocation? = defaultRelativeFileLocation
    ) -> ObjCMemberListResolution<MachOFile, List> {
        resolveRelativeLists(
            in: machO,
            locationResolver: locationResolver,
            makeList: { location, _, listOffset in
                readMemberList(at: location, listOffset: listOffset)
            }
        )
    }

    internal func resolveMemberLists(
        in machO: MachOImage,
        imageLoadResolver: (Int) -> ObjCImageLoadState = defaultRelativeImageLoadState,
        imageResolver: (Int) -> MachOImage? = defaultRelativeImage
    ) -> ObjCMemberListResolution<MachOImage, List> {
        resolveRelativeLists(
            in: machO,
            imageLoadResolver: imageLoadResolver,
            imageResolver: imageResolver,
            makeList: { targetMachO, pointer, listOffset, _ in
                readMemberList(
                    in: targetMachO,
                    pointer: pointer,
                    listOffset: listOffset
                )
            }
        )
    }

    internal func resolveMemberList(
        in machO: MachOFile,
        for entry: Entry,
        locationResolver: (MachOFile, Entry) -> ObjCRelativeFileLocation? = defaultRelativeFileLocation
    ) -> ObjCRelativeListEntryResolution<MachOFile, List> {
        resolveRelativeList(
            in: machO,
            for: entry,
            locationResolver: locationResolver,
            makeList: { location, _, listOffset in
                readMemberList(at: location, listOffset: listOffset)
            }
        )
    }

    internal func resolveMemberList(
        in machO: MachOImage,
        for entry: Entry,
        imageLoadResolver: (Int) -> ObjCImageLoadState = defaultRelativeImageLoadState,
        imageResolver: (Int) -> MachOImage? = defaultRelativeImage
    ) -> ObjCRelativeListEntryResolution<MachOImage, List> {
        resolveRelativeList(
            in: machO,
            for: entry,
            imageLoadResolver: imageLoadResolver,
            imageResolver: imageResolver,
            makeList: { targetMachO, pointer, listOffset, _ in
                readMemberList(
                    in: targetMachO,
                    pointer: pointer,
                    listOffset: listOffset
                )
            }
        )
    }
}

extension ObjCClassRODataProtocol {
    private func memberListResolutions<Relative: ObjCMemberRelativeListListProtocol>(
        rawPointer: UInt64,
        field: LayoutField,
        in machO: MachOFile,
        regularList: () -> Relative.List?,
        makeRelativeList: (Int, EntrySizeListHeader) -> Relative
    ) -> ObjCMemberListResolution<MachOFile, Relative.List> {
        guard rawPointer != 0 else { return .absent }
        if rawPointer & 1 == 0 {
            guard let list = regularList() else { return .absent }
            return .entries([.resolved(machO, list)])
        }

        var unresolved = unresolvedValue(of: field)
        unresolved.value &= ~1
        guard let resolved = machO.resolveRebase(unresolved),
              let relativeOffset = Int(exactly: resolved.offset) else {
            return .failure(
                .table(outerListOffset: offset, reason: .unresolvedListPointer)
            )
        }
        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(
            forResolvedValue: resolved
        ) else {
            return .failure(
                .table(
                    outerListOffset: relativeOffset,
                    reason: .missingListBackingData
                )
            )
        }
        guard let header: EntrySizeListHeader = fileHandle.readLayout(
            offset: fileOffset,
            as: EntrySizeListHeader.self
        ) else {
            return .failure(
                .table(
                    outerListOffset: relativeOffset,
                    reason: .unreadableFileHeader(
                        offset: fileOffset,
                        byteCount: MemoryLayout<EntrySizeListHeader>.size
                    )
                )
            )
        }
        return makeRelativeList(relativeOffset, header).resolveMemberLists(in: machO)
    }

    private func memberListResolutions<Relative: ObjCMemberRelativeListListProtocol>(
        rawPointer: UInt64,
        in machO: MachOImage,
        regularList: () -> Relative.List?,
        makeRelativeList: (UnsafeRawPointer, Int) -> Relative
    ) -> ObjCMemberListResolution<MachOImage, Relative.List> {
        guard rawPointer != 0 else { return .absent }
        if rawPointer & 1 == 0 {
            guard let list = regularList() else { return .absent }
            return .entries([.resolved(machO, list)])
        }

        let strippedAddress = machO.stripPointerTags(of: rawPointer) & ~1
        guard let address = UInt(exactly: strippedAddress),
              let pointer = UnsafeRawPointer(bitPattern: address),
              let relativeOffset = signedDisplacement(
                from: UInt(bitPattern: machO.ptr),
                to: address
              ) else {
            return .failure(
                .table(outerListOffset: offset, reason: .unresolvedListPointer)
            )
        }
        guard isPointerSafelyReadable(
            pointer,
            length: MemoryLayout<EntrySizeListHeader>.size
        ) else {
            return .failure(
                .table(
                    outerListOffset: relativeOffset,
                    reason: .unreadableImageHeader(
                        address: address,
                        byteCount: MemoryLayout<EntrySizeListHeader>.size
                    )
                )
            )
        }
        return makeRelativeList(pointer, relativeOffset).resolveMemberLists(in: machO)
    }

    internal func methodListResolutions(
        in machO: MachOFile
    ) -> ObjCMemberListResolution<MachOFile, ObjCMethodList> {
        memberListResolutions(
            rawPointer: numericCast(layout.baseMethods),
            field: .baseMethods,
            in: machO,
            regularList: { methodList(in: machO) },
            makeRelativeList: { offset, header in
                ObjCMethodRelativeListList(offset: offset, header: header)
            }
        )
    }

    internal func propertyListResolutions(
        in machO: MachOFile
    ) -> ObjCMemberListResolution<MachOFile, ObjCPropertyList> {
        memberListResolutions(
            rawPointer: numericCast(layout.baseProperties),
            field: .baseProperties,
            in: machO,
            regularList: { propertyList(in: machO) },
            makeRelativeList: { offset, header in
                ObjCPropertyRelativeListList(offset: offset, header: header)
            }
        )
    }

    internal func methodListResolutions(
        in machO: MachOImage
    ) -> ObjCMemberListResolution<MachOImage, ObjCMethodList> {
        memberListResolutions(
            rawPointer: numericCast(layout.baseMethods),
            in: machO,
            regularList: { methodList(in: machO) },
            makeRelativeList: { pointer, offset in
                ObjCMethodRelativeListList(ptr: pointer, offset: offset)
            }
        )
    }

    internal func propertyListResolutions(
        in machO: MachOImage
    ) -> ObjCMemberListResolution<MachOImage, ObjCPropertyList> {
        memberListResolutions(
            rawPointer: numericCast(layout.baseProperties),
            in: machO,
            regularList: { propertyList(in: machO) },
            makeRelativeList: { pointer, offset in
                ObjCPropertyRelativeListList(ptr: pointer, offset: offset)
            }
        )
    }
}
