import Foundation
import MachOKit
@_spi(Core) @_spi(Diagnostics) @testable import MachOObjCSection
import XCTest
#if canImport(Darwin)
import Darwin
#endif

final class ObjCLoadedImageSafetyTests: XCTestCase {
    func testLoadedClassRootsPreserveGoodBadGoodAndLegacyProjection() throws {
        let fixture = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: UInt64(3 * MemoryLayout<UInt64>.size)
        )
        let firstOffset = fixture.layoutOffset
        let secondOffset = firstOffset + MemoryLayout<ObjCClass64.Layout>.stride
        fixture.store(Self.class64Layout(isa: 0x10), at: firstOffset)
        fixture.store(Self.class64Layout(isa: 0x20), at: secondOffset)
        fixture.storeRootPointers64([
            fixture.address(at: firstOffset),
            fixture.address(at: fixture.unreadableOffset),
            fixture.address(at: secondOffset),
        ])
        try fixture.protectUnreadablePage()

        XCTAssertTrue(fixture.machO.is64Bit)
        XCTAssertNotNil(fixture.machO.vmaddrSlide)
        XCTAssertEqual(Array(fixture.machO.segments64).map(\.segmentName), ["__TEXT", "__DATA"])
        XCTAssertEqual(fixture.machO.sections64.map(\.sectionName), ["__objc_classlist"])
        XCTAssertNotNil(fixture.machO.findObjCSection64(for: .__objc_classlist))
        let result = fixture.machO.objc.readRoots()

        XCTAssertEqual(result.classes64?.map(\.layout.isa), [0x10, 0x20])
        XCTAssertEqual(fixture.machO.objc.classes64?.map(\.layout.isa), [0x10, 0x20])
        guard result.tableDiagnostics.count == 1 else {
            return XCTFail("Expected one unreadable root diagnostic")
        }
        guard case .entry(index: 1, provenance: _) = result.tableDiagnostics[0].site else {
            return XCTFail("Expected the unreadable middle root entry")
        }
        XCTAssertEqual(
            result.tableDiagnostics[0].owner,
            .loadedImageRoot(section: .classList, pointerWidth: .bits64)
        )
        guard case .unreadableReferencedLayout = result.tableDiagnostics[0].failure else {
            return XCTFail("Expected an unreadable referenced class layout")
        }
    }

    func testLoaded32BitRootDecoderUsesUInt32PointersAndLayout() throws {
        let fixture = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: 0
        )
        let token: UInt32 = 0x1000
        fixture.storeRootPointers32([token])

        let result: ObjCLoadedRootTableRead<ObjCClass32> = fixture.machO.objc
            .readRootTable(
                tableAddress: fixture.address(at: fixture.tableOffset),
                rawByteCount: UInt64(MemoryLayout<UInt32>.size),
                pointerType: UInt32.self,
                layoutType: ObjCClass32.Layout.self,
                root: .classList,
                pointerWidth: .bits32,
                layoutReader: { address in
                    guard address == UInt(token) else {
                        return .failure(
                            .unreadableImageRange(
                                address: address,
                                byteCount: MemoryLayout<ObjCClass32.Layout>.size
                            )
                        )
                    }
                    return .success(Self.class32Layout(isa: 7))
                },
                makeValue: { layout, offset in
                    ObjCClass32(layout: layout, offset: offset)
                }
            )

        XCTAssertEqual(result.values.map(\.layout.isa), [7])
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testLoadedProtocolAndCategoryRootsUseTheSameCheckedOwner() throws {
        let protocolFixture = try SyntheticLoadedObjCImageFixture(
            section: .protocolList,
            sectionByteCount: UInt64(MemoryLayout<UInt64>.size)
        )
        protocolFixture.store(Self.protocol64Layout(), at: protocolFixture.layoutOffset)
        protocolFixture.storeRootPointers64([
            protocolFixture.address(at: protocolFixture.layoutOffset)
        ])

        let categoryFixture = try SyntheticLoadedObjCImageFixture(
            section: .categoryList2,
            sectionByteCount: UInt64(MemoryLayout<UInt64>.size)
        )
        categoryFixture.store(Self.category64Layout(), at: categoryFixture.layoutOffset)
        categoryFixture.storeRootPointers64([
            categoryFixture.address(at: categoryFixture.layoutOffset)
        ])

        XCTAssertEqual(protocolFixture.machO.objc.readRoots().protocols64?.count, 1)
        XCTAssertEqual(categoryFixture.machO.objc.readRoots().categories2_64?.count, 1)
        XCTAssertEqual(categoryFixture.machO.objc.categories2_64?.first?.isCatlist2, true)
    }

    func testReferencedRootLayoutAcceptsExactBoundaryAndRejectsTruncation() throws {
        let fixture = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: UInt64(2 * MemoryLayout<UInt64>.size)
        )
        let exactOffset = fixture.unreadableOffset - MemoryLayout<ObjCClass64.Layout>.size
        let truncatedOffset = exactOffset + MemoryLayout<UInt64>.size
        fixture.store(Self.class64Layout(isa: 0x44), at: exactOffset)
        fixture.storeRootPointers64([
            fixture.address(at: exactOffset),
            fixture.address(at: truncatedOffset),
        ])
        try fixture.protectUnreadablePage()

        let result = fixture.machO.objc.readRoots()

        XCTAssertEqual(result.classes64?.map(\.layout.isa), [0x44])
        guard result.tableDiagnostics.count == 1,
              case .entry(index: 1, provenance: _) = result.tableDiagnostics[0].site,
              case .unreadableReferencedLayout = result.tableDiagnostics[0].failure else {
            return XCTFail("Only the truncated referenced layout should be omitted")
        }
    }

    func testRootAbsenceAndPresentEmptySectionStayDistinct() throws {
        let fixture = try SyntheticLoadedObjCImageFixture(
            section: .categoryList,
            sectionByteCount: 0
        )

        let result = fixture.machO.objc.readRoots()

        XCTAssertNil(result.classes64)
        XCTAssertEqual(result.categories64?.count, 0)
        XCTAssertTrue(result.tableDiagnostics.isEmpty)
    }

    func testMalformedRootSectionRangeAndByteRemainderAreWholeTableFailures() throws {
        let unreadable = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: UInt64(MemoryLayout<UInt64>.size),
            sectionOffset: SyntheticLoadedObjCImageFixture.defaultUnreadablePageIndex
        )
        try unreadable.protectUnreadablePage()
        let unreadableResult = unreadable.machO.objc.readRoots()
        XCTAssertEqual(unreadableResult.classes64?.count, 0)
        guard case .some(.table(_)) = unreadableResult.tableDiagnostics.first?.site else {
            return XCTFail("Expected a whole root table failure")
        }
        guard case .unreadableImageRange = unreadableResult.tableDiagnostics.first?.failure else {
            return XCTFail("Expected an unreadable root pointer table")
        }

        let remainder = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: UInt64(MemoryLayout<UInt64>.size + 1)
        )
        let remainderResult = remainder.machO.objc.readRoots()
        XCTAssertEqual(remainderResult.classes64?.count, 0)
        guard case let .invalidSectionByteCount(byteCount, pointerSize) =
            remainderResult.tableDiagnostics.first?.failure else {
            return XCTFail("Expected a pointer-size remainder failure")
        }
        XCTAssertEqual(byteCount, UInt64(MemoryLayout<UInt64>.size + 1))
        XCTAssertEqual(pointerSize, MemoryLayout<UInt64>.size)
    }

    func testRootBudgetFailsBeforeUnreadableRange() throws {
        let byteCount = UInt64(
            (ObjCMetadataReadLimits.maximumListEntries + 1) * MemoryLayout<UInt64>.size
        )
        let fixture = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: byteCount,
            sectionOffset: SyntheticLoadedObjCImageFixture.defaultUnreadablePageIndex
        )
        try fixture.protectUnreadablePage()

        let result = fixture.machO.objc.readRoots()

        guard case let .excessiveElementCount(actual, maximum) =
            result.tableDiagnostics.first?.failure else {
            return XCTFail("The entry budget must run before range probing")
        }
        XCTAssertEqual(actual, ObjCMetadataReadLimits.maximumListEntries + 1)
        XCTAssertEqual(maximum, ObjCMetadataReadLimits.maximumListEntries)
    }

    func testRootCoordinatesDoNotUseUncheckedTextSlideAndRejectMaxDataCoordinates() throws {
        let invalidImageBase = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: 0,
            textVirtualMemoryAddress: .max
        )
        guard case let .invalidLoadedSectionAddress(
            _, imageVirtualMemoryAddress, _
        ) = invalidImageBase.machO.objc.readRoots().tableDiagnostics.first?.failure else {
            return XCTFail("An unrepresentable image-base displacement must be typed failure")
        }
        XCTAssertEqual(imageVirtualMemoryAddress, UInt64.max)

        let invalidVirtualAddress = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: 0,
            textVirtualMemoryAddress: .max,
            dataVirtualMemoryAddress: .max
        )
        guard case let .invalidSectionCoordinates(
            _, _, _, segmentAddress, _, _, _
        ) = invalidVirtualAddress.machO.objc.readRoots().tableDiagnostics.first?.failure else {
            return XCTFail("An unrepresentable data-segment VM address must be typed failure")
        }
        XCTAssertEqual(segmentAddress, UInt64.max)

        let invalidFileOffset = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: 0,
            textVirtualMemoryAddress: .max,
            dataFileOffset: .max
        )
        guard case let .invalidSectionCoordinates(
            _, _, _, _, _, segmentFileOffset, _
        ) = invalidFileOffset.machO.objc.readRoots().tableDiagnostics.first?.failure else {
            return XCTFail("An unrepresentable data-segment file offset must be typed failure")
        }
        XCTAssertEqual(segmentFileOffset, UInt64.max)
    }

    func testRootAddressUsesTextVMAddressAcrossDistinctDataSegment() throws {
        let textAddress: UInt64 = 0x1_0000_0000
        let fixture = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: UInt64(MemoryLayout<UInt64>.size),
            textVirtualMemoryAddress: textAddress,
            dataVirtualMemoryAddress: textAddress + UInt64(getpagesize()),
            sectionVirtualMemoryAddress: textAddress + UInt64(getpagesize())
        )
        fixture.store(Self.class64Layout(isa: 0x71), at: fixture.layoutOffset)
        fixture.storeRootPointers64([fixture.address(at: fixture.layoutOffset)])

        let result = fixture.machO.objc.readRoots()

        XCTAssertEqual(result.classes64?.map(\.layout.isa), [0x71])
        XCTAssertTrue(result.tableDiagnostics.isEmpty)
    }

    func testLoadedMemberHeadersDistinguishNullExactTruncatedAndEmpty() throws {
        let fixture = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: 0
        )
        let headerSize = MemoryLayout<EntrySizeListHeader>.size
        let exactOffset = fixture.unreadableOffset - headerSize
        let truncatedOffset = exactOffset + 2
        let malformedOffset = exactOffset - 0x100
        fixture.store(
            EntrySizeListHeader(
                layout: .init(entsizeAndFlags: .max, count: 0)
            ),
            at: exactOffset
        )
        fixture.store(
            EntrySizeListHeader(
                layout: .init(entsizeAndFlags: .max, count: 1)
            ),
            at: malformedOffset
        )
        try fixture.protectUnreadablePage()

        let absent = ObjCClassROData64(
            layout: Self.classRO64Layout(),
            offset: 0
        )
        XCTAssertNil(absent.methodList(in: fixture.machO))

        let exact = ObjCClassROData64(
            layout: Self.classRO64Layout(
                baseMethods: UInt64(fixture.address(at: exactOffset))
            ),
            offset: 0
        )
        guard case .value(let emptyList) = exact.readLoadedMethodList(in: fixture.machO) else {
            return XCTFail("A zero-count exact-boundary header is legal")
        }
        XCTAssertEqual(emptyList.header.layout.count, 0)

        let truncated = ObjCClassROData64(
            layout: Self.classRO64Layout(
                baseMethods: UInt64(fixture.address(at: truncatedOffset))
            ),
            offset: 0
        )
        guard case .failure = truncated.readLoadedMethodList(in: fixture.machO) else {
            return XCTFail("A truncated non-null header must be a typed failure")
        }
        XCTAssertNil(truncated.methodList(in: fixture.machO))

        let unreadable = ObjCClassROData64(
            layout: Self.classRO64Layout(
                baseMethods: UInt64(fixture.address(at: fixture.unreadableOffset))
            ),
            offset: 0
        )
        guard case .failure = unreadable.readLoadedMethodList(in: fixture.machO) else {
            return XCTFail("An unreadable non-null header must be a typed failure")
        }

        let malformed = ObjCClassROData64(
            layout: Self.classRO64Layout(
                baseMethods: UInt64(fixture.address(at: malformedOffset))
            ),
            offset: 0
        )
        guard case let .failure(_, reason) = malformed.readLoadedMethodList(in: fixture.machO),
              case .unexpectedElementStride = reason else {
            return XCTFail("A nonempty list must validate its raw stride without numericCast")
        }
    }

    func testLoadedClassCategoryAndProtocolMemberHeadersShareValidation() throws {
        let fixture = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: 0
        )
        let methodOffset = fixture.layoutOffset
        let propertyOffset = methodOffset + 0x100
        let ivarOffset = propertyOffset + 0x100
        fixture.store(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCMethod.Pointer>.size),
                    count: 0
                )
            ),
            at: methodOffset
        )
        fixture.store(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCProperty.Property>.size),
                    count: 0
                )
            ),
            at: propertyOffset
        )
        fixture.store(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCIvar64.Layout>.size),
                    count: 0
                )
            ),
            at: ivarOffset
        )

        let classRO = ObjCClassROData64(
            layout: Self.classRO64Layout(
                baseMethods: UInt64(fixture.address(at: methodOffset)),
                ivars: UInt64(fixture.address(at: ivarOffset)),
                baseProperties: UInt64(fixture.address(at: propertyOffset))
            ),
            offset: 0
        )
        XCTAssertNotNil(classRO.methodList(in: fixture.machO))
        XCTAssertNotNil(classRO.propertyList(in: fixture.machO))
        XCTAssertNotNil(classRO.ivarList(in: fixture.machO))

        let category = ObjCCategory64(
            layout: Self.category64Layout(
                instanceMethods: UInt64(fixture.address(at: methodOffset)),
                classMethods: UInt64(fixture.address(at: methodOffset)),
                instanceProperties: UInt64(fixture.address(at: propertyOffset)),
                classProperties: UInt64(fixture.address(at: propertyOffset))
            ),
            offset: 0,
            isCatlist2: false
        )
        XCTAssertNotNil(category.instanceMethodList(in: fixture.machO))
        XCTAssertNotNil(category.classMethodList(in: fixture.machO))
        XCTAssertNotNil(category.instancePropertyList(in: fixture.machO))
        XCTAssertNotNil(category.classPropertyList(in: fixture.machO))

        let proto = ObjCProtocol64(
            layout: Self.protocol64Layout(
                instanceMethods: UInt64(fixture.address(at: methodOffset)),
                classMethods: UInt64(fixture.address(at: methodOffset)),
                optionalInstanceMethods: UInt64(fixture.address(at: methodOffset)),
                optionalClassMethods: UInt64(fixture.address(at: methodOffset)),
                instanceProperties: UInt64(fixture.address(at: propertyOffset)),
                classProperties: UInt64(fixture.address(at: propertyOffset))
            ),
            offset: 0
        )
        XCTAssertNotNil(proto.instanceMethodList(in: fixture.machO))
        XCTAssertNotNil(proto.classMethodList(in: fixture.machO))
        XCTAssertNotNil(proto.optionalInstanceMethodList(in: fixture.machO))
        XCTAssertNotNil(proto.optionalClassMethodList(in: fixture.machO))
        XCTAssertNotNil(proto.instancePropertyList(in: fixture.machO))
        XCTAssertNotNil(proto.classPropertyList(in: fixture.machO))
    }

    func testRelativeMarkersAreOwnedByClassROAndRejectedByDirectMemberOwners() throws {
        let fixture = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: 0
        )
        let methodOffset = fixture.layoutOffset
        let propertyOffset = methodOffset + 0x100
        fixture.store(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<RelativeListListEntry.Layout>.size),
                    count: 0
                )
            ),
            at: methodOffset
        )
        fixture.store(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<RelativeListListEntry.Layout>.size),
                    count: 0
                )
            ),
            at: propertyOffset
        )
        let methodMarker = UInt64(fixture.address(at: methodOffset)) | 1
        let propertyMarker = UInt64(fixture.address(at: propertyOffset)) | 1

        let classRO = ObjCClassROData64(
            layout: Self.classRO64Layout(
                baseMethods: methodMarker,
                baseProperties: propertyMarker
            ),
            offset: 0
        )
        guard case .value = classRO.readLoadedMethodRelativeListList(in: fixture.machO),
              case .value = classRO.readLoadedPropertyRelativeListList(in: fixture.machO) else {
            return XCTFail("Class RO relative markers must resolve through relative owners")
        }
        XCTAssertNil(classRO.methodList(in: fixture.machO))
        XCTAssertNil(classRO.propertyList(in: fixture.machO))

        let category = ObjCCategory64(
            layout: Self.category64Layout(instanceMethods: methodMarker),
            offset: 0,
            isCatlist2: false
        )
        guard case let .failure(_, categoryReason) = category.readLoadedMethodList(
            at: category.layout.instanceMethods,
            in: fixture.machO
        ), case .unsupportedListEncoding = categoryReason else {
            return XCTFail("Category member fields do not support relative markers")
        }

        let proto = ObjCProtocol64(
            layout: Self.protocol64Layout(instanceMethods: methodMarker),
            offset: 0
        )
        guard case let .failure(_, protocolReason) = proto.readLoadedMethodList(
            field: .instanceMethods,
            in: fixture.machO
        ), case .unsupportedListEncoding = protocolReason else {
            return XCTFail("Protocol member fields do not support relative markers")
        }
    }

    func testUnreadableLoadedRelationshipsDegradeWithoutDereference() throws {
        let fixture = try SyntheticLoadedObjCImageFixture(
            section: .classList,
            sectionByteCount: 0
        )
        try fixture.protectUnreadablePage()
        let unreadableAddress = UInt64(fixture.address(at: fixture.unreadableOffset))
        let cls = ObjCClass64(
            layout: Self.class64Layout(
                isa: unreadableAddress,
                superclass: unreadableAddress
            ),
            offset: 0
        )
        guard case .failure = cls.readLoadedRelatedClass(field: .isa, in: fixture.machO) else {
            return XCTFail("Unreadable metaclass layout must be typed failure")
        }
        let metaClass: (MachOImage, ObjCClass64)? = cls.metaClass(in: fixture.machO)
        XCTAssertNil(metaClass)
        guard case .failure = cls.readLoadedRelatedClass(
            field: .superclass,
            in: fixture.machO
        ) else {
            return XCTFail("Unreadable superclass layout must be typed failure")
        }
        let superclass: (MachOImage, ObjCClass64)? = cls.superClass(in: fixture.machO)
        XCTAssertNil(superclass)

        let category = ObjCCategory64(
            layout: Self.category64Layout(cls: unreadableAddress),
            offset: 0,
            isCatlist2: false
        )
        guard case .failure = category.readLoadedClass(in: fixture.machO) else {
            return XCTFail("Unreadable category class layout must be typed failure")
        }
        let categoryClass: (MachOImage, ObjCClass64)? = category.class(in: fixture.machO)
        XCTAssertNil(categoryClass)
        guard case .failure = category.readLoadedStubClass(in: fixture.machO) else {
            return XCTFail("Unreadable category stub-class layout must be typed failure")
        }
        let stubClass: (MachOImage, ObjCStubClass64)? = category.stubClass(in: fixture.machO)
        XCTAssertNil(stubClass)
    }

    private static func class64Layout(
        isa: UInt64,
        superclass: UInt64 = 0
    ) -> ObjCClass64.Layout {
        .init(
            isa: isa,
            superclass: superclass,
            methodCacheBuckets: 0,
            methodCacheProperties: 0,
            dataVMAddrAndFastFlags: 0,
            swiftClassFlags: 0
        )
    }

    private static func class32Layout(isa: UInt32) -> ObjCClass32.Layout {
        .init(
            isa: isa,
            superclass: 0,
            methodCacheBuckets: 0,
            methodCacheProperties: 0,
            dataVMAddrAndFastFlags: 0,
            swiftClassFlags: 0
        )
    }

    private static func category64Layout(
        cls: UInt64 = 0,
        instanceMethods: UInt64 = 0,
        classMethods: UInt64 = 0,
        instanceProperties: UInt64 = 0,
        classProperties: UInt64 = 0
    ) -> ObjCCategory64.Layout {
        .init(
            name: 0,
            cls: cls,
            instanceMethods: instanceMethods,
            classMethods: classMethods,
            protocols: 0,
            instanceProperties: instanceProperties,
            _classProperties: classProperties
        )
    }

    private static func protocol64Layout(
        instanceMethods: UInt64 = 0,
        classMethods: UInt64 = 0,
        optionalInstanceMethods: UInt64 = 0,
        optionalClassMethods: UInt64 = 0,
        instanceProperties: UInt64 = 0,
        classProperties: UInt64 = 0
    ) -> ObjCProtocol64.Layout {
        .init(
            isa: 0,
            mangledName: 0,
            protocols: 0,
            instanceMethods: instanceMethods,
            classMethods: classMethods,
            optionalInstanceMethods: optionalInstanceMethods,
            optionalClassMethods: optionalClassMethods,
            instanceProperties: instanceProperties,
            size: UInt32(MemoryLayout<ObjCProtocol64.Layout>.size),
            flags: 0,
            _extendedMethodTypes: 0,
            _demangledName: 0,
            _classProperties: classProperties
        )
    }

    private static func classRO64Layout(
        baseMethods: UInt64 = 0,
        ivars: UInt64 = 0,
        baseProperties: UInt64 = 0
    ) -> ObjCClassROData64.Layout {
        .init(
            flags: 0,
            instanceStart: 0,
            instanceSize: 0,
            _reserved: 0,
            ivarLayout: 0,
            name: 0,
            baseMethods: baseMethods,
            baseProtocols: 0,
            ivars: ivars,
            weakIvarLayout: 0,
            baseProperties: baseProperties
        )
    }
}

#if canImport(Darwin)
private final class SyntheticLoadedObjCImageFixture {
    static let defaultUnreadablePageIndex = 3

    enum RootSection {
        case classList
        case protocolList
        case categoryList
        case categoryList2

        var name: String {
            switch self {
            case .classList: "__objc_classlist"
            case .protocolList: "__objc_protolist"
            case .categoryList: "__objc_catlist"
            case .categoryList2: "__objc_catlist2"
            }
        }
    }

    lazy var machO = MachOImage(
        ptr: mapping.assumingMemoryBound(to: mach_header.self)
    )
    let pageSize: Int
    let tableOffset: Int
    let layoutOffset: Int
    let unreadableOffset: Int

    private let mapping: UnsafeMutableRawPointer
    private let mappingLength: Int
    private var unreadablePageIsProtected = false

    init(
        section: RootSection,
        sectionByteCount: UInt64,
        sectionOffset pageIndex: Int = 1,
        textVirtualMemoryAddress: UInt64? = nil,
        dataVirtualMemoryAddress: UInt64? = nil,
        sectionVirtualMemoryAddress: UInt64? = nil,
        dataFileOffset: UInt64 = 0
    ) throws {
        pageSize = Int(getpagesize())
        mappingLength = pageSize * 5
        mapping = try Self.allocateMapping(byteCount: mappingLength)
        mapping.initializeMemory(as: UInt8.self, repeating: 0, count: mappingLength)
        tableOffset = pageSize * pageIndex
        layoutOffset = pageSize * 2
        unreadableOffset = pageSize * Self.defaultUnreadablePageIndex

        writeMachO64(
            root: section,
            sectionByteCount: sectionByteCount,
            textVirtualMemoryAddress: textVirtualMemoryAddress,
            dataVirtualMemoryAddress: dataVirtualMemoryAddress,
            sectionVirtualMemoryAddress: sectionVirtualMemoryAddress,
            dataFileOffset: dataFileOffset
        )
    }

    func address(at offset: Int) -> UInt {
        UInt(bitPattern: mapping.advanced(by: offset))
    }

    func store<Value>(_ value: Value, at offset: Int) {
        mapping.advanced(by: offset).storeUnaligned(value)
    }

    func storeRootPointers64(_ values: [UInt]) {
        for (index, value) in values.enumerated() {
            store(UInt64(value), at: tableOffset + index * MemoryLayout<UInt64>.size)
        }
    }

    func storeRootPointers32(_ values: [UInt32]) {
        for (index, value) in values.enumerated() {
            store(value, at: tableOffset + index * MemoryLayout<UInt32>.size)
        }
    }

    func protectUnreadablePage() throws {
        guard !unreadablePageIsProtected else { return }
        guard mprotect(
            mapping.advanced(by: unreadableOffset),
            pageSize,
            PROT_NONE
        ) == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        unreadablePageIsProtected = true
    }

    private func writeMachO64(
        root: RootSection,
        sectionByteCount: UInt64,
        textVirtualMemoryAddress: UInt64?,
        dataVirtualMemoryAddress: UInt64?,
        sectionVirtualMemoryAddress: UInt64?,
        dataFileOffset: UInt64
    ) {
        let textSize = MemoryLayout<segment_command_64>.size
        let dataSize = MemoryLayout<segment_command_64>.size
            + MemoryLayout<section_64>.size
        var header = mach_header_64()
        header.magic = UInt32(MH_MAGIC_64)
        header.cputype = CPU_TYPE_ARM64
        header.cpusubtype = CPU_SUBTYPE_ARM64_ALL
        header.filetype = UInt32(MH_DYLIB)
        header.ncmds = 2
        header.sizeofcmds = UInt32(textSize + dataSize)
        store(header, at: 0)

        var text = segment_command_64()
        text.cmd = UInt32(LC_SEGMENT_64)
        text.cmdsize = UInt32(textSize)
        Self.storeName("__TEXT", in: &text.segname)
        text.vmaddr = textVirtualMemoryAddress ?? UInt64(UInt(bitPattern: mapping))
        text.vmsize = UInt64(mappingLength)
        text.filesize = UInt64(mappingLength)
        text.maxprot = VM_PROT_READ
        text.initprot = VM_PROT_READ
        store(text, at: MemoryLayout<mach_header_64>.size)

        var data = segment_command_64()
        data.cmd = UInt32(LC_SEGMENT_64)
        data.cmdsize = UInt32(dataSize)
        Self.storeName("__DATA", in: &data.segname)
        data.vmaddr = dataVirtualMemoryAddress ?? UInt64(UInt(bitPattern: mapping))
        let (requiredVirtualSize, virtualSizeOverflow) = UInt64(tableOffset)
            .addingReportingOverflow(sectionByteCount)
        data.vmsize = virtualSizeOverflow
            ? .max
            : max(UInt64(mappingLength), requiredVirtualSize)
        data.fileoff = dataFileOffset
        data.filesize = max(UInt64(mappingLength), sectionByteCount)
        data.maxprot = VM_PROT_READ
        data.initprot = VM_PROT_READ
        data.nsects = 1
        let dataOffset = MemoryLayout<mach_header_64>.size + textSize
        store(data, at: dataOffset)

        var rootSection = section_64()
        Self.storeName(root.name, in: &rootSection.sectname)
        Self.storeName("__DATA", in: &rootSection.segname)
        rootSection.addr = sectionVirtualMemoryAddress ?? UInt64(address(at: tableOffset))
        rootSection.size = sectionByteCount
        rootSection.align = 3
        store(rootSection, at: dataOffset + MemoryLayout<segment_command_64>.size)
    }

    private static func storeName<Name>(_ name: String, in field: inout Name) {
        withUnsafeMutableBytes(of: &field) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            let utf8 = Array(name.utf8.prefix(bytes.count))
            bytes.copyBytes(from: utf8)
        }
    }

    private static func allocateMapping(
        byteCount: Int
    ) throws -> UnsafeMutableRawPointer {
        guard let mapping = mmap(
            nil,
            byteCount,
            PROT_READ | PROT_WRITE,
            MAP_ANON | MAP_PRIVATE,
            -1,
            0
        ), mapping != MAP_FAILED else {
            throw CocoaError(.fileReadUnknown)
        }
        return mapping
    }

    deinit {
        if unreadablePageIsProtected {
            _ = mprotect(
                mapping.advanced(by: unreadableOffset),
                pageSize,
                PROT_READ | PROT_WRITE
            )
        }
        munmap(mapping, mappingLength)
    }
}
#endif

private extension UnsafeMutableRawPointer {
    func storeUnaligned<Value>(_ value: Value) {
        var value = value
        Swift.withUnsafeBytes(of: &value) { bytes in
            copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
}
