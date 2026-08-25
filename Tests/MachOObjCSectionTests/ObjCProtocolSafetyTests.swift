import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
#if canImport(ObjectiveC)
import ObjectiveC
#endif
@_spi(Core) @_spi(Diagnostics) @testable import MachOObjCSection
@testable import MachOKit

final class ObjCProtocolSafetyTests: XCTestCase {
    func testRuntimeNameReaderCachesFailuresAndHonorsTableBudget() throws {
        let first = try XCTUnwrap(UnsafeRawPointer(bitPattern: 0x1_0000))
        let second = try XCTUnwrap(UnsafeRawPointer(bitPattern: 0x2_0000))
        let third = try XCTUnwrap(UnsafeRawPointer(bitPattern: 0x3_0000))
        var requestedByteCounts: [Int] = []
        var reader = ObjCProtocolRuntimeNameReader(
            maximumTableByteCount: 5,
            read: { _, maximumByteCount in
                requestedByteCounts.append(maximumByteCount)
                return nil
            }
        )

        XCTAssertNil(reader.name(at: first, maximumByteCount: 4))
        XCTAssertEqual(reader.remainingByteCount, 1)
        XCTAssertNil(reader.name(at: first, maximumByteCount: 4))
        XCTAssertEqual(reader.remainingByteCount, 1)
        XCTAssertNil(reader.name(at: second, maximumByteCount: 4))
        XCTAssertEqual(reader.remainingByteCount, 0)
        XCTAssertNil(reader.name(at: third, maximumByteCount: 4))
        XCTAssertEqual(requestedByteCounts, [4, 1])
    }

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

    func testRelativeProtocolListTableFailureReturnsTypedFailureWithoutTrapping() throws {
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
        guard case .failure = relative.resolveLists(in: fixture.machO) else {
            return XCTFail("Expected unreadable relative-list table")
        }
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

    func testRuntimeNameRecoversDistinctRawProtocolAliasOnlyForDirectNames() throws {
#if canImport(ObjectiveC)
        let name = "MachOObjCSectionCanonicalProtocolFixture"
        let existing = objc_getProtocol(name)
        let objcProtocol: Protocol
        if let existing {
            objcProtocol = existing
        } else {
            let allocated = try XCTUnwrap(objc_allocateProtocol(name))
            objc_registerProtocol(allocated)
            objcProtocol = allocated
        }
        let canonicalPointer = Unmanaged.passUnretained(objcProtocol).toOpaque()
        let rawProtocol = SyntheticExternalProtocolFixture(name: name)
        XCTAssertNotEqual(rawProtocol.pointer, UnsafeRawPointer(canonicalPointer))
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: rawProtocol.pointer)))]
                )
            ]
        )

        XCTAssertFalse(fixture.machO.contains(ptr: rawProtocol.pointer))
        XCTAssertNil(fixture.machO.resolveImage(containing: rawProtocol.pointer))
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        XCTAssertEqual(list.protocols(in: fixture.machO)?.count, 0)
        let runtimeResolver = try XCTUnwrap(ObjCProtocolRuntimeResolver.runtime)
        guard case .success(let aliasResult) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: runtimeResolver
        ) else {
            return XCTFail("Expected the runtime to resolve the raw protocol alias")
        }
        XCTAssertEqual(
            aliasResult.nameReferences.first?.identity,
            .image(address: UInt(bitPattern: canonicalPointer))
        )

        let result = fixture.protocols[0].readInfo(
            in: fixture.machO,
            options: .directProtocolNames
        )
        XCTAssertEqual(result.value?.protocols.map(\.name), [name])
        XCTAssertTrue(result.diagnostics.isEmpty)

        let full = fixture.protocols[0].readInfo(in: fixture.machO)
        XCTAssertEqual(full.value?.protocols, [])
        guard case .unreadableList(let diagnostic) = full.diagnostics.first else {
            return XCTFail("Expected full metadata to retain the missing-backing diagnostic")
        }
        XCTAssertEqual(diagnostic.failure, .missingBackingData(entryIndex: 0))
#endif
    }

    func testCanonicalCacheProtocolBypassesNameLookupAndPreservesRawIdentity() throws {
        let name = "CanonicalCacheProtocol"
        let external = SyntheticExternalProtocolFixture(
            name: name,
            flags: ObjCProtocolRuntimeFlags.canonical
                | ObjCProtocolRuntimeFlags.preoptimizedFixedValue
        )
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        let cacheUUID = UUID()
        let protocolLocation = ObjCProtocolDyldCacheLocation(
            cacheUUID: cacheUUID,
            unslidAddress: 0x1800_0010_0000,
            remainingMappedByteCount: UInt(MemoryLayout<ObjCProtocol64.Layout>.size)
        )
        let nameLocation = ObjCProtocolDyldCacheLocation(
            cacheUUID: cacheUUID,
            unslidAddress: 0x1800_0020_0000,
            remainingMappedByteCount: UInt(name.utf8.count + 1)
        )
        var lookupCount = 0
        let resolver = syntheticRuntimeResolver(
            protocolAddress: { _ in
                lookupCount += 1
                return nil
            },
            cacheLocations: [
                (external.pointer, protocolLocation),
                (external.namePointer, nameLocation)
            ]
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(lookupCount, 0)
        XCTAssertEqual(result.nameReferences.map(\.name), [name])
        XCTAssertEqual(result.nameReferences.first?.identity, protocolLocation.identity)
        XCTAssertTrue(result.failures.isEmpty)

        guard case .success(let fullResult) = list.readProtocols(in: fixture.machO) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertTrue(fullResult.nameReferences.isEmpty)
        XCTAssertEqual(
            fullResult.failures,
            [.init(index: 0, reason: .missingBackingData)]
        )
    }

    func testCanonicalCacheProtocolNeedsOnlyMandatoryLayoutPrefix() throws {
#if canImport(Darwin)
        let pageSize = Int(getpagesize())
        let mappingByteCount = pageSize * 2
        let mapping = mmap(
            nil,
            mappingByteCount,
            PROT_READ | PROT_WRITE,
            MAP_ANON | MAP_PRIVATE,
            -1,
            0
        )
        guard mapping != MAP_FAILED, let mapping else {
            return XCTFail("Failed to allocate the protocol mapping")
        }
        defer { munmap(mapping, mappingByteCount) }
        XCTAssertEqual(mprotect(mapping.advanced(by: pageSize), pageSize, PROT_NONE), 0)

        let name = "ShortCanonicalCacheProtocol"
        let nameBytes = Array(name.utf8) + [0]
        nameBytes.withUnsafeBytes {
            mapping.copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        typealias RuntimeLayout = ObjCProtocolRuntimeLayoutPrefix<UInt64>
        let mandatoryLayoutByteCount = MemoryLayout<RuntimeLayout>.size
        let protocolPointer = mapping.advanced(
            by: pageSize - mandatoryLayoutByteCount
        )
        protocolPointer.storeUnaligned(
            RuntimeLayout(
                isa: 0,
                mangledName: UInt64(UInt(bitPattern: mapping)),
                protocols: 0,
                instanceMethods: 0,
                classMethods: 0,
                optionalInstanceMethods: 0,
                optionalClassMethods: 0,
                instanceProperties: 0,
                size: UInt32(mandatoryLayoutByteCount),
                flags: ObjCProtocolRuntimeFlags.canonical
                    | ObjCProtocolRuntimeFlags.preoptimizedFixedValue
            )
        )

        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: protocolPointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        let cacheUUID = UUID()
        let protocolLocation = ObjCProtocolDyldCacheLocation(
            cacheUUID: cacheUUID,
            unslidAddress: 0x1800_0010_0000,
            remainingMappedByteCount: UInt(mandatoryLayoutByteCount)
        )
        let resolver = syntheticRuntimeResolver(
            protocolAddress: { _ in
                XCTFail("Canonical cache recovery must bypass name lookup")
                return nil
            },
            cacheLocations: [
                (UnsafeRawPointer(protocolPointer), protocolLocation),
                (
                    UnsafeRawPointer(mapping),
                    .init(
                        cacheUUID: cacheUUID,
                        unslidAddress: 0x1800_0020_0000,
                        remainingMappedByteCount: UInt(nameBytes.count)
                    )
                )
            ]
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(result.nameReferences.map(\.name), [name])
        XCTAssertEqual(result.nameReferences.first?.identity, protocolLocation.identity)
        XCTAssertTrue(result.failures.isEmpty)
#endif
    }

    func testForgedCanonicalProtocolOutsideCacheFallsBackAndFails() throws {
        let external = SyntheticExternalProtocolFixture(
            name: "ForgedCanonicalProtocol",
            flags: ObjCProtocolRuntimeFlags.canonical
                | ObjCProtocolRuntimeFlags.preoptimizedFixedValue
        )
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        var lookupCount = 0
        let resolver = ObjCProtocolRuntimeResolver(
            protocolAddress: { _ in
                lookupCount += 1
                return nil
            }
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(lookupCount, 1)
        XCTAssertTrue(result.nameReferences.isEmpty)
        XCTAssertEqual(
            result.failures,
            [.init(index: 0, reason: .missingBackingData)]
        )
    }

    func testCanonicalProtocolWithWrongFixedMaskFallsBackToNameLookup() throws {
        let name = "WrongFixedMaskProtocol"
        let external = SyntheticExternalProtocolFixture(
            name: name,
            flags: ObjCProtocolRuntimeFlags.canonical | (1 << 31)
        )
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        let cacheUUID = UUID()
        let fallbackPointer = try XCTUnwrap(UnsafeRawPointer(bitPattern: 0x3_0000))
        var lookedUpNames: [String] = []
        let resolver = syntheticRuntimeResolver(
            protocolAddress: { rawName in
                lookedUpNames.append(rawName)
                return fallbackPointer
            },
            cacheLocations: syntheticCacheLocations(
                for: external,
                cacheUUID: cacheUUID,
                nameByteCount: name.utf8.count + 1
            )
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(lookedUpNames, [name])
        XCTAssertEqual(
            result.nameReferences.first?.identity,
            .image(address: UInt(bitPattern: fallbackPointer))
        )
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testCanonicalProtocolRequiresActiveRuntimePreoptimization() throws {
        let name = "DisabledPreoptimizationProtocol"
        let external = SyntheticExternalProtocolFixture(
            name: name,
            flags: ObjCProtocolRuntimeFlags.canonical
                | ObjCProtocolRuntimeFlags.preoptimizedFixedValue
        )
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        let fallbackPointer = try XCTUnwrap(UnsafeRawPointer(bitPattern: 0x4_0000))
        var lookupCount = 0
        let locations = syntheticCacheLocations(
            for: external,
            cacheUUID: UUID(),
            nameByteCount: name.utf8.count + 1
        )
        let resolver = syntheticRuntimeResolver(
            protocolAddress: { _ in
                lookupCount += 1
                return fallbackPointer
            },
            cacheLocations: locations,
            usesSharedCacheProtocolOptimizations: false
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(lookupCount, 1)
        XCTAssertEqual(
            result.nameReferences.first?.identity,
            .image(address: UInt(bitPattern: fallbackPointer))
        )
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testCanonicalProtocolWithSmallDeclaredLayoutFailsBeforeNameLookup() throws {
        let minimumLayoutSize = ObjCProtocolRuntimeFlags.mandatoryLayoutByteCount(
            for: UInt64.self
        )
        let name = "SmallCanonicalProtocol"
        let external = SyntheticExternalProtocolFixture(
            name: name,
            declaredSize: UInt32(minimumLayoutSize - 1),
            flags: ObjCProtocolRuntimeFlags.canonical
                | ObjCProtocolRuntimeFlags.preoptimizedFixedValue
        )
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        var lookupCount = 0
        let resolver = syntheticRuntimeResolver(
            protocolAddress: { _ in
                lookupCount += 1
                return nil
            },
            cacheLocations: syntheticCacheLocations(
                for: external,
                cacheUUID: UUID(),
                nameByteCount: name.utf8.count + 1
            )
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(lookupCount, 0)
        XCTAssertTrue(result.nameReferences.isEmpty)
        XCTAssertEqual(
            result.failures,
            [.init(index: 0, reason: .missingBackingData)]
        )
    }

    func testCanonicalProtocolPrefixCannotCrossCacheMappingBoundary() throws {
        let name = "BoundaryCanonicalProtocolLayout"
        let external = SyntheticExternalProtocolFixture(
            name: name,
            flags: ObjCProtocolRuntimeFlags.canonical
                | ObjCProtocolRuntimeFlags.preoptimizedFixedValue
        )
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        let mandatoryLayoutByteCount = ObjCProtocolRuntimeFlags.mandatoryLayoutByteCount(
            for: UInt64.self
        )
        let cacheUUID = UUID()
        let resolver = syntheticRuntimeResolver(
            protocolAddress: { _ in nil },
            cacheLocations: [
                (
                    external.pointer,
                    .init(
                        cacheUUID: cacheUUID,
                        unslidAddress: 0x1800_0010_0000,
                        remainingMappedByteCount: UInt(mandatoryLayoutByteCount - 1)
                    )
                ),
                (
                    external.namePointer,
                    .init(
                        cacheUUID: cacheUUID,
                        unslidAddress: 0x1800_0020_0000,
                        remainingMappedByteCount: UInt(name.utf8.count + 1)
                    )
                )
            ]
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertTrue(result.nameReferences.isEmpty)
        XCTAssertEqual(
            result.failures,
            [.init(index: 0, reason: .missingBackingData)]
        )
    }

    func testCanonicalProtocolAllowsLowerSwiftFlagBits() throws {
        let name = "CanonicalSwiftProtocol"
        let swiftFlagBits: UInt32 = 0x0000_12A5
        let external = SyntheticExternalProtocolFixture(
            name: name,
            flags: ObjCProtocolRuntimeFlags.canonical
                | ObjCProtocolRuntimeFlags.preoptimizedFixedValue
                | swiftFlagBits
        )
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        var lookupCount = 0
        let locations = syntheticCacheLocations(
            for: external,
            cacheUUID: UUID(),
            nameByteCount: name.utf8.count + 1
        )
        let resolver = syntheticRuntimeResolver(
            protocolAddress: { _ in
                lookupCount += 1
                return nil
            },
            cacheLocations: locations
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(lookupCount, 0)
        XCTAssertEqual(result.nameReferences.map(\.name), [name])
        XCTAssertEqual(result.nameReferences.first?.identity, locations[0].1.identity)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testCanonicalProtocolNameCannotCrossCacheMappingBoundary() throws {
        let name = "BoundaryCanonicalProtocol"
        let external = SyntheticExternalProtocolFixture(
            name: name,
            flags: ObjCProtocolRuntimeFlags.canonical
                | ObjCProtocolRuntimeFlags.preoptimizedFixedValue
        )
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        let cacheUUID = UUID()
        let protocolLocation = ObjCProtocolDyldCacheLocation(
            cacheUUID: cacheUUID,
            unslidAddress: 0x1800_0010_0000,
            remainingMappedByteCount: UInt(MemoryLayout<ObjCProtocol64.Layout>.size)
        )
        let truncatedNameLocation = ObjCProtocolDyldCacheLocation(
            cacheUUID: cacheUUID,
            unslidAddress: 0x1800_0020_0000,
            remainingMappedByteCount: UInt(name.utf8.count)
        )
        var lookupCount = 0
        let resolver = syntheticRuntimeResolver(
            protocolAddress: { _ in
                lookupCount += 1
                return nil
            },
            cacheLocations: [
                (external.pointer, protocolLocation),
                (external.namePointer, truncatedNameLocation)
            ]
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(lookupCount, 0)
        XCTAssertTrue(result.nameReferences.isEmpty)
        XCTAssertEqual(
            result.failures,
            [.init(index: 0, reason: .missingBackingData)]
        )
    }

    func testUnknownRawProtocolNameKeepsMissingBackingDiagnostic() throws {
        let unknownName = "MachOObjCSectionUnknownProtocol_\(UUID().uuidString)"
#if canImport(ObjectiveC)
        XCTAssertNil(objc_getProtocol(unknownName))
#endif
        let external = SyntheticExternalProtocolFixture(name: unknownName)
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )

        let result = fixture.protocols[0].readInfo(
            in: fixture.machO,
            options: .directProtocolNames
        )
        XCTAssertEqual(result.value?.protocols, [])
        guard case .unreadableList(let diagnostic) = result.diagnostics.first else {
            return XCTFail("Expected an unregistered pointer diagnostic")
        }
        XCTAssertEqual(diagnostic.failure, .missingBackingData(entryIndex: 0))
    }

    func testRuntimeNameLookupPreservesRawSwiftMangledName() throws {
        let rawName = "_TtP19CanonicalFixture7Example_"
        let external = SyntheticExternalProtocolFixture(name: rawName)
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        let canonicalPointer = try XCTUnwrap(UnsafeRawPointer(bitPattern: 0x2_0000))
        XCTAssertNotEqual(external.pointer, canonicalPointer)
        var lookedUpNames: [String] = []
        let resolver = ObjCProtocolRuntimeResolver(
            protocolAddress: { name in
                lookedUpNames.append(name)
                return name == rawName ? canonicalPointer : nil
            }
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(lookedUpNames, [rawName])
        XCTAssertEqual(result.nameReferences.map(\.name), [rawName])
        XCTAssertEqual(
            result.nameReferences.first?.identity,
            .image(address: UInt(bitPattern: canonicalPointer))
        )
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testUnreadableRawProtocolNameKeepsMissingBackingFailure() throws {
        let external = SyntheticExternalProtocolFixture(
            nameBytes: [],
            namePointerOverride: 0x10
        )
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        var lookupCount = 0
        let resolver = ObjCProtocolRuntimeResolver(
            protocolAddress: { _ in
                lookupCount += 1
                return UnsafeRawPointer(bitPattern: 0x2_0000)
            }
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(lookupCount, 0)
        XCTAssertEqual(
            result.failures,
            [.init(index: 0, reason: .missingBackingData)]
        )
    }

    func testUnterminatedRawProtocolNameKeepsMissingBackingFailure() throws {
        let external = SyntheticExternalProtocolFixture(
            nameBytes: Array(
                repeating: 0x41,
                count: BoundedCStringReadLimits.maximumByteCount
            )
        )
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        let resolver = ObjCProtocolRuntimeResolver(
            protocolAddress: { _ in UnsafeRawPointer(bitPattern: 0x2_0000) }
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(
            result.failures,
            [.init(index: 0, reason: .missingBackingData)]
        )
    }

    func testOverLimitRawProtocolNameKeepsMissingBackingFailure() throws {
        let nameBytes = Array(
            repeating: UInt8(0x41),
            count: BoundedCStringReadLimits.maximumByteCount
        ) + [0]
        let external = SyntheticExternalProtocolFixture(nameBytes: nameBytes)
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        let resolver = ObjCProtocolRuntimeResolver(
            protocolAddress: { _ in UnsafeRawPointer(bitPattern: 0x2_0000) }
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(
            result.failures,
            [.init(index: 0, reason: .missingBackingData)]
        )
    }

    func testInvalidUTF8RawProtocolNameKeepsMissingBackingFailure() throws {
        let external = SyntheticExternalProtocolFixture(nameBytes: [0xFF, 0])
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(UInt(bitPattern: external.pointer)))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        var lookupCount = 0
        let resolver = ObjCProtocolRuntimeResolver(
            protocolAddress: { _ in
                lookupCount += 1
                return UnsafeRawPointer(bitPattern: 0x2_0000)
            }
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(lookupCount, 0)
        XCTAssertEqual(
            result.failures,
            [.init(index: 0, reason: .missingBackingData)]
        )
    }

    func testUnreadableRawProtocolLayoutFailsBeforeRuntimeNameLookup() throws {
        let unreadableAddress = UInt(0x10)
        let fixture = SyntheticImageFixture(
            nodes: [
                .init(
                    name: "Owner",
                    children: [.pointer(UInt64(unreadableAddress))]
                )
            ]
        )
        let list = try XCTUnwrap(fixture.protocols[0].protocolList(in: fixture.machO))
        let pointer = try XCTUnwrap(UnsafeRawPointer(bitPattern: unreadableAddress))
        XCTAssertNil(fixture.machO.resolveImage(containing: pointer))
        var lookupCount = 0
        let resolver = ObjCProtocolRuntimeResolver(
            protocolAddress: { _ in
                lookupCount += 1
                return UnsafeRawPointer(bitPattern: 0x2_0000)
            }
        )

        guard case .success(let result) = list.readProtocols(
            in: fixture.machO,
            runtimeResolver: resolver
        ) else {
            return XCTFail("Expected a readable protocol pointer table")
        }
        XCTAssertEqual(lookupCount, 0)
        XCTAssertEqual(result.nameReferences.count, 0)
        guard case .unreadableImageLayout(let address, let byteCount) = result.failures.first?.reason else {
            return XCTFail("Expected a typed unreadable-layout failure")
        }
        XCTAssertEqual(address, unreadableAddress)
        XCTAssertEqual(
            byteCount,
            ObjCProtocolRuntimeFlags.mandatoryLayoutByteCount(for: UInt64.self)
        )
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

        let relative64 = fixture.relative64.resolveLists(
            in: fixture.machO,
            imageLoadResolver: { _ in .loaded },
            imageResolver: { _ in fixture.machO }
        )
        guard case .some(.resolved(_, let list64)) = relative64.entriesForTesting.first else {
            return XCTFail("Expected negative 64-bit relative-list displacement to resolve")
        }
        XCTAssertEqual(list64.offset, fixture.listOffset)
        XCTAssertEqual(list64.header._count, 1)

        let relative32 = fixture.relative32.resolveLists(
            in: fixture.machO,
            imageLoadResolver: { _ in .loaded },
            imageResolver: { _ in fixture.machO }
        )
        guard case .some(.resolved(_, let list32)) = relative32.entriesForTesting.first else {
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

        let result64 = fixture.relative64.resolveLists(
            in: fixture.machO,
            locationResolver: locationResolver
        )
        guard case .some(.resolved(_, let list64)) = result64.entriesForTesting.first else {
            return XCTFail("Expected 64-bit relative file list")
        }
        XCTAssertEqual(list64.header._count, 0)

        let result32 = fixture.relative32.resolveLists(
            in: fixture.machO,
            locationResolver: locationResolver
        )
        guard case .some(.resolved(_, let list32)) = result32.entriesForTesting.first else {
            return XCTFail("Expected 32-bit relative file list")
        }
        XCTAssertEqual(list32.header._count, 0)
    }

    func testRelativeImageListsDoNotRequireOwnerEntryAndSkipUnloadedBeforeDereference() {
        let fixture = SyntheticRelativeImageCollectionFixture(
            unreadableEntryIndices: [0, 1, 2, 3]
        )
        var loadChecks: [Int] = []
        var imageResolutions: [Int] = []

        let result = fixture.relative64.resolveLists(
            in: fixture.machO,
            imageLoadResolver: { index in
                loadChecks.append(index)
                return .unloaded
            },
            imageResolver: { index in
                imageResolutions.append(index)
                return fixture.machO
            }
        )

        XCTAssertEqual(fixture.imageIndices, [199, 1194, 1680, 0])
        XCTAssertFalse(fixture.imageIndices.contains(54))
        XCTAssertEqual(loadChecks, fixture.imageIndices)
        XCTAssertTrue(imageResolutions.isEmpty)
        XCTAssertTrue(result.entriesForTesting.isEmpty)
    }

    func testRelativeImageListsPreserveLoadedOrderAndIgnoreUnreadableUnloadedEntries() {
        let fixture = SyntheticRelativeImageCollectionFixture(
            unreadableEntryIndices: [0, 2]
        )
        var imageResolutions: [Int] = []

        let result = fixture.relative64.resolveLists(
            in: fixture.machO,
            imageLoadResolver: { [1194, 0].contains($0) ? .loaded : .unloaded },
            imageResolver: { index in
                imageResolutions.append(index)
                return fixture.machO
            }
        )

        XCTAssertEqual(imageResolutions, [1194, 0])
        XCTAssertEqual(
            result.entriesForTesting.compactMap { resolution -> UInt64? in
                guard case .resolved(_, let list) = resolution else { return nil }
                return list.header._count
            },
            [22, 44]
        )
        XCTAssertFalse(result.entriesForTesting.contains { resolution in
            if case .failure = resolution { return true }
            return false
        })
    }

    func testRelativeImageListsKeepDuplicateImageEntriesAndValidSiblingAfterFailure() {
        let duplicateFixture = SyntheticRelativeImageCollectionFixture(
            imageIndices: [199, 199],
            protocolNamesByList: [["P1", "P2"], ["P3"]]
        )
        var duplicateImageResolutions: [Int] = []
        let duplicateResult = duplicateFixture.relative64.resolveLists(
            in: duplicateFixture.machO,
            imageLoadResolver: { _ in .loaded },
            imageResolver: { index in
                duplicateImageResolutions.append(index)
                return duplicateFixture.machO
            }
        )
        XCTAssertEqual(duplicateImageResolutions, [199, 199])
        XCTAssertEqual(
            duplicateResult.entriesForTesting.compactMap { resolution -> UInt64? in
                guard case .resolved(_, let list) = resolution else { return nil }
                return list.header._count
            },
            [2, 1]
        )
        var protocolNames: [String] = []
        for resolution in duplicateResult.entriesForTesting {
            guard case .resolved(let source, let list) = resolution,
                  case .success(let protocols) = list.readProtocols(in: source) else {
                return XCTFail("Expected each loaded inner protocol list to be readable")
            }
            protocolNames.append(
                contentsOf: protocols.references.compactMap {
                    $0.value.mangledName(in: $0.source)
                }
            )
        }
        XCTAssertEqual(protocolNames, ["P1", "P2", "P3"])

        let siblingFixture = SyntheticRelativeImageCollectionFixture(
            imageIndices: [199, 1194, 1680],
            listCounts: [11, 22, 33]
        )
        let siblingResult = siblingFixture.relative64.resolveLists(
            in: siblingFixture.machO,
            imageLoadResolver: { _ in .loaded },
            imageResolver: { index in
                index == 1194 ? nil : siblingFixture.machO
            }
        )
        XCTAssertEqual(siblingResult.entriesForTesting.count, 3)
        guard case .resolved(_, let firstList) = siblingResult.entriesForTesting[0],
              case .failure(let failure) = siblingResult.entriesForTesting[1],
              case .resolved(_, let lastList) = siblingResult.entriesForTesting[2] else {
            return XCTFail("Expected resolved, failure, resolved outcomes in table order")
        }
        XCTAssertEqual(firstList.header._count, 11)
        XCTAssertEqual(failure.failure, .relativeImageUnavailable(imageIndex: 1194))
        XCTAssertEqual(lastList.header._count, 33)
    }

    func testRelativeImageUnknownLoadStateIsTypedAndDoesNotDropLaterEntry() {
        let fixture = SyntheticRelativeImageCollectionFixture(
            imageIndices: [199, 1194],
            listCounts: [11, 22]
        )
        var imageResolutions: [Int] = []
        let result = fixture.relative64.resolveLists(
            in: fixture.machO,
            imageLoadResolver: { $0 == 199 ? .unavailable : .loaded },
            imageResolver: { index in
                imageResolutions.append(index)
                return fixture.machO
            }
        )

        XCTAssertEqual(imageResolutions, [1194])
        guard case .failure(let failure) = result.entriesForTesting[0],
              case .resolved(_, let list) = result.entriesForTesting[1] else {
            return XCTFail("Expected unknown state followed by a resolved list")
        }
        XCTAssertEqual(failure.failure, .relativeImageUnavailable(imageIndex: 199))
        XCTAssertEqual(list.header._count, 22)
    }

    func testRelativeFileListsResolveEveryEntryInOrderWithoutOwnerIndex() throws {
        let fixture = try SyntheticRelativeFileCollectionFixture()
        let locationResolver: (MachOFile, RelativeListListEntry) -> ObjCProtocolRelativeFileLocation? = {
            _, entry in fixture.location(for: entry)
        }

        let result64 = fixture.relative64.resolveLists(
            in: fixture.machO,
            locationResolver: locationResolver
        )
        let result32 = fixture.relative32.resolveLists(
            in: fixture.machO,
            locationResolver: locationResolver
        )

        XCTAssertFalse(fixture.imageIndices.contains(54))
        XCTAssertEqual(
            result64.entriesForTesting.compactMap { resolution -> UInt64? in
                guard case .resolved(_, let list) = resolution else { return nil }
                return list.header._count
            },
            [11, 22, 33, 44]
        )
        XCTAssertEqual(
            result32.entriesForTesting.compactMap { resolution -> UInt32? in
                guard case .resolved(_, let list) = resolution else { return nil }
                return list.header._count
            },
            [11, 22, 33, 44]
        )
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
        guard case .failure(let strideFailure) = invalidStride
            .resolveLists(in: fixture.machO) else {
            return XCTFail("Expected invalid relative stride")
        }
        guard case .invalidRelativeEntrySize = strideFailure.failure else {
            return XCTFail("Unexpected stride failure: \(strideFailure.failure)")
        }

        guard case .some(.failure(let locationFailure)) = fixture.relative64
            .resolveLists(in: fixture.machO)
            .entriesForTesting.first else {
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
        var fileLocationResolutionCount = 0
        guard case .failure(let fileFailure) = fileList.resolveLists(
            in: fileFixture.machO,
            locationResolver: { _, _ in
                fileLocationResolutionCount += 1
                return nil
            }
        ) else {
            return XCTFail("Expected file relative table byte-budget failure")
        }
        XCTAssertEqual(fileLocationResolutionCount, 0)
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
        var imageLoadResolutionCount = 0
        var imageResolutionCount = 0
        guard case .failure(let imageFailure) = imageList.resolveLists(
            in: imageFixture.machO,
            imageLoadResolver: { _ in
                imageLoadResolutionCount += 1
                return .loaded
            },
            imageResolver: { _ in
                imageResolutionCount += 1
                return imageFixture.machO
            }
        ) else {
            return XCTFail("Expected image relative table byte-budget failure")
        }
        XCTAssertEqual(imageLoadResolutionCount, 0)
        XCTAssertEqual(imageResolutionCount, 0)
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
        guard case .failure(let failure) = relative
            .resolveLists(in: fixture.machO) else {
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

        let result = fixture.relative64.resolveLists(
            in: fixture.machO,
            locationResolver: locationResolver
        )
#if arch(arm64_32) || arch(arm) || arch(i386)
        guard case .some(.failure(let failure)) = result.entriesForTesting.first else {
            return XCTFail("Expected an unrepresentable 32-bit list offset to fail safely")
        }
        XCTAssertEqual(failure.failure, .invalidRelativeListLocation)
#else
        guard case .some(.resolved(_, let list)) = result.entriesForTesting.first else {
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

    func testEmptyRelativeListDoesNotRequireOwnerImageIndex() throws {
        let relativePointer = (SyntheticGraph.fileVMAddress + 0xA00) | 1
        let fixture = try SyntheticFileFixture(
            nodes: [.init(name: "A")],
            classProtocolPointerOverride: relativePointer,
            classRelativeProtocolListHeader: .init(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<RelativeListListEntry.Layout>.size),
                    count: 0
                )
            )
        )
        let result = fixture.objcClass.readInfo(in: fixture.machO)
        XCTAssertEqual(result.value?.protocols, [])
        XCTAssertTrue(result.diagnostics.isEmpty, "Unexpected diagnostics: \(result.diagnostics)")
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

    private func syntheticCacheLocations(
        for fixture: SyntheticExternalProtocolFixture,
        cacheUUID: UUID,
        nameByteCount: Int
    ) -> [(UnsafeRawPointer, ObjCProtocolDyldCacheLocation)] {
        [
            (
                fixture.pointer,
                .init(
                    cacheUUID: cacheUUID,
                    unslidAddress: 0x1800_0010_0000,
                    remainingMappedByteCount: UInt(MemoryLayout<ObjCProtocol64.Layout>.size)
                )
            ),
            (
                fixture.namePointer,
                .init(
                    cacheUUID: cacheUUID,
                    unslidAddress: 0x1800_0020_0000,
                    remainingMappedByteCount: UInt(nameByteCount)
                )
            )
        ]
    }

    private func syntheticRuntimeResolver(
        protocolAddress: @escaping (String) -> UnsafeRawPointer?,
        cacheLocations: [(UnsafeRawPointer, ObjCProtocolDyldCacheLocation)],
        usesSharedCacheProtocolOptimizations: Bool = true
    ) -> ObjCProtocolRuntimeResolver {
        let locationsByAddress = Dictionary(
            uniqueKeysWithValues: cacheLocations.map {
                (UInt(bitPattern: $0.0), $0.1)
            }
        )
        return .init(
            protocolAddress: protocolAddress,
            activeDyldCacheLocation: {
                locationsByAddress[UInt(bitPattern: $0)]
            },
            usesSharedCacheProtocolOptimizations: usesSharedCacheProtocolOptimizations
        )
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

private extension ObjCRelativeListResolution where Failure == ObjCProtocolListResolutionFailure {
    var entriesForTesting: [ObjCProtocolListResolutionEntry<Source, List>] {
        guard case .entries(let entries) = self else { return [] }
        return entries
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
        case pointer(UInt64)
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
        categoryProtocolPointerOverride: UInt64? = nil,
        classRelativeProtocolListHeader: EntrySizeListHeader? = nil
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
                case .pointer(let absolute):
                    pointer = absolute
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

        if let classRelativeProtocolListHeader,
           let taggedPointer = classProtocolPointerOverride {
            let untaggedPointer = taggedPointer & ~1
            if untaggedPointer >= pointerBase,
               let relativeOffset = Int(exactly: untaggedPointer - pointerBase) {
                data.store(classRelativeProtocolListHeader, at: relativeOffset)
            }
        }

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

private final class SyntheticExternalProtocolFixture {
    let pointer: UnsafeRawPointer
    let namePointer: UnsafeRawPointer
    private let storage: UnsafeMutableRawPointer

    convenience init(
        name: String,
        declaredSize: UInt32? = nil,
        flags: UInt32 = 0
    ) {
        self.init(
            nameBytes: Array(name.utf8) + [0],
            declaredSize: declaredSize,
            flags: flags
        )
    }

    init(
        nameBytes: [UInt8],
        namePointerOverride: UInt64? = nil,
        declaredSize: UInt32? = nil,
        flags: UInt32 = 0
    ) {
        let layoutSize = MemoryLayout<ObjCProtocol64.Layout>.size
        let payloadByteCount = max(nameBytes.count, 1)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: layoutSize + payloadByteCount,
            alignment: 16
        )
        self.storage = storage
        self.pointer = UnsafeRawPointer(storage)
        storage.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: layoutSize + payloadByteCount
        )

        let namePointer = storage.advanced(by: layoutSize)
        self.namePointer = UnsafeRawPointer(namePointer)
        if !nameBytes.isEmpty {
            nameBytes.withUnsafeBytes { bytes in
                namePointer.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        var layout = ObjCProtocol64.Layout(
            isa: 0,
            mangledName: namePointerOverride ?? UInt64(UInt(bitPattern: namePointer)),
            protocols: 0,
            instanceMethods: 0,
            classMethods: 0,
            optionalInstanceMethods: 0,
            optionalClassMethods: 0,
            instanceProperties: 0,
            size: declaredSize ?? UInt32(layoutSize),
            flags: flags,
            _extendedMethodTypes: 0,
            _demangledName: 0,
            _classProperties: 0
        )
        withUnsafeBytes(of: &layout) { bytes in
            storage.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }

    deinit {
        storage.deallocate()
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
        categoryProtocolPointerOverride: UInt64? = nil,
        classRelativeProtocolListHeader: EntrySizeListHeader? = nil
    ) throws {
        let built = SyntheticGraph.build(
            nodes: nodes,
            pointerBase: SyntheticGraph.fileVMAddress,
            segmentVMAddress: SyntheticGraph.fileVMAddress,
            classProtocolPointerOverride: classProtocolPointerOverride,
            categoryProtocolPointerOverride: categoryProtocolPointerOverride,
            classRelativeProtocolListHeader: classRelativeProtocolListHeader
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

private final class SyntheticRelativeImageCollectionFixture {
    let machO: MachOImage
    let relative64: ObjCProtocolRelativeListList64
    let relative32: ObjCProtocolRelativeListList32
    let imageIndices: [Int]
    private let storage: UnsafeMutableRawPointer

    init(
        imageIndices: [Int] = [199, 1194, 1680, 0],
        listCounts: [UInt64] = [11, 22, 33, 44],
        unreadableEntryIndices: Set<Int> = [],
        protocolNamesByList: [[String]]? = nil
    ) {
        let effectiveListCounts = protocolNamesByList?.map { UInt64($0.count) } ?? listCounts
        precondition(imageIndices.count == effectiveListCounts.count)

        let byteCount = 0x8000
        let relativeStorageOffset = 0x400
        let firstListStorageOffset = 0x1000
        let listStorageStride = 0x100
        let firstProtocolStorageOffset = 0x3000
        let protocolStorageStride = 0x100
        let firstNameStorageOffset = 0x6000
        let nameStorageStride = 0x40
        let advertisedStride = MemoryLayout<RelativeListListEntry.Layout>.size + 8
        self.imageIndices = imageIndices
        self.storage = .allocate(byteCount: byteCount, alignment: 16)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        let storageAddress = UInt64(UInt(bitPattern: storage))
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
        segment.vmaddr = storageAddress
        segment.vmsize = UInt64(byteCount)
        segment.fileoff = 0
        segment.filesize = UInt64(byteCount)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        storage.advanced(by: MemoryLayout<mach_header_64>.size).storeUnaligned(segment)

        let relativePointer = storage.advanced(by: relativeStorageOffset)
        relativePointer.storeUnaligned(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(advertisedStride),
                    count: UInt32(imageIndices.count)
                )
            )
        )
        let tableOffset = relativeStorageOffset + MemoryLayout<EntrySizeListHeader>.size
        for index in imageIndices.indices {
            let entryOffset = tableOffset + index * advertisedStride
            let listStorageOffset = firstListStorageOffset + index * listStorageStride
            var entry = RelativeListListEntry.Layout()
            entry.imageIndex = numericCast(imageIndices[index])
            if unreadableEntryIndices.contains(index) {
                entry.listOffset = Int64(0x10_0000 - entryOffset)
            } else {
                entry.listOffset = Int64(listStorageOffset - entryOffset)
                storage.advanced(by: listStorageOffset).storeUnaligned(
                    ObjCProtocolListHeader64(_count: effectiveListCounts[index])
                )
            }
            relativePointer
                .advanced(by: MemoryLayout<EntrySizeListHeader>.size + index * advertisedStride)
                .storeUnaligned(entry)
        }

        if let protocolNamesByList {
            var protocolIndex = 0
            for (listIndex, names) in protocolNamesByList.enumerated() {
                let listStorageOffset = firstListStorageOffset + listIndex * listStorageStride
                for (nameIndex, name) in names.enumerated() {
                    let protocolStorageOffset = firstProtocolStorageOffset
                        + protocolIndex * protocolStorageStride
                    let nameStorageOffset = firstNameStorageOffset + protocolIndex * nameStorageStride
                    storage.advanced(by: nameStorageOffset).storeBytes(Array(name.utf8) + [0])
                    storage.advanced(by: protocolStorageOffset).storeUnaligned(
                        ObjCProtocol64.Layout(
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
                    )
                    storage.advanced(
                        by: listStorageOffset
                            + MemoryLayout<ObjCProtocolListHeader64>.size
                            + nameIndex * MemoryLayout<UInt64>.size
                    ).storeUnaligned(storageAddress + UInt64(protocolStorageOffset))
                    protocolIndex += 1
                }
            }
        }

        self.machO = MachOImage(ptr: storage.assumingMemoryBound(to: mach_header.self))
        self.relative64 = ObjCProtocolRelativeListList64(
            ptr: relativePointer,
            offset: relativeStorageOffset
        )
        self.relative32 = ObjCProtocolRelativeListList32(
            ptr: relativePointer,
            offset: relativeStorageOffset
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

private final class SyntheticRelativeFileCollectionFixture {
    let machO: MachOFile
    let relative64: ObjCProtocolRelativeListList64
    let relative32: ObjCProtocolRelativeListList32
    let imageIndices: [Int]
    private let url: URL

    init(
        imageIndices: [Int] = [199, 1194, 1680, 0],
        listCounts: [UInt64] = [11, 22, 33, 44]
    ) throws {
        precondition(imageIndices.count == listCounts.count)

        let fileSize = 0x2000
        let vmAddress: UInt64 = 0x2000_0000
        let relativeOffset = 0x100
        let firstListOffset = 0x1000
        let listStride = 0x100
        let advertisedStride = MemoryLayout<RelativeListListEntry.Layout>.size + 8
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

        let relativeHeader = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(advertisedStride),
                count: UInt32(imageIndices.count)
            )
        )
        data.store(relativeHeader, at: relativeOffset)
        let tableOffset = relativeOffset + MemoryLayout<EntrySizeListHeader>.size
        for index in imageIndices.indices {
            let entryOffset = tableOffset + index * advertisedStride
            let listOffset = firstListOffset + index * listStride
            var entry = RelativeListListEntry.Layout()
            entry.imageIndex = numericCast(imageIndices[index])
            entry.listOffset = Int64(listOffset - entryOffset)
            data.store(entry, at: entryOffset)
            data.store(ObjCProtocolListHeader64(_count: listCounts[index]), at: listOffset)
        }

        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachOObjCSection-relative-collection-\(UUID().uuidString)")
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
        self.imageIndices = imageIndices
    }

    func location(
        for entry: RelativeListListEntry
    ) -> ObjCProtocolRelativeFileLocation? {
        guard let listOffset = addingSignedDisplacement(entry.signedListOffset, to: entry.offset),
              let fileOffset = UInt64(exactly: listOffset) else {
            return nil
        }
        return .direct(in: machO, fileOffset: fileOffset)
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
