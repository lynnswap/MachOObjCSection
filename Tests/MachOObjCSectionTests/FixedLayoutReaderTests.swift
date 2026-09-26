import Foundation
import XCTest
@testable import MachOObjCSection
import MachOKit

final class FixedLayoutReaderTests: XCTestCase {
    func testReadLayoutAcceptsAnExactEndBoundaryAndUnalignedOffset() throws {
        let fixture = try FixedLayoutFileFixture()
        let file = fixture.machO.fileHandle

        XCTAssertEqual(
            file.readLayout(
                offset: UInt64(FixedLayoutFileFixture.markerOffset),
                as: UInt32.self
            ),
            FixedLayoutFileFixture.marker
        )
        XCTAssertNotNil(
            file.readLayout(offset: 1, as: UInt32.self),
            "Fixed layouts must be decoded with an unaligned load"
        )
    }

    func testReadLayoutRejectsTruncatedAndUnrepresentableRanges() throws {
        let fixture = try FixedLayoutFileFixture()
        let file = fixture.machO.fileHandle

        XCTAssertNil(
            file.readLayout(
                offset: UInt64(FixedLayoutFileFixture.fileSize - 3),
                as: UInt32.self
            )
        )
        XCTAssertNil(file.readLayout(offset: .max, as: UInt8.self))
    }
}

private final class FixedLayoutFileFixture {
    static let fileSize = 0x1000
    static let vmAddress: UInt64 = 0x1000_0000
    static let marker: UInt32 = 0x1234_5678
    static let markerOffset = fileSize - MemoryLayout<UInt32>.size

    let machO: MachOFile
    private let url: URL

    init() throws {
        var data = Data(count: Self.fileSize)

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
        segment.vmaddr = Self.vmAddress
        segment.vmsize = UInt64(Self.fileSize)
        segment.fileoff = 0
        segment.filesize = UInt64(Self.fileSize)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        data.store(segment, at: MemoryLayout<mach_header_64>.size)
        data.store(Self.marker, at: Self.markerOffset)

        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachOObjCSection-fixed-layout-\(UUID().uuidString)")
        try data.write(to: url)
        machO = try MachOFile(url: url)
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
