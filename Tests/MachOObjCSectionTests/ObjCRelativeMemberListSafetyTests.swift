import Foundation
import MachOKit
@_spi(Diagnostics) @testable import MachOObjCSection
import XCTest

final class ObjCRelativeMemberListSafetyTests: XCTestCase {
    func testMethodListsSkipUnloadedAndPreserveValidSiblingsInOuterOrder() {
        let fixture = SyntheticRelativeMemberImageFixture(kind: .method)
        var loadChecks: [Int] = []
        var imageResolutions: [Int] = []

        let result = fixture.methodRelative.resolveMemberLists(
            in: fixture.machO,
            imageLoadResolver: { index in
                loadChecks.append(index)
                return index == 199 ? .unloaded : .loaded
            },
            imageResolver: { index in
                imageResolutions.append(index)
                return fixture.machO
            }
        )

        XCTAssertEqual(loadChecks, [199, 1194, 1194, 0])
        XCTAssertEqual(imageResolutions, [1194, 1194, 0])
        XCTAssertEqual(result.entriesForTesting.count, 3)
        guard case .failure(let failure) = result.entriesForTesting[1] else {
            return XCTFail("Expected the malformed loaded method list to stay in order")
        }
        XCTAssertEqual(
            failure.reason,
            .invalidListEntrySize(
                advertised: MemoryLayout<ObjCMethod.Pointer>.size - 4,
                expected: MemoryLayout<ObjCMethod.Pointer>.size
            )
        )
        XCTAssertEqual(methodNames(in: result), ["m1", "m2", "m3"])
    }

    func testPropertyListsSkipUnloadedAndPreserveValidSiblingsInOuterOrder() {
        let fixture = SyntheticRelativeMemberImageFixture(
            kind: .property,
            malformation: .excessiveCount
        )
        let result = fixture.propertyRelative.resolveMemberLists(
            in: fixture.machO,
            imageLoadResolver: { $0 == 199 ? .unloaded : .loaded },
            imageResolver: { _ in fixture.machO }
        )

        XCTAssertEqual(result.entriesForTesting.count, 3)
        guard case .failure(let failure) = result.entriesForTesting[1] else {
            return XCTFail("Expected the malformed loaded property list to stay in order")
        }
        XCTAssertEqual(
            failure.reason,
            .excessiveElementCount(
                actual: ObjCProtocolReadLimits.maximumListEntries + 1,
                maximum: ObjCProtocolReadLimits.maximumListEntries
            )
        )
        XCTAssertEqual(propertyNames(in: result), ["p1", "p2", "p3"])
    }

    func testAllUnloadedIsSuccessfulEmptyAndUnavailableStateKeepsLaterEntries() {
        let fixture = SyntheticRelativeMemberImageFixture(kind: .method)
        var imageResolutionCount = 0
        let empty = fixture.methodRelative.resolveMemberLists(
            in: fixture.machO,
            imageLoadResolver: { _ in .unloaded },
            imageResolver: { _ in
                imageResolutionCount += 1
                return fixture.machO
            }
        )
        guard case .entries(let entries) = empty else {
            return XCTFail("All-unloaded is a valid empty resolution")
        }
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(imageResolutionCount, 0)

        let partial = fixture.methodRelative.resolveMemberLists(
            in: fixture.machO,
            imageLoadResolver: { $0 == 199 ? .unavailable : .loaded },
            imageResolver: { _ in fixture.machO }
        )
        guard case .failure(let firstFailure) = partial.entriesForTesting.first else {
            return XCTFail("Unknown load state must remain a typed entry failure")
        }
        XCTAssertEqual(firstFailure.reason, .relativeImageUnavailable(imageIndex: 199))
        XCTAssertEqual(methodNames(in: partial), ["m1", "m2", "m3"])
    }

    func testFileModeResolvesEveryMethodAndPropertyEntryWithoutOwnerIndex() throws {
        let fixture = try SyntheticRelativeMemberFileFixture()
        let locationResolver: (MachOFile, RelativeListListEntry) -> ObjCRelativeFileLocation? = {
            _, entry in fixture.location(for: entry)
        }

        let methods = fixture.methodRelative.resolveMemberLists(
            in: fixture.machO,
            locationResolver: locationResolver
        )
        let properties = fixture.propertyRelative.resolveMemberLists(
            in: fixture.machO,
            locationResolver: locationResolver
        )

        XCTAssertFalse(fixture.imageIndices.contains(54))
        XCTAssertEqual(
            fixture.methodRelative.entries(in: fixture.machO).map(\.imageIndex),
            fixture.imageIndices
        )
        XCTAssertEqual(
            fixture.propertyRelative.entries(in: fixture.machO).map(\.imageIndex),
            fixture.imageIndices
        )
        XCTAssertEqual(resolvedCount(methods.entriesForTesting), 4)
        XCTAssertEqual(resolvedCount(properties.entriesForTesting), 4)
    }

    func testWholeTableFailureDoesNotInvokeResolvers() {
        let fixture = SyntheticRelativeMemberImageFixture(kind: .method)
        let invalid = ObjCMethodRelativeListList(
            offset: fixture.methodRelative.offset,
            header: .init(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<RelativeListListEntry.Layout>.size - 1),
                    count: 1
                )
            )
        )
        var loadResolutionCount = 0
        var imageResolutionCount = 0
        let result = invalid.resolveMemberLists(
            in: fixture.machO,
            imageLoadResolver: { _ in
                loadResolutionCount += 1
                return .loaded
            },
            imageResolver: { _ in
                imageResolutionCount += 1
                return fixture.machO
            }
        )

        guard case .failure(let failure) = result else {
            return XCTFail("Invalid outer stride must fail the whole table")
        }
        XCTAssertEqual(
            failure.reason,
            .invalidRelativeEntrySize(
                advertised: UInt32(MemoryLayout<RelativeListListEntry.Layout>.size - 1),
                minimum: MemoryLayout<RelativeListListEntry.Layout>.size
            )
        )
        XCTAssertEqual(loadResolutionCount, 0)
        XCTAssertEqual(imageResolutionCount, 0)
    }

    func testInnerMemberTableRangeIsValidatedBeforeLegacyDecode() throws {
        let fixture = try SyntheticRelativeMemberFileFixture()
        let result = fixture.methodRelative.resolveMemberLists(
            in: fixture.machO,
            locationResolver: { machO, _ in
                .direct(
                    in: machO,
                    fileOffset: UInt64(fixture.truncatedMethodListOffset)
                )
            }
        )
        guard case .failure(let failure) = result.entriesForTesting.first else {
            return XCTFail("Expected unreadable inner method table")
        }
        guard case let .unreadableFileRange(_, byteCount) = failure.reason else {
            return XCTFail("Unexpected inner range failure: \(failure.reason)")
        }
        XCTAssertEqual(byteCount, MemoryLayout<ObjCMethod.Pointer>.size)
    }

    func testReadableButMisalignedLoadedListBecomesTypedFailure() {
        let fixture = SyntheticRelativeMemberImageFixture(
            kind: .method,
            malformation: .misalignedAddress
        )
        let result = fixture.methodRelative.resolveMemberLists(
            in: fixture.machO,
            imageLoadResolver: { $0 == 199 ? .unloaded : .loaded },
            imageResolver: { _ in fixture.machO }
        )
        guard case .failure(let failure) = result.entriesForTesting[1] else {
            return XCTFail("Expected a typed misalignment failure between valid siblings")
        }
        guard case let .misalignedListAddress(_, alignment) = failure.reason else {
            return XCTFail("Unexpected alignment failure: \(failure.reason)")
        }
        XCTAssertEqual(alignment, MemoryLayout<ObjCMethod.Pointer>.alignment)
        XCTAssertEqual(methodNames(in: result), ["m1", "m2", "m3"])
    }

    func testMemberDiagnosticsKeepAllFourKindsSeparate() {
        let failure = ObjCRelativeListFailure.entry(
            outerListOffset: 100,
            index: 2,
            entry: SyntheticRelativeMemberImageFixture.syntheticEntry(
                imageIndex: 1194,
                offset: 132
            ),
            reason: .invalidRelativeListLocation
        )
        var context = ObjCProtocolTraversalContext(subject: .class(name: "Owner"))
        let kinds: [ObjCMemberListDiagnostic.Kind] = [
            .instanceMethod,
            .classMethod,
            .instanceProperty,
            .classProperty,
        ]
        for kind in kinds {
            context.record(memberListFailure: failure, className: "Owner", kind: kind)
        }

        XCTAssertEqual(context.memberListDiagnostics.map(\.kind), kinds)
        XCTAssertEqual(context.memberListDiagnostics.map(\.className), Array(repeating: "Owner", count: 4))
        let expectedLocations: [ObjCMemberListDiagnostic.Location] = Array(
            repeating: .entry(index: 2, imageIndex: 1194, offset: 132),
            count: 4
        )
        XCTAssertEqual(context.memberListDiagnostics.map(\.location), expectedLocations)
    }

    private func methodNames(
        in result: ObjCMemberListResolution<MachOImage, ObjCMethodList>
    ) -> [String] {
        result.entriesForTesting.flatMap { entry -> [String] in
            guard case let .resolved(source, list) = entry else { return [] }
            return list.methods(in: source).map(\.name)
        }
    }

    private func propertyNames(
        in result: ObjCMemberListResolution<MachOImage, ObjCPropertyList>
    ) -> [String] {
        result.entriesForTesting.flatMap { entry -> [String] in
            guard case let .resolved(source, list) = entry else { return [] }
            return list.properties(in: source).map(\.name)
        }
    }

    private func resolvedCount<Source, List>(
        _ entries: [ObjCMemberListResolutionEntry<Source, List>]
    ) -> Int {
        entries.reduce(into: 0) { count, entry in
            if case .resolved = entry {
                count += 1
            }
        }
    }
}

private extension ObjCRelativeListResolution where Failure == ObjCRelativeListFailure {
    var entriesForTesting: [ObjCRelativeListResolutionEntry<Source, List, Failure>] {
        guard case .entries(let entries) = self else { return [] }
        return entries
    }
}

private final class SyntheticRelativeMemberImageFixture {
    enum Kind {
        case method
        case property
    }

    enum Malformation {
        case invalidEntrySize
        case excessiveCount
        case misalignedAddress
    }

    let machO: MachOImage
    let methodRelative: ObjCMethodRelativeListList
    let propertyRelative: ObjCPropertyRelativeListList
    private let storage: UnsafeMutableRawPointer

    init(
        kind: Kind,
        malformation: Malformation = .invalidEntrySize
    ) {
        let byteCount = 0x10_000
        let relativeOffset = 0x400
        var listOffsets = [0x2000, 0x2400, 0x2800, 0x2c00]
        if case .misalignedAddress = malformation {
            listOffsets[2] += 1
        }
        let outerStride = MemoryLayout<RelativeListListEntry.Layout>.size + 8
        let imageIndices = [199, 1194, 1194, 0]
        storage = .allocate(byteCount: byteCount, alignment: 16)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        let storageAddress = UInt64(UInt(bitPattern: storage))
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
        segment.vmaddr = storageAddress
        segment.vmsize = UInt64(byteCount)
        segment.fileoff = 0
        segment.filesize = UInt64(byteCount)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        storage.advanced(by: MemoryLayout<mach_header_64>.size).storeUnaligned(segment)

        let relativePointer = storage.advanced(by: relativeOffset)
        let outerHeader = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(outerStride),
                count: UInt32(imageIndices.count)
            )
        )
        relativePointer.storeUnaligned(outerHeader)
        let tableOffset = relativeOffset + MemoryLayout<EntrySizeListHeader>.size
        for index in imageIndices.indices {
            let entryOffset = tableOffset + index * outerStride
            var entry = Self.syntheticEntry(imageIndex: imageIndices[index], offset: entryOffset)
            if index == 0 {
                entry.layout.listOffset = Int64(0x80_0000 - entryOffset)
            } else {
                entry.layout.listOffset = Int64(listOffsets[index] - entryOffset)
            }
            relativePointer
                .advanced(by: MemoryLayout<EntrySizeListHeader>.size + index * outerStride)
                .storeUnaligned(entry.layout)
        }

        machO = MachOImage(ptr: storage.assumingMemoryBound(to: mach_header.self))
        methodRelative = .init(ptr: relativePointer, offset: relativeOffset)
        propertyRelative = .init(ptr: relativePointer, offset: relativeOffset)

        switch kind {
        case .method:
            writeMethodList(names: ["m1", "m2"], at: listOffsets[1], stringBase: 0x6000)
            writeMalformedList(
                kind: malformation,
                at: listOffsets[2],
                expectedEntrySize: MemoryLayout<ObjCMethod.Pointer>.size
            )
            writeMethodList(names: ["m3"], at: listOffsets[3], stringBase: 0x6800)
        case .property:
            writePropertyList(names: ["p1", "p2"], at: listOffsets[1], stringBase: 0x7000)
            writeMalformedList(
                kind: malformation,
                at: listOffsets[2],
                expectedEntrySize: MemoryLayout<ObjCProperty.Property>.size
            )
            writePropertyList(names: ["p3"], at: listOffsets[3], stringBase: 0x7800)
        }
    }

    static func syntheticEntry(
        imageIndex: Int,
        offset: Int
    ) -> RelativeListListEntry {
        var layout = RelativeListListEntry.Layout()
        layout.imageIndex = numericCast(imageIndex)
        return .init(offset: offset, layout: layout)
    }

    private func writeMethodList(
        names: [String],
        at offset: Int,
        stringBase: Int
    ) {
        storage.advanced(by: offset).storeUnaligned(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCMethod.Pointer>.size),
                    count: UInt32(names.count)
                )
            )
        )
        for (index, name) in names.enumerated() {
            let nameOffset = stringBase + index * 0x80
            let typeOffset = nameOffset + 0x40
            storage.advanced(by: nameOffset).storeBytes(Array(name.utf8) + [0])
            storage.advanced(by: typeOffset).storeBytes(Array("v@:".utf8) + [0])
            let method = ObjCMethod.Pointer(
                name: UnsafePointer(storage.advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)),
                types: UnsafePointer(storage.advanced(by: typeOffset).assumingMemoryBound(to: CChar.self)),
                imp: OpaquePointer(storage.advanced(by: 0x100))
            )
            storage.advanced(
                by: offset
                    + MemoryLayout<EntrySizeListHeader>.size
                    + index * MemoryLayout<ObjCMethod.Pointer>.size
            ).storeUnaligned(method)
        }
    }

    private func writePropertyList(
        names: [String],
        at offset: Int,
        stringBase: Int
    ) {
        storage.advanced(by: offset).storeUnaligned(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCProperty.Property>.size),
                    count: UInt32(names.count)
                )
            )
        )
        for (index, name) in names.enumerated() {
            let nameOffset = stringBase + index * 0x80
            let attributesOffset = nameOffset + 0x40
            storage.advanced(by: nameOffset).storeBytes(Array(name.utf8) + [0])
            storage.advanced(by: attributesOffset).storeBytes(Array("T@".utf8) + [0])
            let property = ObjCProperty.Property(
                name: UnsafePointer(storage.advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)),
                attributes: UnsafePointer(
                    storage.advanced(by: attributesOffset).assumingMemoryBound(to: CChar.self)
                )
            )
            storage.advanced(
                by: offset
                    + MemoryLayout<EntrySizeListHeader>.size
                    + index * MemoryLayout<ObjCProperty.Property>.size
            ).storeUnaligned(property)
        }
    }

    private func writeMalformedList(
        kind: Malformation,
        at offset: Int,
        expectedEntrySize: Int
    ) {
        let advertisedEntrySize: Int
        let count: UInt32
        switch kind {
        case .invalidEntrySize:
            advertisedEntrySize = expectedEntrySize - 4
            count = 1
        case .excessiveCount:
            advertisedEntrySize = expectedEntrySize
            count = UInt32(ObjCProtocolReadLimits.maximumListEntries + 1)
        case .misalignedAddress:
            advertisedEntrySize = expectedEntrySize
            count = 1
        }
        storage.advanced(by: offset).storeUnaligned(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(advertisedEntrySize),
                    count: count
                )
            )
        )
    }

    deinit {
        storage.deallocate()
    }
}

private final class SyntheticRelativeMemberFileFixture {
    let machO: MachOFile
    let methodRelative: ObjCMethodRelativeListList
    let propertyRelative: ObjCPropertyRelativeListList
    let imageIndices = [199, 1194, 1194, 0]
    let truncatedMethodListOffset = 0x4ff8
    private let url: URL

    init() throws {
        let fileSize = 0x5000
        let vmAddress: UInt64 = 0x2000_0000
        let methodRelativeOffset = 0x400
        let propertyRelativeOffset = 0x800
        let methodListBase = 0x2000
        let propertyListBase = 0x3000
        let listStride = 0x100
        let outerStride = MemoryLayout<RelativeListListEntry.Layout>.size + 8
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

        let outerHeader = EntrySizeListHeader(
            layout: .init(
                entsizeAndFlags: UInt32(outerStride),
                count: UInt32(imageIndices.count)
            )
        )
        data.store(outerHeader, at: methodRelativeOffset)
        data.store(outerHeader, at: propertyRelativeOffset)
        for index in imageIndices.indices {
            Self.storeEntry(
                in: &data,
                outerOffset: methodRelativeOffset,
                outerStride: outerStride,
                index: index,
                imageIndex: imageIndices[index],
                listOffset: methodListBase + index * listStride
            )
            Self.storeEntry(
                in: &data,
                outerOffset: propertyRelativeOffset,
                outerStride: outerStride,
                index: index,
                imageIndex: imageIndices[index],
                listOffset: propertyListBase + index * listStride
            )
            data.store(
                EntrySizeListHeader(
                    layout: .init(
                        entsizeAndFlags: UInt32(MemoryLayout<ObjCMethod.Pointer64>.size),
                        count: 0
                    )
                ),
                at: methodListBase + index * listStride
            )
            data.store(
                EntrySizeListHeader(
                    layout: .init(
                        entsizeAndFlags: UInt32(MemoryLayout<ObjCProperty.Property64>.size),
                        count: 0
                    )
                ),
                at: propertyListBase + index * listStride
            )
        }
        data.store(
            EntrySizeListHeader(
                layout: .init(
                    entsizeAndFlags: UInt32(MemoryLayout<ObjCMethod.Pointer64>.size),
                    count: 1
                )
            ),
            at: truncatedMethodListOffset
        )

        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachOObjCSection-relative-members-\(UUID().uuidString)")
        try data.write(to: url)
        machO = try MachOFile(url: url)
        methodRelative = .init(offset: methodRelativeOffset, header: outerHeader)
        propertyRelative = .init(offset: propertyRelativeOffset, header: outerHeader)
    }

    func location(for entry: RelativeListListEntry) -> ObjCRelativeFileLocation? {
        guard let listOffset = addingSignedDisplacement(entry.signedListOffset, to: entry.offset),
              let fileOffset = UInt64(exactly: listOffset) else {
            return nil
        }
        return .direct(in: machO, fileOffset: fileOffset)
    }

    private static func storeEntry(
        in data: inout Data,
        outerOffset: Int,
        outerStride: Int,
        index: Int,
        imageIndex: Int,
        listOffset: Int
    ) {
        let entryOffset = outerOffset + MemoryLayout<EntrySizeListHeader>.size + index * outerStride
        var entry = RelativeListListEntry.Layout()
        entry.imageIndex = numericCast(imageIndex)
        entry.listOffset = Int64(listOffset - entryOffset)
        data.store(entry, at: entryOffset)
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

    func storeBytes(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buffer in
            copyMemory(from: buffer.baseAddress!, byteCount: buffer.count)
        }
    }
}
