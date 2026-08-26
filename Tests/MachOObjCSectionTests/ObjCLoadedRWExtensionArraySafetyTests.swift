import Foundation
import MachOKit
@_spi(Core) @_spi(Diagnostics) @testable import MachOObjCSection
import XCTest
#if canImport(Darwin)
import Darwin
#endif

#if canImport(Darwin)
final class ObjCLoadedRWExtensionArraySafetyTests: XCTestCase {
    func testAllFieldKindsUseCheckedSingleProjection() throws {
        let fixture = try LoadedRWExtensionFixture()
        let methodOffset = fixture.pageSize
        let propertyOffset = methodOffset + 0x100
        let protocolOffset = propertyOffset + 0x100
        fixture.store(Self.emptyMemberHeader(), at: methodOffset)
        fixture.store(Self.emptyMemberHeader(), at: propertyOffset)
        fixture.store(ObjCProtocolListHeader64(_count: 0), at: protocolOffset)
        let ext = fixture.extensionData(
            methods: fixture.address64(at: methodOffset),
            properties: fixture.address64(at: propertyOffset),
            protocols: fixture.address64(at: protocolOffset)
        )

        let methods = ext.readMethodLists(in: fixture.machO)
        let properties = ext.readPropertyLists(in: fixture.machO)
        let protocols = ext.readProtocolLists(in: fixture.machO)

        XCTAssertEqual(methods.representation, .single)
        XCTAssertEqual(properties.representation, .single)
        XCTAssertEqual(protocols.representation, .single)
        XCTAssertEqual(methods.entries.count, 1)
        XCTAssertEqual(properties.entries.count, 1)
        XCTAssertEqual(protocols.entries.count, 1)
        XCTAssertTrue(methods.tableDiagnostics.isEmpty)
        XCTAssertTrue(properties.tableDiagnostics.isEmpty)
        XCTAssertTrue(protocols.tableDiagnostics.isEmpty)
        XCTAssertEqual(ext.methodList(in: fixture.machO)?.lists(in: fixture.machO).count, 1)
        XCTAssertEqual(ext.propertyList(in: fixture.machO)?.lists(in: fixture.machO).count, 1)
        XCTAssertEqual(ext.protocolList(in: fixture.machO)?.lists(in: fixture.machO).count, 1)
    }

    func testPointerArrayPreservesGoodBadGoodAndLegacyProjection() throws {
        let fixture = try LoadedRWExtensionFixture()
        let arrayOffset = fixture.pageSize
        let firstListOffset = fixture.pageSize * 2
        let secondListOffset = fixture.pageSize * 4
        fixture.store(Self.emptyMemberHeader(), at: firstListOffset)
        fixture.store(Self.emptyMemberHeader(), at: secondListOffset)
        fixture.storeArray64(
            pointers: [
                fixture.address64(at: firstListOffset),
                fixture.address64(at: fixture.unreadableOffset),
                fixture.address64(at: secondListOffset),
            ],
            at: arrayOffset
        )
        try fixture.protectUnreadablePage()
        let ext = fixture.extensionData(
            methods: fixture.address64(at: arrayOffset) | 1
        )

        let result = ext.readMethodLists(in: fixture.machO)

        XCTAssertEqual(result.representation, .array)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries.map(\.list.header.count), [0, 0])
        XCTAssertEqual(result.tableDiagnostics.count, 1)
        XCTAssertEqual(
            result.tableDiagnostics.first?.owner,
            .loadedRWExtension(kind: .method, pointerWidth: .bits64)
        )
        guard case .entry(index: 1, provenance: _) = result.tableDiagnostics.first?.site,
              case .unreadableReferencedLayout = result.tableDiagnostics.first?.failure else {
            return XCTFail("Only the unreadable middle list should be omitted")
        }
        XCTAssertEqual(
            ext.methodList(in: fixture.machO)?.lists(in: fixture.machO).count,
            2
        )
    }

    func testAbsentTagOnlyAndReservedStorageStayDistinct() throws {
        let fixture = try LoadedRWExtensionFixture()
        let ext = fixture.extensionData(
            methods: 0,
            properties: 1,
            protocols: 3
        )

        let absent = ext.readMethodLists(in: fixture.machO)
        let tagOnly = ext.readPropertyLists(in: fixture.machO)
        let reserved = ext.readProtocolLists(in: fixture.machO)

        XCTAssertNil(absent.representation)
        XCTAssertTrue(absent.tableDiagnostics.isEmpty)
        XCTAssertNil(ext.methodList(in: fixture.machO))
        XCTAssertEqual(tagOnly.representation, .array)
        guard tagOnly.tableDiagnostics.count == 1,
              case .invalidPointer(rawValue: 1) = tagOnly.tableDiagnostics[0].failure else {
            return XCTFail("A nonzero tag-only value must be malformed")
        }
        XCTAssertNil(ext.propertyList(in: fixture.machO))
        guard reserved.tableDiagnostics.count == 1,
              case .unsupportedListEncoding = reserved.tableDiagnostics[0].failure else {
            return XCTFail("Tag 3 must stop before a payload read")
        }
        XCTAssertNil(ext.protocolList(in: fixture.machO))
    }

    func testLegalEmptyArrayAndRelativeStorageArePresent() throws {
        let fixture = try LoadedRWExtensionFixture()
        let arrayOffset = fixture.pageSize
        let relativeOffset = fixture.pageSize * 2
        fixture.storeArray64(pointers: [], at: arrayOffset)
        fixture.store(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<RelativeListListEntry.Layout>.size),
                    count: 0
                )
            ),
            at: relativeOffset
        )
        let array = fixture.extensionData(
            methods: fixture.address64(at: arrayOffset) | 1
        )
        let relative = fixture.extensionData(
            methods: fixture.address64(at: relativeOffset) | 2,
            properties: fixture.address64(at: relativeOffset) | 2,
            protocols: fixture.address64(at: relativeOffset) | 2
        )

        let emptyArray = array.readMethodLists(in: fixture.machO)
        XCTAssertEqual(emptyArray.representation, .array)
        XCTAssertTrue(emptyArray.entries.isEmpty)
        XCTAssertTrue(emptyArray.tableDiagnostics.isEmpty)
        XCTAssertNotNil(array.methodList(in: fixture.machO))

        let methodRelative = relative.readMethodLists(in: fixture.machO)
        let propertyRelative = relative.readPropertyLists(in: fixture.machO)
        let protocolRelative = relative.readProtocolLists(in: fixture.machO)
        XCTAssertEqual(methodRelative.representation, .relative)
        XCTAssertEqual(propertyRelative.representation, .relative)
        XCTAssertEqual(protocolRelative.representation, .relative)
        XCTAssertNotNil(methodRelative.relativeListList)
        XCTAssertNotNil(propertyRelative.relativeListList)
        XCTAssertNotNil(protocolRelative.relativeListList)
        XCTAssertTrue(methodRelative.entries.isEmpty)
        XCTAssertTrue(propertyRelative.entries.isEmpty)
        XCTAssertTrue(protocolRelative.entries.isEmpty)
        XCTAssertTrue(methodRelative.tableDiagnostics.isEmpty)
        XCTAssertTrue(propertyRelative.tableDiagnostics.isEmpty)
        XCTAssertTrue(protocolRelative.tableDiagnostics.isEmpty)
        XCTAssertTrue(
            relative.methodList(in: fixture.machO)?.lists(in: fixture.machO).isEmpty
                == true
        )
        XCTAssertNotNil(relative.methodList(in: fixture.machO)?.relativeListList(in: fixture.machO))
    }

    func testWholePointerTableAndInnerTableTruncationAreTyped() throws {
        let pointerTableFixture = try LoadedRWExtensionFixture()
        let arrayOffset = pointerTableFixture.unreadableOffset - 16
        pointerTableFixture.store(UInt32(2), at: arrayOffset)
        pointerTableFixture.store(
            pointerTableFixture.address64(at: pointerTableFixture.pageSize),
            at: arrayOffset + 8
        )
        try pointerTableFixture.protectUnreadablePage()
        let pointerTable = pointerTableFixture.extensionData(
            methods: pointerTableFixture.address64(at: arrayOffset) | 1
        ).readMethodLists(in: pointerTableFixture.machO)
        XCTAssertTrue(pointerTable.entries.isEmpty)
        guard case .unreadableImageRange = pointerTable.tableDiagnostics.first?.failure else {
            return XCTFail("A truncated complete pointer table must fail as one table")
        }

        let innerFixture = try LoadedRWExtensionFixture()
        let listOffset = innerFixture.unreadableOffset
            - MemoryLayout<EntrySizeListHeader>.size
        innerFixture.store(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCMethod.Pointer>.size),
                    count: 1
                )
            ),
            at: listOffset
        )
        try innerFixture.protectUnreadablePage()
        let inner = innerFixture.extensionData(
            methods: innerFixture.address64(at: listOffset)
        ).readMethodLists(in: innerFixture.machO)
        XCTAssertTrue(inner.entries.isEmpty)
        guard case .unreadableImageRange = inner.tableDiagnostics.first?.failure else {
            return XCTFail("A readable header with a truncated inner table must be typed")
        }
    }

    func testArrayBudgetRunsBeforeUnreadablePointerTable() throws {
        let fixture = try LoadedRWExtensionFixture()
        let arrayOffset = fixture.pageSize
        fixture.store(
            UInt32(ObjCMetadataReadLimits.maximumListEntries + 1),
            at: arrayOffset
        )
        let result = fixture.extensionData(
            methods: fixture.address64(at: arrayOffset) | 1
        ).readMethodLists(in: fixture.machO)

        guard case let .excessiveElementCount(actual, maximum) =
            result.tableDiagnostics.first?.failure else {
            return XCTFail("The shared count budget must precede range probing")
        }
        XCTAssertEqual(actual, ObjCMetadataReadLimits.maximumListEntries + 1)
        XCTAssertEqual(maximum, ObjCMetadataReadLimits.maximumListEntries)
    }

    func testCentralReaderUsesExact32And64BitPointerLayouts() throws {
        let fixture = try LoadedRWExtensionFixture()
        let offset32 = fixture.pageSize
        fixture.store(UInt32(2), at: offset32)
        fixture.store(UInt32(0x1111), at: offset32 + 4)
        fixture.store(UInt32(0x2222), at: offset32 + 8)
        let storage32 = fixture.storage(at: offset32, representation: .array)
        let result32: ObjCLoadedListArrayReadResult<Int, Never> =
            ObjCLoadedListArrayReader.read(
                .value(storage32),
                in: fixture.machO,
                pointerType: UInt32.self,
                owner: .loadedRWExtension(kind: .method, pointerWidth: .bits32),
                readList: { .value(Int($0)) },
                readRelative: { _ in XCTFail("Unexpected relative route"); return .init(representation: nil) }
            )
        XCTAssertEqual(result32.entries.map(\.list), [0x1111, 0x2222])

        let offset64 = fixture.pageSize * 2
        fixture.store(UInt32(2), at: offset64)
        fixture.store(UInt64(0x3333), at: offset64 + 8)
        fixture.store(UInt64(0x4444), at: offset64 + 16)
        let storage64 = fixture.storage(at: offset64, representation: .array)
        let result64: ObjCLoadedListArrayReadResult<Int, Never> =
            ObjCLoadedListArrayReader.read(
                .value(storage64),
                in: fixture.machO,
                pointerType: UInt64.self,
                owner: .loadedRWExtension(kind: .method, pointerWidth: .bits64),
                readList: { .value(Int($0)) },
                readRelative: { _ in XCTFail("Unexpected relative route"); return .init(representation: nil) }
            )
        XCTAssertEqual(result64.entries.map(\.list), [0x3333, 0x4444])
    }

    func testRelativeAdapterPreservesGoodBadGoodOrder() throws {
        let fixture = try LoadedRWExtensionFixture()
        var layout = RelativeListListEntry.Layout()
        layout.imageIndex = 7
        layout.listOffset = 0
        let encodedEntry = RelativeListListEntry(
            offset: fixture.pageSize + MemoryLayout<EntrySizeListHeader>.size,
            layout: layout
        )
        let failure = ObjCRelativeListFailure.entry(
            outerListOffset: fixture.pageSize,
            index: 1,
            entry: encodedEntry,
            reason: .relativeImageUnavailable(imageIndex: 7)
        )
        let resolution = ObjCRelativeListResolution<
            MachOImage,
            Int,
            ObjCRelativeListFailure
        >.entries([
            .resolved(fixture.machO, 10),
            .failure(failure),
            .resolved(fixture.machO, 20),
        ])

        let result = ObjCLoadedListArrayReader.relativeResult(
            "relative",
            resolution: resolution,
            in: fixture.machO,
            owner: .loadedRWExtension(kind: .method, pointerWidth: .bits64)
        )

        XCTAssertEqual(result.entries.map(\.list), [10, 20])
        XCTAssertEqual(result.relativeListList, "relative")
        guard result.tableDiagnostics.count == 1,
              case .entry(index: 1, provenance: _) = result.tableDiagnostics[0].site,
              case .relativeImageUnavailable(imageIndex: 7) =
                result.tableDiagnostics[0].failure else {
            return XCTFail("The middle relative failure must remain indexed")
        }
    }

    private static func emptyMemberHeader() -> EntrySizeListHeader {
        .init(layout: .init(entsizeAndFlags: .max, count: 0))
    }
}

private final class LoadedRWExtensionFixture {
    lazy var machO = MachOImage(
        ptr: mapping.assumingMemoryBound(to: mach_header.self)
    )
    let pageSize = Int(getpagesize())
    let unreadableOffset: Int

    private let mapping: UnsafeMutableRawPointer
    private let mappingLength: Int
    private var unreadablePageIsProtected = false

    init() throws {
        mappingLength = pageSize * 6
        unreadableOffset = pageSize * 3
        guard let mapping = mmap(
            nil,
            mappingLength,
            PROT_READ | PROT_WRITE,
            MAP_ANON | MAP_PRIVATE,
            -1,
            0
        ), mapping != MAP_FAILED else {
            throw CocoaError(.fileReadUnknown)
        }
        self.mapping = mapping
        mapping.initializeMemory(as: UInt8.self, repeating: 0, count: mappingLength)
        writeMachO()
    }

    func address(at offset: Int) -> UInt {
        UInt(bitPattern: mapping.advanced(by: offset))
    }

    func address64(at offset: Int) -> UInt64 {
        UInt64(address(at: offset))
    }

    func store<Value>(_ value: Value, at offset: Int) {
        mapping.advanced(by: offset).storeUnaligned(value)
    }

    func storeArray64(pointers: [UInt64], at offset: Int) {
        store(UInt32(pointers.count), at: offset)
        for (index, pointer) in pointers.enumerated() {
            store(pointer, at: offset + 8 + index * MemoryLayout<UInt64>.size)
        }
    }

    func extensionData(
        methods: UInt64 = 0,
        properties: UInt64 = 0,
        protocols: UInt64 = 0
    ) -> ObjCClassRWDataExt64 {
        ObjCClassRWDataExt64(
            layout: .init(
                ro: 0,
                methods: methods,
                properties: properties,
                protocols: protocols,
                demangledName: 0,
                version: 0
            ),
            offset: 0
        )
    }

    func storage(
        at offset: Int,
        representation: ObjCLoadedListArrayRepresentation
    ) -> ObjCLoadedListArrayStorage {
        let tag: Int
        switch representation {
        case .single: tag = 0
        case .array: tag = 1
        case .relative: tag = 2
        }
        return .init(
            representation: representation,
            taggedOffset: offset | tag,
            offset: offset,
            address: address(at: offset),
            provenance: .init(
                logicalOffset: offset,
                imageAddress: address(at: offset)
            )
        )
    }

    func protectUnreadablePage() throws {
        guard !unreadablePageIsProtected else { return }
        guard mprotect(
            mapping.advanced(by: unreadableOffset),
            pageSize,
            PROT_NONE
        ) == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        unreadablePageIsProtected = true
    }

    private func writeMachO() {
        var header = mach_header_64()
        header.magic = UInt32(MH_MAGIC_64)
        header.cputype = CPU_TYPE_ARM64
        header.cpusubtype = CPU_SUBTYPE_ARM64_ALL
        header.filetype = UInt32(MH_DYLIB)
        header.ncmds = 1
        header.sizeofcmds = UInt32(MemoryLayout<segment_command_64>.size)
        store(header, at: 0)

        var segment = segment_command_64()
        segment.cmd = UInt32(LC_SEGMENT_64)
        segment.cmdsize = UInt32(MemoryLayout<segment_command_64>.size)
        segment.vmaddr = address64(at: 0)
        segment.vmsize = UInt64(mappingLength)
        segment.filesize = UInt64(mappingLength)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        store(segment, at: MemoryLayout<mach_header_64>.size)
    }

    deinit {
        if unreadablePageIsProtected {
            _ = mprotect(
                mapping.advanced(by: unreadableOffset),
                pageSize,
                PROT_READ | PROT_WRITE
            )
        }
        munmap(mapping, mappingLength)
    }
}

private extension UnsafeMutableRawPointer {
    func storeUnaligned<Value>(_ value: Value) {
        var value = value
        Swift.withUnsafeBytes(of: &value) { bytes in
            copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
}
#endif
