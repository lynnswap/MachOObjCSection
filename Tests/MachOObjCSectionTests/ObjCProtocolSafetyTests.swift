import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@_spi(Core) @_spi(Diagnostics) @testable import MachOObjCSection
@testable import MachOKit

final class ObjCProtocolSafetyTests: XCTestCase {
    func testMemoryProbeRejectsUnreadableMiddlePage() throws {
#if canImport(Darwin)
        let pageSize = Int(getpagesize())
        let length = pageSize * 3
        let mapping = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard mapping != MAP_FAILED, let mapping else {
            return XCTFail("Failed to allocate test mapping")
        }
        defer { munmap(mapping, length) }
        XCTAssertEqual(mprotect(mapping.advanced(by: pageSize), pageSize, PROT_NONE), 0)
        XCTAssertFalse(isPointerSafelyReadable(UnsafeRawPointer(mapping), length: length))
#endif
    }

    func testCacheAddressArithmeticRejectsUnderflowAndOverflow() {
        XCTAssertNil(checkedCacheOffset(address: 0x0FFF, sharedRegionStart: 0x1000))
        XCTAssertEqual(checkedCacheOffset(address: 0x1001, sharedRegionStart: 0x1000), 1)
        XCTAssertNil(checkedCacheAddress(sharedRegionStart: .max, offset: 1))
    }

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

        let excessiveCount = ObjCProtocolReadLimits.maximumListEntries + 1
        let excessiveList = ObjCProtocolList64(
            offset: SyntheticGraph.protocolListOffset(for: 0),
            header: .init(_count: UInt64(excessiveCount))
        )
        assertTableFailure(excessiveList.readProtocols(in: fixture.machO)) {
            guard case let .excessiveElementCount(actual, maximum) = $0 else { return false }
            return actual == excessiveCount && maximum == ObjCProtocolReadLimits.maximumListEntries
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

        let overflowingRange = ObjCProtocolList64(
            offset: .min,
            header: .init(_count: 1)
        )
        assertTableFailure(overflowingRange.readProtocols(in: fixture.machO)) {
            guard case .invalidListOffset = $0 else { return false }
            return true
        }
    }

    func testLoadedImageRejectsExcessiveCountBeforeReadableMappingWork() throws {
        let fixture = SyntheticReadableImageFixture()
        let excessiveCount = ObjCProtocolReadLimits.maximumListEntries + 1
        let list = ObjCProtocolList64(
            offset: fixture.tableOffset,
            header: .init(_count: UInt64(excessiveCount))
        )
        assertTableFailure(list.readProtocols(in: fixture.machO)) {
            guard case let .excessiveElementCount(actual, maximum) = $0 else { return false }
            return actual == excessiveCount
                && maximum == ObjCProtocolReadLimits.maximumListEntries
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

    func testReadableUnalignedHeadersAndProtocolLayoutAreLoadedSafely() throws {
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(name: "A", children: [.node(1)]),
                .init(name: "B", objectOffsetAdjustment: 1)
            ]
        )
        XCTAssertEqual(
            fixture.protocols[0].readInfo(in: fixture.machO).value?.protocols.map(\.name),
            ["B"]
        )

        let storage = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        var listHeader = ObjCProtocolListHeader64(_count: 7)
        var relativeHeader = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(MemoryLayout<RelativeListListEntry.Layout>.size),
                count: 3
            )
        )
        Swift.withUnsafeBytes(of: &listHeader) {
            storage.advanced(by: 1).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        Swift.withUnsafeBytes(of: &relativeHeader) {
            storage.advanced(by: 17).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        XCTAssertEqual(ObjCProtocolList64(ptr: storage.advanced(by: 1), offset: 0).header._count, 7)
        XCTAssertEqual(
            ObjCProtocolRelativeListList64(ptr: storage.advanced(by: 17), offset: 0).header.count,
            3
        )
    }

    func testNegativeImageDisplacementAndRelativeStrideRemainValid() throws {
        let fixture = SyntheticNegativeImageFixture()

        let direct = fixture.list64.readProtocols(in: fixture.machO)
        guard case .success(let directSuccess) = direct else {
            return XCTFail("Expected negative direct-list displacement to resolve")
        }
        XCTAssertEqual(directSuccess.references.map { $0.value.mangledName(in: fixture.machO) }, ["Before"])

        let relative64 = fixture.relative64.resolveList(
            in: fixture.machO,
            forImageIndex: 1,
            imageResolver: { _ in fixture.machO }
        )
        guard case .resolved(_, let list64) = relative64 else {
            return XCTFail("Expected negative 64-bit relative-list displacement to resolve")
        }
        XCTAssertEqual(list64.offset, fixture.listOffset)
        XCTAssertEqual(list64.header._count, 1)

        let relative32 = fixture.relative32.resolveList(
            in: fixture.machO,
            forImageIndex: 1,
            imageResolver: { _ in fixture.machO }
        )
        guard case .resolved(_, let list32) = relative32 else {
            return XCTFail("Expected negative 32-bit relative-list displacement to resolve")
        }
        XCTAssertEqual(list32.offset, fixture.listOffset)
        XCTAssertEqual(list32.header._count, 1)
    }

    func testRelativeFileListsHonorStrideFor32And64BitLists() throws {
        let fixture = try SyntheticRelativeFileFixture()
        let locationResolver: (MachOFile, RelativeListListEntry) -> ObjCProtocolRelativeFileLocation? = {
            machO, _ in
            .direct(
                in: machO,
                fileOffset: UInt64(fixture.regularListOffset)
            )
        }

        let result64 = fixture.relative64.resolveList(
            in: fixture.machO,
            forImageIndex: 1,
            locationResolver: locationResolver
        )
        guard case .resolved(_, let list64) = result64 else {
            return XCTFail("Expected 64-bit relative file list")
        }
        XCTAssertEqual(list64.header._count, 0)

        let result32 = fixture.relative32.resolveList(
            in: fixture.machO,
            forImageIndex: 1,
            locationResolver: locationResolver
        )
        guard case .resolved(_, let list32) = result32 else {
            return XCTFail("Expected 32-bit relative file list")
        }
        XCTAssertEqual(list32.header._count, 0)
    }

    func testRelativeListFailuresRemainTyped() throws {
        let fixture = try SyntheticRelativeFileFixture()
        let invalidStrideHeader = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(MemoryLayout<RelativeListListEntry.Layout>.size - 1),
                count: 1
            )
        )
        let invalidStride = ObjCProtocolRelativeListList64(
            offset: fixture.relativeOffset,
            header: invalidStrideHeader
        )
        guard case .failure(let strideFailure) = invalidStride.resolveList(
            in: fixture.machO,
            forImageIndex: 1
        ) else {
            return XCTFail("Expected invalid relative stride")
        }
        guard case .invalidRelativeEntrySize = strideFailure.failure else {
            return XCTFail("Unexpected stride failure: \(strideFailure.failure)")
        }

        guard case .failure(let locationFailure) = fixture.relative64.resolveList(
            in: fixture.machO,
            forImageIndex: 1
        ) else {
            return XCTFail("Expected missing relative cache location")
        }
        XCTAssertEqual(locationFailure.failure, .invalidRelativeListLocation)

        var context = ObjCProtocolTraversalContext(subject: .class(name: "Owner"))
        context.record(resolutionFailure: locationFailure)
        guard case .unreadableList(let diagnostic) = context.diagnostics.first else {
            return XCTFail("Expected relative resolution failure in traversal diagnostics")
        }
        XCTAssertEqual(diagnostic.subject, .class(name: "Owner"))
        XCTAssertEqual(diagnostic.listOffset, locationFailure.listOffset)
        XCTAssertEqual(diagnostic.failure, .invalidRelativeListLocation)
    }

    func testRelativeTablesRejectExcessiveByteCountForFileAndImage() throws {
        let advertisedStride = ObjCProtocolReadLimits.maximumTableByteCount + 1
        let header = EntrySizeListHeader(
            layout: .init(entsizeAndFlags: UInt32(advertisedStride), count: 1)
        )

        let fileFixture = try SyntheticRelativeFileFixture()
        let fileList = ObjCProtocolRelativeListList64(
            offset: fileFixture.relativeOffset,
            header: header
        )
        guard case .failure(let fileFailure) = fileList.resolveList(
            in: fileFixture.machO,
            forImageIndex: 1
        ) else {
            return XCTFail("Expected file relative table byte-budget failure")
        }
        XCTAssertEqual(
            fileFailure.failure,
            .excessiveByteCount(
                actual: advertisedStride,
                maximum: ObjCProtocolReadLimits.maximumTableByteCount
            )
        )

        let imageFixture = SyntheticNegativeImageFixture()
        let imageList = ObjCProtocolRelativeListList64(
            offset: imageFixture.relative64.offset,
            header: header
        )
        guard case .failure(let imageFailure) = imageList.resolveList(
            in: imageFixture.machO,
            forImageIndex: 1,
            imageResolver: { _ in imageFixture.machO }
        ) else {
            return XCTFail("Expected image relative table byte-budget failure")
        }
        XCTAssertEqual(
            imageFailure.failure,
            .excessiveByteCount(
                actual: advertisedStride,
                maximum: ObjCProtocolReadLimits.maximumTableByteCount
            )
        )
    }

    func testRelativeByteOverflowReportsAdvertisedStride() throws {
        let fixture = try SyntheticRelativeFileFixture()
        let advertisedStride = UInt32.max
        let relative = ObjCProtocolRelativeListList64(
            offset: fixture.relativeOffset,
            header: .init(
                layout: .init(entsizeAndFlags: advertisedStride, count: UInt32.max)
            )
        )
        guard case .failure(let failure) = relative.resolveList(
            in: fixture.machO,
            forImageIndex: 1
        ) else {
            return XCTFail("Expected relative table byte-count overflow")
        }
#if arch(arm64_32) || arch(arm) || arch(i386)
        XCTAssertEqual(failure.failure, .invalidElementCount(UInt64(UInt32.max)))
#else
        XCTAssertEqual(
            failure.failure,
            .byteCountOverflow(
                elementCount: Int(UInt32.max),
                elementSize: Int(advertisedStride)
            )
        )
#endif
    }

    func testProtocolRelativeDisplacementDoesNotNarrowBeforeCheckedResolution() throws {
        let fixture = try SyntheticRelativeFileFixture(
            entryListOffset: Int64(Int32.max) + 1
        )
        let locationResolver: (MachOFile, RelativeListListEntry) -> ObjCProtocolRelativeFileLocation? = {
            machO, _ in
            .direct(
                in: machO,
                fileOffset: UInt64(fixture.regularListOffset)
            )
        }

        let result = fixture.relative64.resolveList(
            in: fixture.machO,
            forImageIndex: 1,
            locationResolver: locationResolver
        )
#if arch(arm64_32) || arch(arm) || arch(i386)
        guard case .failure(let failure) = result else {
            return XCTFail("Expected an unrepresentable 32-bit list offset to fail safely")
        }
        XCTAssertEqual(failure.failure, .invalidRelativeListLocation)
#else
        guard case .resolved(_, let list) = result else {
            return XCTFail("Expected the signed 48-bit displacement to remain intact")
        }
        XCTAssertEqual(
            list.offset,
            fixture.relativeOffset
                + MemoryLayout<EntrySizeListHeader>.size
                + Int(Int32.max)
                + 1
        )
#endif
    }

    func testRelativeCountRejectsValuesBeyondArm64_32IntRange() {
        XCTAssertEqual(
            exactRelativeListCount(
                UInt32(Int32.max),
                maximumIntValue: UInt64(Int32.max)
            ),
            Int(Int32.max)
        )
        XCTAssertNil(
            exactRelativeListCount(
                UInt32.max,
                maximumIntValue: UInt64(Int32.max)
            )
        )
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

    func testDefaultRecursiveHardLimitProducesOneShallowLeafDiagnostic() throws {
        let nodes = (0...66).map { index in
            SyntheticGraph.Node(
                name: "P\(index)",
                children: index < 66 ? [.node(index + 1)] : []
            )
        }
        let fixture = try SyntheticFileFixture(nodes: nodes)

        let result = fixture.protocols[0].readInfo(in: fixture.machO)
        var current = try XCTUnwrap(result.value)
        var traversedNames: [String] = []
        while let child = current.protocols.first {
            traversedNames.append(child.name)
            current = child
        }
        XCTAssertEqual(traversedNames.count, 65)
        XCTAssertEqual(traversedNames.last, "P65")
        XCTAssertEqual(current.name, "P65")
        XCTAssertEqual(current.protocols, [], "The cutoff node has P66 in raw metadata but must be shallow")
        XCTAssertEqual(result.diagnostics.count, 1)
        guard case .recursionLimit(let diagnostic) = result.diagnostics[0] else {
            return XCTFail("Expected recursion-limit diagnostic")
        }
        XCTAssertEqual(diagnostic.maximumDepth, 64)
        XCTAssertEqual(diagnostic.protocolPath.count, 66)
        XCTAssertEqual(diagnostic.protocolPath.last, "P65")
    }

    func testDepthAboveHardLimitAlsoProducesShallowLeafDiagnostic() throws {
        let nodes = (0...66).map { index in
            SyntheticGraph.Node(
                name: "P\(index)",
                children: index < 66 ? [.node(index + 1)] : []
            )
        }
        let fixture = try SyntheticFileFixture(nodes: nodes)
        let result = fixture.protocols[0].readInfo(
            in: fixture.machO,
            options: .init(traversal: .depth(65), referencedProtocolInfo: .full)
        )
        XCTAssertEqual(result.diagnostics.count, 1)
        guard case .recursionLimit(let diagnostic) = result.diagnostics[0] else {
            return XCTFail("Expected recursion-limit diagnostic")
        }
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

    func testUnreadableRegularListHeaderReachesTypedDiagnostics() throws {
        let fixture = try SyntheticFileFixture(nodes: [.init(name: "A")])
        let original = fixture.protocols[0].layout
        let protocolWithUnreadableList = ObjCProtocol64(
            layout: .init(
                isa: original.isa,
                mangledName: original.mangledName,
                protocols: SyntheticGraph.fileVMAddress + UInt64(SyntheticGraph.fileSize - 4),
                instanceMethods: original.instanceMethods,
                classMethods: original.classMethods,
                optionalInstanceMethods: original.optionalInstanceMethods,
                optionalClassMethods: original.optionalClassMethods,
                instanceProperties: original.instanceProperties,
                size: original.size,
                flags: original.flags,
                _extendedMethodTypes: original._extendedMethodTypes,
                _demangledName: original._demangledName,
                _classProperties: original._classProperties
            ),
            offset: fixture.protocols[0].offset
        )

        let result = protocolWithUnreadableList.readInfo(in: fixture.machO)
        XCTAssertEqual(result.value?.protocols, [])
        guard case .unreadableList(let diagnostic) = result.diagnostics.first else {
            return XCTFail("Expected regular-header diagnostic")
        }
        guard case .unreadableFileHeader = diagnostic.failure else {
            return XCTFail("Expected unreadable file header, got \(diagnostic.failure)")
        }
    }

    func testClassAndCategoryListResolutionFailuresKeepSubjectAttribution() throws {
        let unreadablePointer = SyntheticGraph.fileVMAddress + UInt64(SyntheticGraph.fileSize - 4)
        let fixture = try SyntheticFileFixture(
            nodes: [.init(name: "A")],
            classProtocolPointerOverride: unreadablePointer,
            categoryProtocolPointerOverride: unreadablePointer
        )

        let classResult = fixture.objcClass.readInfo(in: fixture.machO)
        guard case .unreadableList(let classDiagnostic) = classResult.diagnostics.first else {
            return XCTFail("Expected class list-resolution diagnostic")
        }
        XCTAssertEqual(classDiagnostic.subject, .class(name: "FixtureClass"))
        guard case .unreadableFileHeader = classDiagnostic.failure else {
            return XCTFail("Unexpected class failure: \(classDiagnostic.failure)")
        }

        let categoryResult = fixture.category.readInfo(in: fixture.machO)
        guard case .unreadableList(let categoryDiagnostic) = categoryResult.diagnostics.first else {
            return XCTFail("Expected category list-resolution diagnostic")
        }
        XCTAssertEqual(
            categoryDiagnostic.subject,
            .category(className: "FixtureClass", name: "FixtureCategory")
        )
        guard case .unreadableFileHeader = categoryDiagnostic.failure else {
            return XCTFail("Unexpected category failure: \(categoryDiagnostic.failure)")
        }
    }

    func testRelativeListMissingImageIndexReachesReadInfoDiagnostics() throws {
        let relativePointer = (SyntheticGraph.fileVMAddress + 0xA00) | 1
        let fixture = try SyntheticFileFixture(
            nodes: [.init(name: "A")],
            classProtocolPointerOverride: relativePointer
        )
        let result = fixture.objcClass.readInfo(in: fixture.machO)
        guard case .unreadableList(let diagnostic) = result.diagnostics.first else {
            return XCTFail("Expected relative-list diagnostic")
        }
        XCTAssertEqual(diagnostic.subject, .class(name: "FixtureClass"))
        XCTAssertEqual(diagnostic.failure, .missingRelativeImageIndex)
    }

    func testMissingRootIdentityIsDiagnosedAndStopsReferences() throws {
        let file = try SyntheticFileFixture(
            nodes: [.init(name: "A", children: [.node(0)])]
        )
        let invalidFileProtocol = ObjCProtocol64(
            layout: file.protocols[0].layout,
            offset: -1
        )
        let fileResult = invalidFileProtocol.readInfo(in: file.machO)
        XCTAssertEqual(fileResult.value?.protocols, [])
        guard case .invalidIdentity(let fileDiagnostic) = fileResult.diagnostics.first else {
            return XCTFail("Expected missing file identity diagnostic")
        }
        XCTAssertEqual(fileDiagnostic.protocolOffset, -1)

        let image = SyntheticImageFixture(
            nodes: [.init(name: "A", children: [.node(0)])]
        )
        let invalidImageProtocol = ObjCProtocol64(
            layout: image.protocols[0].layout,
            offset: .min
        )
        let imageResult = invalidImageProtocol.readInfo(in: image.machO)
        XCTAssertEqual(imageResult.value?.protocols, [])
        guard case .invalidIdentity = imageResult.diagnostics.first else {
            return XCTFail("Expected missing image identity diagnostic")
        }
    }

    func testStableIdentitiesDistinguishObjectsAndSurviveReconstructedSources() throws {
        let fixture = try SyntheticFileFixture(nodes: [.init(name: "Same"), .init(name: "Same")])
        let reconstructed = try MachOFile(url: fixture.url)
        XCTAssertEqual(
            fixture.machO.traversalIdentity(protocolOffset: SyntheticGraph.protocolOffset(for: 0)),
            reconstructed.traversalIdentity(protocolOffset: SyntheticGraph.protocolOffset(for: 0))
        )
        XCTAssertNotEqual(
            fixture.machO.traversalIdentity(protocolOffset: SyntheticGraph.protocolOffset(for: 0)),
            fixture.machO.traversalIdentity(protocolOffset: SyntheticGraph.protocolOffset(for: 1))
        )
        let firstObject = try XCTUnwrap(
            fixture.machO.traversalIdentity(protocolOffset: SyntheticGraph.protocolOffset(for: 0))
        )
        let sameNameOtherOffset = try XCTUnwrap(
            fixture.machO.traversalIdentity(protocolOffset: SyntheticGraph.protocolOffset(for: 1))
        )
        var distinctObjectContext = ObjCProtocolTraversalContext(
            subject: .protocol(name: "Same"),
            rootProtocol: (firstObject, "Same")
        )
        XCTAssertEqual(
            distinctObjectContext.decision(for: sameNameOtherOffset, name: "Same"),
            .descend
        )

        let uuid = UUID()
        let firstWrapperIdentity = ObjCProtocolIdentity.cache(uuid: uuid, unslidAddress: 0x1234)
        let reopenedSubcacheIdentity = ObjCProtocolIdentity.cache(uuid: uuid, unslidAddress: 0x1234)
        var context = ObjCProtocolTraversalContext(
            subject: .protocol(name: "Same"),
            rootProtocol: (firstWrapperIdentity, "Same")
        )
        XCTAssertEqual(
            context.decision(for: reopenedSubcacheIdentity, name: "Same"),
            .shallowCycle
        )
        XCTAssertEqual(context.diagnostics.count, 1)
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
        let objectOffsetAdjustment: Int

        init(
            name: String,
            children: [Child] = [],
            declaredCount: UInt64? = nil,
            objectOffsetAdjustment: Int = 0
        ) {
            self.name = name
            self.children = children
            self.declaredCount = declaredCount
            self.objectOffsetAdjustment = objectOffsetAdjustment
        }
    }

    struct Built {
        let data: Data
        let protocolLayouts: [ObjCProtocol64.Layout]
        let protocolOffsets: [Int]
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
        segmentVMAddress: UInt64,
        classProtocolPointerOverride: UInt64? = nil,
        categoryProtocolPointerOverride: UInt64? = nil
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
        let protocolOffsets = nodes.enumerated().map { index, node in
            protocolOffset(for: index) + node.objectOffsetAdjustment
        }
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
                    pointer = address(protocolOffsets[target])
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
            data.store(layout, at: protocolOffsets[index])
        }

        data.store(
            ObjCProtocolListHeader64(_count: nodes.isEmpty ? 0 : 1),
            at: classProtocolListOffset
        )
        data.store(
            nodes.isEmpty ? UInt64(0) : address(protocolOffsets[0]),
            at: classProtocolListOffset + MemoryLayout<ObjCProtocolListHeader64>.size
        )
        data.store(
            ObjCProtocolListHeader64(_count: nodes.isEmpty ? 0 : 1),
            at: categoryProtocolListOffset
        )
        data.store(
            nodes.isEmpty ? UInt64(0) : address(protocolOffsets[0]),
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
            baseProtocols: classProtocolPointerOverride
                ?? (nodes.isEmpty ? 0 : address(classProtocolListOffset)),
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
            protocols: categoryProtocolPointerOverride
                ?? (nodes.isEmpty ? 0 : address(categoryProtocolListOffset)),
            instanceProperties: 0,
            _classProperties: 0
        )
        data.store(categoryLayout, at: categoryOffset)

        return .init(
            data: data,
            protocolLayouts: protocolLayouts,
            protocolOffsets: protocolOffsets,
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
    let url: URL

    init(
        nodes: [SyntheticGraph.Node],
        classProtocolPointerOverride: UInt64? = nil,
        categoryProtocolPointerOverride: UInt64? = nil
    ) throws {
        let built = SyntheticGraph.build(
            nodes: nodes,
            pointerBase: SyntheticGraph.fileVMAddress,
            segmentVMAddress: SyntheticGraph.fileVMAddress,
            classProtocolPointerOverride: classProtocolPointerOverride,
            categoryProtocolPointerOverride: categoryProtocolPointerOverride
        )
        self.data = built.data
        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachOObjCSection-\(UUID().uuidString)")
        try built.data.write(to: url)
        self.machO = try MachOFile(url: url)
        self.protocols = built.protocolLayouts.enumerated().map { index, layout in
            ObjCProtocol64(layout: layout, offset: built.protocolOffsets[index])
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
            ObjCProtocol64(layout: layout, offset: built.protocolOffsets[index])
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

private final class SyntheticReadableImageFixture {
    let machO: MachOImage
    let tableOffset = 0x100
    private let storage: UnsafeMutableRawPointer

    init() {
        let tableBytes = (ObjCProtocolReadLimits.maximumListEntries + 1)
            * MemoryLayout<UInt64>.size
        let byteCount = tableOffset + MemoryLayout<ObjCProtocolListHeader64>.size + tableBytes
        let allocatedStorage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        self.storage = allocatedStorage
        allocatedStorage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        var header = mach_header_64()
        header.magic = UInt32(MH_MAGIC_64)
        Swift.withUnsafeBytes(of: &header) { bytes in
            allocatedStorage.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        self.machO = MachOImage(ptr: allocatedStorage.assumingMemoryBound(to: mach_header.self))
    }

    deinit {
        storage.deallocate()
    }
}

private final class SyntheticNegativeImageFixture {
    let machO: MachOImage
    let list64: ObjCProtocolList64
    let relative64: ObjCProtocolRelativeListList64
    let relative32: ObjCProtocolRelativeListList32
    let listOffset = -0x800
    private let storage: UnsafeMutableRawPointer

    init() {
        let byteCount = 0x4000
        let machOOffset = 0x1000
        let listStorageOffset = 0x800
        let relativeStorageOffset = 0x600
        let protocolStorageOffset = 0x1800
        let nameStorageOffset = 0x1900
        self.storage = .allocate(byteCount: byteCount, alignment: 16)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        let storageAddress = UInt64(UInt(bitPattern: storage))
        let machOPointer = storage.advanced(by: machOOffset)
        var header = mach_header_64()
        header.magic = UInt32(MH_MAGIC_64)
        header.cputype = CPU_TYPE_ARM64
        header.cpusubtype = CPU_SUBTYPE_ARM64_ALL
        header.filetype = UInt32(MH_DYLIB)
        header.ncmds = 1
        header.sizeofcmds = UInt32(MemoryLayout<segment_command_64>.size)
        machOPointer.storeUnaligned(header)

        var segment = segment_command_64()
        segment.cmd = UInt32(LC_SEGMENT_64)
        segment.cmdsize = UInt32(MemoryLayout<segment_command_64>.size)
        segment.vmaddr = storageAddress
        segment.vmsize = UInt64(byteCount)
        segment.fileoff = 0
        segment.filesize = UInt64(byteCount)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        machOPointer.advanced(by: MemoryLayout<mach_header_64>.size).storeUnaligned(segment)

        storage.advanced(by: nameStorageOffset).storeBytes(Array("Before".utf8) + [0])
        let protocolLayout = ObjCProtocol64.Layout(
            isa: 0,
            mangledName: storageAddress + UInt64(nameStorageOffset),
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
        )
        storage.advanced(by: protocolStorageOffset).storeUnaligned(protocolLayout)

        let listPointer = storage.advanced(by: listStorageOffset)
        listPointer.storeUnaligned(ObjCProtocolListHeader64(_count: 1))
        listPointer.advanced(by: MemoryLayout<ObjCProtocolListHeader64>.size).storeUnaligned(
            storageAddress + UInt64(protocolStorageOffset)
        )

        let relativePointer = storage.advanced(by: relativeStorageOffset)
        let advertisedStride = MemoryLayout<RelativeListListEntry.Layout>.size + 8
        relativePointer.storeUnaligned(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(advertisedStride),
                    count: 1
                )
            )
        )
        let entryAddress = relativeStorageOffset + MemoryLayout<EntrySizeListHeader>.size
        var entryLayout = RelativeListListEntry.Layout()
        entryLayout.imageIndex = 1
        entryLayout.listOffset = Int64(listStorageOffset - entryAddress)
        relativePointer.advanced(by: MemoryLayout<EntrySizeListHeader>.size).storeUnaligned(entryLayout)

        self.machO = MachOImage(
            ptr: machOPointer.assumingMemoryBound(to: mach_header.self)
        )
        self.list64 = ObjCProtocolList64(ptr: listPointer, offset: listOffset)
        self.relative64 = ObjCProtocolRelativeListList64(
            ptr: relativePointer,
            offset: relativeStorageOffset - machOOffset
        )
        self.relative32 = ObjCProtocolRelativeListList32(
            ptr: relativePointer,
            offset: relativeStorageOffset - machOOffset
        )
    }

    deinit {
        storage.deallocate()
    }
}

private final class SyntheticRelativeFileFixture {
    let machO: MachOFile
    let relative64: ObjCProtocolRelativeListList64
    let relative32: ObjCProtocolRelativeListList32
    let relativeOffset = 0x100
    let regularListOffset = 0x300
    private let url: URL

    init(entryListOffset: Int64? = nil) throws {
        let fileSize = 0x1000
        let vmAddress: UInt64 = 0x2000_0000
        var data = Data(count: fileSize)

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
        segment.vmaddr = vmAddress
        segment.vmsize = UInt64(fileSize)
        segment.fileoff = 0
        segment.filesize = UInt64(fileSize)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        data.store(segment, at: MemoryLayout<mach_header_64>.size)

        let stride = MemoryLayout<RelativeListListEntry.Layout>.size + 8
        let relativeHeader = EntrySizeListHeader(
            layout: .init(entsizeAndFlags: UInt32(stride), count: 1)
        )
        data.store(relativeHeader, at: relativeOffset)
        let entryOffset = relativeOffset + MemoryLayout<EntrySizeListHeader>.size
        var entry = RelativeListListEntry.Layout()
        entry.imageIndex = 1
        entry.listOffset = entryListOffset ?? Int64(regularListOffset - entryOffset)
        data.store(entry, at: entryOffset)
        data.store(ObjCProtocolListHeader64(_count: 0), at: regularListOffset)

        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachOObjCSection-relative-\(UUID().uuidString)")
        try data.write(to: url)
        self.machO = try MachOFile(url: url)
        self.relative64 = ObjCProtocolRelativeListList64(
            offset: relativeOffset,
            header: relativeHeader
        )
        self.relative32 = ObjCProtocolRelativeListList32(
            offset: relativeOffset,
            header: relativeHeader
        )
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

    func storeBytes(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buffer in
            copyMemory(from: buffer.baseAddress!, byteCount: buffer.count)
        }
    }
}
