import Foundation
@testable import MachOObjCSection
import MachOKit
import XCTest

final class ObjCMetadataTableReaderTests: XCTestCase {
    func testFileReaderAcceptsExactBoundaryAndUnalignedEntries() throws {
        let fixture = try MetadataTableFileFixture(fileSize: 0x1001)
        let tableOffset = fixture.fileSize - 2 * MemoryLayout<UInt32>.size
        try fixture.rewrite { data in
            data.store(UInt32(0x1234_5678), at: tableOffset)
            data.store(UInt32(0x90ab_cdef), at: tableOffset + MemoryLayout<UInt32>.size)
        }

        let entries: [ObjCMetadataTableEntry<UInt32>]
        switch ObjCMetadataTableReader.readFile(
            fixture.machO.fileHandle,
            offset: UInt64(tableOffset),
            logicalOffset: Int.max - 16,
            count: 2,
            as: UInt32.self
        ) {
        case .success(let value): entries = value
        case .failure(let failure): return XCTFail("Unexpected failure: \(failure)")
        }

        XCTAssertEqual(entries.map(\.value), [0x1234_5678, 0x90ab_cdef])
        XCTAssertEqual(entries.map(\.fileOffset), [UInt64(tableOffset), UInt64(tableOffset + 4)])
        XCTAssertEqual(entries.map(\.logicalOffset), [Int.max - 16, Int.max - 12])
    }

    func testFileReaderRejectsTruncationAndUnrepresentableOffset() throws {
        let fixture = try MetadataTableFileFixture(fileSize: 0x1000)
        let truncated = ObjCMetadataTableReader.readFile(
            fixture.machO.fileHandle,
            offset: UInt64(fixture.fileSize - 7),
            count: 2,
            as: UInt32.self
        )
        XCTAssertEqual(
            truncated.failure,
            .unreadableFileRange(offset: UInt64(fixture.fileSize - 7), byteCount: 8)
        )

        let unrepresentable = ObjCMetadataTableReader.readFile(
            fixture.machO.fileHandle,
            offset: .max,
            count: 1,
            as: UInt8.self
        )
        XCTAssertEqual(
            unrepresentable.failure,
            .unreadableFileRange(offset: .max, byteCount: 1)
        )
    }

    func testLimitFailurePrecedenceAndFiniteBudgets() {
        XCTAssertEqual(
            ObjCMetadataTableReader.checkedByteCount(count: Int.max, stride: 2).failure,
            .byteCountOverflow(elementCount: Int.max, elementSize: 2)
        )
        XCTAssertEqual(
            ObjCMetadataTableReader.checkedByteCount(
                count: ObjCMetadataReadLimits.maximumListEntries + 1,
                stride: 1
            ).failure,
            .excessiveElementCount(
                actual: ObjCMetadataReadLimits.maximumListEntries + 1,
                maximum: ObjCMetadataReadLimits.maximumListEntries
            )
        )
        XCTAssertEqual(
            ObjCMetadataTableReader.checkedByteCount(
                count: ObjCMetadataReadLimits.maximumListEntries,
                stride: 9
            ).failure,
            .excessiveByteCount(
                actual: ObjCMetadataReadLimits.maximumListEntries * 9,
                maximum: ObjCMetadataReadLimits.maximumTableByteCount
            )
        )
        XCTAssertEqual(
            ObjCMetadataTableReader.checkedByteCount(count: -1, stride: 1).failure,
            .invalidSignedElementCount(-1)
        )
    }

    func testZeroCountDoesNotInspectUnusedStrideOrAddress() throws {
        let fixture = try MetadataTableFileFixture(fileSize: 0x1000)
        let file = ObjCMetadataTableReader.readFile(
            fixture.machO.fileHandle,
            offset: UInt64(fixture.fileSize),
            count: 0,
            stride: -1,
            as: UInt64.self
        )
        XCTAssertEqual(file.values?.count, 0)

        let image = ObjCMetadataTableReader.readImage(
            address: 0,
            count: 0,
            stride: -1,
            as: UInt64.self
        )
        XCTAssertEqual(image.values?.count, 0)
    }

    func testImageReaderUsesOneFullRangeProbeAndUnalignedLoads() {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 16)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        storage.advanced(by: 1).storeUnaligned(UInt32(7))
        storage.advanced(by: 5).storeUnaligned(UInt32(11))

        let entries: [ObjCMetadataTableEntry<UInt32>]
        switch ObjCMetadataTableReader.readImage(
            address: UInt(bitPattern: storage.advanced(by: 1)),
            logicalOffset: 101,
            count: 2,
            as: UInt32.self
        ) {
        case .success(let value): entries = value
        case .failure(let failure): return XCTFail("Unexpected failure: \(failure)")
        }
        XCTAssertEqual(entries.map(\.value), [7, 11])
        XCTAssertEqual(entries.map(\.logicalOffset), [101, 105])

        XCTAssertEqual(
            ObjCMetadataTableReader.readImage(
                address: 0x10,
                count: 1,
                as: UInt32.self
            ).failure,
            .unreadableImageRange(address: 0x10, byteCount: 4)
        )
    }

    func testExactCountAndStrideCanModelArm64_32Representability() {
        XCTAssertEqual(
            ObjCMetadataTableReader.exactCount(
                UInt64(UInt32.max),
                maximumIntValue: UInt64(Int32.max)
            ).failure,
            .invalidElementCount(UInt64(UInt32.max))
        )
        XCTAssertEqual(
            ObjCMetadataTableReader.exactStride(
                UInt64(UInt32.max),
                maximumIntValue: UInt64(Int32.max)
            ).failure,
            .invalidElementStride(UInt64(UInt32.max))
        )
    }
}

private extension ObjCMetadataTableRead {
    var values: Value? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    var failure: ObjCMetadataTableFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private final class MetadataTableFileFixture {
    let fileSize: Int
    private(set) var machO: MachOFile
    private let url: URL

    init(fileSize: Int) throws {
        self.fileSize = fileSize
        self.url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MachOObjCSection-table-reader-\(UUID().uuidString)"
        )
        let data = Self.machOData(fileSize: fileSize)
        try data.write(to: url)
        self.machO = try MachOFile(url: url)
    }

    func rewrite(_ update: (inout Data) -> Void) throws {
        var data = Self.machOData(fileSize: fileSize)
        update(&data)
        try data.write(to: url, options: .atomic)
        machO = try MachOFile(url: url)
    }

    private static func machOData(fileSize: Int) -> Data {
        var data = Data(count: fileSize)
        var header = mach_header_64()
        header.magic = UInt32(MH_MAGIC_64)
        header.cputype = CPU_TYPE_ARM64
        header.cpusubtype = CPU_SUBTYPE_ARM64_ALL
        header.filetype = UInt32(MH_DYLIB)
        header.ncmds = 1
        header.sizeofcmds = UInt32(MemoryLayout<segment_command_64>.size)
        data.store(header, at: 0)

        var segment = segment_command_64()
        segment.cmd = UInt32(LC_SEGMENT_64)
        segment.cmdsize = UInt32(MemoryLayout<segment_command_64>.size)
        segment.vmaddr = 0x1000_0000
        segment.vmsize = UInt64(fileSize)
        segment.filesize = UInt64(fileSize)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        data.store(segment, at: MemoryLayout<mach_header_64>.size)
        return data
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
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

private extension UnsafeMutableRawPointer {
    func storeUnaligned<Value>(_ value: Value) {
        var value = value
        Swift.withUnsafeBytes(of: &value) { bytes in
            copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
}
