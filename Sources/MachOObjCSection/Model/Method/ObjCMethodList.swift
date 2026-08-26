//
//  ObjCMethodList.swift
//
//
//  Created by p-x9 on 2024/05/16
//
//

import Foundation
@_spi(Support) import MachOKit

// https://github.com/apple-oss-distributions/objc4/blob/01edf1705fbc3ff78a423cd21e03dfc21eb4d780/runtime/objc-runtime-new.h#L707

// https://github.com/apple-oss-distributions/dyld/blob/25174f1accc4d352d9e7e6294835f9e6e9b3c7bf/common/ObjCVisitor.h#L191

public struct ObjCMethodList: EntrySizeListProtocol {
    public typealias Entry = ObjCMethod

    /// Offset from machO header start
    public let offset: Int
    public let header: Header
    public let is64Bit: Bool
}

extension ObjCMethodList {
    public var isListOfLists: Bool {
        offset & 1 == 1
    }
}

extension ObjCMethodList {
    public static var flagMask: UInt32 { 0xffff0003 }
}

extension ObjCMethodList {
    typealias Mask = ObjCMethodListMask

    public var listKind: ObjCMethod.Kind {
        if usesRelativeOffsets {
            if usesOffsetsFromTypeBuffer {
                return .relativeDirectSelectorsAndTypes
            } else if usesOffsetsFromSelectorBuffer {
                return .relativeDirectSelectors
            }
            return .relativeIndirect
        }
        return .pointer
    }

    public var usesOffsetsFromTypeBuffer: Bool {
        header.entsizeAndFlags & Mask.usesTypeOffsets != 0
    }

    public var usesOffsetsFromSelectorBuffer: Bool {
        header.entsizeAndFlags & Mask.usesSelectorOffsets != 0
    }

    public var usesRelativeOffsets: Bool {
        header.entsizeAndFlags & Mask.isRelative != 0
    }
}

extension ObjCMethodList {
    func expectedEntrySize(is64Bit: Bool) -> Int {
        switch listKind {
        case .pointer where is64Bit:
            return MemoryLayout<ObjCMethod.Pointer64>.size
        case .pointer:
            return MemoryLayout<ObjCMethod.Pointer32>.size
        case .relativeDirectSelectors, .relativeDirectSelectorsAndTypes:
            return MemoryLayout<ObjCMethod.RelativeDirect>.size
        case .relativeIndirect:
            return MemoryLayout<ObjCMethod.RelativeInDirect>.size
        }
    }

    func expectedEntryAlignment(is64Bit: Bool) -> Int {
        switch listKind {
        case .pointer where is64Bit:
            return MemoryLayout<ObjCMethod.Pointer64>.alignment
        case .pointer:
            return MemoryLayout<ObjCMethod.Pointer32>.alignment
        case .relativeDirectSelectors, .relativeDirectSelectorsAndTypes:
            return MemoryLayout<ObjCMethod.RelativeDirect>.alignment
        case .relativeIndirect:
            return MemoryLayout<ObjCMethod.RelativeInDirect>.alignment
        }
    }

    func isValidEntrySize(is64Bit: Bool) -> Bool {
        guard header.count > 0 else { return true }
        return Int(exactly: header.entsizeAndFlags & ~Self.flagMask)
            == expectedEntrySize(is64Bit: is64Bit)
    }
}

extension ObjCMethodList {
    public func methods(
        in machO: MachOImage
    ) -> [ObjCMethod] {
        readMethods(in: machO).values ?? []
    }

    public func methods(
        in machO: MachOFile
    ) -> [ObjCMethod]? {
        readMethods(in: machO).values
    }

    internal func readMethods(
        in machO: MachOImage
    ) -> ObjCMemberTableReadOutcome<ObjCMethod> {
        guard !isListOfLists else {
            return .failure(.unsupportedListEncoding)
        }

        switch listKind {
        case .pointer:
            return decodedImageMethods(
                readImageTable(
                    in: machO,
                    expectedStride: MemoryLayout<ObjCMethod.Pointer>.size,
                    requiredAlignment: MemoryLayout<ObjCMethod.Pointer>.alignment,
                    as: ObjCMethod.Pointer.self
                )
            ) { entry in
                return ObjCMethod(entry.value)
            }
        case .relativeDirectSelectors, .relativeDirectSelectorsAndTypes:
            let usesRelativeDirectType = listKind == .relativeDirectSelectorsAndTypes
            return decodedImageMethods(
                readImageTable(
                    in: machO,
                    expectedStride: MemoryLayout<ObjCMethod.RelativeDirect>.size,
                    requiredAlignment: MemoryLayout<ObjCMethod.RelativeDirect>.alignment,
                    as: ObjCMethod.RelativeDirect.self
                )
            ) { entry in
                guard let address = entry.address,
                      let pointer = UnsafeRawPointer(bitPattern: address) else {
                    return nil
                }
                return ObjCMethod(
                    entry.value,
                    at: pointer,
                    isRelativeDirectType: usesRelativeDirectType
                )
            }
        case .relativeIndirect:
            return decodedImageMethods(
                readImageTable(
                    in: machO,
                    expectedStride: MemoryLayout<ObjCMethod.RelativeInDirect>.size,
                    requiredAlignment: MemoryLayout<ObjCMethod.RelativeInDirect>.alignment,
                    as: ObjCMethod.RelativeInDirect.self
                )
            ) { entry in
                guard let address = entry.address,
                      let pointer = UnsafeRawPointer(bitPattern: address) else {
                    return nil
                }
                return ObjCMethod(entry.value, at: pointer)
            }
        }
    }

    internal func readMethods(
        in machO: MachOFile
    ) -> ObjCMemberTableReadOutcome<ObjCMethod> {
        guard !isListOfLists else {
            return .failure(.unsupportedListEncoding)
        }

        switch listKind {
        case .pointer where machO.is64Bit:
            return decodedFileMethods(
                readFileTable(
                    in: machO,
                    expectedStride: MemoryLayout<ObjCMethod.Pointer64>.size,
                    requiredAlignment: MemoryLayout<ObjCMethod.Pointer64>.alignment,
                    as: ObjCMethod.Pointer64.self
                )
            ) { entry in
                pointerMethod(entry.value, in: machO)
            }
        case .pointer:
            return decodedFileMethods(
                readFileTable(
                    in: machO,
                    expectedStride: MemoryLayout<ObjCMethod.Pointer32>.size,
                    requiredAlignment: MemoryLayout<ObjCMethod.Pointer32>.alignment,
                    as: ObjCMethod.Pointer32.self
                )
            ) { entry in
                pointerMethod(entry.value, in: machO)
            }
        case .relativeIndirect:
            return decodedFileMethods(
                readFileTable(
                    in: machO,
                    expectedStride: MemoryLayout<ObjCMethod.RelativeInDirect>.size,
                    requiredAlignment: MemoryLayout<ObjCMethod.RelativeInDirect>.alignment,
                    as: ObjCMethod.RelativeInDirect.self
                )
            ) { entry in
                guard let logicalOffset = entry.logicalOffset,
                      let logicalOffset64 = UInt64(exactly: logicalOffset),
                      let fileOffset = entry.fileOffset,
                      let (fileHandle, _) = machO.fileHandleAndOffset(
                        forOffset: logicalOffset64
                      ) else {
                    return .failure(.invalidLogicalOffset)
                }
                return indirectMethod(
                    entry.value,
                    in: machO,
                    fileHandle: fileHandle,
                    entryOffset: logicalOffset64,
                    fileOffset: fileOffset
                )
            }
        case .relativeDirectSelectors, .relativeDirectSelectorsAndTypes:
            let nameOffsetInCache = machO.relativeMethodSelectorBaseAddressOffset ?? 0
            let usesRelativeDirectType = listKind == .relativeDirectSelectorsAndTypes
            return decodedFileMethods(
                readFileTable(
                    in: machO,
                    expectedStride: MemoryLayout<ObjCMethod.RelativeDirect>.size,
                    requiredAlignment: MemoryLayout<ObjCMethod.RelativeDirect>.alignment,
                    as: ObjCMethod.RelativeDirect.self
                )
            ) { entry in
                guard let logicalOffset = entry.logicalOffset,
                      let entryOffset = UInt64(exactly: logicalOffset) else {
                    return .failure(.invalidLogicalOffset)
                }
                return directMethod(
                    entry.value,
                    in: machO,
                    entryOffset: entryOffset,
                    nameBaseOffset: nameOffsetInCache,
                    typeBaseOffset: usesRelativeDirectType ? nameOffsetInCache : nil
                )
            }
        }
    }

    private func decodedImageMethods<Layout>(
        _ result: ObjCMetadataTableRead<[ObjCMetadataTableEntry<Layout>]>,
        transform: (ObjCMetadataTableEntry<Layout>) -> ObjCMethod?
    ) -> ObjCMemberTableReadOutcome<ObjCMethod> {
        switch result {
        case .failure(let failure):
            return .failure(failure)
        case .success(let entries):
            return .success(
                .init(values: entries.compactMap(transform), failures: [])
            )
        }
    }

    private func decodedFileMethods<Layout>(
        _ result: ObjCMetadataTableRead<[ObjCMetadataTableEntry<Layout>]>,
        transform: (ObjCMetadataTableEntry<Layout>) -> Result<ObjCMethod, ObjCMetadataTableEntryFailureReason>
    ) -> ObjCMemberTableReadOutcome<ObjCMethod> {
        switch result {
        case .failure(let failure):
            return .failure(failure)
        case .success(let entries):
            var values: [ObjCMethod] = []
            var failures: [ObjCMetadataTableEntryFailure] = []
            values.reserveCapacity(entries.count)
            for entry in entries {
                switch transform(entry) {
                case .success(let method):
                    values.append(method)
                case .failure(let reason):
                    failures.append(.init(index: entry.index, reason: reason))
                }
            }
            return .success(.init(values: values, failures: failures))
        }
    }
}

extension ObjCMethodList {
    private func pointerMethod(
        _ pointer: ObjCMethod.Pointer64,
        in machO: MachOFile
    ) -> Result<ObjCMethod, ObjCMetadataTableEntryFailureReason> {
        let imp: UInt64
        if let cache = machO.cache, pointer.imp > 0 {
            guard let offset = checkedCacheOffset(
                address: pointer.imp,
                sharedRegionStart: cache.mainCacheHeader.sharedRegionStart
            ) else {
                return .failure(.invalidImplementationOffset)
            }
            imp = offset
        } else if pointer.imp == 0 {
            imp = 0
        } else {
            guard let offset = machO.fileOffset(of: pointer.imp) else {
                return .failure(.invalidImplementationOffset)
            }
            imp = offset
        }

        return .success(
            ObjCMethod(
                name: resolveString(
                    in: machO,
                    forAddress: pointer.name
                ),
                types: resolveString(
                    in: machO,
                    forAddress: pointer.types
                ),
                imp: imp
            )
        )
    }

    private func pointerMethod(
        _ pointer: ObjCMethod.Pointer32,
        in machO: MachOFile
    ) -> Result<ObjCMethod, ObjCMetadataTableEntryFailureReason> {
        let rawImplementation = UInt64(pointer.imp)
        let imp: UInt64
        if let cache = machO.cache, pointer.imp > 0 {
            guard let offset = checkedCacheOffset(
                address: rawImplementation,
                sharedRegionStart: cache.mainCacheHeader.sharedRegionStart
            ) else {
                return .failure(.invalidImplementationOffset)
            }
            imp = offset
        } else if pointer.imp == 0 {
            imp = 0
        } else {
            guard let offset = machO.fileOffset(of: rawImplementation) else {
                return .failure(.invalidImplementationOffset)
            }
            imp = offset
        }

        return .success(
            ObjCMethod(
                name: resolveString(
                    in: machO,
                    forAddress: UInt64(pointer.name)
                ),
                types: resolveString(
                    in: machO,
                    forAddress: UInt64(pointer.types)
                ),
                imp: imp
            )
        )
    }

    private func indirectMethod(
        _ relativeIndirect: ObjCMethod.RelativeInDirect,
        in machO: MachOFile,
        fileHandle: MachOFile.File,
        entryOffset: UInt64,
        fileOffset: UInt64
    ) -> Result<ObjCMethod, ObjCMetadataTableEntryFailureReason> {
        guard let namePointerOffset = resolvedOffset(
            base: fileOffset,
            relative: relativeIndirect.name.offset
        ) else {
            return .failure(.invalidRelativeDisplacement)
        }
        let nameAddress: UInt64
        let namePointerByteCount: Int
        if machO.is64Bit {
            namePointerByteCount = MemoryLayout<UInt64>.size
            guard let address = fileHandle.readLayout(
                offset: namePointerOffset,
                as: UInt64.self
            ) else {
                return .failure(
                    .unreadableFileRange(
                        offset: namePointerOffset,
                        byteCount: namePointerByteCount
                    )
                )
            }
            nameAddress = address
        } else {
            namePointerByteCount = MemoryLayout<UInt32>.size
            guard let address = fileHandle.readLayout(
                offset: namePointerOffset,
                as: UInt32.self
            ) else {
                return .failure(
                    .unreadableFileRange(
                        offset: namePointerOffset,
                        byteCount: namePointerByteCount
                    )
                )
            }
            nameAddress = UInt64(address)
        }
        guard let types = resolvedOffset(
            base: fileOffset,
            relative: relativeIndirect.types.offset,
            adjustment: 4
        ) else {
            return .failure(.invalidRelativeDisplacement)
        }

        guard let imp = resolvedOffset(
            base: entryOffset,
            relative: relativeIndirect.imp.offset,
            adjustment: 8
        ) else {
            return .failure(.invalidRelativeDisplacement)
        }

        return .success(
            ObjCMethod(
                name: resolveString(
                    in: machO,
                    forAddress: nameAddress
                ),
                types: fileHandle.readString(offset: types) ?? "",
                imp: imp
            )
        )
    }

    private func directMethod(
        _ relativeDirect: ObjCMethod.RelativeDirect,
        in machO: MachOFile,
        entryOffset: UInt64,
        nameBaseOffset: UInt64,
        typeBaseOffset: UInt64?
    ) -> Result<ObjCMethod, ObjCMetadataTableEntryFailureReason> {
        guard let nameOffset = resolvedOffset(
            base: nameBaseOffset,
            relative: relativeDirect.name.offset
        ) else {
            return .failure(.invalidRelativeDisplacement)
        }

        let typesOffset: UInt64
        if let typeBaseOffset {
            guard let resolved = resolvedOffset(
                base: typeBaseOffset,
                relative: relativeDirect.types.offset
            ) else {
                return .failure(.invalidRelativeDisplacement)
            }
            typesOffset = resolved
        } else {
            guard let resolved = resolvedOffset(
                base: entryOffset,
                relative: relativeDirect.types.offset,
                adjustment: 4
            ) else {
                return .failure(.invalidRelativeDisplacement)
            }
            typesOffset = resolved
        }

        guard let imp = resolvedOffset(
            base: entryOffset,
            relative: relativeDirect.imp.offset,
            adjustment: 8
        ) else {
            return .failure(.invalidRelativeDisplacement)
        }

        return .success(
            ObjCMethod(
                name: resolveString(
                    in: machO,
                    forOffset: nameOffset
                ),
                types: resolveString(
                    in: machO,
                    forOffset: typesOffset
                ),
                imp: imp
            )
        )
    }
}

extension ObjCMethodList {
    private func resolvedOffset<Offset: BinaryInteger>(
        base: UInt64,
        relative: Offset,
        adjustment: UInt64 = 0
    ) -> UInt64? {
        guard let relative = Int64(exactly: relative) else { return nil }
        let displaced: UInt64
        if relative >= 0 {
            guard let magnitude = UInt64(exactly: relative) else { return nil }
            let (value, overflow) = base.addingReportingOverflow(magnitude)
            guard !overflow else { return nil }
            displaced = value
        } else {
            let magnitude = UInt64(relative.magnitude)
            let (value, underflow) = base.subtractingReportingOverflow(magnitude)
            guard !underflow else { return nil }
            displaced = value
        }
        let (result, overflow) = displaced.addingReportingOverflow(adjustment)
        return overflow ? nil : result
    }

    private func resolveString(
        in machO: MachOFile,
        forAddress address: UInt64
    ) -> String {
        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forAddress: address) else {
            return ""
        }
        return fileHandle.readString(offset: fileOffset) ?? ""
    }

    private func resolveString(
        in machO: MachOFile,
        forOffset offset: UInt64
    ) -> String {
        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forOffset: offset) else {
            return ""
        }
        return fileHandle.readString(offset: fileOffset) ?? ""
    }
}
