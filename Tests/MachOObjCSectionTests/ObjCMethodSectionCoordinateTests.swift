import Foundation
@testable import MachOObjCSection
import MachOKit
import XCTest

final class ObjCMethodSectionCoordinateTests: XCTestCase {
    func testValid32And64BitMethodSectionsRemainReadableForFileAndImage() throws {
        for architecture in MethodSectionArchitecture.allCases {
            let file = try MethodSectionFileFixture(
                architecture: architecture,
                malformedField: .none
            )
            let image = MethodSectionImageFixture(
                architecture: architecture,
                malformedField: .none
            )

            XCTAssertEqual(try XCTUnwrap(file.machO.objc.methods).map(\.header.count), [0])
            XCTAssertEqual(try XCTUnwrap(image.machO.objc.methods).map(\.header.count), [0])
        }
    }

    func testMalformedRawSectionAndSegmentCoordinatesReturnNilWithoutGetterTrap() throws {
        for architecture in MethodSectionArchitecture.allCases {
            for malformedField in MethodSectionMalformedField.allCases where malformedField != .none {
                let file = try MethodSectionFileFixture(
                    architecture: architecture,
                    malformedField: malformedField
                )
                let image = MethodSectionImageFixture(
                    architecture: architecture,
                    malformedField: malformedField
                )

                XCTAssertNil(
                    file.machO.objc.methods,
                    "Unexpected file methods for \(architecture) / \(malformedField)"
                )
                XCTAssertNil(
                    image.machO.objc.methods,
                    "Unexpected image methods for \(architecture) / \(malformedField)"
                )
            }
        }
    }

    func testRawUInt32CoordinateAndAlignmentConversionCanModelArm64_32() {
        XCTAssertEqual(
            exactObjCSectionCoordinate(
                UInt64(Int32.max),
                maximumIntValue: UInt64(Int32.max)
            ),
            Int(Int32.max)
        )
        XCTAssertNil(
            exactObjCSectionCoordinate(
                UInt64(UInt32.max),
                maximumIntValue: UInt64(Int32.max)
            )
        )
        XCTAssertEqual(
            checkedObjCSectionAlignmentExponent(
                30,
                maximumIntValue: UInt64(Int32.max),
                intBitWidth: 32
            ),
            30
        )
        XCTAssertNil(
            checkedObjCSectionAlignmentExponent(
                31,
                maximumIntValue: UInt64(Int32.max),
                intBitWidth: 32
            )
        )
    }
}

private enum MethodSectionArchitecture: CaseIterable {
    case bit32
    case bit64
}

private enum MethodSectionMalformedField: CaseIterable {
    case none
    case address
    case size
    case fileOffset
    case alignment
    case segmentAddress
    case segmentFileOffset
}

private enum MethodSectionFixtureData {
    static let fileSize = 0x1000
    static let virtualMemoryAddress: UInt64 = 0x1000_0000
    static let methodListOffset = 0x400

    static func make(
        architecture: MethodSectionArchitecture,
        malformedField: MethodSectionMalformedField
    ) -> Data {
        var data = Data(count: fileSize)
        switch architecture {
        case .bit64:
            write64(into: &data, malformedField: malformedField)
        case .bit32:
            write32(into: &data, malformedField: malformedField)
        }
        data.store(
            EntrySizeListHeader(
                layout: .init(entsizeAndFlags: UInt32.max, count: 0)
            ),
            at: methodListOffset
        )
        return data
    }

    private static func write64(
        into data: inout Data,
        malformedField: MethodSectionMalformedField
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
        data.store(header, at: 0)

        var segment = segment_command_64()
        segment.cmd = UInt32(LC_SEGMENT_64)
        segment.cmdsize = UInt32(header.sizeofcmds)
        setMachOName("__TEXT", in: &segment.segname)
        segment.vmaddr = virtualMemoryAddress
        segment.vmsize = UInt64(fileSize)
        segment.fileoff = 0
        segment.filesize = UInt64(fileSize)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        segment.nsects = 1
        apply(malformedField, to: &segment)
        data.store(segment, at: MemoryLayout<mach_header_64>.size)

        var section = section_64()
        setMachOName("__objc_methlist", in: &section.sectname)
        setMachOName("__TEXT", in: &section.segname)
        section.addr = virtualMemoryAddress + UInt64(methodListOffset)
        section.size = UInt64(MemoryLayout<EntrySizeListHeader>.size)
        section.offset = UInt32(methodListOffset)
        section.align = 3
        apply(malformedField, to: &section)
        data.store(
            section,
            at: MemoryLayout<mach_header_64>.size + MemoryLayout<segment_command_64>.size
        )
    }

    private static func write32(
        into data: inout Data,
        malformedField: MethodSectionMalformedField
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
        data.store(header, at: 0)

        var segment = segment_command()
        segment.cmd = UInt32(LC_SEGMENT)
        segment.cmdsize = UInt32(header.sizeofcmds)
        setMachOName("__TEXT", in: &segment.segname)
        segment.vmaddr = UInt32(virtualMemoryAddress)
        segment.vmsize = UInt32(fileSize)
        segment.fileoff = 0
        segment.filesize = UInt32(fileSize)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        segment.nsects = 1
        apply(malformedField, to: &segment)
        data.store(segment, at: MemoryLayout<mach_header>.size)

        var section = section()
        setMachOName("__objc_methlist", in: &section.sectname)
        setMachOName("__TEXT", in: &section.segname)
        section.addr = UInt32(virtualMemoryAddress) + UInt32(methodListOffset)
        section.size = UInt32(MemoryLayout<EntrySizeListHeader>.size)
        section.offset = UInt32(methodListOffset)
        section.align = 3
        apply(malformedField, to: &section)
        data.store(
            section,
            at: MemoryLayout<mach_header>.size + MemoryLayout<segment_command>.size
        )
    }

    private static func apply(
        _ malformedField: MethodSectionMalformedField,
        to section: inout section_64
    ) {
        switch malformedField {
        case .none: break
        case .address: section.addr = .max
        case .size: section.size = .max
        case .fileOffset: section.offset = .max
        case .alignment: section.align = .max
        case .segmentAddress, .segmentFileOffset: break
        }
    }

    private static func apply(
        _ malformedField: MethodSectionMalformedField,
        to section: inout section
    ) {
        switch malformedField {
        case .none: break
        case .address: section.addr = .max
        case .size: section.size = .max
        case .fileOffset: section.offset = .max
        case .alignment: section.align = .max
        case .segmentAddress, .segmentFileOffset: break
        }
    }

    private static func apply(
        _ malformedField: MethodSectionMalformedField,
        to segment: inout segment_command_64
    ) {
        switch malformedField {
        case .segmentAddress: segment.vmaddr = .max
        case .segmentFileOffset: segment.fileoff = .max
        default: break
        }
    }

    private static func apply(
        _ malformedField: MethodSectionMalformedField,
        to segment: inout segment_command
    ) {
        switch malformedField {
        case .segmentAddress: segment.vmaddr = .max
        case .segmentFileOffset: segment.fileoff = .max
        default: break
        }
    }

    private static func setMachOName<Tuple>(
        _ value: String,
        in tuple: inout Tuple
    ) {
        let bytes = Array(value.utf8.prefix(MemoryLayout<Tuple>.size - 1)) + [0]
        withUnsafeMutableBytes(of: &tuple) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
    }
}

private final class MethodSectionFileFixture {
    let machO: MachOFile
    private let url: URL

    init(
        architecture: MethodSectionArchitecture,
        malformedField: MethodSectionMalformedField
    ) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MachOObjCSection-method-section-file-\(UUID().uuidString)"
        )
        try MethodSectionFixtureData.make(
            architecture: architecture,
            malformedField: malformedField
        ).write(to: url)
        machO = try MachOFile(url: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class MethodSectionImageFixture {
    let machO: MachOImage
    private let storage: UnsafeMutableRawPointer

    init(
        architecture: MethodSectionArchitecture,
        malformedField: MethodSectionMalformedField
    ) {
        let data = MethodSectionFixtureData.make(
            architecture: architecture,
            malformedField: malformedField
        )
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: data.count,
            alignment: 16
        )
        data.withUnsafeBytes { bytes in
            storage.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        self.storage = storage
        machO = MachOImage(ptr: storage.assumingMemoryBound(to: mach_header.self))
    }

    deinit {
        storage.deallocate()
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
