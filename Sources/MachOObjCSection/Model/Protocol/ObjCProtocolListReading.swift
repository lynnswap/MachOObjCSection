//
//  ObjCProtocolListReading.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit
#if compiler(>=6.0) || (compiler(>=5.10) && hasFeature(AccessLevelOnImport))
internal import FileIO
#else
@_implementationOnly import FileIO
#endif

internal enum ObjCProtocolIdentity: Hashable {
    case cache(uuid: UUID, unslidAddress: UInt64)
    case file(path: String, headerOffset: Int, protocolOffset: Int)
    case image(address: UInt)
}

internal enum ObjCProtocolReadLimits {
    /// At 64-bit pointer width this admits a 512 KiB table spanning at most 129
    /// 4 KiB pages, while preventing task-wide readable mappings from turning an
    /// external count into unbounded probe/allocation work.
    static let maximumLoadedListEntries = 65_536
}

internal struct ObjCProtocolReference<Source, Protocol> {
    let index: Int
    let source: Source
    let value: Protocol
    let identity: ObjCProtocolIdentity
}

internal enum ObjCProtocolListTableFailure: Error, Equatable {
    case unsupportedListEncoding
    case invalidListOffset(Int)
    case invalidElementCount(UInt64)
    case invalidSignedElementCount(Int)
    case excessiveElementCount(actual: Int, maximum: Int)
    case byteCountOverflow(elementCount: Int, elementSize: Int)
    case rangeOverflow(startOffset: UInt64, byteCount: Int)
    case unreadableFileRange(offset: UInt64, byteCount: Int)
    case unreadableImageRange(address: UInt, byteCount: Int)
}

internal enum ObjCProtocolListEntryFailureReason: Equatable {
    case unresolvedRebase
    case invalidEntryOffset
    case invalidPointer
    case invalidIdentity
    case missingBackingData
    case unreadableFileLayout(offset: UInt64, byteCount: Int)
    case unreadableImageLayout(address: UInt, byteCount: Int)
}

internal struct ObjCProtocolListEntryFailure: Equatable {
    let index: Int
    let reason: ObjCProtocolListEntryFailureReason
}

internal enum ObjCProtocolListReadEntry<Source, Protocol> {
    case reference(ObjCProtocolReference<Source, Protocol>)
    case failure(ObjCProtocolListEntryFailure)
}

internal struct ObjCProtocolListReadSuccess<Source, Protocol> {
    let entries: [ObjCProtocolListReadEntry<Source, Protocol>]

    var references: [ObjCProtocolReference<Source, Protocol>] {
        entries.compactMap { entry in
            guard case .reference(let reference) = entry else { return nil }
            return reference
        }
    }

    var failures: [ObjCProtocolListEntryFailure] {
        entries.compactMap { entry in
            guard case .failure(let failure) = entry else { return nil }
            return failure
        }
    }
}

internal enum ObjCProtocolListReadOutcome<Source, Protocol> {
    case success(ObjCProtocolListReadSuccess<Source, Protocol>)
    case failure(ObjCProtocolListTableFailure)

    var values: [(Source, Protocol)]? {
        switch self {
        case .success(let success):
            success.references.map { ($0.source, $0.value) }
        case .failure:
            nil
        }
    }
}

extension ObjCProtocolListTableFailure {
    var diagnosticFailure: ObjCProtocolDiagnostic.UnreadableList.Failure {
        switch self {
        case .unsupportedListEncoding:
            .unsupportedListEncoding
        case .invalidListOffset(let offset):
            .invalidListOffset(offset)
        case .invalidElementCount(let count):
            .invalidElementCount(count)
        case .invalidSignedElementCount(let count):
            .invalidSignedElementCount(count)
        case let .excessiveElementCount(actual, maximum):
            .excessiveElementCount(actual: actual, maximum: maximum)
        case let .byteCountOverflow(count, size):
            .byteCountOverflow(elementCount: count, elementSize: size)
        case let .rangeOverflow(offset, byteCount):
            .rangeOverflow(startOffset: offset, byteCount: byteCount)
        case let .unreadableFileRange(offset, byteCount):
            .unreadableFileRange(offset: offset, byteCount: byteCount)
        case let .unreadableImageRange(address, byteCount):
            .unreadableImageRange(address: address, byteCount: byteCount)
        }
    }
}

extension ObjCProtocolListEntryFailure {
    var diagnosticFailure: ObjCProtocolDiagnostic.UnreadableList.Failure {
        switch reason {
        case .unresolvedRebase:
            .unresolvedRebase(entryIndex: index)
        case .invalidEntryOffset:
            .invalidEntryOffset(entryIndex: index)
        case .invalidPointer:
            .invalidPointer(entryIndex: index)
        case .invalidIdentity:
            .invalidIdentity(entryIndex: index)
        case .missingBackingData:
            .missingBackingData(entryIndex: index)
        case let .unreadableFileLayout(offset, byteCount):
            .unreadableFileLayout(entryIndex: index, offset: offset, byteCount: byteCount)
        case let .unreadableImageLayout(address, byteCount):
            .unreadableImageLayout(entryIndex: index, address: address, byteCount: byteCount)
        }
    }
}

internal enum CheckedProtocolRead<Value> {
    case success(Value)
    case failure(ObjCProtocolListTableFailure)
}

extension _FileIOProtocol {
    internal func readProtocolTable<Element>(
        offset: UInt64,
        count: Int,
        stride: Int? = nil,
        as elementType: Element.Type
    ) -> CheckedProtocolRead<[Element]> {
        let elementSize = MemoryLayout<Element>.size
        let stride = stride ?? elementSize
        guard stride >= elementSize else {
            return .failure(.byteCountOverflow(elementCount: count, elementSize: stride))
        }
        let (byteCount, byteCountOverflow) = count.multipliedReportingOverflow(by: stride)
        guard !byteCountOverflow else {
            return .failure(.byteCountOverflow(elementCount: count, elementSize: elementSize))
        }

        guard let readOffset = Int(exactly: offset),
              readOffset >= 0,
              byteCount >= 0,
              readOffset <= size,
              byteCount <= size - readOffset else {
            return .failure(.unreadableFileRange(offset: offset, byteCount: byteCount))
        }

        guard let data = try? readData(offset: readOffset, length: byteCount) else {
            return .failure(.unreadableFileRange(offset: offset, byteCount: byteCount))
        }

        let pointers = data.withUnsafeBytes { bytes in
            (0..<count).map { index in
                bytes.loadUnaligned(fromByteOffset: index * stride, as: Element.self)
            }
        }
        return .success(pointers)
    }

    internal func readProtocolLayout<Layout>(
        offset: UInt64,
        as layoutType: Layout.Type
    ) -> Layout? {
        let byteCount = MemoryLayout<Layout>.size
        guard let readOffset = Int(exactly: offset),
              readOffset >= 0,
              readOffset <= size,
              byteCount <= size - readOffset else {
            return nil
        }
        guard let data = try? readData(offset: readOffset, length: byteCount) else {
            return nil
        }
        return data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(as: Layout.self)
        }
    }
}

extension ObjCProtocolListProtocol {
    private func checkedElementCount() -> Result<Int, ObjCProtocolListTableFailure> {
        if let header = header as? ObjCProtocolListHeader64 {
            guard let count = Int(exactly: header._count) else {
                return .failure(.invalidElementCount(header._count))
            }
            return .success(count)
        }
        if let header = header as? ObjCProtocolListHeader32 {
            guard let count = Int(exactly: header._count) else {
                return .failure(.invalidElementCount(UInt64(header._count)))
            }
            return .success(count)
        }

        let count = header.count
        guard count >= 0 else {
            return .failure(.invalidSignedElementCount(count))
        }
        return .success(count)
    }

    private func checkedByteCount(count: Int) -> Result<Int, ObjCProtocolListTableFailure> {
        let elementSize = MemoryLayout<ObjCProtocol.Layout.Pointer>.size
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: elementSize)
        guard !overflow else {
            return .failure(.byteCountOverflow(elementCount: count, elementSize: elementSize))
        }
        return .success(byteCount)
    }

    internal func readProtocols(
        in machO: MachOFile
    ) -> ObjCProtocolListReadOutcome<MachOFile, ObjCProtocol> {
        guard !isListOfLists else {
            return .failure(.unsupportedListEncoding)
        }
        guard offset >= 0, let logicalListOffset = UInt64(exactly: offset) else {
            return .failure(.invalidListOffset(offset))
        }

        let count: Int
        switch checkedElementCount() {
        case .success(let value): count = value
        case .failure(let failure): return .failure(failure)
        }
        let byteCount: Int
        switch checkedByteCount(count: count) {
        case .success(let value): byteCount = value
        case .failure(let failure): return .failure(failure)
        }

        let headerSize = UInt64(MemoryLayout<Header>.size)
        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forOffset: logicalListOffset) else {
            let (tableOffset, overflow) = logicalListOffset.addingReportingOverflow(headerSize)
            return .failure(
                overflow
                    ? .rangeOverflow(startOffset: logicalListOffset, byteCount: byteCount)
                    : .unreadableFileRange(offset: tableOffset, byteCount: byteCount)
            )
        }
        let (tableOffset, tableOffsetOverflow) = fileOffset.addingReportingOverflow(headerSize)
        guard !tableOffsetOverflow else {
            return .failure(.rangeOverflow(startOffset: fileOffset, byteCount: byteCount))
        }
        let byteCount64 = UInt64(byteCount)
        let (_, rangeOverflow) = tableOffset.addingReportingOverflow(byteCount64)
        guard !rangeOverflow else {
            return .failure(.rangeOverflow(startOffset: tableOffset, byteCount: byteCount))
        }

        let pointers: [ObjCProtocol.Layout.Pointer]
        switch fileHandle.readProtocolTable(
            offset: tableOffset,
            count: count,
            as: ObjCProtocol.Layout.Pointer.self
        ) {
        case .success(let value): pointers = value
        case .failure(let failure): return .failure(failure)
        }

        var entries: [ObjCProtocolListReadEntry<MachOFile, ObjCProtocol>] = []
        entries.reserveCapacity(count)

        let (fieldBase, fieldBaseOverflow) = offset.addingReportingOverflow(MemoryLayout<Header>.size)
        for (index, pointer) in pointers.enumerated() {
            let (entryDelta, entryDeltaOverflow) = index.multipliedReportingOverflow(
                by: MemoryLayout<ObjCProtocol.Layout.Pointer>.stride
            )
            let (fieldOffset, fieldOffsetOverflow) = fieldBase.addingReportingOverflow(entryDelta)
            guard !fieldBaseOverflow, !entryDeltaOverflow, !fieldOffsetOverflow,
                  let rawValue = UInt64(exactly: pointer) else {
                entries.append(.failure(.init(index: index, reason: .invalidEntryOffset)))
                continue
            }

            let unresolved = UnresolvedValue(fieldOffset: fieldOffset, value: rawValue)
            guard let resolved = machO.resolveRebase(unresolved) else {
                entries.append(.failure(.init(index: index, reason: .unresolvedRebase)))
                continue
            }
            guard let (layoutFile, layoutOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
                entries.append(.failure(.init(index: index, reason: .missingBackingData)))
                continue
            }

            var targetMachO = machO
            if !targetMachO.contains(unslidAddress: resolved.address),
               let cache = machO.cache(for: resolved.address),
               let resolvedMachO = cache.machO(containing: resolved.address) {
                targetMachO = resolvedMachO
            }

            guard let layout: ObjCProtocol.Layout = layoutFile.readProtocolLayout(
                offset: layoutOffset,
                as: ObjCProtocol.Layout.self
            ) else {
                entries.append(
                    .failure(.init(
                        index: index,
                        reason: .unreadableFileLayout(
                            offset: layoutOffset,
                            byteCount: MemoryLayout<ObjCProtocol.Layout>.size
                        )
                    ))
                )
                continue
            }

            guard let protocolOffset = Int(exactly: resolved.offset) else {
                entries.append(.failure(.init(index: index, reason: .invalidEntryOffset)))
                continue
            }
            let objcProtocol = ObjCProtocol(layout: layout, offset: protocolOffset)
            guard let identity = targetMachO.traversalIdentity(
                protocolOffset: protocolOffset,
                unslidAddress: resolved.address
            ) else {
                entries.append(.failure(.init(index: index, reason: .invalidIdentity)))
                continue
            }
            entries.append(
                .reference(.init(
                    index: index,
                    source: targetMachO,
                    value: objcProtocol,
                    identity: identity
                ))
            )
        }

        return .success(.init(entries: entries))
    }

    internal func readProtocols(
        in machO: MachOImage
    ) -> ObjCProtocolListReadOutcome<MachOImage, ObjCProtocol> {
        guard !isListOfLists else {
            return .failure(.unsupportedListEncoding)
        }
        let imageAddress = UInt(bitPattern: machO.ptr)
        guard let listAddress = addingSignedDisplacement(offset, to: imageAddress) else {
            return .failure(.invalidListOffset(offset))
        }

        let count: Int
        switch checkedElementCount() {
        case .success(let value): count = value
        case .failure(let failure): return .failure(failure)
        }
        guard count <= ObjCProtocolReadLimits.maximumLoadedListEntries else {
            return .failure(
                .excessiveElementCount(
                    actual: count,
                    maximum: ObjCProtocolReadLimits.maximumLoadedListEntries
                )
            )
        }
        let byteCount: Int
        switch checkedByteCount(count: count) {
        case .success(let value): byteCount = value
        case .failure(let failure): return .failure(failure)
        }

        let (tableAddress, headerOverflow) = listAddress.addingReportingOverflow(
            UInt(MemoryLayout<Header>.size)
        )
        guard !headerOverflow else {
            return .failure(.rangeOverflow(startOffset: UInt64(imageAddress), byteCount: byteCount))
        }
        let (_, tableOverflow) = tableAddress.addingReportingOverflow(UInt(byteCount))
        guard !tableOverflow else {
            return .failure(.rangeOverflow(startOffset: UInt64(tableAddress), byteCount: byteCount))
        }

        if byteCount > 0 {
            guard let tablePointer = UnsafeRawPointer(bitPattern: tableAddress),
                  isPointerSafelyReadable(tablePointer, length: byteCount) else {
                return .failure(.unreadableImageRange(address: tableAddress, byteCount: byteCount))
            }
        }

        let pointerSize = MemoryLayout<ObjCProtocol.Layout.Pointer>.size
        var pointers: [ObjCProtocol.Layout.Pointer] = []
        pointers.reserveCapacity(count)
        for index in 0..<count {
            let entryAddress = tableAddress + UInt(index * pointerSize)
            guard let entryPointer = UnsafeRawPointer(bitPattern: entryAddress) else {
                return .failure(.unreadableImageRange(address: entryAddress, byteCount: pointerSize))
            }
            pointers.append(entryPointer.loadUnaligned(as: ObjCProtocol.Layout.Pointer.self))
        }

        var entries: [ObjCProtocolListReadEntry<MachOImage, ObjCProtocol>] = []
        entries.reserveCapacity(count)

        for (index, pointer) in pointers.enumerated() {
            guard let rawValue = UInt64(exactly: pointer) else {
                entries.append(.failure(.init(index: index, reason: .invalidPointer)))
                continue
            }
            let strippedAddress64 = machO.stripPointerTags(of: rawValue)
            guard let strippedAddress = UInt(exactly: strippedAddress64),
                  let protocolPointer = UnsafeRawPointer(bitPattern: strippedAddress) else {
                entries.append(.failure(.init(index: index, reason: .invalidPointer)))
                continue
            }

            var targetMachO = machO
            if !targetMachO.contains(ptr: protocolPointer) {
                guard let resolvedMachO = machO.resolveImage(containing: protocolPointer) else {
                    entries.append(.failure(.init(index: index, reason: .missingBackingData)))
                    continue
                }
                targetMachO = resolvedMachO
            }

            let layoutSize = MemoryLayout<ObjCProtocol.Layout>.size
            guard isPointerSafelyReadable(protocolPointer, length: layoutSize) else {
                entries.append(
                    .failure(.init(
                        index: index,
                        reason: .unreadableImageLayout(
                            address: strippedAddress,
                            byteCount: layoutSize
                        )
                    ))
                )
                continue
            }

            guard let protocolOffset = signedDisplacement(
                from: UInt(bitPattern: targetMachO.ptr),
                to: strippedAddress
            ) else {
                entries.append(.failure(.init(index: index, reason: .invalidEntryOffset)))
                continue
            }

            let layout = protocolPointer.loadUnaligned(as: ObjCProtocol.Layout.self)
            let objcProtocol = ObjCProtocol(layout: layout, offset: protocolOffset)
            entries.append(
                .reference(.init(
                    index: index,
                    source: targetMachO,
                    value: objcProtocol,
                    identity: .image(address: strippedAddress)
                ))
            )
        }

        return .success(.init(entries: entries))
    }
}
