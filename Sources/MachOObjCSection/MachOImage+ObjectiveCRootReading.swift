//
//  MachOImage+ObjectiveCRootReading.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit

/// The Objective-C root metadata discovered in one loaded Mach-O image.
///
/// Existing root properties remain the compatibility surface. Diagnostics SPI
/// consumers use this aggregate to retain ordered structural failures while
/// preserving every readable sibling root.
@_spi(Diagnostics)
public struct ObjCImageRootReadResult {
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

extension MachOImage.ObjectiveC {
    /// Reads all loaded Objective-C root sections and returns recoverable failures
    /// in the same section and entry discovery order as the root values.
    @_spi(Diagnostics)
    public func readRoots() -> ObjCImageRootReadResult {
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

        return ObjCImageRootReadResult(
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

extension MachOImage.ObjectiveC {
    internal func readClasses64(
        section sectionName: ObjCMachOSection,
        root: ObjCMetadataTableDiagnostic.LoadedImageRootSection
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
        root: ObjCMetadataTableDiagnostic.LoadedImageRootSection
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
        root: ObjCMetadataTableDiagnostic.LoadedImageRootSection,
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
        root: ObjCMetadataTableDiagnostic.LoadedImageRootSection,
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
        root: ObjCMetadataTableDiagnostic.LoadedImageRootSection,
        pointerWidth: ObjCMetadataTableDiagnostic.PointerWidth,
        makeValue: (Layout, Int) -> Value
    ) -> ObjCRootTableRead<Value> where Pointer: ObjCRootPointer {
        let owner = ObjCMetadataTableDiagnostic.Owner.loadedImageRoot(
            section: root,
            pointerWidth: pointerWidth
        )
        guard let coordinates = checkedObjCSectionCoordinates(section, in: segment) else {
            return .init(
                values: [],
                diagnostics: [
                    .init(
                        owner: owner,
                        site: .table(.init()),
                        failure: .invalidSectionCoordinates(
                            sectionAddress: section.layout.addr,
                            sectionSize: section.layout.size,
                            sectionFileOffset: UInt64(section.layout.offset),
                            segmentAddress: segment.layout.vmaddr,
                            segmentSize: segment.layout.vmsize,
                            segmentFileOffset: segment.layout.fileoff,
                            segmentFileSize: segment.layout.filesize
                        )
                    )
                ]
            )
        }
        guard let imageBaseSegment = machO.loadCommands.text64 else {
            return .init(
                values: [],
                diagnostics: [
                    .init(
                        owner: owner,
                        site: .table(.init()),
                        failure: .missingImageBaseSegment
                    )
                ]
            )
        }
        return readRootTable(
            section: coordinates,
            rawByteCount: section.layout.size,
            imageVirtualMemoryAddress: imageBaseSegment.layout.vmaddr,
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
        root: ObjCMetadataTableDiagnostic.LoadedImageRootSection,
        pointerWidth: ObjCMetadataTableDiagnostic.PointerWidth,
        makeValue: (Layout, Int) -> Value
    ) -> ObjCRootTableRead<Value> where Pointer: ObjCRootPointer {
        let owner = ObjCMetadataTableDiagnostic.Owner.loadedImageRoot(
            section: root,
            pointerWidth: pointerWidth
        )
        guard let coordinates = checkedObjCSectionCoordinates(section, in: segment) else {
            return .init(
                values: [],
                diagnostics: [
                    .init(
                        owner: owner,
                        site: .table(.init()),
                        failure: .invalidSectionCoordinates(
                            sectionAddress: UInt64(section.layout.addr),
                            sectionSize: UInt64(section.layout.size),
                            sectionFileOffset: UInt64(section.layout.offset),
                            segmentAddress: UInt64(segment.layout.vmaddr),
                            segmentSize: UInt64(segment.layout.vmsize),
                            segmentFileOffset: UInt64(segment.layout.fileoff),
                            segmentFileSize: UInt64(segment.layout.filesize)
                        )
                    )
                ]
            )
        }
        guard let imageBaseSegment = machO.loadCommands.text else {
            return .init(
                values: [],
                diagnostics: [
                    .init(
                        owner: owner,
                        site: .table(.init()),
                        failure: .missingImageBaseSegment
                    )
                ]
            )
        }
        return readRootTable(
            section: coordinates,
            rawByteCount: UInt64(section.layout.size),
            imageVirtualMemoryAddress: UInt64(imageBaseSegment.layout.vmaddr),
            pointerType: pointerType,
            layoutType: layoutType,
            root: root,
            pointerWidth: pointerWidth,
            makeValue: makeValue
        )
    }

    private func readRootTable<Pointer, Layout, Value>(
        section: CheckedObjCSectionCoordinates,
        rawByteCount: UInt64,
        imageVirtualMemoryAddress: UInt64,
        pointerType: Pointer.Type,
        layoutType: Layout.Type,
        root: ObjCMetadataTableDiagnostic.LoadedImageRootSection,
        pointerWidth: ObjCMetadataTableDiagnostic.PointerWidth,
        makeValue: (Layout, Int) -> Value
    ) -> ObjCRootTableRead<Value> where Pointer: ObjCRootPointer {
        let owner = ObjCMetadataTableDiagnostic.Owner.loadedImageRoot(
            section: root,
            pointerWidth: pointerWidth
        )
        let imageBase = UInt(bitPattern: machO.ptr)
        guard let tableAddress = section.loadedImageAddress(
            relativeTo: imageBase,
            imageVirtualMemoryAddress: imageVirtualMemoryAddress
        ) else {
            return .init(
                values: [],
                diagnostics: [
                    .init(
                        owner: owner,
                        site: .table(.init()),
                        failure: .invalidLoadedSectionAddress(
                            imageBase: imageBase,
                            imageVirtualMemoryAddress: imageVirtualMemoryAddress,
                            sectionAddress: section.address
                        )
                    )
                ]
            )
        }
        return readRootTable(
            tableAddress: tableAddress,
            rawByteCount: rawByteCount,
            pointerType: pointerType,
            layoutType: layoutType,
            root: root,
            pointerWidth: pointerWidth,
            layoutReader: { address in
                ObjCMetadataTableReader.readImageLayout(
                    address: address,
                    as: layoutType
                )
            },
            makeValue: makeValue
        )
    }

    internal func readRootTable<Pointer, Layout, Value>(
        tableAddress: UInt,
        rawByteCount: UInt64,
        pointerType: Pointer.Type,
        layoutType: Layout.Type,
        root: ObjCMetadataTableDiagnostic.LoadedImageRootSection,
        pointerWidth: ObjCMetadataTableDiagnostic.PointerWidth,
        layoutReader: (UInt) -> ObjCMetadataTableRead<Layout>,
        makeValue: (Layout, Int) -> Value
    ) -> ObjCRootTableRead<Value> where Pointer: ObjCRootPointer {
        let owner = ObjCMetadataTableDiagnostic.Owner.loadedImageRoot(
            section: root,
            pointerWidth: pointerWidth
        )
        let pointerSize = MemoryLayout<Pointer>.size
        let imageBase = UInt(bitPattern: machO.ptr)

        guard rawByteCount.isMultiple(of: UInt64(pointerSize)) else {
            return .init(
                values: [],
                diagnostics: [
                    .init(
                        owner: owner,
                        site: .table(.init()),
                        failure: .invalidSectionByteCount(
                            byteCount: rawByteCount,
                            pointerSize: pointerSize
                        )
                    )
                ]
            )
        }
        let tableOffset = signedDisplacement(from: imageBase, to: tableAddress)
        let tableProvenance = ObjCMetadataTableDiagnostic.Provenance(
            logicalOffset: tableOffset,
            imageAddress: tableAddress
        )
        let rawCount = rawByteCount / UInt64(pointerSize)
        let count: Int
        switch ObjCMetadataTableReader.exactCount(rawCount) {
        case .success(let value):
            count = value
        case .failure(let failure):
            return .init(
                values: [],
                diagnostics: [
                    .init(
                        owner: owner,
                        site: .table(tableProvenance),
                        failure: .init(failure)
                    )
                ]
            )
        }

        let pointerEntries: [ObjCMetadataTableEntry<Pointer>]
        switch ObjCMetadataTableReader.readImage(
            address: tableAddress,
            logicalOffset: tableOffset,
            count: count,
            stride: pointerSize,
            as: pointerType
        ) {
        case .success(let entries):
            pointerEntries = entries
        case .failure(let failure):
            return .init(
                values: [],
                diagnostics: [
                    .init(
                        owner: owner,
                        site: .table(tableProvenance),
                        failure: .init(failure)
                    )
                ]
            )
        }

        var values: [Value] = []
        var diagnostics: [ObjCMetadataTableDiagnostic] = []
        values.reserveCapacity(pointerEntries.count)
        for entry in pointerEntries {
            let entryProvenance = ObjCMetadataTableDiagnostic.Provenance(
                logicalOffset: entry.logicalOffset,
                imageAddress: entry.address
            )
            let rawPointer = entry.value.rootPointerValue
            guard rawPointer != 0 else {
                diagnostics.append(
                    .init(
                        owner: owner,
                        site: .entry(
                            index: entry.index,
                            provenance: entryProvenance
                        ),
                        failure: .invalidPointer(rawValue: rawPointer)
                    )
                )
                continue
            }
            let strippedAddress = machO.stripPointerTags(of: rawPointer)
            guard strippedAddress != 0,
                  let address = UInt(exactly: strippedAddress) else {
                diagnostics.append(
                    .init(
                        owner: owner,
                        site: .entry(
                            index: entry.index,
                            provenance: entryProvenance
                        ),
                        failure: .invalidPointer(rawValue: rawPointer)
                    )
                )
                continue
            }
            guard let offset = signedDisplacement(from: imageBase, to: address) else {
                diagnostics.append(
                    .init(
                        owner: owner,
                        site: .entry(
                            index: entry.index,
                            provenance: entryProvenance
                        ),
                        failure: .invalidEntryArithmetic(
                            baseAddress: imageBase,
                            targetAddress: address
                        )
                    )
                )
                continue
            }
            let layoutRead = layoutReader(address)
            switch layoutRead {
            case .success(let layout):
                values.append(makeValue(layout, offset))
            case .failure:
                diagnostics.append(
                    .init(
                        owner: owner,
                        site: .entry(
                            index: entry.index,
                            provenance: entryProvenance
                        ),
                        failure: .unreadableReferencedLayout(
                            address: address,
                            byteCount: MemoryLayout<Layout>.size
                        )
                    )
                )
            }
        }

        return .init(values: values, diagnostics: diagnostics)
    }
}
