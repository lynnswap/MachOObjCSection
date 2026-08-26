import Foundation
import MachOKit
@_spi(Core) @_spi(Diagnostics) @testable import MachOObjCSection
import XCTest

final class ObjCFileRootSafetyTests: XCTestCase {
    func testCacheLogicalOffsetUsesMainSharedRegionDomain() {
        let sharedRegionStart: UInt64 = 0x1_0000_0000
        XCTAssertEqual(
            checkedFileRootLogicalOffset(
                sectionAddress: sharedRegionStart + 0x400,
                sectionFileOffset: 0x900,
                cacheSharedRegionStart: sharedRegionStart
            ),
            0x400
        )
        XCTAssertNil(
            checkedFileRootLogicalOffset(
                sectionAddress: sharedRegionStart - 1,
                sectionFileOffset: 0x900,
                cacheSharedRegionStart: sharedRegionStart
            )
        )
        XCTAssertNil(
            checkedFileRootLogicalOffset(
                sectionAddress: sharedRegionStart + UInt64(UInt32.max),
                sectionFileOffset: 0x900,
                cacheSharedRegionStart: sharedRegionStart,
                maximumIntValue: UInt64(Int32.max)
            )
        )
        XCTAssertEqual(
            checkedFileRootLogicalOffset(
                sectionAddress: .max,
                sectionFileOffset: 0x900,
                cacheSharedRegionStart: nil
            ),
            0x900
        )
    }

    func testAllFileRootSectionsUseTheSharedCheckedReaderFor32And64() throws {
        for architecture in FileRootArchitecture.allCases {
            for root in FileRootFixtureSection.allCases {
                let fixture = try FileRootFixture(
                    architecture: architecture,
                    root: root,
                    sectionByteCount: UInt64(architecture.pointerSize)
                ) { data, base in
                    let targetAddress = architecture.virtualMemoryAddress
                        + UInt64(FileRootFixture.layoutOffset)
                    data.storeRootPointer(
                        targetAddress,
                        architecture: architecture,
                        at: base + FileRootFixture.tableOffset
                    )
                    data.storeRootLayout(
                        architecture: architecture,
                        root: root,
                        at: base + FileRootFixture.layoutOffset
                    )
                }

                let result = fixture.machO.objc.readRoots()

                XCTAssertEqual(
                    result.count(for: root, architecture: architecture),
                    1,
                    "Unexpected aggregate result for \(architecture) / \(root)"
                )
                XCTAssertEqual(
                    fixture.machO.objc.legacyCount(
                        for: root,
                        architecture: architecture
                    ),
                    1,
                    "Unexpected legacy result for \(architecture) / \(root)"
                )
                XCTAssertTrue(result.tableDiagnostics.isEmpty)
                XCTAssertTrue(
                    result.wrongBitnessIsNil(
                        for: root,
                        architecture: architecture
                    )
                )
                if root == .categoryList2 {
                    XCTAssertEqual(
                        result.category2Flag(architecture: architecture),
                        true
                    )
                }
            }
        }
    }

    func testFileClassRootsPreserveGoodBadGoodAndLegacyProjection() throws {
        let fixture = try FileRootFixture(
            architecture: .bit64,
            root: .classList,
            sectionByteCount: UInt64(3 * MemoryLayout<UInt64>.size),
            headerPrefix: 257
        ) { data, base in
            let firstAddress = FileRootArchitecture.bit64.virtualMemoryAddress
                + UInt64(FileRootFixture.layoutOffset)
            let secondLayoutOffset = FileRootFixture.layoutOffset
                + MemoryLayout<ObjCClass64.Layout>.stride
            let secondAddress = FileRootArchitecture.bit64.virtualMemoryAddress
                + UInt64(secondLayoutOffset)
            let invalidAddress = FileRootArchitecture.bit64.virtualMemoryAddress
                + UInt64(FileRootFixture.fileSize + 0x100)
            data.store(UInt64(firstAddress), at: base + FileRootFixture.tableOffset)
            data.store(
                UInt64(invalidAddress),
                at: base + FileRootFixture.tableOffset + MemoryLayout<UInt64>.size
            )
            data.store(
                UInt64(secondAddress),
                at: base + FileRootFixture.tableOffset + 2 * MemoryLayout<UInt64>.size
            )
            data.store(Self.class64Layout(isa: 0x11), at: base + FileRootFixture.layoutOffset)
            data.store(Self.class64Layout(isa: 0x22), at: base + secondLayoutOffset)
        }

        let result = fixture.machO.objc.readRoots()

        XCTAssertEqual(result.classes64?.map(\.layout.isa), [0x11, 0x22])
        XCTAssertEqual(fixture.machO.objc.classes64?.map(\.layout.isa), [0x11, 0x22])
        XCTAssertEqual(result.tableDiagnostics.count, 1)
        XCTAssertEqual(
            result.tableDiagnostics.first?.owner,
            .fileRoot(section: .classList, pointerWidth: .bits64)
        )
        guard case let .entry(index, provenance) = result.tableDiagnostics.first?.site else {
            return XCTFail("Expected the malformed middle root entry")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(
            provenance.logicalOffset,
            FileRootFixture.tableOffset + MemoryLayout<UInt64>.size
        )
        XCTAssertEqual(
            provenance.fileOffset,
            UInt64(257 + FileRootFixture.tableOffset + MemoryLayout<UInt64>.size)
        )
        guard case .unresolvedFileRootPointer = result.tableDiagnostics.first?.failure else {
            return XCTFail("Expected an unresolved file root pointer")
        }
    }

    func testReferencedLayoutsAcceptExactBoundaryAndRejectOneByteTruncation() throws {
        let exactOffset = FileRootFixture.fileSize - MemoryLayout<ObjCClass64.Layout>.size
        let truncatedOffset = exactOffset + 1
        let fixture = try FileRootFixture(
            architecture: .bit64,
            root: .classList,
            sectionByteCount: UInt64(2 * MemoryLayout<UInt64>.size)
        ) { data, base in
            let vmaddr = FileRootArchitecture.bit64.virtualMemoryAddress
            data.store(UInt64(vmaddr + UInt64(exactOffset)), at: base + FileRootFixture.tableOffset)
            data.store(
                UInt64(vmaddr + UInt64(truncatedOffset)),
                at: base + FileRootFixture.tableOffset + MemoryLayout<UInt64>.size
            )
            data.store(Self.class64Layout(isa: 0x44), at: base + exactOffset)
        }

        let result = fixture.machO.objc.readRoots()

        XCTAssertEqual(result.classes64?.map(\.layout.isa), [0x44])
        guard result.tableDiagnostics.count == 1,
              case .entry(index: 1, provenance: _) = result.tableDiagnostics[0].site,
              case let .unreadableFileRange(offset, byteCount) =
                result.tableDiagnostics[0].failure else {
            return XCTFail("Only the one-byte-truncated referenced layout should fail")
        }
        XCTAssertEqual(offset, UInt64(truncatedOffset))
        XCTAssertEqual(byteCount, MemoryLayout<ObjCClass64.Layout>.size)
    }

    func testAbsentWrongBitnessAndEmptySectionsRemainDistinct() throws {
        let absent = try FileRootFixture(
            architecture: .bit64,
            root: .protocolList,
            sectionByteCount: 0
        )
        let absentResult = absent.machO.objc.readRoots()
        XCTAssertNil(absentResult.classes64)
        XCTAssertNil(absentResult.protocols32)
        XCTAssertEqual(absentResult.protocols64?.count, 0)
        XCTAssertTrue(absentResult.tableDiagnostics.isEmpty)

        for architecture in FileRootArchitecture.allCases {
            let emptyMismatch = try FileRootFixture(
                architecture: architecture,
                root: .classList,
                sectionByteCount: 0,
                sectionFileOffset: 0
            )
            let result = emptyMismatch.machO.objc.readRoots()
            XCTAssertEqual(
                result.count(for: .classList, architecture: architecture),
                0
            )
            XCTAssertTrue(result.tableDiagnostics.isEmpty)
        }
    }

    func testMalformedTableRangeRemainderAndBudgetAreWholeTableFailures() throws {
        let truncated = try FileRootFixture(
            architecture: .bit64,
            root: .classList,
            sectionByteCount: UInt64(2 * MemoryLayout<UInt64>.size),
            sectionFileOffset: FileRootFixture.fileSize - MemoryLayout<UInt64>.size,
            sectionVirtualMemoryOffset: FileRootFixture.fileSize - MemoryLayout<UInt64>.size,
            declaredSegmentSize: FileRootFixture.fileSize + MemoryLayout<UInt64>.size
        )
        let truncatedResult = truncated.machO.objc.readRoots()
        guard case let .unreadableFileRange(offset, byteCount) =
            truncatedResult.tableDiagnostics.first?.failure else {
            return XCTFail("Expected a truncated whole root table")
        }
        XCTAssertEqual(offset, UInt64(FileRootFixture.fileSize - MemoryLayout<UInt64>.size))
        XCTAssertEqual(byteCount, 2 * MemoryLayout<UInt64>.size)

        let remainder = try FileRootFixture(
            architecture: .bit32,
            root: .classList,
            sectionByteCount: UInt64(MemoryLayout<UInt32>.size + 1)
        )
        guard case let .invalidSectionByteCount(byteCount, pointerSize) =
            remainder.machO.objc.readRoots().tableDiagnostics.first?.failure else {
            return XCTFail("Expected a pointer-size remainder failure")
        }
        XCTAssertEqual(byteCount, UInt64(MemoryLayout<UInt32>.size + 1))
        XCTAssertEqual(pointerSize, MemoryLayout<UInt32>.size)

        for architecture in FileRootArchitecture.allCases {
            let excessiveByteCount = UInt64(
                (ObjCMetadataReadLimits.maximumListEntries + 1)
                    * architecture.pointerSize
            )
            let budget = try FileRootFixture(
                architecture: architecture,
                root: .classList,
                sectionByteCount: excessiveByteCount,
                declaredSegmentSize: FileRootFixture.tableOffset + Int(excessiveByteCount)
            )
            guard case let .excessiveElementCount(actual, maximum) =
                budget.machO.objc.readRoots().tableDiagnostics.first?.failure else {
                return XCTFail("The shared budget must run before backing range checks")
            }
            XCTAssertEqual(actual, ObjCMetadataReadLimits.maximumListEntries + 1)
            XCTAssertEqual(maximum, ObjCMetadataReadLimits.maximumListEntries)
        }
    }

    func testRaw32And64CoordinatesAndNonemptyMappingMismatchAreTypedFailures() throws {
        let overflow64 = try FileRootFixture(
            architecture: .bit64,
            root: .classList,
            sectionByteCount: UInt64.max,
            declaredSegmentSize64: UInt64.max
        )
        guard case let .invalidSectionCoordinates(_, sectionSize, _, _, _, _, _) =
            overflow64.machO.objc.readRoots().tableDiagnostics.first?.failure else {
            return XCTFail("A 64-bit raw size overflow must be typed")
        }
        XCTAssertEqual(sectionSize, UInt64.max)

        let invalid32 = try FileRootFixture(
            architecture: .bit32,
            root: .classList,
            sectionByteCount: UInt64(MemoryLayout<UInt32>.size),
            sectionAddress32: UInt32.max
        )
        guard case let .invalidSectionCoordinates(sectionAddress, _, _, _, _, _, _) =
            invalid32.machO.objc.readRoots().tableDiagnostics.first?.failure else {
            return XCTFail("A malformed 32-bit raw address must be typed")
        }
        XCTAssertEqual(sectionAddress, UInt64(UInt32.max))

        for architecture in FileRootArchitecture.allCases {
            let mismatch = try FileRootFixture(
                architecture: architecture,
                root: .classList,
                sectionByteCount: UInt64(architecture.pointerSize + 1),
                sectionFileOffset: FileRootFixture.tableOffset + architecture.pointerSize
            )
            guard case .invalidSectionCoordinates =
                mismatch.machO.objc.readRoots().tableDiagnostics.first?.failure else {
                return XCTFail("A nonempty section/file mapping mismatch must be rejected")
            }
        }
    }

    private static func class64Layout(isa: UInt64) -> ObjCClass64.Layout {
        .init(
            isa: isa,
            superclass: 0,
            methodCacheBuckets: 0,
            methodCacheProperties: 0,
            dataVMAddrAndFastFlags: 0,
            swiftClassFlags: 0
        )
    }
}

private enum FileRootArchitecture: CaseIterable, CustomStringConvertible {
    case bit32
    case bit64

    var pointerSize: Int {
        switch self {
        case .bit32: MemoryLayout<UInt32>.size
        case .bit64: MemoryLayout<UInt64>.size
        }
    }

    var virtualMemoryAddress: UInt64 {
        switch self {
        case .bit32: 0x1000_0000
        case .bit64: 0x1_0000_0000
        }
    }

    var description: String {
        switch self {
        case .bit32: "32-bit"
        case .bit64: "64-bit"
        }
    }
}

private enum FileRootFixtureSection: CaseIterable, CustomStringConvertible {
    case classList
    case nonLazyClassList
    case protocolList
    case categoryList
    case nonLazyCategoryList
    case categoryList2

    var name: String {
        switch self {
        case .classList: "__objc_classlist"
        case .nonLazyClassList: "__objc_nlclslist"
        case .protocolList: "__objc_protolist"
        case .categoryList: "__objc_catlist"
        case .nonLazyCategoryList: "__objc_nlcatlist"
        case .categoryList2: "__objc_catlist2"
        }
    }

    var description: String { name }
}

private final class FileRootFixture {
    static let fileSize = 0x1000
    static let tableOffset = 0x400
    static let layoutOffset = 0x800

    let machO: MachOFile
    private let url: URL

    init(
        architecture: FileRootArchitecture,
        root: FileRootFixtureSection,
        sectionByteCount: UInt64,
        fileSize: Int = FileRootFixture.fileSize,
        headerPrefix: Int = 0,
        sectionFileOffset: Int = FileRootFixture.tableOffset,
        sectionVirtualMemoryOffset: Int = FileRootFixture.tableOffset,
        declaredSegmentSize: Int? = nil,
        declaredSegmentSize64: UInt64? = nil,
        sectionAddress32: UInt32? = nil,
        populate: ((inout Data, Int) -> Void)? = nil
    ) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MachOObjCSection-file-roots-\(UUID().uuidString)"
        )
        var data = Data(count: headerPrefix + fileSize)
        switch architecture {
        case .bit64:
            Self.write64(
                into: &data,
                base: headerPrefix,
                root: root,
                sectionByteCount: sectionByteCount,
                sectionFileOffset: sectionFileOffset,
                sectionVirtualMemoryOffset: sectionVirtualMemoryOffset,
                declaredSegmentSize: declaredSegmentSize,
                declaredSegmentSize64: declaredSegmentSize64
            )
        case .bit32:
            Self.write32(
                into: &data,
                base: headerPrefix,
                root: root,
                sectionByteCount: sectionByteCount,
                sectionFileOffset: sectionFileOffset,
                sectionVirtualMemoryOffset: sectionVirtualMemoryOffset,
                declaredSegmentSize: declaredSegmentSize,
                sectionAddress: sectionAddress32
            )
        }
        populate?(&data, headerPrefix)
        try data.write(to: url)
        machO = try MachOFile(url: url, headerStartOffset: headerPrefix)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    private static func write64(
        into data: inout Data,
        base: Int,
        root: FileRootFixtureSection,
        sectionByteCount: UInt64,
        sectionFileOffset: Int,
        sectionVirtualMemoryOffset: Int,
        declaredSegmentSize: Int?,
        declaredSegmentSize64: UInt64?
    ) {
        var header = mach_header_64()
        header.magic = UInt32(MH_MAGIC_64)
        header.cputype = CPU_TYPE_ARM64
        header.cpusubtype = CPU_SUBTYPE_ARM64_ALL
        header.filetype = UInt32(MH_DYLIB)
        header.ncmds = 1
        header.sizeofcmds = UInt32(
            MemoryLayout<segment_command_64>.size + MemoryLayout<section_64>.size
        )
        data.store(header, at: base)

        let segmentSize = declaredSegmentSize64
            ?? UInt64(declaredSegmentSize ?? fileSize)
        var segment = segment_command_64()
        segment.cmd = UInt32(LC_SEGMENT_64)
        segment.cmdsize = UInt32(header.sizeofcmds)
        setFileRootMachOName("__DATA", in: &segment.segname)
        segment.vmaddr = FileRootArchitecture.bit64.virtualMemoryAddress
        segment.vmsize = segmentSize
        segment.fileoff = 0
        segment.filesize = segmentSize
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        segment.nsects = 1
        data.store(segment, at: base + MemoryLayout<mach_header_64>.size)

        var section = section_64()
        setFileRootMachOName(root.name, in: &section.sectname)
        setFileRootMachOName("__DATA", in: &section.segname)
        section.addr = segment.vmaddr + UInt64(sectionVirtualMemoryOffset)
        section.size = sectionByteCount
        section.offset = UInt32(truncatingIfNeeded: sectionFileOffset)
        section.align = 3
        data.store(
            section,
            at: base + MemoryLayout<mach_header_64>.size
                + MemoryLayout<segment_command_64>.size
        )
    }

    private static func write32(
        into data: inout Data,
        base: Int,
        root: FileRootFixtureSection,
        sectionByteCount: UInt64,
        sectionFileOffset: Int,
        sectionVirtualMemoryOffset: Int,
        declaredSegmentSize: Int?,
        sectionAddress: UInt32?
    ) {
        var header = mach_header()
        header.magic = UInt32(MH_MAGIC)
        header.cputype = CPU_TYPE_I386
        header.cpusubtype = 3
        header.filetype = UInt32(MH_DYLIB)
        header.ncmds = 1
        header.sizeofcmds = UInt32(
            MemoryLayout<segment_command>.size + MemoryLayout<section>.size
        )
        data.store(header, at: base)

        let segmentSize = UInt32(declaredSegmentSize ?? fileSize)
        var segment = segment_command()
        segment.cmd = UInt32(LC_SEGMENT)
        segment.cmdsize = UInt32(header.sizeofcmds)
        setFileRootMachOName("__DATA", in: &segment.segname)
        segment.vmaddr = UInt32(FileRootArchitecture.bit32.virtualMemoryAddress)
        segment.vmsize = segmentSize
        segment.fileoff = 0
        segment.filesize = segmentSize
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        segment.nsects = 1
        data.store(segment, at: base + MemoryLayout<mach_header>.size)

        var rootSection = section()
        setFileRootMachOName(root.name, in: &rootSection.sectname)
        setFileRootMachOName("__DATA", in: &rootSection.segname)
        rootSection.addr = sectionAddress
            ?? segment.vmaddr + UInt32(sectionVirtualMemoryOffset)
        rootSection.size = UInt32(sectionByteCount)
        rootSection.offset = UInt32(sectionFileOffset)
        rootSection.align = 2
        data.store(
            rootSection,
            at: base + MemoryLayout<mach_header>.size
                + MemoryLayout<segment_command>.size
        )
    }
}

private extension Data {
    mutating func store<Value>(_ value: Value, at offset: Int) {
        var value = value
        Swift.withUnsafeBytes(of: &value) { bytes in
            replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }

    mutating func storeRootPointer(
        _ value: UInt64,
        architecture: FileRootArchitecture,
        at offset: Int
    ) {
        switch architecture {
        case .bit32: store(UInt32(value), at: offset)
        case .bit64: store(value, at: offset)
        }
    }

    mutating func storeRootLayout(
        architecture: FileRootArchitecture,
        root: FileRootFixtureSection,
        at offset: Int
    ) {
        switch (architecture, root) {
        case (.bit64, .classList), (.bit64, .nonLazyClassList):
            store(
                ObjCClass64.Layout(
                    isa: 1,
                    superclass: 0,
                    methodCacheBuckets: 0,
                    methodCacheProperties: 0,
                    dataVMAddrAndFastFlags: 0,
                    swiftClassFlags: 0
                ),
                at: offset
            )
        case (.bit32, .classList), (.bit32, .nonLazyClassList):
            store(
                ObjCClass32.Layout(
                    isa: 1,
                    superclass: 0,
                    methodCacheBuckets: 0,
                    methodCacheProperties: 0,
                    dataVMAddrAndFastFlags: 0,
                    swiftClassFlags: 0
                ),
                at: offset
            )
        case (.bit64, .protocolList):
            store(
                ObjCProtocol64.Layout(
                    isa: 0,
                    mangledName: 0,
                    protocols: 0,
                    instanceMethods: 0,
                    classMethods: 0,
                    optionalInstanceMethods: 0,
                    optionalClassMethods: 0,
                    instanceProperties: 0,
                    size: UInt32(MemoryLayout<ObjCProtocol64.Layout>.size),
                    flags: 0,
                    _extendedMethodTypes: 0,
                    _demangledName: 0,
                    _classProperties: 0
                ),
                at: offset
            )
        case (.bit32, .protocolList):
            store(
                ObjCProtocol32.Layout(
                    isa: 0,
                    mangledName: 0,
                    protocols: 0,
                    instanceMethods: 0,
                    classMethods: 0,
                    optionalInstanceMethods: 0,
                    optionalClassMethods: 0,
                    instanceProperties: 0,
                    size: UInt32(MemoryLayout<ObjCProtocol32.Layout>.size),
                    flags: 0,
                    _extendedMethodTypes: 0,
                    _demangledName: 0,
                    _classProperties: 0
                ),
                at: offset
            )
        case (.bit64, _):
            store(
                ObjCCategory64.Layout(
                    name: 0,
                    cls: 0,
                    instanceMethods: 0,
                    classMethods: 0,
                    protocols: 0,
                    instanceProperties: 0,
                    _classProperties: 0
                ),
                at: offset
            )
        case (.bit32, _):
            store(
                ObjCCategory32.Layout(
                    name: 0,
                    cls: 0,
                    instanceMethods: 0,
                    classMethods: 0,
                    protocols: 0,
                    instanceProperties: 0,
                    _classProperties: 0
                ),
                at: offset
            )
        }
    }
}

private extension ObjCFileRootReadResult {
    func count(
        for root: FileRootFixtureSection,
        architecture: FileRootArchitecture
    ) -> Int? {
        switch (architecture, root) {
        case (.bit64, .classList): classes64?.count
        case (.bit32, .classList): classes32?.count
        case (.bit64, .nonLazyClassList): nonLazyClasses64?.count
        case (.bit32, .nonLazyClassList): nonLazyClasses32?.count
        case (.bit64, .protocolList): protocols64?.count
        case (.bit32, .protocolList): protocols32?.count
        case (.bit64, .categoryList): categories64?.count
        case (.bit32, .categoryList): categories32?.count
        case (.bit64, .nonLazyCategoryList): nonLazyCategories64?.count
        case (.bit32, .nonLazyCategoryList): nonLazyCategories32?.count
        case (.bit64, .categoryList2): categories2_64?.count
        case (.bit32, .categoryList2): categories2_32?.count
        }
    }

    func wrongBitnessIsNil(
        for root: FileRootFixtureSection,
        architecture: FileRootArchitecture
    ) -> Bool {
        switch (architecture, root) {
        case (.bit64, .classList): classes32 == nil
        case (.bit32, .classList): classes64 == nil
        case (.bit64, .nonLazyClassList): nonLazyClasses32 == nil
        case (.bit32, .nonLazyClassList): nonLazyClasses64 == nil
        case (.bit64, .protocolList): protocols32 == nil
        case (.bit32, .protocolList): protocols64 == nil
        case (.bit64, .categoryList): categories32 == nil
        case (.bit32, .categoryList): categories64 == nil
        case (.bit64, .nonLazyCategoryList): nonLazyCategories32 == nil
        case (.bit32, .nonLazyCategoryList): nonLazyCategories64 == nil
        case (.bit64, .categoryList2): categories2_32 == nil
        case (.bit32, .categoryList2): categories2_64 == nil
        }
    }

    func category2Flag(architecture: FileRootArchitecture) -> Bool? {
        switch architecture {
        case .bit32: categories2_32?.first?.isCatlist2
        case .bit64: categories2_64?.first?.isCatlist2
        }
    }
}

private extension MachOFile.ObjectiveC {
    func legacyCount(
        for root: FileRootFixtureSection,
        architecture: FileRootArchitecture
    ) -> Int? {
        switch (architecture, root) {
        case (.bit64, .classList): classes64?.count
        case (.bit32, .classList): classes32?.count
        case (.bit64, .nonLazyClassList): nonLazyClasses64?.count
        case (.bit32, .nonLazyClassList): nonLazyClasses32?.count
        case (.bit64, .protocolList): protocols64?.count
        case (.bit32, .protocolList): protocols32?.count
        case (.bit64, .categoryList): categories64?.count
        case (.bit32, .categoryList): categories32?.count
        case (.bit64, .nonLazyCategoryList): nonLazyCategories64?.count
        case (.bit32, .nonLazyCategoryList): nonLazyCategories32?.count
        case (.bit64, .categoryList2): categories2_64?.count
        case (.bit32, .categoryList2): categories2_32?.count
        }
    }
}

private func setFileRootMachOName<Tuple>(
    _ value: String,
    in tuple: inout Tuple
) {
    let bytes = Array(value.utf8.prefix(MemoryLayout<Tuple>.size))
    withUnsafeMutableBytes(of: &tuple) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        bytes.withUnsafeBytes { source in
            destination.copyBytes(from: source)
        }
    }
}
