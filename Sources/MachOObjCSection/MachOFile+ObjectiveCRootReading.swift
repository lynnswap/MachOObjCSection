//
//  MachOFile+ObjectiveCRootReading.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit

@inline(__always)
internal func checkedFileRootLogicalOffset(
    sectionAddress: UInt64,
    sectionFileOffset: Int,
    cacheSharedRegionStart: UInt64?,
    maximumIntValue: UInt64 = UInt64(Int.max)
) -> Int? {
    guard let cacheSharedRegionStart else { return sectionFileOffset }
    guard let rawOffset = checkedCacheOffset(
        address: sectionAddress,
        sharedRegionStart: cacheSharedRegionStart
    ), rawOffset <= maximumIntValue else { return nil }
    return Int(exactly: rawOffset)
}

/// The Objective-C root metadata discovered in one file-backed Mach-O image.
///
/// Existing root properties remain the compatibility surface. Diagnostics SPI
/// consumers use this aggregate to retain ordered structural failures while
/// preserving every readable sibling root.
@_spi(Diagnostics)
public struct ObjCFileRootReadResult {
    /// Roots from `__objc_classlist`, or `nil` when the section/bitness is absent.
    public let classes64: [ObjCClass64]?
    /// 32-bit roots from `__objc_classlist`, or `nil` when absent.
    public let classes32: [ObjCClass32]?
    /// Roots from `__objc_nlclslist`, or `nil` when the section/bitness is absent.
    public let nonLazyClasses64: [ObjCClass64]?
    /// 32-bit roots from `__objc_nlclslist`, or `nil` when absent.
    public let nonLazyClasses32: [ObjCClass32]?
    /// Roots from `__objc_protolist`, or `nil` when the section/bitness is absent.
    public let protocols64: [ObjCProtocol64]?
    /// 32-bit roots from `__objc_protolist`, or `nil` when absent.
    public let protocols32: [ObjCProtocol32]?
    /// Roots from `__objc_catlist`, or `nil` when the section/bitness is absent.
    public let categories64: [ObjCCategory64]?
    /// 32-bit roots from `__objc_catlist`, or `nil` when absent.
    public let categories32: [ObjCCategory32]?
    /// Roots from `__objc_nlcatlist`, or `nil` when the section/bitness is absent.
    public let nonLazyCategories64: [ObjCCategory64]?
    /// 32-bit roots from `__objc_nlcatlist`, or `nil` when absent.
    public let nonLazyCategories32: [ObjCCategory32]?
    /// Roots from `__objc_catlist2`, or `nil` when the section/bitness is absent.
    public let categories2_64: [ObjCCategory64]?
    /// 32-bit roots from `__objc_catlist2`, or `nil` when absent.
    public let categories2_32: [ObjCCategory32]?
    /// Recoverable root table and entry failures in discovery order.
    public let tableDiagnostics: [ObjCMetadataTableDiagnostic]

    internal init(
        classes64: [ObjCClass64]?,
        classes32: [ObjCClass32]?,
        nonLazyClasses64: [ObjCClass64]?,
        nonLazyClasses32: [ObjCClass32]?,
        protocols64: [ObjCProtocol64]?,
        protocols32: [ObjCProtocol32]?,
        categories64: [ObjCCategory64]?,
        categories32: [ObjCCategory32]?,
        nonLazyCategories64: [ObjCCategory64]?,
        nonLazyCategories32: [ObjCCategory32]?,
        categories2_64: [ObjCCategory64]?,
        categories2_32: [ObjCCategory32]?,
        tableDiagnostics: [ObjCMetadataTableDiagnostic]
    ) {
        self.classes64 = classes64
        self.classes32 = classes32
        self.nonLazyClasses64 = nonLazyClasses64
        self.nonLazyClasses32 = nonLazyClasses32
        self.protocols64 = protocols64
        self.protocols32 = protocols32
        self.categories64 = categories64
        self.categories32 = categories32
        self.nonLazyCategories64 = nonLazyCategories64
        self.nonLazyCategories32 = nonLazyCategories32
        self.categories2_64 = categories2_64
        self.categories2_32 = categories2_32
        self.tableDiagnostics = tableDiagnostics
    }
}

extension MachOFile.ObjectiveC {
    /// Reads all file-backed Objective-C root sections and returns recoverable
    /// failures in section and entry discovery order.
    @_spi(Diagnostics)
    public func readRoots() -> ObjCFileRootReadResult {
        let classes64 = readClasses64(
            section: .__objc_classlist,
            root: .classList
        )
        let classes32 = readClasses32(
            section: .__objc_classlist,
            root: .classList
        )
        let nonLazyClasses64 = readClasses64(
            section: .__objc_nlclslist,
            root: .nonLazyClassList
        )
        let nonLazyClasses32 = readClasses32(
            section: .__objc_nlclslist,
            root: .nonLazyClassList
        )
        let protocols64 = readProtocols64()
        let protocols32 = readProtocols32()
        let categories64 = readCategories64(
            section: .__objc_catlist,
            root: .categoryList,
            isCatlist2: false
        )
        let categories32 = readCategories32(
            section: .__objc_catlist,
            root: .categoryList,
            isCatlist2: false
        )
        let nonLazyCategories64 = readCategories64(
            section: .__objc_nlcatlist,
            root: .nonLazyCategoryList,
            isCatlist2: false
        )
        let nonLazyCategories32 = readCategories32(
            section: .__objc_nlcatlist,
            root: .nonLazyCategoryList,
            isCatlist2: false
        )
        let categories2_64 = readCategories64(
            section: .__objc_catlist2,
            root: .categoryList2,
            isCatlist2: true
        )
        let categories2_32 = readCategories32(
            section: .__objc_catlist2,
            root: .categoryList2,
            isCatlist2: true
        )

        var tableDiagnostics: [ObjCMetadataTableDiagnostic] = []
        tableDiagnostics.append(contentsOf: classes64?.diagnostics ?? [])
        tableDiagnostics.append(contentsOf: classes32?.diagnostics ?? [])
        tableDiagnostics.append(contentsOf: nonLazyClasses64?.diagnostics ?? [])
        tableDiagnostics.append(contentsOf: nonLazyClasses32?.diagnostics ?? [])
        tableDiagnostics.append(contentsOf: protocols64?.diagnostics ?? [])
        tableDiagnostics.append(contentsOf: protocols32?.diagnostics ?? [])
        tableDiagnostics.append(contentsOf: categories64?.diagnostics ?? [])
        tableDiagnostics.append(contentsOf: categories32?.diagnostics ?? [])
        tableDiagnostics.append(contentsOf: nonLazyCategories64?.diagnostics ?? [])
        tableDiagnostics.append(contentsOf: nonLazyCategories32?.diagnostics ?? [])
        tableDiagnostics.append(contentsOf: categories2_64?.diagnostics ?? [])
        tableDiagnostics.append(contentsOf: categories2_32?.diagnostics ?? [])

        return ObjCFileRootReadResult(
            classes64: classes64?.values,
            classes32: classes32?.values,
            nonLazyClasses64: nonLazyClasses64?.values,
            nonLazyClasses32: nonLazyClasses32?.values,
            protocols64: protocols64?.values,
            protocols32: protocols32?.values,
            categories64: categories64?.values,
            categories32: categories32?.values,
            nonLazyCategories64: nonLazyCategories64?.values,
            nonLazyCategories32: nonLazyCategories32?.values,
            categories2_64: categories2_64?.values,
            categories2_32: categories2_32?.values,
            tableDiagnostics: tableDiagnostics
        )
    }
}

extension MachOFile.ObjectiveC {
    public var protocols64: [ObjCProtocol64]? {
        readProtocols64()?.values
    }

    public var protocols32: [ObjCProtocol32]? {
        readProtocols32()?.values
    }

    public var classes64: [ObjCClass64]? {
        readClasses64(section: .__objc_classlist, root: .classList)?.values
    }

    public var classes32: [ObjCClass32]? {
        readClasses32(section: .__objc_classlist, root: .classList)?.values
    }

    public var nonLazyClasses64: [ObjCClass64]? {
        readClasses64(section: .__objc_nlclslist, root: .nonLazyClassList)?.values
    }

    public var nonLazyClasses32: [ObjCClass32]? {
        readClasses32(section: .__objc_nlclslist, root: .nonLazyClassList)?.values
    }

    public var categories64: [ObjCCategory64]? {
        readCategories64(
            section: .__objc_catlist,
            root: .categoryList,
            isCatlist2: false
        )?.values
    }

    public var categories32: [ObjCCategory32]? {
        readCategories32(
            section: .__objc_catlist,
            root: .categoryList,
            isCatlist2: false
        )?.values
    }

    public var nonLazyCategories64: [ObjCCategory64]? {
        readCategories64(
            section: .__objc_nlcatlist,
            root: .nonLazyCategoryList,
            isCatlist2: false
        )?.values
    }

    public var nonLazyCategories32: [ObjCCategory32]? {
        readCategories32(
            section: .__objc_nlcatlist,
            root: .nonLazyCategoryList,
            isCatlist2: false
        )?.values
    }

    public var categories2_64: [ObjCCategory64]? {
        readCategories64(
            section: .__objc_catlist2,
            root: .categoryList2,
            isCatlist2: true
        )?.values
    }

    public var categories2_32: [ObjCCategory32]? {
        readCategories32(
            section: .__objc_catlist2,
            root: .categoryList2,
            isCatlist2: true
        )?.values
    }
}

extension MachOFile.ObjectiveC {
    internal func readClasses64(
        section sectionName: ObjCMachOSection,
        root: ObjCMetadataTableDiagnostic.FileRootSection
    ) -> ObjCRootTableRead<ObjCClass64>? {
        guard machO.is64Bit,
              let match = machO.findObjCSection64AndSegment(for: sectionName) else {
            return nil
        }
        return readRootTable(
            section: match.section,
            segment: match.segment,
            pointerType: UInt64.self,
            layoutType: ObjCClass64.Layout.self,
            root: root,
            pointerWidth: .bits64
        ) { layout, offset in
            ObjCClass64(layout: layout, offset: offset)
        }
    }

    internal func readClasses32(
        section sectionName: ObjCMachOSection,
        root: ObjCMetadataTableDiagnostic.FileRootSection
    ) -> ObjCRootTableRead<ObjCClass32>? {
        guard !machO.is64Bit,
              let match = machO.findObjCSection32AndSegment(for: sectionName) else {
            return nil
        }
        return readRootTable(
            section: match.section,
            segment: match.segment,
            pointerType: UInt32.self,
            layoutType: ObjCClass32.Layout.self,
            root: root,
            pointerWidth: .bits32
        ) { layout, offset in
            ObjCClass32(layout: layout, offset: offset)
        }
    }

    internal func readProtocols64() -> ObjCRootTableRead<ObjCProtocol64>? {
        guard machO.is64Bit,
              let match = machO.findObjCSection64AndSegment(for: .__objc_protolist) else {
            return nil
        }
        return readRootTable(
            section: match.section,
            segment: match.segment,
            pointerType: UInt64.self,
            layoutType: ObjCProtocol64.Layout.self,
            root: .protocolList,
            pointerWidth: .bits64
        ) { layout, offset in
            ObjCProtocol64(layout: layout, offset: offset)
        }
    }

    internal func readProtocols32() -> ObjCRootTableRead<ObjCProtocol32>? {
        guard !machO.is64Bit,
              let match = machO.findObjCSection32AndSegment(for: .__objc_protolist) else {
            return nil
        }
        return readRootTable(
            section: match.section,
            segment: match.segment,
            pointerType: UInt32.self,
            layoutType: ObjCProtocol32.Layout.self,
            root: .protocolList,
            pointerWidth: .bits32
        ) { layout, offset in
            ObjCProtocol32(layout: layout, offset: offset)
        }
    }

    internal func readCategories64(
        section sectionName: ObjCMachOSection,
        root: ObjCMetadataTableDiagnostic.FileRootSection,
        isCatlist2: Bool
    ) -> ObjCRootTableRead<ObjCCategory64>? {
        guard machO.is64Bit,
              let match = machO.findObjCSection64AndSegment(for: sectionName) else {
            return nil
        }
        return readRootTable(
            section: match.section,
            segment: match.segment,
            pointerType: UInt64.self,
            layoutType: ObjCCategory64.Layout.self,
            root: root,
            pointerWidth: .bits64
        ) { layout, offset in
            ObjCCategory64(
                layout: layout,
                offset: offset,
                isCatlist2: isCatlist2
            )
        }
    }

    internal func readCategories32(
        section sectionName: ObjCMachOSection,
        root: ObjCMetadataTableDiagnostic.FileRootSection,
        isCatlist2: Bool
    ) -> ObjCRootTableRead<ObjCCategory32>? {
        guard !machO.is64Bit,
              let match = machO.findObjCSection32AndSegment(for: sectionName) else {
            return nil
        }
        return readRootTable(
            section: match.section,
            segment: match.segment,
            pointerType: UInt32.self,
            layoutType: ObjCCategory32.Layout.self,
            root: root,
            pointerWidth: .bits32
        ) { layout, offset in
            ObjCCategory32(
                layout: layout,
                offset: offset,
                isCatlist2: isCatlist2
            )
        }
    }

    private func readRootTable<Pointer, Layout, Value>(
        section: Section64,
        segment: SegmentCommand64,
        pointerType: Pointer.Type,
        layoutType: Layout.Type,
        root: ObjCMetadataTableDiagnostic.FileRootSection,
        pointerWidth: ObjCMetadataTableDiagnostic.PointerWidth,
        makeValue: (Layout, Int) -> Value
    ) -> ObjCRootTableRead<Value> where Pointer: ObjCRootPointer {
        let owner = ObjCMetadataTableDiagnostic.Owner.fileRoot(
            section: root,
            pointerWidth: pointerWidth
        )
        guard let coordinates = checkedObjCSectionCoordinates(section, in: segment) else {
            return invalidCoordinatesResult(
                owner: owner,
                sectionAddress: section.layout.addr,
                sectionSize: section.layout.size,
                sectionFileOffset: UInt64(section.layout.offset),
                segmentAddress: segment.layout.vmaddr,
                segmentSize: segment.layout.vmsize,
                segmentFileOffset: segment.layout.fileoff,
                segmentFileSize: segment.layout.filesize
            )
        }
        let fileMappingFailure: ObjCMetadataTableDiagnostic.Failure? =
            if coordinates.mappedFileOffset == UInt64(section.layout.offset) {
                nil
            } else {
                .invalidSectionCoordinates(
                    sectionAddress: section.layout.addr,
                    sectionSize: section.layout.size,
                    sectionFileOffset: UInt64(section.layout.offset),
                    segmentAddress: segment.layout.vmaddr,
                    segmentSize: segment.layout.vmsize,
                    segmentFileOffset: segment.layout.fileoff,
                    segmentFileSize: segment.layout.filesize
                )
            }
        return readRootTable(
            section: coordinates,
            rawByteCount: section.layout.size,
            fileMappingFailure: fileMappingFailure,
            pointerType: pointerType,
            layoutType: layoutType,
            root: root,
            pointerWidth: pointerWidth,
            makeValue: makeValue
        )
    }

    private func readRootTable<Pointer, Layout, Value>(
        section: Section,
        segment: SegmentCommand,
        pointerType: Pointer.Type,
        layoutType: Layout.Type,
        root: ObjCMetadataTableDiagnostic.FileRootSection,
        pointerWidth: ObjCMetadataTableDiagnostic.PointerWidth,
        makeValue: (Layout, Int) -> Value
    ) -> ObjCRootTableRead<Value> where Pointer: ObjCRootPointer {
        let owner = ObjCMetadataTableDiagnostic.Owner.fileRoot(
            section: root,
            pointerWidth: pointerWidth
        )
        guard let coordinates = checkedObjCSectionCoordinates(section, in: segment) else {
            return invalidCoordinatesResult(
                owner: owner,
                sectionAddress: UInt64(section.layout.addr),
                sectionSize: UInt64(section.layout.size),
                sectionFileOffset: UInt64(section.layout.offset),
                segmentAddress: UInt64(segment.layout.vmaddr),
                segmentSize: UInt64(segment.layout.vmsize),
                segmentFileOffset: UInt64(segment.layout.fileoff),
                segmentFileSize: UInt64(segment.layout.filesize)
            )
        }
        let fileMappingFailure: ObjCMetadataTableDiagnostic.Failure? =
            if coordinates.mappedFileOffset == UInt64(section.layout.offset) {
                nil
            } else {
                .invalidSectionCoordinates(
                    sectionAddress: UInt64(section.layout.addr),
                    sectionSize: UInt64(section.layout.size),
                    sectionFileOffset: UInt64(section.layout.offset),
                    segmentAddress: UInt64(segment.layout.vmaddr),
                    segmentSize: UInt64(segment.layout.vmsize),
                    segmentFileOffset: UInt64(segment.layout.fileoff),
                    segmentFileSize: UInt64(segment.layout.filesize)
                )
            }
        return readRootTable(
            section: coordinates,
            rawByteCount: UInt64(section.layout.size),
            fileMappingFailure: fileMappingFailure,
            pointerType: pointerType,
            layoutType: layoutType,
            root: root,
            pointerWidth: pointerWidth,
            makeValue: makeValue
        )
    }

    private func invalidCoordinatesResult<Value>(
        owner: ObjCMetadataTableDiagnostic.Owner,
        sectionAddress: UInt64,
        sectionSize: UInt64,
        sectionFileOffset: UInt64,
        segmentAddress: UInt64,
        segmentSize: UInt64,
        segmentFileOffset: UInt64,
        segmentFileSize: UInt64
    ) -> ObjCRootTableRead<Value> {
        .init(
            values: [],
            diagnostics: [
                .init(
                    owner: owner,
                    site: .table(.init()),
                    failure: .invalidSectionCoordinates(
                        sectionAddress: sectionAddress,
                        sectionSize: sectionSize,
                        sectionFileOffset: sectionFileOffset,
                        segmentAddress: segmentAddress,
                        segmentSize: segmentSize,
                        segmentFileOffset: segmentFileOffset,
                        segmentFileSize: segmentFileSize
                    )
                )
            ]
        )
    }

    private func readRootTable<Pointer, Layout, Value>(
        section: CheckedObjCSectionCoordinates,
        rawByteCount: UInt64,
        fileMappingFailure: ObjCMetadataTableDiagnostic.Failure?,
        pointerType: Pointer.Type,
        layoutType: Layout.Type,
        root: ObjCMetadataTableDiagnostic.FileRootSection,
        pointerWidth: ObjCMetadataTableDiagnostic.PointerWidth,
        makeValue: (Layout, Int) -> Value
    ) -> ObjCRootTableRead<Value> where Pointer: ObjCRootPointer {
        let owner = ObjCMetadataTableDiagnostic.Owner.fileRoot(
            section: root,
            pointerWidth: pointerWidth
        )
        // A removed/coalesced empty section can retain offset zero at a segment
        // boundary. It is complete without a linear-mapping or backing lookup.
        guard rawByteCount > 0 else {
            return .init(values: [], diagnostics: [])
        }
        if let fileMappingFailure {
            return tableFailure(
                owner: owner,
                provenance: .init(),
                failure: fileMappingFailure
            )
        }
        let pointerSize = MemoryLayout<Pointer>.size
        guard rawByteCount.isMultiple(of: UInt64(pointerSize)) else {
            return tableFailure(
                owner: owner,
                provenance: .init(),
                failure: .invalidSectionByteCount(
                    byteCount: rawByteCount,
                    pointerSize: pointerSize
                )
            )
        }

        let rawCount = rawByteCount / UInt64(pointerSize)
        let count: Int
        switch ObjCMetadataTableReader.exactCount(rawCount) {
        case .success(let value):
            count = value
        case .failure(let failure):
            return tableFailure(
                owner: owner,
                provenance: .init(),
                failure: .init(failure)
            )
        }
        switch ObjCMetadataTableReader.checkedByteCount(
            count: count,
            stride: pointerSize
        ) {
        case .success:
            break
        case .failure(let failure):
            return tableFailure(
                owner: owner,
                provenance: .init(),
                failure: .init(failure)
            )
        }

        let logicalOffset: Int
        if machO.isLoadedFromDyldCache {
            guard let cache = machO.cache else {
                return tableFailure(
                    owner: owner,
                    provenance: .init(),
                    failure: .missingFileRootBackingData(
                        sectionAddress: section.address
                    )
                )
            }
            let sharedRegionStart = cache.mainCacheHeader.sharedRegionStart
            guard let exactLogicalOffset = checkedFileRootLogicalOffset(
                sectionAddress: section.address,
                sectionFileOffset: section.fileOffset,
                cacheSharedRegionStart: sharedRegionStart
            ) else {
                return tableFailure(
                    owner: owner,
                    provenance: .init(),
                    failure: .invalidFileRootOffset(
                        sectionAddress: section.address,
                        sharedRegionStart: sharedRegionStart
                    )
                )
            }
            logicalOffset = exactLogicalOffset
        } else {
            logicalOffset = section.fileOffset
        }

        let unresolvedProvenance = ObjCMetadataTableDiagnostic.Provenance(
            logicalOffset: logicalOffset
        )
        // This offset-domain API owns both ordinary headerStartOffset and the
        // main-cache-relative to actual subcache-local physical mapping.
        guard let rawLogicalOffset = UInt64(exactly: logicalOffset),
              let (file, fileOffset) = machO.fileHandleAndOffset(
                forOffset: rawLogicalOffset
              ) else {
            return tableFailure(
                owner: owner,
                provenance: unresolvedProvenance,
                failure: .missingFileRootBackingData(
                    sectionAddress: section.address
                )
            )
        }
        let tableProvenance = ObjCMetadataTableDiagnostic.Provenance(
            logicalOffset: logicalOffset,
            fileOffset: fileOffset
        )

        let pointerEntries: [ObjCMetadataTableEntry<Pointer>]
        switch ObjCMetadataTableReader.readFile(
            file,
            offset: fileOffset,
            logicalOffset: logicalOffset,
            count: count,
            stride: pointerSize,
            as: pointerType
        ) {
        case .success(let entries):
            pointerEntries = entries
        case .failure(let failure):
            return tableFailure(
                owner: owner,
                provenance: tableProvenance,
                failure: .init(failure)
            )
        }

        var values: [Value] = []
        var diagnostics: [ObjCMetadataTableDiagnostic] = []
        values.reserveCapacity(pointerEntries.count)
        for entry in pointerEntries {
            let entryProvenance = ObjCMetadataTableDiagnostic.Provenance(
                logicalOffset: entry.logicalOffset,
                fileOffset: entry.fileOffset
            )
            let rawPointer = entry.value.rootPointerValue
            guard rawPointer != 0 else {
                diagnostics.append(
                    entryFailure(
                        owner: owner,
                        entry: entry,
                        provenance: entryProvenance,
                        failure: .invalidPointer(rawValue: rawPointer)
                    )
                )
                continue
            }
            guard let entryLogicalOffset = entry.logicalOffset else {
                diagnostics.append(
                    entryFailure(
                        owner: owner,
                        entry: entry,
                        provenance: entryProvenance,
                        failure: .invalidEntryLogicalOffset
                    )
                )
                continue
            }
            let unresolved = UnresolvedValue(
                fieldOffset: entryLogicalOffset,
                value: rawPointer
            )
            guard let resolved = machO.resolveRebase(unresolved) else {
                diagnostics.append(
                    entryFailure(
                        owner: owner,
                        entry: entry,
                        provenance: entryProvenance,
                        failure: .unresolvedFileRootPointer(rawValue: rawPointer)
                    )
                )
                continue
            }
            guard let resolvedLogicalOffset = Int(exactly: resolved.offset) else {
                diagnostics.append(
                    entryFailure(
                        owner: owner,
                        entry: entry,
                        provenance: entryProvenance,
                        failure: .invalidReferencedFileOffset(resolved.offset)
                    )
                )
                continue
            }
            guard let (layoutFile, layoutFileOffset) = machO.fileHandleAndOffset(
                forResolvedValue: resolved
            ) else {
                diagnostics.append(
                    entryFailure(
                        owner: owner,
                        entry: entry,
                        provenance: entryProvenance,
                        failure: .missingReferencedFileBackingData(
                            logicalOffset: resolved.offset
                        )
                    )
                )
                continue
            }
            switch ObjCMetadataTableReader.readFileLayout(
                layoutFile,
                offset: layoutFileOffset,
                logicalOffset: resolvedLogicalOffset,
                as: layoutType
            ) {
            case .success(let layout):
                values.append(makeValue(layout, resolvedLogicalOffset))
            case .failure(let failure):
                diagnostics.append(
                    entryFailure(
                        owner: owner,
                        entry: entry,
                        provenance: entryProvenance,
                        failure: .init(failure)
                    )
                )
            }
        }

        return .init(values: values, diagnostics: diagnostics)
    }

    private func tableFailure<Value>(
        owner: ObjCMetadataTableDiagnostic.Owner,
        provenance: ObjCMetadataTableDiagnostic.Provenance,
        failure: ObjCMetadataTableDiagnostic.Failure
    ) -> ObjCRootTableRead<Value> {
        .init(
            values: [],
            diagnostics: [
                .init(
                    owner: owner,
                    site: .table(provenance),
                    failure: failure
                )
            ]
        )
    }

    private func entryFailure<Pointer>(
        owner: ObjCMetadataTableDiagnostic.Owner,
        entry: ObjCMetadataTableEntry<Pointer>,
        provenance: ObjCMetadataTableDiagnostic.Provenance,
        failure: ObjCMetadataTableDiagnostic.Failure
    ) -> ObjCMetadataTableDiagnostic {
        .init(
            owner: owner,
            site: .entry(index: entry.index, provenance: provenance),
            failure: failure
        )
    }
}
