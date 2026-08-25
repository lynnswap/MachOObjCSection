import Foundation
@_spi(Core) @testable import MachOObjCSection
import MachOKit
import XCTest

final class ObjCFileMemberTableSafetyTests: XCTestCase {
    func testPointerMethodsSkipMalformedImplementationAndPreserveOrderFor32And64BitFiles() throws {
        for is64Bit in [false, true] {
            let fixture = try DirectMemberFileFixture(is64Bit: is64Bit)
            let list = fixture.writePointerMethods(
                names: ["first", "broken", "last"],
                invalidImplementationIndex: 1
            )

            let outcome = list.readMethods(in: fixture.machO)

            XCTAssertEqual(outcome.values?.map(\.name), ["first", "last"])
            XCTAssertEqual(outcome.success?.failures, [
                .init(index: 1, reason: .invalidImplementationOffset),
            ])
            XCTAssertEqual(list.methods(in: fixture.machO)?.map(\.name), ["first", "last"])
        }
    }

    func testAllRelativeMethodEncodingsUseTheCheckedDirectProjection() throws {
        let kinds: [ObjCMethod.Kind] = [
            .relativeIndirect,
            .relativeDirectSelectors,
            .relativeDirectSelectorsAndTypes,
        ]
        for kind in kinds {
            let fixture = try DirectMemberFileFixture(is64Bit: true)
            let list = fixture.writeRelativeMethod(kind: kind)

            let outcome = list.readMethods(in: fixture.machO)

            XCTAssertEqual(outcome.values?.map(\.name), ["relativeName"], "Unexpected \(kind)")
            XCTAssertEqual(outcome.values?.map(\.types), ["v@:"], "Unexpected \(kind)")
            XCTAssertEqual(outcome.values?.map(\.imp), [UInt64(DirectMemberFileFixture.impOffset)])
            XCTAssertTrue(outcome.success?.failures.isEmpty == true)
            XCTAssertEqual(
                list.methods(in: fixture.machO)?.map(\.name),
                outcome.values?.map(\.name)
            )
        }
    }

    func testRelativeMethodArithmeticSkipsOnlyTheInvalidEntry() throws {
        let fixture = try DirectMemberFileFixture(is64Bit: true)
        let list = fixture.writeRelativeMethodsWithInvalidMiddle()

        let outcome = list.readMethods(in: fixture.machO)

        XCTAssertEqual(outcome.values?.map(\.name), ["relativeFirst", "relativeLast"])
        XCTAssertEqual(outcome.success?.failures, [
            .init(index: 1, reason: .invalidRelativeDisplacement),
        ])
        XCTAssertEqual(
            list.methods(in: fixture.machO)?.map(\.name),
            ["relativeFirst", "relativeLast"]
        )
    }

    func testPropertiesAndIvarsDecodeFor32And64BitFiles() throws {
        for is64Bit in [false, true] {
            let fixture = try DirectMemberFileFixture(is64Bit: is64Bit)
            let propertyList = fixture.writeProperty(name: "property", attributes: "T@")

            XCTAssertEqual(
                propertyList.readProperties(in: fixture.machO).values?.map(\.name),
                ["property"]
            )
            XCTAssertEqual(propertyList.properties(in: fixture.machO).map(\.attributes), ["T@"])

            let ivarList = fixture.writeIvar(name: "ivar", type: "i", value: 24)
            if is64Bit {
                let list = try XCTUnwrap(ivarList as? ObjCIvarList64)
                XCTAssertEqual(list.readIvars(in: fixture.machO).values?.map { $0.name(in: fixture.machO) }, ["ivar"])
                XCTAssertEqual(list.ivars(in: fixture.machO)?.compactMap { $0.offset(in: fixture.machO) }, [24])
            } else {
                let list = try XCTUnwrap(ivarList as? ObjCIvarList32)
                XCTAssertEqual(list.readIvars(in: fixture.machO).values?.map { $0.name(in: fixture.machO) }, ["ivar"])
                XCTAssertEqual(list.ivars(in: fixture.machO)?.compactMap { $0.offset(in: fixture.machO) }, [24])
            }
        }
    }

    func testTruncatedAndExcessiveMethodTablesFailWithoutPublicQueryTrap() throws {
        let truncatedFixture = try DirectMemberFileFixture(
            is64Bit: true,
            fileSize: DirectMemberFileFixture.listOffset
                + MemoryLayout<EntrySizeListHeader>.size
        )
        let truncatedHeader = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(MemoryLayout<ObjCMethod.Pointer64>.size),
                count: 1
            )
        )
        let truncated = ObjCMethodList(
            offset: DirectMemberFileFixture.listOffset,
            header: truncatedHeader,
            is64Bit: true
        )
        XCTAssertNil(truncated.methods(in: truncatedFixture.machO))
        XCTAssertEqual(
            truncated.readMethods(in: truncatedFixture.machO).failure,
            .unreadableFileRange(
                offset: UInt64(truncatedFixture.fileSize),
                byteCount: MemoryLayout<ObjCMethod.Pointer64>.size
            )
        )

        let excessiveFixture = try DirectMemberFileFixture(is64Bit: true)
        let excessiveCount = ObjCMetadataReadLimits.maximumListEntries + 1
        let excessive = ObjCMethodList(
            offset: DirectMemberFileFixture.listOffset,
            header: .init(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCMethod.Pointer64>.size),
                    count: UInt32(excessiveCount)
                )
            ),
            is64Bit: true
        )
        XCTAssertNil(excessive.methods(in: excessiveFixture.machO))
        XCTAssertEqual(
            excessive.readMethods(in: excessiveFixture.machO).failure,
            .excessiveElementCount(
                actual: excessiveCount,
                maximum: ObjCMetadataReadLimits.maximumListEntries
            )
        )
    }

    func testEmptyMemberTablesIgnoreUnusedStrideAndAlignment() throws {
        let fixture = try DirectMemberFileFixture(is64Bit: true)
        let header = EntrySizeListHeader(
            layout: .init(entsizeAndFlags: UInt32.max, count: 0)
        )
        let method = ObjCMethodList(
            offset: DirectMemberFileFixture.listOffset + 2,
            header: header,
            is64Bit: true
        )
        let property = ObjCPropertyList(
            offset: DirectMemberFileFixture.propertyListOffset + 2,
            header: header,
            is64Bit: true
        )
        let ivar = ObjCIvarList64(
            header: header,
            offset: DirectMemberFileFixture.ivarListOffset + 1
        )

        XCTAssertEqual(method.methods(in: fixture.machO)?.count, 0)
        XCTAssertEqual(property.properties(in: fixture.machO).count, 0)
        XCTAssertEqual(ivar.ivars(in: fixture.machO)?.count, 0)
    }

    func testLoadedMethodPropertyAndIvarTablesUseTheSharedReader() {
        let fixture = DirectMemberImageFixture()

        XCTAssertEqual(fixture.methodList.methods(in: fixture.machO).map(\.name), ["imageMethod"])
        XCTAssertEqual(
            fixture.propertyList.properties(in: fixture.machO).map(\.name),
            ["imageProperty"]
        )
        XCTAssertEqual(
            fixture.ivarList.ivars(in: fixture.machO)?.map { $0.name(in: fixture.machO) },
            ["imageIvar"]
        )
    }
}

private final class DirectMemberImageFixture {
    private static let storageSize = 0x2000
    private static let methodListOffset = 0x400
    private static let propertyListOffset = 0x800
    private static let ivarListOffset = 0xc00
    private static let methodNameOffset = 0x1000
    private static let propertyNameOffset = 0x1080
    private static let ivarNameOffset = 0x1100
    private static let methodTypeOffset = 0x1180
    private static let propertyTypeOffset = 0x1200
    private static let ivarTypeOffset = 0x1280
    private static let ivarValueOffset = 0x1300

    let machO: MachOImage
    let methodList: ObjCMethodList
    let propertyList: ObjCPropertyList
    let ivarList: ObjCIvarList64
    private let storage: UnsafeMutableRawPointer

    init() {
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Self.storageSize,
            alignment: 16
        )
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: Self.storageSize)
        self.storage = storage

        let baseAddress = UInt64(UInt(bitPattern: storage))
        var header = mach_header_64()
        header.magic = UInt32(MH_MAGIC_64)
        header.cputype = CPU_TYPE_ARM64
        header.cpusubtype = CPU_SUBTYPE_ARM64_ALL
        header.filetype = UInt32(MH_DYLIB)
        header.ncmds = 1
        header.sizeofcmds = UInt32(MemoryLayout<segment_command_64>.size)
        storage.storeUnaligned(header)

        var segment = segment_command_64()
        segment.cmd = UInt32(LC_SEGMENT_64)
        segment.cmdsize = UInt32(MemoryLayout<segment_command_64>.size)
        segment.vmaddr = baseAddress
        segment.vmsize = UInt64(Self.storageSize)
        segment.filesize = UInt64(Self.storageSize)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        storage.advanced(by: MemoryLayout<mach_header_64>.size).storeUnaligned(segment)

        storage.advanced(by: Self.methodNameOffset).storeCString("imageMethod")
        storage.advanced(by: Self.propertyNameOffset).storeCString("imageProperty")
        storage.advanced(by: Self.ivarNameOffset).storeCString("imageIvar")
        storage.advanced(by: Self.methodTypeOffset).storeCString("v@:")
        storage.advanced(by: Self.propertyTypeOffset).storeCString("T@")
        storage.advanced(by: Self.ivarTypeOffset).storeCString("i")
        storage.advanced(by: Self.ivarValueOffset).storeUnaligned(UInt32(32))

        let methodHeader = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(MemoryLayout<ObjCMethod.Pointer>.size),
                count: 1
            )
        )
        storage.advanced(by: Self.methodListOffset).storeUnaligned(methodHeader)
        storage.advanced(
            by: Self.methodListOffset + MemoryLayout<EntrySizeListHeader>.size
        ).storeUnaligned(
            ObjCMethod.Pointer(
                name: UnsafePointer(
                    storage.advanced(by: Self.methodNameOffset).assumingMemoryBound(to: CChar.self)
                ),
                types: UnsafePointer(
                    storage.advanced(by: Self.methodTypeOffset).assumingMemoryBound(to: CChar.self)
                ),
                imp: OpaquePointer(storage.advanced(by: 0x200))
            )
        )

        let propertyHeader = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(MemoryLayout<ObjCProperty.Property>.size),
                count: 1
            )
        )
        storage.advanced(by: Self.propertyListOffset).storeUnaligned(propertyHeader)
        storage.advanced(
            by: Self.propertyListOffset + MemoryLayout<EntrySizeListHeader>.size
        ).storeUnaligned(
            ObjCProperty.Property(
                name: UnsafePointer(
                    storage.advanced(by: Self.propertyNameOffset).assumingMemoryBound(to: CChar.self)
                ),
                attributes: UnsafePointer(
                    storage.advanced(by: Self.propertyTypeOffset).assumingMemoryBound(to: CChar.self)
                )
            )
        )

        let ivarHeader = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(MemoryLayout<ObjCIvar64.Layout>.size),
                count: 1
            )
        )
        storage.advanced(by: Self.ivarListOffset).storeUnaligned(ivarHeader)
        storage.advanced(
            by: Self.ivarListOffset + MemoryLayout<EntrySizeListHeader>.size
        ).storeUnaligned(
            ObjCIvar64.Layout(
                offset: baseAddress + UInt64(Self.ivarValueOffset),
                name: baseAddress + UInt64(Self.ivarNameOffset),
                type: baseAddress + UInt64(Self.ivarTypeOffset),
                alignment: 2,
                size: 4
            )
        )

        machO = MachOImage(ptr: storage.assumingMemoryBound(to: mach_header.self))
        methodList = .init(
            offset: Self.methodListOffset,
            header: methodHeader,
            is64Bit: true
        )
        propertyList = .init(
            offset: Self.propertyListOffset,
            header: propertyHeader,
            is64Bit: true
        )
        ivarList = .init(header: ivarHeader, offset: Self.ivarListOffset)
    }

    deinit {
        storage.deallocate()
    }
}

private extension ObjCMemberTableReadOutcome {
    var success: ObjCMemberTableReadSuccess<Value>? {
        guard case .success(let success) = self else { return nil }
        return success
    }

    var failure: ObjCMetadataTableFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private final class DirectMemberFileFixture {
    static let listOffset = 0x400
    static let propertyListOffset = 0x800
    static let ivarListOffset = 0xc00
    static let nameOffset = 0x1200
    static let typeOffset = 0x1300
    static let indirectNamePointerOffset = 0x1400
    static let ivarValueOffset = 0x1500
    static let impOffset = 0x200

    let is64Bit: Bool
    let fileSize: Int
    private(set) var machO: MachOFile
    private let url: URL
    private var data: Data
    private let vmAddress: UInt64 = 0x1000_0000

    init(is64Bit: Bool, fileSize: Int = 0x2000) throws {
        self.is64Bit = is64Bit
        self.fileSize = fileSize
        self.data = Data(count: fileSize)
        self.url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MachOObjCSection-direct-members-\(UUID().uuidString)"
        )
        Self.writeMachOHeader(
            into: &data,
            is64Bit: is64Bit,
            fileSize: fileSize,
            vmAddress: vmAddress
        )
        try data.write(to: url)
        self.machO = try MachOFile(url: url)
    }

    func writePointerMethods(
        names: [String],
        invalidImplementationIndex: Int?
    ) -> ObjCMethodList {
        let entrySize = is64Bit
            ? MemoryLayout<ObjCMethod.Pointer64>.size
            : MemoryLayout<ObjCMethod.Pointer32>.size
        let header = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(entrySize),
                count: UInt32(names.count)
            )
        )
        data.store(header, at: Self.listOffset)
        for (index, name) in names.enumerated() {
            let nameOffset = Self.nameOffset + index * 0x40
            let typeOffset = Self.typeOffset + index * 0x40
            data.storeCString(name, at: nameOffset)
            data.storeCString("v@:", at: typeOffset)
            let implementation = invalidImplementationIndex == index
                ? UInt64(1)
                : address(Self.impOffset + index * 4)
            let entryOffset = Self.listOffset
                + MemoryLayout<EntrySizeListHeader>.size
                + index * entrySize
            if is64Bit {
                data.store(
                    ObjCMethod.Pointer64(
                        name: address(nameOffset),
                        types: address(typeOffset),
                        imp: implementation
                    ),
                    at: entryOffset
                )
            } else {
                data.store(
                    ObjCMethod.Pointer32(
                        name: UInt32(address(nameOffset)),
                        types: UInt32(address(typeOffset)),
                        imp: UInt32(implementation)
                    ),
                    at: entryOffset
                )
            }
        }
        reload()
        return .init(offset: Self.listOffset, header: header, is64Bit: is64Bit)
    }

    func writeRelativeMethod(kind: ObjCMethod.Kind) -> ObjCMethodList {
        precondition(is64Bit)
        data.storeCString("relativeName", at: Self.nameOffset)
        data.storeCString("v@:", at: Self.typeOffset)
        data.store(address(Self.nameOffset), at: Self.indirectNamePointerOffset)
        let entryOffset = Self.listOffset + MemoryLayout<EntrySizeListHeader>.size

        let flags: UInt32
        switch kind {
        case .pointer:
            preconditionFailure("Relative fixture requires a relative method kind")
        case .relativeIndirect:
            flags = ObjCMethodListMask.isRelative
            data.store(
                ObjCMethod.RelativeInDirect(
                    name: .init(rawPointer: .init(
                        offset: Int32(Self.indirectNamePointerOffset - entryOffset)
                    )),
                    types: .init(rawPointer: .init(
                        offset: Int32(Self.typeOffset - (entryOffset + 4))
                    )),
                    imp: .init(rawPointer: .init(
                        offset: Int32(Self.impOffset - (entryOffset + 8))
                    ))
                ),
                at: entryOffset
            )
        case .relativeDirectSelectors:
            flags = ObjCMethodListMask.isRelative | ObjCMethodListMask.usesSelectorOffsets
            data.store(
                relativeDirectLayout(
                    entryOffset: entryOffset,
                    typesUseSelectorBase: false
                ),
                at: entryOffset
            )
        case .relativeDirectSelectorsAndTypes:
            flags = ObjCMethodListMask.isRelative | ObjCMethodListMask.usesTypeOffsets
            data.store(
                relativeDirectLayout(
                    entryOffset: entryOffset,
                    typesUseSelectorBase: true
                ),
                at: entryOffset
            )
        }
        let header = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(MemoryLayout<ObjCMethod.RelativeDirect>.size) | flags,
                count: 1
            )
        )
        data.store(header, at: Self.listOffset)
        reload()
        return .init(offset: Self.listOffset, header: header, is64Bit: true)
    }

    func writeRelativeMethodsWithInvalidMiddle() -> ObjCMethodList {
        precondition(is64Bit)
        let names = ["relativeFirst", "relativeBroken", "relativeLast"]
        let entrySize = MemoryLayout<ObjCMethod.RelativeDirect>.size
        let header = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(entrySize)
                    | ObjCMethodListMask.isRelative
                    | ObjCMethodListMask.usesSelectorOffsets,
                count: UInt32(names.count)
            )
        )
        data.store(header, at: Self.listOffset)
        for (index, name) in names.enumerated() {
            let nameOffset = Self.nameOffset + index * 0x40
            let typeOffset = Self.typeOffset + index * 0x40
            data.storeCString(name, at: nameOffset)
            data.storeCString("v@:", at: typeOffset)
            let entryOffset = Self.listOffset
                + MemoryLayout<EntrySizeListHeader>.size
                + index * entrySize
            let implementationDisplacement = index == 1
                ? Int32.min
                : Int32(Self.impOffset - (entryOffset + 8))
            data.store(
                ObjCMethod.RelativeDirect(
                    name: .init(rawPointer: .init(offset: Int32(nameOffset))),
                    types: .init(rawPointer: .init(
                        offset: Int32(typeOffset - (entryOffset + 4))
                    )),
                    imp: .init(rawPointer: .init(offset: implementationDisplacement))
                ),
                at: entryOffset
            )
        }
        reload()
        return .init(offset: Self.listOffset, header: header, is64Bit: true)
    }

    func writeProperty(name: String, attributes: String) -> ObjCPropertyList {
        data.storeCString(name, at: Self.nameOffset)
        data.storeCString(attributes, at: Self.typeOffset)
        let entrySize = is64Bit
            ? MemoryLayout<ObjCProperty.Property64>.size
            : MemoryLayout<ObjCProperty.Property32>.size
        let header = EntrySizeListHeader(
            layout: .init(entsizeAndFlags: UInt32(entrySize), count: 1)
        )
        data.store(header, at: Self.propertyListOffset)
        let entryOffset = Self.propertyListOffset + MemoryLayout<EntrySizeListHeader>.size
        if is64Bit {
            data.store(
                ObjCProperty.Property64(
                    name: address(Self.nameOffset),
                    attributes: address(Self.typeOffset)
                ),
                at: entryOffset
            )
        } else {
            data.store(
                ObjCProperty.Property32(
                    name: UInt32(address(Self.nameOffset)),
                    attributes: UInt32(address(Self.typeOffset))
                ),
                at: entryOffset
            )
        }
        reload()
        return .init(offset: Self.propertyListOffset, header: header, is64Bit: is64Bit)
    }

    func writeIvar(name: String, type: String, value: UInt32) -> Any {
        data.storeCString(name, at: Self.nameOffset)
        data.storeCString(type, at: Self.typeOffset)
        data.store(value, at: Self.ivarValueOffset)
        let header: EntrySizeListHeader
        let entryOffset = Self.ivarListOffset + MemoryLayout<EntrySizeListHeader>.size
        if is64Bit {
            header = .init(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCIvar64.Layout>.size),
                    count: 1
                )
            )
            data.store(header, at: Self.ivarListOffset)
            data.store(
                ObjCIvar64.Layout(
                    offset: address(Self.ivarValueOffset),
                    name: address(Self.nameOffset),
                    type: address(Self.typeOffset),
                    alignment: 2,
                    size: 4
                ),
                at: entryOffset
            )
            reload()
            return ObjCIvarList64(header: header, offset: Self.ivarListOffset)
        } else {
            header = .init(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCIvar32.Layout>.size),
                    count: 1
                )
            )
            data.store(header, at: Self.ivarListOffset)
            data.store(
                ObjCIvar32.Layout(
                    offset: UInt32(address(Self.ivarValueOffset)),
                    name: UInt32(address(Self.nameOffset)),
                    type: UInt32(address(Self.typeOffset)),
                    alignment: 2,
                    size: 4
                ),
                at: entryOffset
            )
            reload()
            return ObjCIvarList32(header: header, offset: Self.ivarListOffset)
        }
    }

    private func relativeDirectLayout(
        entryOffset: Int,
        typesUseSelectorBase: Bool
    ) -> ObjCMethod.RelativeDirect {
        ObjCMethod.RelativeDirect(
            name: .init(rawPointer: .init(offset: Int32(Self.nameOffset))),
            types: .init(rawPointer: .init(
                offset: Int32(
                    typesUseSelectorBase
                        ? Self.typeOffset
                        : Self.typeOffset - (entryOffset + 4)
                )
            )),
            imp: .init(rawPointer: .init(
                offset: Int32(Self.impOffset - (entryOffset + 8))
            ))
        )
    }

    private func address(_ offset: Int) -> UInt64 {
        vmAddress + UInt64(offset)
    }

    private func reload() {
        do {
            try data.write(to: url, options: .atomic)
            machO = try MachOFile(url: url)
        } catch {
            preconditionFailure("DirectMemberFileFixture owns a writable temporary file: \(error)")
        }
    }

    private static func writeMachOHeader(
        into data: inout Data,
        is64Bit: Bool,
        fileSize: Int,
        vmAddress: UInt64
    ) {
        if is64Bit {
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
            segment.vmaddr = vmAddress
            segment.vmsize = UInt64(fileSize)
            segment.filesize = UInt64(fileSize)
            segment.maxprot = VM_PROT_READ
            segment.initprot = VM_PROT_READ
            data.store(segment, at: MemoryLayout<mach_header_64>.size)
        } else {
            var header = mach_header()
            header.magic = UInt32(MH_MAGIC)
            header.cputype = CPU_TYPE_I386
            header.cpusubtype = 3
            header.filetype = UInt32(MH_DYLIB)
            header.ncmds = 1
            header.sizeofcmds = UInt32(MemoryLayout<segment_command>.size)
            data.store(header, at: 0)

            var segment = segment_command()
            segment.cmd = UInt32(LC_SEGMENT)
            segment.cmdsize = UInt32(MemoryLayout<segment_command>.size)
            segment.vmaddr = UInt32(vmAddress)
            segment.vmsize = UInt32(fileSize)
            segment.filesize = UInt32(fileSize)
            segment.maxprot = VM_PROT_READ
            segment.initprot = VM_PROT_READ
            data.store(segment, at: MemoryLayout<mach_header>.size)
        }
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

    func storeCString(_ value: String) {
        let bytes = Array(value.utf8) + [0]
        bytes.withUnsafeBytes { buffer in
            copyMemory(from: buffer.baseAddress!, byteCount: buffer.count)
        }
    }
}
