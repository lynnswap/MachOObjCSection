import Foundation
import XCTest
@_spi(Core) @_spi(Diagnostics) @testable import MachOObjCSection
@testable import MachOKit

final class ObjCMetadataFieldDiagnosticsTests: XCTestCase {
    func testUnreadableInstanceClassRODataReturnsANamelessRootDiagnostic() throws {
        let fixture = try SyntheticFieldFileFixture(instanceROStorage: .truncated)

        let result = fixture.objcClass.readInfo(in: fixture.machO)

        XCTAssertNil(result.value)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertTrue(result.memberListDiagnostics.isEmpty)
        XCTAssertEqual(result.fieldDiagnostics.count, 1)
        guard case .classROData(let diagnostic) = result.fieldDiagnostics.first else {
            return XCTFail("Expected an instance class RO diagnostic")
        }
        XCTAssertEqual(
            diagnostic.subject,
            .classObject(offset: SyntheticFieldFileFixture.classOffset)
        )
        XCTAssertEqual(diagnostic.role, .instance)
        XCTAssertEqual(
            diagnostic.classObjectOffset,
            SyntheticFieldFileFixture.classOffset
        )
        XCTAssertEqual(
            diagnostic.failure,
            .unreadableFileRange(
                offset: UInt64(SyntheticFieldFileFixture.truncatedClassROOffset),
                byteCount: MemoryLayout<ObjCClassROData64.Layout>.size
            )
        )
        XCTAssertNil(fixture.objcClass.info(in: fixture.machO))
    }

    func testUnreadableMetaclassRODataPreservesInstanceMetadata() throws {
        let fixture = try SyntheticFieldFileFixture(
            metaROStorage: .truncated,
            ivars: [.init(name: "kept", offsetStorage: .value(24))]
        )

        let result = fixture.objcClass.readInfo(in: fixture.machO)

        XCTAssertEqual(result.value?.name, "FieldOwner")
        XCTAssertEqual(result.value?.ivars.map(\.name), ["kept"])
        XCTAssertEqual(result.value?.ivars.map(\.offset), [24])
        XCTAssertEqual(result.value?.classProperties, [])
        XCTAssertEqual(result.value?.classMethods, [])
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertTrue(result.memberListDiagnostics.isEmpty)
        XCTAssertEqual(result.fieldDiagnostics.count, 1)
        guard case .classROData(let diagnostic) = result.fieldDiagnostics.first else {
            return XCTFail("Expected a metaclass RO diagnostic")
        }
        XCTAssertEqual(
            diagnostic.subject,
            .namedClass(
                name: "FieldOwner",
                objectOffset: SyntheticFieldFileFixture.classOffset
            )
        )
        XCTAssertEqual(diagnostic.role, .metaclass)
        XCTAssertEqual(
            diagnostic.classObjectOffset,
            SyntheticFieldFileFixture.metaClassOffset
        )
        XCTAssertEqual(
            diagnostic.failure,
            .unreadableFileRange(
                offset: UInt64(SyntheticFieldFileFixture.truncatedClassROOffset),
                byteCount: MemoryLayout<ObjCClassROData64.Layout>.size
            )
        )
        XCTAssertNotNil(fixture.objcClass.info(in: fixture.machO))
    }

    func testUnreadableIvarOffsetsDropOnlyTheirEntriesAndKeepDiagnosticOrder() throws {
        let fixture = try SyntheticFieldFileFixture(
            ivars: [
                .init(name: "first", offsetStorage: .value(0)),
                .init(name: "brokenOne", offsetStorage: .truncated(bytesFromEnd: 2)),
                .init(name: "middle", offsetStorage: .value(16)),
                .init(name: "brokenTwo", offsetStorage: .truncated(bytesFromEnd: 1)),
                .init(name: "last", offsetStorage: .value(32)),
            ]
        )

        let result = fixture.objcClass.readInfo(in: fixture.machO)

        XCTAssertEqual(result.value?.ivars.map(\.name), ["first", "middle", "last"])
        XCTAssertEqual(result.value?.ivars.map(\.offset), [0, 16, 32])
        let diagnostics: [ObjCMetadataFieldDiagnostic.IvarOffset] = result.fieldDiagnostics.compactMap { diagnostic in
            guard case .ivarOffset(let details) = diagnostic else { return nil }
            return details
        }
        XCTAssertEqual(diagnostics.map(\.index), [1, 3])
        XCTAssertEqual(diagnostics.map(\.name), ["brokenOne", "brokenTwo"])
        let expectedSubject = ObjCMetadataFieldDiagnostic.Subject.namedClass(
            name: "FieldOwner",
            objectOffset: SyntheticFieldFileFixture.classOffset
        )
        XCTAssertEqual(diagnostics.map(\.subject), [expectedSubject, expectedSubject])
        let expectedFailures: [ObjCMetadataFieldDiagnostic.Failure] = [
            .unreadableFileRange(
                offset: UInt64(SyntheticFieldFileFixture.fileSize - 2),
                byteCount: MemoryLayout<UInt32>.size
            ),
            .unreadableFileRange(
                offset: UInt64(SyntheticFieldFileFixture.fileSize - 1),
                byteCount: MemoryLayout<UInt32>.size
            ),
        ]
        XCTAssertEqual(diagnostics.map(\.failure), expectedFailures)
    }

    func testLoadedDirectRWAndExtClassROFailuresRemainTyped() {
        for path in SyntheticFieldImageFixture.Path.allCases {
            let fixture = SyntheticFieldImageFixture(path: path)

            let result = fixture.objcClass.readInfo(in: fixture.machO)

            XCTAssertNil(result.value, "Unexpected value for \(path)")
            XCTAssertEqual(result.fieldDiagnostics.count, 1, "Unexpected diagnostics for \(path)")
            guard case .classROData(let diagnostic) = result.fieldDiagnostics.first else {
                XCTFail("Expected a class RO diagnostic for \(path)")
                continue
            }
            XCTAssertEqual(
                diagnostic.subject,
                .classObject(offset: SyntheticFieldImageFixture.classOffset)
            )
            XCTAssertEqual(diagnostic.role, .instance)
            XCTAssertEqual(
                diagnostic.failure,
                .unreadableImageRange(
                    address: SyntheticFieldImageFixture.unreadableAddress,
                    byteCount: MemoryLayout<ObjCClassROData64.Layout>.size
                )
            )
        }
    }

    func testLoadedIvarOffsetDistinguishesUnreadableStorageFromAbsence() {
        let fixture = SyntheticFieldImageFixture(path: .direct)
        let unreadable = ObjCIvar64(
            layout: .init(
                offset: UInt64(SyntheticFieldImageFixture.unreadableAddress),
                name: 0,
                type: 0,
                alignment: 0,
                size: 0
            ),
            offset: 0
        )
        XCTAssertEqual(
            unreadable.readOffset(in: fixture.machO).failureForTesting,
            .unreadableImageRange(
                address: SyntheticFieldImageFixture.unreadableAddress,
                byteCount: MemoryLayout<UInt32>.size
            )
        )

        let absent = ObjCIvar64(
            layout: .init(
                offset: 0,
                name: 0,
                type: 0,
                alignment: 0,
                size: 0
            ),
            offset: 0
        )
        guard case .absent = absent.readOffset(in: fixture.machO) else {
            return XCTFail("A null ivar offset field must remain structurally absent")
        }
    }
}

private extension ObjCMetadataFieldRead {
    var failureForTesting: ObjCMetadataFieldDiagnostic.Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private final class SyntheticFieldFileFixture {
    static let fileSize = 0x4000
    static let vmAddress: UInt64 = 0x1_0000_0000
    static let classOffset = 0x400
    static let metaClassOffset = 0x480
    static let classROOffset = 0x500
    static let metaClassROOffset = 0x580
    static let ivarListOffset = 0x700
    static let classNameOffset = 0x1000
    static let ivarNameBaseOffset = 0x1100
    static let ivarNameStride = 0x40
    static let ivarTypeOffset = 0x1300
    static let ivarValueBaseOffset = 0x1400
    static let truncatedClassROOffset = fileSize - 8

    enum ClassROStorage {
        case valid
        case truncated
    }

    struct Ivar {
        let name: String
        let offsetStorage: OffsetStorage

        enum OffsetStorage {
            case value(UInt32)
            case truncated(bytesFromEnd: Int)
        }
    }

    let machO: MachOFile
    let objcClass: ObjCClass64
    private let url: URL

    init(
        instanceROStorage: ClassROStorage = .valid,
        metaROStorage: ClassROStorage = .valid,
        ivars: [Ivar] = []
    ) throws {
        var data = Data(count: Self.fileSize)

        var machHeader = mach_header_64()
        machHeader.magic = UInt32(MH_MAGIC_64)
        machHeader.cputype = CPU_TYPE_ARM64
        machHeader.cpusubtype = CPU_SUBTYPE_ARM64_ALL
        machHeader.filetype = UInt32(MH_DYLIB)
        machHeader.ncmds = 1
        machHeader.sizeofcmds = UInt32(MemoryLayout<segment_command_64>.size)
        data.store(machHeader, at: 0)

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

        func address(_ offset: Int) -> UInt64 {
            Self.vmAddress + UInt64(offset)
        }

        data.storeCString("FieldOwner", at: Self.classNameOffset)
        data.storeCString("i", at: Self.ivarTypeOffset)

        if !ivars.isEmpty {
            let header = EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCIvar64.Layout>.size),
                    count: UInt32(ivars.count)
                )
            )
            data.store(header, at: Self.ivarListOffset)
            for (index, ivar) in ivars.enumerated() {
                let nameOffset = Self.ivarNameBaseOffset + index * Self.ivarNameStride
                data.storeCString(ivar.name, at: nameOffset)

                let offsetAddress: UInt64
                switch ivar.offsetStorage {
                case .value(let value):
                    let valueOffset = Self.ivarValueBaseOffset + index * MemoryLayout<UInt32>.size
                    data.store(value, at: valueOffset)
                    offsetAddress = address(valueOffset)
                case .truncated(let bytesFromEnd):
                    precondition(bytesFromEnd > 0 && bytesFromEnd < MemoryLayout<UInt32>.size)
                    offsetAddress = address(Self.fileSize - bytesFromEnd)
                }

                let layout = ObjCIvar64.Layout(
                    offset: offsetAddress,
                    name: address(nameOffset),
                    type: address(Self.ivarTypeOffset),
                    alignment: 2,
                    size: UInt32(MemoryLayout<UInt32>.size)
                )
                let entryOffset = Self.ivarListOffset
                    + MemoryLayout<EntrySizeListHeader>.size
                    + index * MemoryLayout<ObjCIvar64.Layout>.size
                data.store(layout, at: entryOffset)
            }
        }

        let classRO = ObjCClassROData64.Layout(
            flags: 0,
            instanceStart: 0,
            instanceSize: UInt32(max(1, ivars.count) * MemoryLayout<UInt32>.size),
            _reserved: 0,
            ivarLayout: 0,
            name: address(Self.classNameOffset),
            baseMethods: 0,
            baseProtocols: 0,
            ivars: ivars.isEmpty ? 0 : address(Self.ivarListOffset),
            weakIvarLayout: 0,
            baseProperties: 0
        )
        let metaRO = ObjCClassROData64.Layout(
            flags: 0,
            instanceStart: 0,
            instanceSize: 0,
            _reserved: 0,
            ivarLayout: 0,
            name: address(Self.classNameOffset),
            baseMethods: 0,
            baseProtocols: 0,
            ivars: 0,
            weakIvarLayout: 0,
            baseProperties: 0
        )
        data.store(classRO, at: Self.classROOffset)
        data.store(metaRO, at: Self.metaClassROOffset)

        func classROAddress(for storage: ClassROStorage, validOffset: Int) -> UInt64 {
            switch storage {
            case .valid:
                address(validOffset)
            case .truncated:
                address(Self.truncatedClassROOffset)
            }
        }

        let classLayout = ObjCClass64.Layout(
            isa: address(Self.metaClassOffset),
            superclass: 0,
            methodCacheBuckets: 0,
            methodCacheProperties: 0,
            dataVMAddrAndFastFlags: classROAddress(
                for: instanceROStorage,
                validOffset: Self.classROOffset
            ),
            swiftClassFlags: 0
        )
        let metaClassLayout = ObjCClass64.Layout(
            isa: address(Self.metaClassOffset),
            superclass: 0,
            methodCacheBuckets: 0,
            methodCacheProperties: 0,
            dataVMAddrAndFastFlags: classROAddress(
                for: metaROStorage,
                validOffset: Self.metaClassROOffset
            ),
            swiftClassFlags: 0
        )
        data.store(classLayout, at: Self.classOffset)
        data.store(metaClassLayout, at: Self.metaClassOffset)

        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MachOObjCSection-field-diagnostics-\(UUID().uuidString)"
        )
        try data.write(to: url)
        machO = try MachOFile(url: url)
        objcClass = ObjCClass64(layout: classLayout, offset: Self.classOffset)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class SyntheticFieldImageFixture {
    enum Path: CaseIterable {
        case direct
        case readWriteData
        case readWriteExtension
    }

    static let classOffset = 0x400
    static let unreadableAddress: UInt = 0x10
    private static let storageSize = 0x1000
    private static let readWriteDataOffset = 0x200
    private static let readWriteExtensionOffset = 0x280
    private static let readWritePointerFlag: UInt64 = 0x8000_0000_0000_0000

    let machO: MachOImage
    let objcClass: ObjCClass64
    private let storage: UnsafeMutableRawPointer

    init(path: Path) {
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Self.storageSize,
            alignment: 16
        )
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: Self.storageSize)
        self.storage = storage

        let baseAddress = UInt64(UInt(bitPattern: storage))
        var machHeader = mach_header_64()
        machHeader.magic = UInt32(MH_MAGIC_64)
        machHeader.cputype = CPU_TYPE_ARM64
        machHeader.cpusubtype = CPU_SUBTYPE_ARM64_ALL
        machHeader.filetype = UInt32(MH_DYLIB)
        machHeader.ncmds = 1
        machHeader.sizeofcmds = UInt32(MemoryLayout<segment_command_64>.size)
        storage.storeUnaligned(machHeader)

        var segment = segment_command_64()
        segment.cmd = UInt32(LC_SEGMENT_64)
        segment.cmdsize = UInt32(MemoryLayout<segment_command_64>.size)
        segment.vmaddr = baseAddress
        segment.vmsize = UInt64(Self.storageSize)
        segment.fileoff = 0
        segment.filesize = UInt64(Self.storageSize)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        storage.advanced(by: MemoryLayout<mach_header_64>.size).storeUnaligned(segment)

        let dataPointer: UInt64
        switch path {
        case .direct:
            dataPointer = UInt64(Self.unreadableAddress)
        case .readWriteData:
            let address = baseAddress + UInt64(Self.readWriteDataOffset)
            storage.advanced(by: Self.readWriteDataOffset).storeUnaligned(
                ObjCClassRWData64.Layout(
                    flags: 0,
                    witness: 0,
                    index: 0,
                    ro_or_rw_ext: UInt64(Self.unreadableAddress),
                    firstSubclass: 0,
                    nextSiblingClass: 0
                )
            )
            dataPointer = address | Self.readWritePointerFlag
        case .readWriteExtension:
            let readWriteAddress = baseAddress + UInt64(Self.readWriteDataOffset)
            let extensionAddress = baseAddress + UInt64(Self.readWriteExtensionOffset)
            storage.advanced(by: Self.readWriteDataOffset).storeUnaligned(
                ObjCClassRWData64.Layout(
                    flags: 0,
                    witness: 0,
                    index: 0,
                    ro_or_rw_ext: extensionAddress | 1,
                    firstSubclass: 0,
                    nextSiblingClass: 0
                )
            )
            storage.advanced(by: Self.readWriteExtensionOffset).storeUnaligned(
                ObjCClassRWDataExt64.Layout(
                    ro: UInt64(Self.unreadableAddress),
                    methods: 0,
                    properties: 0,
                    protocols: 0,
                    demangledName: 0,
                    version: 0
                )
            )
            dataPointer = readWriteAddress | Self.readWritePointerFlag
        }

        machO = MachOImage(ptr: storage.assumingMemoryBound(to: mach_header.self))
        objcClass = ObjCClass64(
            layout: .init(
                isa: 0,
                superclass: 0,
                methodCacheBuckets: 0,
                methodCacheProperties: 0,
                dataVMAddrAndFastFlags: dataPointer,
                swiftClassFlags: 0
            ),
            offset: Self.classOffset
        )
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

    mutating func storeCString(_ value: String, at offset: Int) {
        let bytes = Array(value.utf8) + [0]
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
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
