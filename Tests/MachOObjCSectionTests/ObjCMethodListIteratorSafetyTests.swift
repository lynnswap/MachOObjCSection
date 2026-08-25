import Foundation
@testable import MachOObjCSection
import XCTest

final class ObjCMethodListIteratorSafetyTests: XCTestCase {
    func testFileIteratorAcceptsEmptyListsWithoutReadingUnusedStride() throws {
        var data = Data(count: 16)
        data.store(
            EntrySizeListHeader(
                layout: .init(entsizeAndFlags: UInt32.max, count: 0)
            ),
            at: 0
        )
        data.store(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCMethod.Pointer64>.size),
                    count: 0
                )
            ),
            at: 8
        )
        let lists = MachOFile.ObjCMethodLists(
            data: data,
            offset: 0x400,
            align: 3,
            is64Bit: true
        )

        let values = Array(lists)

        XCTAssertEqual(values.map(\.offset), [0x400, 0x408])
        XCTAssertEqual(values.map(\.header.count), [0, 0])
    }

    func testFileIteratorStopsOnTruncatedInvalidAndExcessiveLists() {
        let truncated = MachOFile.ObjCMethodLists(
            data: Data(count: MemoryLayout<EntrySizeListHeader>.size - 1),
            offset: 0,
            align: 0,
            is64Bit: true
        )
        XCTAssertTrue(Array(truncated).isEmpty)

        let invalidStride = listsData(
            entrySize: MemoryLayout<ObjCMethod.Pointer64>.size - 1,
            count: 1,
            dataSize: 128
        )
        XCTAssertTrue(Array(MachOFile.ObjCMethodLists(
            data: invalidStride,
            offset: 0,
            align: 0,
            is64Bit: true
        )).isEmpty)

        let excessive = listsData(
            entrySize: MemoryLayout<ObjCMethod.Pointer64>.size,
            count: ObjCMetadataReadLimits.maximumListEntries + 1,
            dataSize: 128
        )
        XCTAssertTrue(Array(MachOFile.ObjCMethodLists(
            data: excessive,
            offset: 0,
            align: 0,
            is64Bit: true
        )).isEmpty)
    }

    func testIteratorRejectsInvalidAlignmentExponentWithoutTrap() {
        let data = listsData(entrySize: 0, count: 0, dataSize: 8)
        XCTAssertTrue(Array(MachOFile.ObjCMethodLists(
            data: data,
            offset: 0,
            align: Int.max,
            is64Bit: true
        )).isEmpty)
        XCTAssertNil(checkedAlignedOffset(8, alignmentExponent: Int.max))
        XCTAssertEqual(checkedAlignedOffset(10, alignmentExponent: 3), 16)
    }

    func testImageIteratorUsesCheckedHeaderAndListRanges() {
        let data = listsData(
            entrySize: MemoryLayout<ObjCMethod.Pointer64>.size,
            count: 1,
            dataSize: MemoryLayout<EntrySizeListHeader>.size
                + MemoryLayout<ObjCMethod.Pointer64>.size
        )
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: data.count,
            alignment: 16
        )
        defer { storage.deallocate() }
        data.withUnsafeBytes { bytes in
            storage.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }

        let exact = MachOImage.ObjCMethodLists(
            offset: 0,
            basePointer: UnsafeRawPointer(storage),
            tableSize: data.count,
            align: 0,
            is64Bit: true
        )
        XCTAssertEqual(Array(exact).count, 1)

        let truncated = MachOImage.ObjCMethodLists(
            offset: 0,
            basePointer: UnsafeRawPointer(storage),
            tableSize: data.count - 1,
            align: 0,
            is64Bit: true
        )
        XCTAssertTrue(Array(truncated).isEmpty)
    }

    func testEntrySizeListSizeProjectionIsBoundedAndOverflowSafe() {
        let empty = EntrySizeListHeader(
            layout: .init(entsizeAndFlags: UInt32.max, count: 0)
        )
        XCTAssertEqual(ObjCPropertyList.size(for: empty), MemoryLayout<EntrySizeListHeader>.size)

        let excessive = EntrySizeListHeader(
            layout: .init(entsizeAndFlags: UInt32.max, count: UInt32.max)
        )
        XCTAssertNil(ObjCPropertyList.size(for: excessive))
    }

    private func listsData(
        entrySize: Int,
        count: Int,
        dataSize: Int
    ) -> Data {
        var data = Data(count: dataSize)
        data.store(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(clamping: entrySize),
                    count: UInt32(clamping: count)
                )
            ),
            at: 0
        )
        return data
    }
}

private extension Data {
    mutating func store<Value>(_ value: Value, at offset: Int) {
        var value = value
        Swift.withUnsafeBytes(of: &value) { bytes in
            replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }
}
