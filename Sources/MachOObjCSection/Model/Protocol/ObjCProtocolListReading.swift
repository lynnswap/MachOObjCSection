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

internal struct ObjCProtocolRuntimeNameReader {
    private enum CachedName {
        case value(String)
        case invalid
    }

    private var namesByAddress: [UInt: CachedName] = [:]
    private(set) var remainingByteCount: Int
    private let read: (UnsafeRawPointer, Int) -> String?

    init(
        maximumTableByteCount: Int = ObjCMetadataReadLimits.maximumRuntimeNameTableByteCount,
        read: @escaping (UnsafeRawPointer, Int) -> String? = {
            readBoundedNullTerminatedUTF8(at: $0, maximumByteCount: $1)
        }
    ) {
        self.remainingByteCount = max(0, maximumTableByteCount)
        self.read = read
    }

    mutating func name(
        at pointer: UnsafeRawPointer,
        maximumByteCount: Int
    ) -> String? {
        let address = UInt(bitPattern: pointer)
        if let cached = namesByAddress[address] {
            switch cached {
            case .value(let name): return name
            case .invalid: return nil
            }
        }

        let allowedByteCount = min(max(0, maximumByteCount), remainingByteCount)
        guard allowedByteCount > 0 else {
            namesByAddress[address] = .invalid
            return nil
        }

        guard let name = read(pointer, allowedByteCount), !name.isEmpty else {
            remainingByteCount -= allowedByteCount
            namesByAddress[address] = .invalid
            return nil
        }
        let (consumedByteCount, overflow) = name.utf8.count.addingReportingOverflow(1)
        guard !overflow, consumedByteCount <= allowedByteCount else {
            remainingByteCount -= allowedByteCount
            namesByAddress[address] = .invalid
            return nil
        }

        remainingByteCount -= consumedByteCount
        namesByAddress[address] = .value(name)
        return name
    }
}

internal struct ObjCProtocolRuntimeLayoutPrefix<Pointer: FixedWidthInteger> {
    let isa: Pointer
    let mangledName: Pointer
    let protocols: Pointer
    let instanceMethods: Pointer
    let classMethods: Pointer
    let optionalInstanceMethods: Pointer
    let optionalClassMethods: Pointer
    let instanceProperties: Pointer
    let size: UInt32
    let flags: UInt32
}

internal enum ObjCProtocolRuntimeFlags {
    // objc4 owns the upper runtime bits. Compare only its canonical/fixed masks:
    // lower bits carry Swift protocol metadata and must not affect remapping.
    static let canonical: UInt32 = 1 << 29
    static let fixedMask: UInt32 = (1 << 30) | (1 << 31)
    static let preoptimizedFixedValue: UInt32 = 1 << 30

    static func isPreoptimizedCanonical(_ flags: UInt32) -> Bool {
        flags & canonical != 0
            && flags & fixedMask == preoptimizedFixedValue
    }

    static func mandatoryLayoutByteCount<Pointer>(
        for _: Pointer.Type
    ) -> Int where Pointer: FixedWidthInteger {
        MemoryLayout<ObjCProtocolRuntimeLayoutPrefix<Pointer>>.size
    }
}

internal struct ObjCProtocolReference<Source, Protocol> {
    let index: Int
    let source: Source
    let value: Protocol
    let identity: ObjCProtocolIdentity
}

internal struct ObjCProtocolNameReference {
    let index: Int
    let name: String
    let identity: ObjCProtocolIdentity
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
    case nameReference(ObjCProtocolNameReference)
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

    var nameReferences: [ObjCProtocolNameReference] {
        entries.compactMap { entry in
            guard case .nameReference(let reference) = entry else { return nil }
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
    case failure(ObjCMetadataTableFailure)

    var values: [(Source, Protocol)]? {
        switch self {
        case .success(let success):
            success.references.map { ($0.source, $0.value) }
        case .failure:
            nil
        }
    }
}

extension ObjCMetadataTableFailure {
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
        case .invalidElementStride(let stride):
            .byteCountOverflow(elementCount: 1, elementSize: Int(clamping: stride))
        case let .elementStrideTooSmall(advertised, _):
            .byteCountOverflow(elementCount: 1, elementSize: advertised)
        case let .unexpectedElementStride(advertised, _):
            .byteCountOverflow(elementCount: 1, elementSize: advertised)
        case let .misalignedTableOffset(offset, _):
            .invalidListOffset(offset)
        case .misalignedTableAddress:
            .invalidListOffset(0)
        case let .excessiveElementCount(actual, maximum):
            .excessiveElementCount(actual: actual, maximum: maximum)
        case let .excessiveByteCount(actual, maximum):
            .excessiveByteCount(actual: actual, maximum: maximum)
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

extension ObjCProtocolListProtocol {
    private func checkedElementCount() -> ObjCMetadataTableRead<Int> {
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

    private func checkedByteCount(count: Int) -> ObjCMetadataTableRead<Int> {
        let elementSize = MemoryLayout<ObjCProtocol.Layout.Pointer>.size
        return ObjCMetadataTableReader.checkedByteCount(
            count: count,
            stride: elementSize
        )
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
        let (fieldBase, fieldBaseOverflow) = offset.addingReportingOverflow(
            MemoryLayout<Header>.size
        )

        let pointerEntries: [ObjCMetadataTableEntry<ObjCProtocol.Layout.Pointer>]
        switch ObjCMetadataTableReader.readFile(
            fileHandle,
            offset: tableOffset,
            logicalOffset: fieldBaseOverflow ? nil : fieldBase,
            count: count,
            as: ObjCProtocol.Layout.Pointer.self
        ) {
        case .success(let value): pointerEntries = value
        case .failure(let failure): return .failure(failure)
        }

        var entries: [ObjCProtocolListReadEntry<MachOFile, ObjCProtocol>] = []
        entries.reserveCapacity(count)

        for pointerEntry in pointerEntries {
            let index = pointerEntry.index
            let pointer = pointerEntry.value
            guard !fieldBaseOverflow,
                  let fieldOffset = pointerEntry.logicalOffset,
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

            guard let layout: ObjCProtocol.Layout = layoutFile.readLayout(
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
        in machO: MachOImage,
        runtimeResolver: ObjCProtocolRuntimeResolver? = nil
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
        let (tableAddress, headerOverflow) = listAddress.addingReportingOverflow(
            UInt(MemoryLayout<Header>.size)
        )
        guard !headerOverflow else {
            return .failure(.rangeOverflow(startOffset: UInt64(imageAddress), byteCount: 0))
        }

        let pointerEntries: [ObjCMetadataTableEntry<ObjCProtocol.Layout.Pointer>]
        switch ObjCMetadataTableReader.readImage(
            address: tableAddress,
            count: count,
            as: ObjCProtocol.Layout.Pointer.self
        ) {
        case .success(let value): pointerEntries = value
        case .failure(let failure): return .failure(failure)
        }

        var entries: [ObjCProtocolListReadEntry<MachOImage, ObjCProtocol>] = []
        entries.reserveCapacity(count)
        var runtimeNameReader = ObjCProtocolRuntimeNameReader()

        for pointerEntry in pointerEntries {
            let index = pointerEntry.index
            let pointer = pointerEntry.value
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

            let targetMachO: MachOImage?
            if machO.contains(ptr: protocolPointer) {
                targetMachO = machO
            } else {
                targetMachO = machO.resolveImage(containing: protocolPointer)
            }

            if targetMachO == nil {
                guard let runtimeResolver else {
                    entries.append(.failure(.init(index: index, reason: .missingBackingData)))
                    continue
                }
                typealias RuntimeLayout = ObjCProtocolRuntimeLayoutPrefix<ObjCProtocol.Layout.Pointer>
                let mandatoryLayoutByteCount = MemoryLayout<RuntimeLayout>.size
                guard isPointerSafelyReadable(
                    protocolPointer,
                    length: mandatoryLayoutByteCount
                ) else {
                    entries.append(
                        .failure(.init(
                            index: index,
                            reason: .unreadableImageLayout(
                                address: strippedAddress,
                                byteCount: mandatoryLayoutByteCount
                            )
                        ))
                    )
                    continue
                }

                let layout = protocolPointer.loadUnaligned(as: RuntimeLayout.self)
                guard UInt64(layout.size) >= UInt64(mandatoryLayoutByteCount),
                      let rawNameAddress64 = UInt64(exactly: layout.mangledName),
                      let rawNameAddress = UInt(exactly: machO.stripPointerTags(of: rawNameAddress64)),
                      let rawNamePointer = UnsafeRawPointer(bitPattern: rawNameAddress) else {
                    entries.append(.failure(.init(index: index, reason: .missingBackingData)))
                    continue
                }

                let protocolCacheLocation = runtimeResolver.activeDyldCacheLocation(
                    protocolPointer
                )
                let nameCacheLocation = runtimeResolver.activeDyldCacheLocation(
                    rawNamePointer
                )
                let maximumNameByteCount = nameCacheLocation.map {
                    min(
                        BoundedCStringReadLimits.maximumByteCount,
                        Int(clamping: $0.remainingMappedByteCount)
                    )
                } ?? BoundedCStringReadLimits.maximumByteCount
                guard let rawName = runtimeNameReader.name(
                    at: rawNamePointer,
                    maximumByteCount: maximumNameByteCount
                ), !rawName.isEmpty else {
                    entries.append(.failure(.init(index: index, reason: .missingBackingData)))
                    continue
                }

                // Do not gate this path on objc_getProtocol: objc4 returns a
                // cache-owned canonical object before its name lookup, and a
                // private protocol may be absent from the global registry.
                if let protocolCacheLocation,
                   nameCacheLocation != nil,
                   runtimeResolver.usesSharedCacheProtocolOptimizations,
                   protocolCacheLocation.remainingMappedByteCount
                    >= UInt(mandatoryLayoutByteCount),
                   ObjCProtocolRuntimeFlags.isPreoptimizedCanonical(layout.flags) {
                    entries.append(
                        .nameReference(.init(
                            index: index,
                            name: rawName,
                            identity: protocolCacheLocation.identity
                        ))
                    )
                    continue
                }

                // Noncanonical raw aliases follow objc4's name-based remap path.
                guard let canonicalProtocolPointer = runtimeResolver.protocolAddress(rawName) else {
                    entries.append(.failure(.init(index: index, reason: .missingBackingData)))
                    continue
                }
                entries.append(
                    .nameReference(.init(
                        index: index,
                        name: rawName,
                        identity: .image(address: UInt(bitPattern: canonicalProtocolPointer))
                    ))
                )
                continue
            }

            guard let targetMachO else {
                entries.append(.failure(.init(index: index, reason: .missingBackingData)))
                continue
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
            let layout = protocolPointer.loadUnaligned(as: ObjCProtocol.Layout.self)
            guard let protocolOffset = signedDisplacement(
                from: UInt(bitPattern: targetMachO.ptr),
                to: strippedAddress
            ) else {
                entries.append(.failure(.init(index: index, reason: .invalidEntryOffset)))
                continue
            }

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
