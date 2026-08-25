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
    public let classes64: [ObjCClass64]?
    public let classes32: [ObjCClass32]?
    public let nonLazyClasses64: [ObjCClass64]?
    public let nonLazyClasses32: [ObjCClass32]?
    public let protocols64: [ObjCProtocol64]?
    public let protocols32: [ObjCProtocol32]?
    public let categories64: [ObjCCategory64]?
    public let categories32: [ObjCCategory32]?
    public let nonLazyCategories64: [ObjCCategory64]?
    public let nonLazyCategories32: [ObjCCategory32]?
    public let categories2_64: [ObjCCategory64]?
    public let categories2_32: [ObjCCategory32]?
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

internal struct ObjCLoadedRootTableRead<Value> {
    let values: [Value]
    let diagnostics: [ObjCMetadataTableDiagnostic]
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

        let reads: [AnyRootRead] = [
            classes64.map(AnyRootRead.init),
            classes32.map(AnyRootRead.init),
            nonLazyClasses64.map(AnyRootRead.init),
            nonLazyClasses32.map(AnyRootRead.init),
            protocols64.map(AnyRootRead.init),
            protocols32.map(AnyRootRead.init),
            categories64.map(AnyRootRead.init),
            categories32.map(AnyRootRead.init),
            nonLazyCategories64.map(AnyRootRead.init),
            nonLazyCategories32.map(AnyRootRead.init),
            categories2_64.map(AnyRootRead.init),
            categories2_32.map(AnyRootRead.init),
        ].compactMap { $0 }

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
            tableDiagnostics: reads.flatMap(\.diagnostics)
        )
    }
}

private struct AnyRootRead {
    let diagnostics: [ObjCMetadataTableDiagnostic]

    init<Value>(_ read: ObjCLoadedRootTableRead<Value>) {
        self.diagnostics = read.diagnostics
    }
}

extension MachOImage.ObjectiveC {
    internal func readClasses64(
        section sectionName: ObjCMachOSection,
        root: ObjCMetadataTableDiagnostic.LoadedImageRootSection
    ) -> ObjCLoadedRootTableRead<ObjCClass64>? {
        guard machO.is64Bit,
              let section = machO.findObjCSection64(for: sectionName) else {
            return nil
        }
        return readRootTable(
            rawAddress: section.layout.addr,
            rawByteCount: section.layout.size,
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
    ) -> ObjCLoadedRootTableRead<ObjCClass32>? {
        guard !machO.is64Bit,
              let section = machO.findObjCSection32(for: sectionName) else {
            return nil
        }
        return readRootTable(
            rawAddress: UInt64(section.layout.addr),
            rawByteCount: UInt64(section.layout.size),
            pointerType: UInt32.self,
            layoutType: ObjCClass32.Layout.self,
            root: root,
            pointerWidth: .bits32
        ) { layout, offset in
            ObjCClass32(layout: layout, offset: offset)
        }
    }

    internal func readProtocols64() -> ObjCLoadedRootTableRead<ObjCProtocol64>? {
        guard machO.is64Bit,
              let section = machO.findObjCSection64(for: .__objc_protolist) else {
            return nil
        }
        return readRootTable(
            rawAddress: section.layout.addr,
            rawByteCount: section.layout.size,
            pointerType: UInt64.self,
            layoutType: ObjCProtocol64.Layout.self,
            root: .protocolList,
            pointerWidth: .bits64
        ) { layout, offset in
            ObjCProtocol64(layout: layout, offset: offset)
        }
    }

    internal func readProtocols32() -> ObjCLoadedRootTableRead<ObjCProtocol32>? {
        guard !machO.is64Bit,
              let section = machO.findObjCSection32(for: .__objc_protolist) else {
            return nil
        }
        return readRootTable(
            rawAddress: UInt64(section.layout.addr),
            rawByteCount: UInt64(section.layout.size),
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
    ) -> ObjCLoadedRootTableRead<ObjCCategory64>? {
        guard machO.is64Bit,
              let section = machO.findObjCSection64(for: sectionName) else {
            return nil
        }
        return readRootTable(
            rawAddress: section.layout.addr,
            rawByteCount: section.layout.size,
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
    ) -> ObjCLoadedRootTableRead<ObjCCategory32>? {
        guard !machO.is64Bit,
              let section = machO.findObjCSection32(for: sectionName) else {
            return nil
        }
        return readRootTable(
            rawAddress: UInt64(section.layout.addr),
            rawByteCount: UInt64(section.layout.size),
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
        rawAddress: UInt64,
        rawByteCount: UInt64,
        pointerType: Pointer.Type,
        layoutType: Layout.Type,
        root: ObjCMetadataTableDiagnostic.LoadedImageRootSection,
        pointerWidth: ObjCMetadataTableDiagnostic.PointerWidth,
        makeValue: (Layout, Int) -> Value
    ) -> ObjCLoadedRootTableRead<Value> where Pointer: FixedWidthInteger {
        let subject = ObjCMetadataTableDiagnostic.Subject.loadedImageRoot(
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
                        subject: subject,
                        location: .table,
                        provenance: .init(),
                        failure: .invalidSectionByteCount(
                            byteCount: rawByteCount,
                            pointerSize: pointerSize
                        )
                    )
                ]
            )
        }
        guard let slide = machO.vmaddrSlide,
              let unslidAddress = UInt(exactly: rawAddress),
              let tableAddress = addingSignedDisplacement(slide, to: unslidAddress) else {
            return .init(
                values: [],
                diagnostics: [
                    .init(
                        subject: subject,
                        location: .table,
                        provenance: .init(),
                        failure: .invalidSectionAddress(
                            rawAddress: rawAddress,
                            slide: machO.vmaddrSlide ?? 0
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
                        subject: subject,
                        location: .table,
                        provenance: tableProvenance,
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
                        subject: subject,
                        location: .table,
                        provenance: tableProvenance,
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
            guard let rawPointer = UInt64(exactly: entry.value), rawPointer != 0,
                  let address = UInt(exactly: machO.stripPointerTags(of: rawPointer)) else {
                diagnostics.append(
                    .init(
                        subject: subject,
                        location: .entry(index: entry.index),
                        provenance: entryProvenance,
                        failure: .invalidPointer(
                            rawValue: UInt64(exactly: entry.value) ?? 0
                        )
                    )
                )
                continue
            }
            guard let offset = signedDisplacement(from: imageBase, to: address) else {
                diagnostics.append(
                    .init(
                        subject: subject,
                        location: .entry(index: entry.index),
                        provenance: entryProvenance,
                        failure: .invalidEntryArithmetic(
                            baseAddress: imageBase,
                            targetAddress: address
                        )
                    )
                )
                continue
            }
            switch ObjCMetadataTableReader.readImageLayout(
                address: address,
                as: layoutType
            ) {
            case .success(let layout):
                values.append(makeValue(layout, offset))
            case .failure:
                diagnostics.append(
                    .init(
                        subject: subject,
                        location: .entry(index: entry.index),
                        provenance: entryProvenance,
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
