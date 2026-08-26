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

        for trailingByteCount in 1..<MemoryLayout<EntrySizeListHeader>.size {
            let trailingBytes = MachOImage.ObjCMethodLists(
                offset: 0,
                basePointer: UnsafeRawPointer(storage),
                tableSize: trailingByteCount,
                align: 0,
                is64Bit: true
            )
            XCTAssertTrue(Array(trailingBytes).isEmpty)
        }
    }

    func testEntrySizeListSizeProjectionIsBoundedAndOverflowSafe() {
        let empty = EntrySizeListHeader(
            layout: .init(entsizeAndFlags: UInt32.max, count: 0)
        )
        XCTAssertEqual(ObjCPropertyList.size(for: empty), MemoryLayout<EntrySizeListHeader>.size)
        XCTAssertEqual(
            ObjCPropertyList.checkedSize(
                for: empty,
                expectedEntrySize: MemoryLayout<ObjCProperty.Property64>.size
            ),
            MemoryLayout<EntrySizeListHeader>.size
        )

        let capPlusOneCount = ObjCMetadataReadLimits.maximumListEntries + 1
        let capPlusOne = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(MemoryLayout<ObjCMethod.Pointer64>.size),
                count: UInt32(capPlusOneCount)
            )
        )
        XCTAssertEqual(
            ObjCMethodList.size(for: capPlusOne),
            MemoryLayout<EntrySizeListHeader>.size
                + capPlusOneCount * MemoryLayout<ObjCMethod.Pointer64>.size
        )
        XCTAssertNil(
            ObjCMethodList.checkedSize(
                for: capPlusOne,
                expectedEntrySize: MemoryLayout<ObjCMethod.Pointer64>.size
            )
        )

        let overflowing = EntrySizeListHeader(
            layout: .init(entsizeAndFlags: UInt32.max, count: UInt32.max)
        )
        XCTAssertEqual(ObjCPropertyList.size(for: overflowing), 0)
        XCTAssertNil(
            ObjCPropertyList.checkedSize(
                for: overflowing,
                expectedEntrySize: MemoryLayout<ObjCProperty.Property64>.size
            )
        )

        let list = ObjCPropertyList(offset: 0, header: overflowing, is64Bit: true)
        let staticSize: Int = ObjCPropertyList.size(for: overflowing)
        let instanceSize: Int = list.size
        let entrySize: Int = list.entrySize
        let count: Int = list.count
        XCTAssertEqual(staticSize, 0)
        XCTAssertEqual(instanceSize, 0)
#if arch(arm64_32) || arch(arm) || arch(i386)
        XCTAssertEqual(entrySize, 0)
        XCTAssertEqual(count, 0)
#else
        XCTAssertEqual(entrySize, Int(UInt32.max))
        XCTAssertEqual(count, Int(UInt32.max))
#endif
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
