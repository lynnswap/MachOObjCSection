import Foundation
import XCTest
@_spi(Core) @_spi(Diagnostics) @testable import MachOObjCSection
@testable import MachOKit

final class ObjCProtocolSafetyTests: XCTestCase {
    func testFileProtocolListsRejectInvalidCountsAndRangesWithoutTrapping() throws {
        let fixture = try SyntheticFileFixture(nodes: [.init(name: "A")])

        let invalidCount = ObjCProtocolList64(
            offset: SyntheticGraph.protocolListOffset(for: 0),
            header: .init(_count: .max)
        )
        XCTAssertNil(invalidCount.protocols(in: fixture.machO))
        assertTableFailure(invalidCount.readProtocols(in: fixture.machO)) {
            guard case .invalidElementCount(.max) = $0 else { return false }
            return true
        }

        let overflowingCount = UInt64(Int.max / MemoryLayout<UInt64>.size + 1)
        let byteOverflow = ObjCProtocolList64(
            offset: SyntheticGraph.protocolListOffset(for: 0),
            header: .init(_count: overflowingCount)
        )
        assertTableFailure(byteOverflow.readProtocols(in: fixture.machO)) {
            guard case .byteCountOverflow = $0 else { return false }
            return true
        }

        let endOfFile = fixture.data.count - MemoryLayout<ObjCProtocolListHeader64>.size
        let outOfBounds = ObjCProtocolList64(
            offset: endOfFile,
            header: .init(_count: 1)
        )
        XCTAssertNil(outOfBounds.protocols(in: fixture.machO))
        assertTableFailure(outOfBounds.readProtocols(in: fixture.machO)) {
            guard case .unreadableFileRange = $0 else { return false }
            return true
        }

        let outOfBounds32 = ObjCProtocolList32(
            offset: fixture.data.count - MemoryLayout<ObjCProtocolListHeader32>.size,
            header: .init(_count: 1)
        )
        XCTAssertNil(outOfBounds32.protocols(in: fixture.machO))
    }

    func testImageProtocolListsRejectCountAndAddressOverflowWithoutDereference() throws {
        let fixture = SyntheticImageFixture(nodes: [.init(name: "A")])
        let invalidCount = ObjCProtocolList64(
            offset: SyntheticGraph.protocolListOffset(for: 0),
            header: .init(_count: .max)
        )
        XCTAssertNil(invalidCount.protocols(in: fixture.machO))

        let count = Int.max / MemoryLayout<UInt64>.size
        let overflowingRange = ObjCProtocolList64(
            offset: Int.max - 1,
            header: .init(_count: UInt64(count))
        )
        assertTableFailure(overflowingRange.readProtocols(in: fixture.machO)) {
            guard case .rangeOverflow = $0 else { return false }
            return true
        }
    }

    func testRelativeProtocolListTableFailureReturnsNilWithoutTrapping() throws {
        let fixture = try SyntheticFileFixture(nodes: [.init(name: "A")])
        let relative = ObjCProtocolRelativeListList64(
            offset: fixture.data.count - MemoryLayout<EntrySizeListHeader>.size,
            header: .init(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<RelativeListListEntry.Layout>.size),
                    count: 1
                )
            )
        )
        XCTAssertNil(relative.safelyReadList(in: fixture.machO, forImageIndex: 0))
    }

    func testFileProtocolListSkipsOnlyInvalidEntryAndReportsItsIndex() throws {
        let fixture = try SyntheticFileFixture(
            nodes: [
                .init(name: "A", children: [.node(1), .invalid]),
                .init(name: "B")
            ]
        )

        let result = fixture.protocols[0].readInfo(in: fixture.machO)
        XCTAssertEqual(result.value?.protocols.map(\.name), ["B"])
        XCTAssertEqual(result.diagnostics.count, 1)
        guard case .unreadableList(let diagnostic) = result.diagnostics[0] else {
            return XCTFail("Expected unreadable-list diagnostic")
        }
        XCTAssertEqual(diagnostic.subject, .protocol(name: "A"))
        XCTAssertEqual(diagnostic.protocolPath, ["A"])
        XCTAssertEqual(diagnostic.failure, .unresolvedRebase(entryIndex: 1))
    }

    func testDiagnosticsFollowProtocolListDiscoveryOrder() throws {
        let fixture = try SyntheticFileFixture(
            nodes: [
                .init(name: "A", children: [.invalid, .node(1)]),
                .init(name: "B", children: [.node(1)])
            ]
        )

        let diagnostics = fixture.protocols[0].readInfo(in: fixture.machO).diagnostics
        XCTAssertEqual(diagnostics.count, 2)
        guard case .unreadableList(let unreadable) = diagnostics[0],
              case .cycle(let cycle) = diagnostics[1] else {
            return XCTFail("Expected entry failure before the later nested cycle")
        }
        XCTAssertEqual(unreadable.failure, .unresolvedRebase(entryIndex: 0))
        XCTAssertEqual(cycle.protocolPath, ["A", "B", "B"])
    }

    func testFileProtocolListSkipsUnreadableLayoutButRetainsSibling() throws {
        let fixture = try SyntheticFileFixture(
            nodes: [
                .init(
                    name: "A",
                    children: [
                        .node(1),
                        .offset(SyntheticGraph.fileSize - 4)
                    ]
                ),
                .init(name: "B")
            ]
        )

        let result = fixture.protocols[0].readInfo(in: fixture.machO)
        XCTAssertEqual(result.value?.protocols.map(\.name), ["B"])
        XCTAssertEqual(result.diagnostics.count, 1)
        guard case .unreadableList(let diagnostic) = result.diagnostics[0] else {
            return XCTFail("Expected unreadable-list diagnostic")
        }
        guard case .unreadableFileLayout(let index, _, let byteCount) = diagnostic.failure else {
            return XCTFail("Expected unreadable-layout entry diagnostic")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(byteCount, MemoryLayout<ObjCProtocol64.Layout>.size)
    }

    func test32BitProtocolListRetainsValidEntryBesideInvalidEntry() throws {
        let fixture = try Synthetic32FileFixture()
        let outcome = fixture.list.readProtocols(in: fixture.machO)
        guard case .success(let success) = outcome else {
            return XCTFail("Expected a readable 32-bit pointer table")
        }
        XCTAssertEqual(success.references.count, 1)
        XCTAssertEqual(success.references[0].value.mangledName(in: fixture.machO), "P32")
        XCTAssertEqual(
            success.failures,
            [.init(index: 1, reason: .unresolvedRebase)]
        )
    }

    func testSelfCycleProducesShallowLeafForFileAndLegacyInfoStaysSafe() throws {
        let fixture = try SyntheticFileFixture(
            nodes: [.init(name: "A", children: [.node(0)])]
        )

        let result = fixture.protocols[0].readInfo(in: fixture.machO)
        XCTAssertEqual(result.value?.protocols.map(\.name), ["A"])
        XCTAssertEqual(result.value?.protocols[0].protocols, [])
        XCTAssertEqual(result.diagnostics.count, 1)
        guard case .cycle(let cycle) = result.diagnostics[0] else {
            return XCTFail("Expected cycle diagnostic")
        }
        XCTAssertEqual(cycle.subject, .protocol(name: "A"))
        XCTAssertEqual(cycle.protocolPath, ["A", "A"])

        let legacy = fixture.protocols[0].info(in: fixture.machO)
        XCTAssertEqual(legacy?.protocols.map(\.name), ["A"])
    }

    func testABACycleProducesShallowLeafForImage() throws {
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(name: "A", children: [.node(1)]),
                .init(name: "B", children: [.node(0)])
            ]
        )

        let result = fixture.protocols[0].readInfo(in: fixture.machO)
        XCTAssertEqual(result.value?.protocols.first?.name, "B")
        XCTAssertEqual(result.value?.protocols.first?.protocols.first?.name, "A")
        XCTAssertEqual(result.value?.protocols.first?.protocols.first?.protocols, [])
        XCTAssertEqual(result.diagnostics.count, 1)
        guard case .cycle(let cycle) = result.diagnostics[0] else {
            return XCTFail("Expected cycle diagnostic")
        }
        XCTAssertEqual(cycle.protocolPath, ["A", "B", "A"])
    }

    func testDiamondGraphPreservesSharedDescendantAndStateResetsAcrossRoots() throws {
        let nodes: [SyntheticGraph.Node] = [
            .init(name: "A", children: [.node(1), .node(2)]),
            .init(name: "B", children: [.node(3)]),
            .init(name: "C", children: [.node(3)]),
            .init(name: "D")
        ]
        let fixture = try SyntheticFileFixture(nodes: nodes)

        let result = fixture.protocols[0].readInfo(in: fixture.machO)
        XCTAssertEqual(result.value?.protocols[0].protocols.map(\.name), ["D"])
        XCTAssertEqual(result.value?.protocols[1].protocols.map(\.name), ["D"])
        XCTAssertTrue(result.diagnostics.isEmpty)

        let firstRoot = fixture.protocols[1].readInfo(in: fixture.machO)
        let secondRoot = fixture.protocols[2].readInfo(in: fixture.machO)
        XCTAssertEqual(firstRoot.value?.protocols.map(\.name), ["D"])
        XCTAssertEqual(secondRoot.value?.protocols.map(\.name), ["D"])
        XCTAssertTrue(firstRoot.diagnostics.isEmpty)
        XCTAssertTrue(secondRoot.diagnostics.isEmpty)
    }

    func testHardLimitProducesOneShallowLeafDiagnostic() throws {
        let nodes = (0...65).map { index in
            SyntheticGraph.Node(
                name: "P\(index)",
                children: index < 65 ? [.node(index + 1)] : []
            )
        }
        let fixture = try SyntheticFileFixture(nodes: nodes)

        let result = fixture.protocols[0].readInfo(
            in: fixture.machO,
            options: .init(traversal: .depth(65), referencedProtocolInfo: .full)
        )
        var current = try XCTUnwrap(result.value)
        var traversedNames: [String] = []
        while let child = current.protocols.first {
            traversedNames.append(child.name)
            current = child
        }
        XCTAssertEqual(traversedNames.count, 65)
        XCTAssertEqual(traversedNames.last, "P65")
        XCTAssertEqual(result.diagnostics.count, 1)
        guard case .recursionLimit(let diagnostic) = result.diagnostics[0] else {
            return XCTFail("Expected recursion-limit diagnostic")
        }
        XCTAssertEqual(diagnostic.maximumDepth, 64)
        XCTAssertEqual(diagnostic.protocolPath.count, 66)
        XCTAssertEqual(diagnostic.protocolPath.last, "P65")
    }

    func testDirectProtocolNamesStopsIntentionallyWithoutLimitDiagnostic() throws {
        let fixture = try SyntheticFileFixture(
            nodes: [
                .init(name: "A", children: [.node(1)]),
                .init(name: "B", children: [.node(2)]),
                .init(name: "C")
            ]
        )

        let result = fixture.protocols[0].readInfo(
            in: fixture.machO,
            options: .directProtocolNames
        )
        XCTAssertEqual(result.value?.protocols.map(\.name), ["B"])
        XCTAssertEqual(result.value?.protocols[0].protocols, [])
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testClassProtocolAndCategoryDiagnosticsCarryTheirRootSubjects() throws {
        let file = try SyntheticFileFixture(
            nodes: [.init(name: "A", children: [.node(0)])]
        )
        assertCycleSubject(
            file.objcClass.readInfo(in: file.machO).diagnostics,
            equals: .class(name: "FixtureClass")
        )
        assertCycleSubject(
            file.protocols[0].readInfo(in: file.machO).diagnostics,
            equals: .protocol(name: "A")
        )
        assertCycleSubject(
            file.category.readInfo(in: file.machO).diagnostics,
            equals: .category(className: "FixtureClass", name: "FixtureCategory")
        )

        let image = SyntheticImageFixture(
            nodes: [.init(name: "A", children: [.node(0)])]
        )
        assertCycleSubject(
            image.objcClass.readInfo(in: image.machO).diagnostics,
            equals: .class(name: "FixtureClass")
        )
        assertCycleSubject(
            image.category.readInfo(in: image.machO).diagnostics,
            equals: .category(className: "FixtureClass", name: "FixtureCategory")
        )
    }

    func testLegacyInfoOmitsUnreadableListWithoutTrappingForFileAndImage() throws {
        let nodes = [SyntheticGraph.Node(name: "A", declaredCount: .max)]
        let file = try SyntheticFileFixture(nodes: nodes)
        XCTAssertEqual(file.protocols[0].info(in: file.machO)?.protocols, [])
        let fileResult = file.protocols[0].readInfo(in: file.machO)
        XCTAssertEqual(fileResult.diagnostics.count, 1)

        let image = SyntheticImageFixture(nodes: nodes)
        XCTAssertEqual(image.protocols[0].info(in: image.machO)?.protocols, [])
        let imageResult = image.protocols[0].readInfo(in: image.machO)
        XCTAssertEqual(imageResult.diagnostics.count, 1)
    }

    private func assertTableFailure<Source, Protocol>(
        _ outcome: ObjCProtocolListReadOutcome<Source, Protocol>,
        matches: (ObjCProtocolListTableFailure) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let failure) = outcome else {
            return XCTFail("Expected whole-table failure", file: file, line: line)
        }
        XCTAssertTrue(matches(failure), "Unexpected failure: \(failure)", file: file, line: line)
    }

    private func assertCycleSubject(
        _ diagnostics: [ObjCProtocolDiagnostic],
        equals subject: ObjCProtocolDiagnostic.Subject,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .cycle(let cycle) = diagnostics.first else {
            return XCTFail("Expected cycle diagnostic", file: file, line: line)
        }
        XCTAssertEqual(cycle.subject, subject, file: file, line: line)
    }
}

private enum SyntheticGraph {
    static let fileSize = 0x12000
    static let fileVMAddress: UInt64 = 0x1_0000_0000
    static let classOffset = 0x400
    static let metaClassOffset = 0x480
    static let classROOffset = 0x500
    static let metaClassROOffset = 0x580
    static let classProtocolListOffset = 0x600
    static let categoryOffset = 0x700
    static let categoryProtocolListOffset = 0x780
    static let classNameOffset = 0x800
    static let categoryNameOffset = 0x840
    static let protocolBaseOffset = 0x1000
    static let protocolStride = 0x100
    static let listBaseOffset = 0x8000
    static let listStride = 0x100
    static let nameBaseOffset = 0x10000
    static let nameStride = 0x40

    enum Child {
        case node(Int)
        case invalid
        case offset(Int)
    }

    struct Node {
        let name: String
        let children: [Child]
        let declaredCount: UInt64?

        init(
            name: String,
            children: [Child] = [],
            declaredCount: UInt64? = nil
        ) {
            self.name = name
            self.children = children
            self.declaredCount = declaredCount
        }
    }

    struct Built {
        let data: Data
        let protocolLayouts: [ObjCProtocol64.Layout]
        let classLayout: ObjCClass64.Layout
        let categoryLayout: ObjCCategory64.Layout
    }

    static func protocolOffset(for index: Int) -> Int {
        protocolBaseOffset + protocolStride * index
    }

    static func protocolListOffset(for index: Int) -> Int {
        listBaseOffset + listStride * index
    }

    static func build(
        nodes: [Node],
        pointerBase: UInt64,
        segmentVMAddress: UInt64
    ) -> Built {
        precondition(nodes.count <= 70)
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
        segment.vmaddr = segmentVMAddress
        segment.vmsize = UInt64(fileSize)
        segment.fileoff = 0
        segment.filesize = UInt64(fileSize)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        data.store(segment, at: MemoryLayout<mach_header_64>.size)

        func address(_ offset: Int) -> UInt64 {
            pointerBase + UInt64(offset)
        }

        data.storeCString("FixtureClass", at: classNameOffset)
        data.storeCString("FixtureCategory", at: categoryNameOffset)

        var protocolLayouts: [ObjCProtocol64.Layout] = []
        for (index, node) in nodes.enumerated() {
            let nameOffset = nameBaseOffset + nameStride * index
            data.storeCString(node.name, at: nameOffset)

            let listOffset = protocolListOffset(for: index)
            let declaredCount = node.declaredCount ?? UInt64(node.children.count)
            data.store(ObjCProtocolListHeader64(_count: declaredCount), at: listOffset)
            for (childIndex, child) in node.children.enumerated() {
                let pointer: UInt64
                switch child {
                case .node(let target):
                    pointer = address(protocolOffset(for: target))
                case .invalid:
                    pointer = 0xDEAD_BEEF
                case .offset(let offset):
                    pointer = address(offset)
                }
                data.store(
                    pointer,
                    at: listOffset + MemoryLayout<ObjCProtocolListHeader64>.size
                        + childIndex * MemoryLayout<UInt64>.size
                )
            }

            let layout = ObjCProtocol64.Layout(
                isa: 0,
                mangledName: address(nameOffset),
                protocols: node.children.isEmpty && node.declaredCount == nil ? 0 : address(listOffset),
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
            )
            protocolLayouts.append(layout)
            data.store(layout, at: protocolOffset(for: index))
        }

        data.store(
            ObjCProtocolListHeader64(_count: nodes.isEmpty ? 0 : 1),
            at: classProtocolListOffset
        )
        data.store(
            nodes.isEmpty ? UInt64(0) : address(protocolOffset(for: 0)),
            at: classProtocolListOffset + MemoryLayout<ObjCProtocolListHeader64>.size
        )
        data.store(
            ObjCProtocolListHeader64(_count: nodes.isEmpty ? 0 : 1),
            at: categoryProtocolListOffset
        )
        data.store(
            nodes.isEmpty ? UInt64(0) : address(protocolOffset(for: 0)),
            at: categoryProtocolListOffset + MemoryLayout<ObjCProtocolListHeader64>.size
        )

        let classRO = ObjCClassROData64.Layout(
            flags: 0,
            instanceStart: 0,
            instanceSize: 0,
            _reserved: 0,
            ivarLayout: 0,
            name: address(classNameOffset),
            baseMethods: 0,
            baseProtocols: nodes.isEmpty ? 0 : address(classProtocolListOffset),
            ivars: 0,
            weakIvarLayout: 0,
            baseProperties: 0
        )
        let metaRO = ObjCClassROData64.Layout(
            flags: 0,
            instanceStart: 0,
            instanceSize: 0,
            _reserved: 0,
            ivarLayout: 0,
            name: address(classNameOffset),
            baseMethods: 0,
            baseProtocols: 0,
            ivars: 0,
            weakIvarLayout: 0,
            baseProperties: 0
        )
        data.store(classRO, at: classROOffset)
        data.store(metaRO, at: metaClassROOffset)

        let classLayout = ObjCClass64.Layout(
            isa: address(metaClassOffset),
            superclass: 0,
            methodCacheBuckets: 0,
            methodCacheProperties: 0,
            dataVMAddrAndFastFlags: address(classROOffset),
            swiftClassFlags: 0
        )
        let metaClassLayout = ObjCClass64.Layout(
            isa: address(metaClassOffset),
            superclass: 0,
            methodCacheBuckets: 0,
            methodCacheProperties: 0,
            dataVMAddrAndFastFlags: address(metaClassROOffset),
            swiftClassFlags: 0
        )
        data.store(classLayout, at: classOffset)
        data.store(metaClassLayout, at: metaClassOffset)

        let categoryLayout = ObjCCategory64.Layout(
            name: address(categoryNameOffset),
            cls: address(classOffset),
            instanceMethods: 0,
            classMethods: 0,
            protocols: nodes.isEmpty ? 0 : address(categoryProtocolListOffset),
            instanceProperties: 0,
            _classProperties: 0
        )
        data.store(categoryLayout, at: categoryOffset)

        return .init(
            data: data,
            protocolLayouts: protocolLayouts,
            classLayout: classLayout,
            categoryLayout: categoryLayout
        )
    }
}

private final class Synthetic32FileFixture {
    let machO: MachOFile
    let list: ObjCProtocolList32
    private let url: URL

    init() throws {
        let fileSize = 0x1000
        let vmAddress: UInt64 = 0x1000_0000
        let listOffset = 0x100
        let protocolOffset = 0x200
        let nameOffset = 0x300
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
        segment.vmaddr = vmAddress
        segment.vmsize = UInt64(fileSize)
        segment.fileoff = 0
        segment.filesize = UInt64(fileSize)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        data.store(segment, at: MemoryLayout<mach_header_64>.size)

        data.store(ObjCProtocolListHeader32(_count: 2), at: listOffset)
        data.store(
            UInt32(vmAddress + UInt64(protocolOffset)),
            at: listOffset + MemoryLayout<ObjCProtocolListHeader32>.size
        )
        data.store(
            UInt32(0xDEAD_BEEF),
            at: listOffset + MemoryLayout<ObjCProtocolListHeader32>.size
                + MemoryLayout<UInt32>.size
        )
        data.storeCString("P32", at: nameOffset)
        data.store(
            ObjCProtocol32.Layout(
                isa: 0,
                mangledName: UInt32(vmAddress + UInt64(nameOffset)),
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
            at: protocolOffset
        )

        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachOObjCSection-32-\(UUID().uuidString)")
        try data.write(to: url)
        self.machO = try MachOFile(url: url)
        self.list = ObjCProtocolList32(
            offset: listOffset,
            header: .init(_count: 2)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class SyntheticFileFixture {
    let data: Data
    let machO: MachOFile
    let protocols: [ObjCProtocol64]
    let objcClass: ObjCClass64
    let category: ObjCCategory64
    private let url: URL

    init(nodes: [SyntheticGraph.Node]) throws {
        let built = SyntheticGraph.build(
            nodes: nodes,
            pointerBase: SyntheticGraph.fileVMAddress,
            segmentVMAddress: SyntheticGraph.fileVMAddress
        )
        self.data = built.data
        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachOObjCSection-\(UUID().uuidString)")
        try built.data.write(to: url)
        self.machO = try MachOFile(url: url)
        self.protocols = built.protocolLayouts.enumerated().map { index, layout in
            ObjCProtocol64(layout: layout, offset: SyntheticGraph.protocolOffset(for: index))
        }
        self.objcClass = ObjCClass64(
            layout: built.classLayout,
            offset: SyntheticGraph.classOffset
        )
        self.category = ObjCCategory64(
            layout: built.categoryLayout,
            offset: SyntheticGraph.categoryOffset,
            isCatlist2: false
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class SyntheticImageFixture {
    let machO: MachOImage
    let protocols: [ObjCProtocol64]
    let objcClass: ObjCClass64
    let category: ObjCCategory64
    private let storage: UnsafeMutableRawPointer

    init(nodes: [SyntheticGraph.Node]) {
        self.storage = .allocate(byteCount: SyntheticGraph.fileSize, alignment: 16)
        let baseAddress = UInt64(UInt(bitPattern: storage))
        let built = SyntheticGraph.build(
            nodes: nodes,
            pointerBase: baseAddress,
            segmentVMAddress: baseAddress
        )
        built.data.copyBytes(
            to: storage.assumingMemoryBound(to: UInt8.self),
            count: built.data.count
        )
        self.machO = MachOImage(
            ptr: storage.assumingMemoryBound(to: mach_header.self)
        )
        self.protocols = built.protocolLayouts.enumerated().map { index, layout in
            ObjCProtocol64(layout: layout, offset: SyntheticGraph.protocolOffset(for: index))
        }
        self.objcClass = ObjCClass64(
            layout: built.classLayout,
            offset: SyntheticGraph.classOffset
        )
        self.category = ObjCCategory64(
            layout: built.categoryLayout,
            offset: SyntheticGraph.categoryOffset,
            isCatlist2: false
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
