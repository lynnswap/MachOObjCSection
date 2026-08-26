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
        guard header.count > 0 else { return true }
        return Int(exactly: header.entsizeAndFlags & ~Self.flagMask)
            == expectedEntrySize(is64Bit: is64Bit)
    }
}

extension ObjCPropertyList {
    public func properties(
        in machO: MachOImage
    ) -> [ObjCProperty] {
        readProperties(in: machO).values ?? []
    }

    public func properties(
        in machO: MachOFile
    ) -> [ObjCProperty] {
        readProperties(in: machO).values ?? []
    }

    internal func readProperties(
        in machO: MachOImage
    ) -> ObjCMemberTableReadOutcome<ObjCProperty> {
        guard !isListOfLists else {
            return .failure(.unsupportedListEncoding)
        }

        switch readImageTable(
            in: machO,
            expectedStride: MemoryLayout<ObjCProperty.Property>.size,
            requiredAlignment: MemoryLayout<ObjCProperty.Property>.alignment,
            as: ObjCProperty.Property.self
        ) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let entries):
            return .success(
                .init(
                    values: entries.map { ObjCProperty($0.value) },
                    failures: []
                )
            )
        }
    }

    internal func readProperties(
        in machO: MachOFile
    ) -> ObjCMemberTableReadOutcome<ObjCProperty> {
        guard !isListOfLists else {
            return .failure(.unsupportedListEncoding)
        }
        if machO.is64Bit {
            switch readFileTable(
                in: machO,
                expectedStride: MemoryLayout<ObjCProperty.Property64>.size,
                requiredAlignment: MemoryLayout<ObjCProperty.Property64>.alignment,
                as: ObjCProperty.Property64.self
            ) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let entries):
                var unresolved: [ObjCProperty.UnresolvedProperty] = []
                var failures: [ObjCMetadataTableEntryFailure] = []
                unresolved.reserveCapacity(entries.count)
                for entry in entries {
                    guard let fieldOffset = entry.logicalOffset else {
                        failures.append(.init(index: entry.index, reason: .invalidLogicalOffset))
                        continue
                    }
                    let (attributesOffset, overflow) = fieldOffset.addingReportingOverflow(
                        MemoryLayout<UInt64>.size
                    )
                    guard !overflow else {
                        failures.append(.init(index: entry.index, reason: .invalidLogicalOffset))
                        continue
                    }
                    unresolved.append(
                        ObjCProperty.UnresolvedProperty(
                            name: .init(
                                fieldOffset: fieldOffset,
                                value: entry.value.name
                            ),
                            attributes: .init(
                                fieldOffset: attributesOffset,
                                value: entry.value.attributes
                            )
                        )
                    )
                }
                let properties = unresolved.compactMap { machO.resolveRebase($0) }
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
                return .success(.init(values: properties, failures: failures))
            }
        } else {
            switch readFileTable(
                in: machO,
                expectedStride: MemoryLayout<ObjCProperty.Property32>.size,
                requiredAlignment: MemoryLayout<ObjCProperty.Property32>.alignment,
                as: ObjCProperty.Property32.self
            ) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let entries):
                var unresolved: [ObjCProperty.UnresolvedProperty] = []
                var failures: [ObjCMetadataTableEntryFailure] = []
                unresolved.reserveCapacity(entries.count)
                for entry in entries {
                    guard let fieldOffset = entry.logicalOffset else {
                        failures.append(.init(index: entry.index, reason: .invalidLogicalOffset))
                        continue
                    }
                    let (attributesOffset, overflow) = fieldOffset.addingReportingOverflow(
                        MemoryLayout<UInt32>.size
                    )
                    guard !overflow else {
                        failures.append(.init(index: entry.index, reason: .invalidLogicalOffset))
                        continue
                    }
                    unresolved.append(
                        ObjCProperty.UnresolvedProperty(
                            name: .init(
                                fieldOffset: fieldOffset,
                                value: UInt64(entry.value.name)
                            ),
                            attributes: .init(
                                fieldOffset: attributesOffset,
                                value: UInt64(entry.value.attributes)
                            )
                        )
                    )
                }
                let properties = unresolved.compactMap { machO.resolveRebase($0) }
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
                return .success(.init(values: properties, failures: failures))
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
