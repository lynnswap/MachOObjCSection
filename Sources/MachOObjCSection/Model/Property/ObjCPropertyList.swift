//
//  ObjCPropertyList.swift
//
//
//  Created by p-x9 on 2024/05/25
//
//

import Foundation
@_spi(Support) import MachOKit

public struct ObjCPropertyList: EntrySizeListProtocol {
    public typealias Entry = ObjCProperty

    /// Offset from machO header start
    public let offset: Int
    public let header: Header
    public let is64Bit: Bool
}

extension ObjCPropertyList {
    init(
        ptr: UnsafeRawPointer,
        offset: Int,
        is64Bit: Bool
    ) {
        self.offset = offset
        self.header = ptr.loadUnaligned(as: Header.self)
        self.is64Bit = is64Bit
    }
}

extension ObjCPropertyList {
    public var isListOfLists: Bool {
        offset & 1 == 1
    }
}

extension ObjCPropertyList {
    public static var flagMask: UInt32 { 0 }
}

extension ObjCPropertyList {
    func expectedEntrySize(is64Bit: Bool) -> Int {
        if is64Bit {
            MemoryLayout<ObjCProperty.Property64>.size
        } else {
            MemoryLayout<ObjCProperty.Property32>.size
        }
    }

    func expectedEntryAlignment(is64Bit: Bool) -> Int {
        if is64Bit {
            MemoryLayout<ObjCProperty.Property64>.alignment
        } else {
            MemoryLayout<ObjCProperty.Property32>.alignment
        }
    }

    func isValidEntrySize(is64Bit: Bool) -> Bool {
        expectedEntrySize(is64Bit: is64Bit) == entrySize
    }
}

extension ObjCPropertyList {
    public func properties(
        in machO: MachOImage
    ) -> [ObjCProperty] {
        // TODO: Support listOfLists
        guard !isListOfLists else { return [] }

        let ptr = machO.ptr.advanced(by: offset)
        let start = ptr.advanced(by: MemoryLayout<Header>.size)
        let sequence = MemorySequence(
            basePointer: start.assumingMemoryBound(
                to: ObjCProperty.Property.self
            ),
            numberOfElements: count
        )
        return sequence
            .map { ObjCProperty($0) }
    }

    public func properties(
        in machO: MachOFile
    ) -> [ObjCProperty] {
        guard !isListOfLists else {
            assertionFailure()
            return []
        }

        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forOffset: numericCast(offset)) else {
            return []
        }

        if machO.is64Bit {
            let sequence: DataSequence<ObjCProperty.Property64> = fileHandle
                .readDataSequence(
                    offset: fileOffset + numericCast(MemoryLayout<Header>.size),
                    numberOfElements: count
                )
            return sequence.enumerated()
                .map { i, property in
                    let fieldOffset: Int = offset
                    + MemoryLayout<Header>.size
                    + MemoryLayout<ObjCProperty.Property64>.size * i
                    return ObjCProperty.UnresolvedProperty(
                        name: .init(
                            fieldOffset: fieldOffset,
                            value: property.name
                        ),
                        attributes: .init(
                            fieldOffset: fieldOffset + 8,
                            value: property.attributes
                        )
                    )
                }
                .compactMap {
                    machO.resolveRebase($0)
                }
                .compactMap {
                    var name = ""
                    if let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: $0.name) {
                        name = fileHandle.readString(
                            offset: fileOffset
                        ) ?? ""
                    }

                    var attributes = ""
                    if let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: $0.attributes) {
                        attributes = fileHandle.readString(
                            offset: fileOffset
                        ) ?? ""
                    }

                    return ObjCProperty(
                        name: name,
                        attributes: attributes
                    )
                }
        } else {
            let sequence: DataSequence<ObjCProperty.Property32> = fileHandle
                .readDataSequence(
                    offset: fileOffset + numericCast(MemoryLayout<Header>.size),
                    numberOfElements: count
                )
            return sequence.enumerated()
                .map { i, property in
                    let fieldOffset: Int = offset
                    + MemoryLayout<Header>.size
                    + MemoryLayout<ObjCProperty.Property32>.size * i
                    return ObjCProperty.UnresolvedProperty(
                        name: .init(
                            fieldOffset: fieldOffset,
                            value: numericCast(property.name)
                        ),
                        attributes: .init(
                            fieldOffset: fieldOffset + 4,
                            value: numericCast(property.attributes)
                        )
                    )
                }
                .compactMap {
                    machO.resolveRebase($0)
                }
                .map {
                    var name = ""
                    if let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: $0.name) {
                        name = fileHandle.readString(
                            offset: fileOffset
                        ) ?? ""
                    }

                    var attributes = ""
                    if let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: $0.attributes) {
                        attributes = fileHandle.readString(
                            offset: fileOffset
                        ) ?? ""
                    }

                    return ObjCProperty(
                        name: name,
                        attributes: attributes
                    )
                }
        }
    }
}

extension MachOFile {
    func resolveRebase(
        _ unresolvedValue: ObjCProperty.UnresolvedProperty
    ) -> ObjCProperty.ResolvedProperty? {
        guard let name = resolveRebase(unresolvedValue.name),
              let attributes = resolveRebase(unresolvedValue.attributes) else {
            return nil
        }
        return ObjCProperty.ResolvedProperty(
            name: name,
            attributes: attributes
        )
    }
}
