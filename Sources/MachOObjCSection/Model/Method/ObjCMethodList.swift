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

    init(
        ptr: UnsafeRawPointer,
        offset: Int,
        is64Bit: Bool
    ) {
        self.offset = offset
        self.header = ptr.assumingMemoryBound(to: Header.self).pointee
        self.is64Bit = is64Bit
    }
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
            return usesOffsetsFromSelectorBuffer ? .relativeDirect : .relativeIndirect
        }
        return .pointer
    }

    public var usesOffsetsFromSelectorBuffer: Bool {
        header.entsizeAndFlags & Mask.usesSelectorOffsets != 0
    }

    public var usesRelativeOffsets: Bool {
        header.entsizeAndFlags & Mask.isRelative != 0
    }
}

extension ObjCMethodList {
    func isValidEntrySize(is64Bit: Bool) -> Bool {
        switch listKind {
        case .pointer where is64Bit:
            MemoryLayout<ObjCMethod.Pointer64>.size == entrySize
        case .pointer:
            MemoryLayout<ObjCMethod.Pointer32>.size == entrySize
        case .relativeDirect:
            MemoryLayout<ObjCMethod.RelativeDirect>.size == entrySize
        case .relativeIndirect:
            MemoryLayout<ObjCMethod.RelativeInDirect>.size == entrySize
        }
    }
}

extension ObjCMethodList {
    public func methods(
        in machO: MachOImage
    ) -> [ObjCMethod] {
        // TODO: Support listOfLists
        guard !isListOfLists else { return [] }

        let ptr = machO.ptr.advanced(by: offset)
        let start = ptr.advanced(by: MemoryLayout<Header>.size)

        switch listKind {
        case .pointer:
            let sequence = MemorySequence(
                basePointer: start.assumingMemoryBound(
                    to: ObjCMethod.Pointer.self
                ),
                numberOfElements: count
            )
            return sequence
                .map { ObjCMethod($0) }

        case .relativeDirect:
            let sequence = MemorySequence(
                basePointer: start.assumingMemoryBound(
                    to: ObjCMethod.RelativeDirect.self
                ),
                numberOfElements: count
            )
            let size = MemoryLayout<ObjCMethod.RelativeInDirect>.size
            return sequence
                .enumerated()
                .map {
                    ObjCMethod($1, at: start.advanced(by: size * $0))
                }

        case .relativeIndirect:
            let sequence = MemorySequence(
                basePointer: start.assumingMemoryBound(
                    to: ObjCMethod.RelativeInDirect.self
                ),
                numberOfElements: count
            )
            let size = MemoryLayout<ObjCMethod.RelativeInDirect>.size
            return sequence
                .enumerated()
                .map {
                    ObjCMethod($1, at: start.advanced(by: size * $0))
                }
        }
    }

    public func methods(
        in machO: MachOFile
    ) -> [ObjCMethod]? {
        guard !isListOfLists else {
            assertionFailure()
            return nil
        }

        let listOffset = offset
        let (headerOffset, overflow) = listOffset
            .addingReportingOverflow(MemoryLayout<Header>.size)
        guard !overflow, headerOffset >= 0 else { return nil }
        let offset: UInt64 = UInt64(headerOffset)
        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forOffset: offset) else {
            return nil
        }
        guard let baseFileOffset = Int(exactly: fileOffset) else { return nil }

        switch listKind {
        case .pointer where machO.is64Bit:
            let sequence: DataSequence<ObjCMethod.Pointer64> = fileHandle.readDataSequence(
                offset: fileOffset,
                numberOfElements: count,
                swapHandler: nil
            )
            return sequence
                .map {
                    var name = ""
                    if let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forAddress: $0.name) {
                        name = fileHandle.readString(
                            offset: fileOffset
                        ) ?? ""
                    }
                    var types = ""
                    if let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forAddress: $0.types) {
                        types = fileHandle.readString(
                            offset: fileOffset
                        ) ?? ""
                    }

                    let imp: UInt64 = if let cache = machO.cache, $0.imp > 0 {
                        numericCast($0.imp) - cache.mainCacheHeader.sharedRegionStart
                    } else {
                        machO.fileOffset(of: numericCast($0.imp)) ?? 0
                    }

                    return ObjCMethod(
                        name: name,
                        types: types,
                        imp: imp
                    )
                }
        case .pointer:
            let sequence: DataSequence<ObjCMethod.Pointer32> = fileHandle.readDataSequence(
                offset: fileOffset,
                numberOfElements: count,
                swapHandler: nil
            )
            return sequence
                .map {
                    var name = ""
                    if let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forAddress: numericCast($0.name)) {
                        name = fileHandle.readString(
                            offset: fileOffset
                        ) ?? ""
                    }
                    var types = ""
                    if let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forAddress: numericCast($0.types)) {
                        types = fileHandle.readString(
                            offset: fileOffset
                        ) ?? ""
                    }

                    let imp: UInt64 = if let cache = machO.cache, $0.imp > 0 {
                        numericCast($0.imp) - cache.mainCacheHeader.sharedRegionStart
                    } else {
                        machO.fileOffset(of: numericCast($0.imp)) ?? 0
                    }

                    return ObjCMethod(
                        name: name,
                        types: types,
                        imp: imp
                    )
                }

        case .relativeIndirect:
            let sequence: DataSequence<ObjCMethod.RelativeInDirect> = fileHandle.readDataSequence(
                offset: fileOffset,
                numberOfElements: count,
                swapHandler: nil
            )
            let size = MemoryLayout<ObjCMethod.RelativeInDirect>.size
            return sequence.enumerated()
                .map {
                    let (entryOffset, entryOffsetOverflow) = headerOffset
                        .addingReportingOverflow($0 * size)
                    let (entryFileOffset, entryFileOffsetOverflow) = baseFileOffset
                        .addingReportingOverflow($0 * size)
                    if entryOffsetOverflow || entryFileOffsetOverflow {
                        return ObjCMethod(name: "", types: "", imp: 0)
                    }
                    var name = ""
                    let nameOffset = entryFileOffset + Int($1.name.offset)
                    if nameOffset >= 0,
                       let address: UInt64 = try? fileHandle.read(offset: nameOffset),
                       let (fileHandle, fileOffset) = machO.fileHandleAndOffset(
                        forAddress: address
                       ) {
                        name = fileHandle.readString(offset: fileOffset) ?? ""
                    }

                    let typesOffset = Int64(entryFileOffset)
                        + Int64($1.types.offset)
                        + 4
                    let types = if typesOffset >= 0 {
                        fileHandle.readString(offset: UInt64(typesOffset)) ?? ""
                    } else {
                        ""
                    }

                    let impOffset = Int64(entryOffset)
                        + Int64($1.imp.offset)
                        + 8
                    let imp: UInt64 = impOffset >= 0 ? UInt64(impOffset) : 0

                    return ObjCMethod(
                        name: name,
                        types: types,
                        imp: imp
                    )
                }

        case .relativeDirect:
            let sequence: DataSequence<ObjCMethod.RelativeDirect> = fileHandle.readDataSequence(
                offset: fileOffset,
                numberOfElements: count,
                swapHandler: nil
            )

            let size = MemoryLayout<ObjCMethod.RelativeDirect>.size
            let nameOffsetInCache = machO.relativeMethodSelectorBaseAddressOffset ?? 0

            return sequence.enumerated()
                .map {
                    let (entryOffset, entryOffsetOverflow) = headerOffset
                        .addingReportingOverflow($0 * size)
                    if entryOffsetOverflow {
                        return ObjCMethod(name: "", types: "", imp: 0)
                    }

                    let nameOffsetValue = Int64($1.name.offset)
                    let typesOffset = Int64(entryOffset)
                        + Int64($1.types.offset)
                        + 4
                    let impOffset = Int64(entryOffset)
                        + Int64($1.imp.offset)
                        + 8

                    var name = ""
                    if nameOffsetValue >= 0,
                       let nameOffset = UInt64(exactly: nameOffsetValue),
                       let (fileHandle, fileOffset) = machO.fileHandleAndOffset(
                        forOffset: nameOffsetInCache + nameOffset
                       ) {
                        name = fileHandle.readString(
                            offset: fileOffset
                        ) ?? ""
                    }

                    var types = ""
                    if typesOffset >= 0,
                       let typesOffsetValue = UInt64(exactly: typesOffset),
                       let (fileHandle, fileOffset) = machO.fileHandleAndOffset(
                        forOffset: typesOffsetValue
                       ) {
                        types = fileHandle.readString(
                            offset: fileOffset
                        ) ?? ""
                    }

                    return ObjCMethod(
                        name: name,
                        types: types,
                        imp: impOffset >= 0 ? UInt64(impOffset) : 0
                    )
                }
        }
    }
}
