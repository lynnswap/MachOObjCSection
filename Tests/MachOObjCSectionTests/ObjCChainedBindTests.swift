import Foundation
import XCTest
import MachOKit
@_spi(Core) @_spi(Diagnostics) @testable import MachOObjCSection

final class ObjCChainedBindTests: XCTestCase {
    func testSelfBindReadsClassAndMetaclassAtTheirFileOffsets() throws {
        for prefix in [0, 257] {
            let fixture = try ChainedClassFixture(headerPrefix: prefix)
            let roots = fixture.machO.objc.readRoots()
            XCTAssertTrue(roots.tableDiagnostics.isEmpty)
            let cls = try XCTUnwrap(roots.classes64?.first)
            XCTAssertEqual(cls.offset, 0x900)
            XCTAssertEqual(cls.classROData(in: fixture.machO)?.name(in: fixture.machO), "BoundClass")
            let (_, meta): (MachOFile, ObjCClass64) = try XCTUnwrap(cls.metaClass(in: fixture.machO))
            XCTAssertEqual(meta.offset, 0x980)
            XCTAssertEqual(meta.classROData(in: fixture.machO)?.name(in: fixture.machO), "BoundClass")
        }
    }

    func testCategoryCanReadItsSelfBoundClass() throws {
        let fixture = try ChainedClassFixture(options: .init(category: true))
        let roots = fixture.machO.objc.readRoots()
        XCTAssertTrue(roots.tableDiagnostics.isEmpty)
        let category = try XCTUnwrap(roots.categories64?.first)
        let (_, cls): (MachOFile, ObjCClass64) = try XCTUnwrap(category.class(in: fixture.machO))
        XCTAssertEqual(cls.offset, 0x980)
    }

    func testUnresolvedBindsProduceRootDiagnosticsInsteadOfClasses() throws {
        for options in [
            ChainedClassFixture.Options(libraryOrdinal: 1),
            .init(libraryOrdinal: -2),
            .init(definedSymbol: false),
            .init(importOrdinal: 7),
        ] {
            let fixture = try ChainedClassFixture(options: options)
            let roots = fixture.machO.objc.readRoots()
            XCTAssertEqual(roots.classes64?.count, 0)
            XCTAssertEqual(roots.tableDiagnostics.count, 1)
            guard case .unresolvedFileRootPointer = roots.tableDiagnostics.first?.failure else {
                XCTFail("Expected an unresolved root pointer diagnostic")
                continue
            }
            XCTAssertEqual(fixture.machO.objc.classes64?.count, 0)
        }
    }

    func testBindAddendsAreAppliedBeforeMappingToFileOffsets() throws {
        let fixture = try ChainedClassFixture(
            options: .init(symbolDisplacement: 16, importAddend: -24, pointerAddend: 8)
        )
        let roots = fixture.machO.objc.readRoots()
        XCTAssertTrue(roots.tableDiagnostics.isEmpty)
        XCTAssertEqual(roots.classes64?.first?.offset, 0x900)
    }

    func testMissingSymbolTableDefinitionLeavesADiagnostic() throws {
        let fixture = try ChainedClassFixture(options: .init(exportOnly: true))
        let roots = fixture.machO.objc.readRoots()
        XCTAssertEqual(roots.classes64?.count, 0)
        XCTAssertEqual(roots.tableDiagnostics.count, 1)
    }

    func testMalformedExportDataDoesNotPreventSymbolTableResolution() throws {
        let fixture = try ChainedClassFixture(options: .init(exportOffset: 0xfffffff0))
        XCTAssertEqual(fixture.machO.objc.readRoots().classes64?.first?.offset, 0x900)
    }

    func testMalformedSymbolAndStringTablesLeaveDiagnostics() throws {
        for options in [
            ChainedClassFixture.Options(symbolOffset: 0xfffffff0),
            .init(stringOffset: 0xfffffff0),
            .init(stringSize: 1),
            .init(stringSize: .max),
        ] {
            let fixture = try ChainedClassFixture(options: options)
            let roots = fixture.machO.objc.readRoots()
            XCTAssertEqual(roots.classes64?.count, 0)
            XCTAssertEqual(roots.tableDiagnostics.count, 1)
        }
    }

    func testLowAbsoluteSymbolAddressIsNotAHeaderRelativeOffset() throws {
        let fixture = try ChainedClassFixture(options: .init(symbolDisplacement: -0x1_0000_1000))
        let roots = fixture.machO.objc.readRoots()
        XCTAssertEqual(roots.classes64?.count, 0)
        XCTAssertEqual(roots.tableDiagnostics.count, 1)
        guard case .unresolvedFileRootPointer = roots.tableDiagnostics.first?.failure else {
            return XCTFail("Expected an unresolved self-bind diagnostic")
        }
    }

    func testSelfBindDefinitionsBelongToTheirImage() throws {
        let first = try ChainedClassFixture()
        let second = try ChainedClassFixture(options: .init(symbolDisplacement: 0x80))
        for _ in 0..<2 {
            XCTAssertEqual(first.machO.objc.readRoots().classes64?.first?.offset, 0x900)
            XCTAssertEqual(second.machO.objc.readRoots().classes64?.first?.offset, 0x980)
        }
    }

    func testLocalDefinitionDoesNotShadowTheExportedSelfBind() throws {
        let fixture = try ChainedClassFixture(options: .init(localDuplicate: true))
        XCTAssertEqual(fixture.machO.objc.readRoots().classes64?.first?.offset, 0x900)
    }

    func testLocalOnlyDefinitionCannotResolveABind() throws {
        let fixture = try ChainedClassFixture(options: .init(symbolIsExternal: false))
        let roots = fixture.machO.objc.readRoots()
        XCTAssertEqual(roots.classes64?.count, 0)
        XCTAssertEqual(roots.tableDiagnostics.count, 1)
    }

    func testOutOfImageBindDoesNotWrapIntoTheHeader() throws {
        let fixture = try ChainedClassFixture(options: .init(symbolDisplacement: -0x1100, importAddend: -1))
        let roots = fixture.machO.objc.readRoots()
        XCTAssertEqual(roots.classes64?.count, 0)
        XCTAssertEqual(roots.tableDiagnostics.count, 1)
    }
}

private final class ChainedClassFixture {
    struct Options {
        var libraryOrdinal: Int8 = 0
        var definedSymbol = true
        var symbolIsExternal = true
        var localDuplicate = false
        var importOrdinal: UInt64 = 0
        var symbolDisplacement = 0
        var importAddend: Int32 = 0
        var pointerAddend: UInt64 = 0
        var exportOnly = false
        var category = false
        var exportOffset: UInt32 = 0x2200
        var symbolOffset: UInt32 = 0x2100
        var stringOffset: UInt32 = 0x2180
        var stringSize: UInt32 = 128
    }

    let machO: MachOFile
    private let url: URL

    init(headerPrefix: Int = 0, options: Options = .init()) throws {
        let base: UInt64 = 0x1_0000_0000
        var data = Data(count: headerPrefix + 0x2400)
        func store<T>(_ value: T, at offset: Int) {
            var value = value
            withUnsafeBytes(of: &value) {
                data.replaceSubrange((headerPrefix + offset)..<(headerPrefix + offset + $0.count), with: $0)
            }
        }
        func string(_ value: String, at offset: Int) {
            let bytes = Array(value.utf8) + [0]
            data.replaceSubrange((headerPrefix + offset)..<(headerPrefix + offset + bytes.count), with: bytes)
        }
        func setName<T>(_ name: String, in field: inout T) {
            withUnsafeMutableBytes(of: &field) { $0.copyBytes(from: Array(name.utf8) + Array(repeating: 0, count: 16 - name.utf8.count)) }
        }
        var header = mach_header_64()
        header.magic = UInt32(MH_MAGIC_64)
        header.cputype = CPU_TYPE_ARM64
        header.filetype = UInt32(MH_DYLIB)
        header.ncmds = 6
        header.sizeofcmds = UInt32(3 * MemoryLayout<segment_command_64>.size + MemoryLayout<section_64>.size + 2 * MemoryLayout<linkedit_data_command>.size + MemoryLayout<symtab_command>.size)
        store(header, at: 0)
        var commandOffset = MemoryLayout<mach_header_64>.size
        for (name, vmOffset, fileOffset, fileSize, sections) in [
            ("__TEXT", 0, 0, 0x800, 0),
            ("__DATA", 0x1000, 0x800, 0x1000, 1),
            ("__LINKEDIT", 0x3000, 0x2000, 0x400, 0),
        ] {
            var segment = segment_command_64()
            segment.cmd = UInt32(LC_SEGMENT_64)
            segment.cmdsize = UInt32(MemoryLayout<segment_command_64>.size + sections * MemoryLayout<section_64>.size)
            setName(name, in: &segment.segname)
            segment.vmaddr = base + UInt64(vmOffset)
            segment.vmsize = 0x1000
            segment.fileoff = UInt64(fileOffset)
            segment.filesize = UInt64(fileSize)
            segment.maxprot = VM_PROT_READ | VM_PROT_WRITE
            segment.initprot = segment.maxprot
            segment.nsects = UInt32(sections)
            store(segment, at: commandOffset)
            if sections > 0 {
                var section = section_64()
                setName(options.category ? "__objc_catlist" : "__objc_classlist", in: &section.sectname)
                setName(name, in: &section.segname)
                section.addr = base + 0x1000
                section.offset = 0x800
                section.size = 8
                section.align = 3
                store(section, at: commandOffset + MemoryLayout<segment_command_64>.size)
            }
            commandOffset += Int(segment.cmdsize)
        }
        var fixups = linkedit_data_command()
        fixups.cmd = UInt32(LC_DYLD_CHAINED_FIXUPS)
        fixups.cmdsize = UInt32(MemoryLayout<linkedit_data_command>.size)
        fixups.dataoff = 0x2000
        fixups.datasize = 0x100
        store(fixups, at: commandOffset)
        commandOffset += Int(fixups.cmdsize)

        let classSymbol = "_OBJC_CLASS_$_BoundClass"
        let metaSymbol = "_OBJC_METACLASS_$_BoundClass"
        var symtab = symtab_command()
        symtab.cmd = UInt32(LC_SYMTAB)
        symtab.cmdsize = UInt32(MemoryLayout<symtab_command>.size)
        symtab.symoff = options.symbolOffset
        symtab.nsyms = options.exportOnly ? 0 : (options.localDuplicate ? 3 : 2)
        symtab.stroff = options.stringOffset
        symtab.strsize = options.stringSize
        store(symtab, at: commandOffset)
        commandOffset += Int(symtab.cmdsize)
        for (index, name, offset) in [(0, classSymbol, 1), (1, metaSymbol, classSymbol.utf8.count + 2)] {
            var symbol = nlist_64()
            symbol.n_un.n_strx = UInt32(offset)
            symbol.n_type = UInt8(options.definedSymbol ? N_SECT : N_UNDF) | UInt8(options.symbolIsExternal ? N_EXT : 0)
            symbol.n_sect = options.definedSymbol ? 1 : 0
            symbol.n_value = index == 0 ? UInt64(Int64(base + 0x1100) + Int64(options.symbolDisplacement)) : base + 0x1180
            store(symbol, at: 0x2100 + (index + (options.localDuplicate ? 1 : 0)) * MemoryLayout<nlist_64>.size)
            string(name, at: 0x2180 + offset)
        }

        if options.localDuplicate {
            var local = nlist_64()
            local.n_un.n_strx = 1
            local.n_type = UInt8(N_SECT)
            local.n_sect = 1
            local.n_value = base + 0x1180
            store(local, at: 0x2100)
        }

        var exports = linkedit_data_command()
        exports.cmd = UInt32(LC_DYLD_EXPORTS_TRIE)
        exports.cmdsize = UInt32(MemoryLayout<linkedit_data_command>.size)
        exports.dataoff = options.exportOffset
        // One regular export at image-relative address 0x1100, without a symbol table.
        let childOffset = UInt8(2 + classSymbol.utf8.count + 2)
        let trie: [UInt8] = [0, 1] + Array(classSymbol.utf8) + [0, childOffset, 3, 0, 0x80, 0x22, 0]
        exports.datasize = options.exportOnly ? UInt32(trie.count) : 2
        store(exports, at: commandOffset)
        if options.exportOnly {
            data.replaceSubrange((headerPrefix + 0x2200)..<(headerPrefix + 0x2200 + trie.count), with: trie)
        }

        // DYLD_CHAINED_IMPORT_ADDEND with __DATA starts and two self imports.
        for (offset, value) in [(0, 0), (4, 0x20), (8, 0x50), (12, 0x60), (16, 2), (20, 2), (24, 0)] {
            store(UInt32(value), at: 0x2000 + offset)
        }
        for (offset, value) in [(0, 3), (4, 0), (8, 16), (12, 0)] {
            store(UInt32(value), at: 0x2020 + offset)
        }
        store(UInt32(24), at: 0x2030)
        store(UInt16(0x1000), at: 0x2034)
        store(UInt16(6), at: 0x2036) // DYLD_CHAINED_PTR_64_OFFSET
        store(UInt64(0x1000), at: 0x2038)
        store(UInt32(0), at: 0x2040)
        store(UInt16(1), at: 0x2044)
        store(UInt16(0), at: 0x2046)
        store(UInt32(UInt8(bitPattern: options.libraryOrdinal)), at: 0x2050)
        store(options.importAddend, at: 0x2054)
        store(UInt32(classSymbol.utf8.count + 1) << 9, at: 0x2058)
        store(Int32(0), at: 0x205c)
        string(classSymbol, at: 0x2060)
        string(metaSymbol, at: 0x2060 + classSymbol.utf8.count + 1)

        let nextOffset = options.category ? 0x108 : 0x100
        let rootPointer = UInt64(1) << 63 | UInt64(nextOffset / 4) << 51 | options.pointerAddend << 24 | options.importOrdinal
        store(rootPointer, at: 0x800)
        if options.category {
            store(base + 0x1300, at: 0x900)
            store(UInt64(1) << 63 | 1, at: 0x908)
        } else {
            store(UInt64(1) << 63 | 1, at: 0x900) // self-bound metaclass
        }
        store(base + 0x1200, at: 0x920)
        store(base + 0x1200, at: 0x9a0)
        store(base + 0x1300, at: 0xa18) // class_ro_t.name
        string("BoundClass", at: 0xb00)

        url = FileManager.default.temporaryDirectory.appendingPathComponent("ObjC-chained-bind-\(UUID().uuidString)")
        try data.write(to: url)
        machO = try MachOFile(url: url, headerStartOffset: headerPrefix)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
