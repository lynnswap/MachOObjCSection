//
//  MachOFile+ObjectiveC.swift
//
//
//  Created by p-x9 on 2024/08/01
//
//

import Foundation
@_spi(Support) import MachOKit

extension MachOFile {
    public struct ObjectiveC: ObjCSectionRepresentable {
        private let machO: MachOFile

        init(machO: MachOFile) {
            self.machO = machO
        }
    }

    public var objc: ObjectiveC {
        .init(machO: self)
    }
}

extension MachOFile.ObjectiveC {
    public var imageInfo: ObjCImageInfo? {
        let __objc_imageinfo: any SectionProtocol
        if machO.is64Bit,
           let section = machO.findObjCSection64(for: .__objc_imageinfo) {
            __objc_imageinfo = section
        } else if let section = machO.findObjCSection32(for: .__objc_imageinfo) {
            __objc_imageinfo = section
        } else {
            return nil
        }

        guard let fileSlice = machO._fileSliceForSection(section: __objc_imageinfo) else {
            return nil
        }
        return try? fileSlice.read(offset: 0)
    }
}

extension MachOFile.ObjectiveC {
    public var methods: MachOFile.ObjCMethodLists? {
        let loadCommands = machO.loadCommands

        let __objc_methlist: any SectionProtocol
        if let text = loadCommands.text64,
           let section = text.__objc_methlist(in: machO) {
            __objc_methlist = section
        } else if let text = loadCommands.text,
                  let section = text.__objc_methlist(in: machO) {
            __objc_methlist = section
        } else {
            return nil
        }

        let offset = if let cache = machO.cache {
            __objc_methlist.address - numericCast(cache.mainCacheHeader.sharedRegionStart)
        } else {
            __objc_methlist.offset
        }

        return .init(
            data: try! machO.fileHandle.readData(
                offset: numericCast(__objc_methlist.offset + machO.headerStartOffset),
                length: __objc_methlist.size
            ),
            offset: offset,
            align: __objc_methlist.align,
            is64Bit: machO.is64Bit
        )
    }
}

extension MachOFile.ObjectiveC {
    public var protocols64: [ObjCProtocol64]? {
        guard machO.is64Bit else { return nil }

        guard let __objc_protolist = machO.findObjCSection64(
            for: .__objc_protolist
        ) else { return nil }

        guard let protocols: [ObjCProtocol64] = _readProtocols(
            from: __objc_protolist,
            in: machO
        ) else { return nil }

        return protocols
    }

    public var protocols32: [ObjCProtocol32]? {
        guard !machO.is64Bit else { return nil }

        guard let __objc_protolist = machO.findObjCSection32(
            for: .__objc_protolist
        ) else { return nil }

        guard let protocols: [ObjCProtocol32] = _readProtocols(
            from: __objc_protolist,
            in: machO
        ) else { return nil }

        return protocols
    }
}

extension MachOFile.ObjectiveC {
    public var classes64: [ObjCClass64]? {
        guard machO.is64Bit else { return nil }

        guard let __objc_classlist = machO.findObjCSection64(
            for: .__objc_classlist
        ) else { return nil }

        guard let classes: [ObjCClass64] = _readClasses(
            from: __objc_classlist,
            in: machO
        ) else { return nil }

        return classes
    }

    public var classes32: [ObjCClass32]? {
        guard !machO.is64Bit else { return nil }

        guard let __objc_classlist = machO.findObjCSection32(
            for: .__objc_classlist
        ) else { return nil }

        guard let classes: [ObjCClass32] = _readClasses(
            from: __objc_classlist,
            in: machO
        ) else { return nil }

        return classes
    }

    public var nonLazyClasses64: [ObjCClass64]? {
        guard machO.is64Bit else { return nil }

        guard let __objc_nlclslist = machO.findObjCSection64(
            for: .__objc_nlclslist
        ) else { return nil }

        guard let classes: [ObjCClass64] = _readClasses(
            from: __objc_nlclslist,
            in: machO
        ) else { return nil }

        return classes
    }

    public var nonLazyClasses32: [ObjCClass32]? {
        guard !machO.is64Bit else { return nil }

        guard let __objc_nlclslist = machO.findObjCSection32(
            for: .__objc_nlclslist
        ) else { return nil }

        guard let classes: [ObjCClass32] = _readClasses(
            from: __objc_nlclslist,
            in: machO
        ) else { return nil }

        return classes
    }
}

extension MachOFile.ObjectiveC {
    public var categories64: [ObjCCategory64]? {
        guard machO.is64Bit else { return nil }

        guard let __objc_catlist = machO.findObjCSection64(
            for: .__objc_catlist
        ) else { return nil }

        guard let categories: [ObjCCategory64] = _readCategories(
            from: __objc_catlist,
            in: machO
        ) else { return nil }

        return categories
    }

    public var categories32: [ObjCCategory32]? {
        guard !machO.is64Bit else { return nil }

        guard let __objc_catlist = machO.findObjCSection32(
            for: .__objc_catlist
        ) else { return nil }

        guard let categories: [ObjCCategory32] = _readCategories(
            from: __objc_catlist,
            in: machO
        ) else { return nil }

        return categories
    }

    public var nonLazyCategories64: [ObjCCategory64]? {
        guard machO.is64Bit else { return nil }

        guard let __objc_nlcatlist = machO.findObjCSection64(
            for: .__objc_nlcatlist
        ) else { return nil }

        guard let categories: [ObjCCategory64] = _readCategories(
            from: __objc_nlcatlist,
            in: machO
        ) else { return nil }

        return categories
    }

    public var nonLazyCategories32: [ObjCCategory32]? {
        guard !machO.is64Bit else { return nil }

        guard let __objc_nlcatlist = machO.findObjCSection32(
            for: .__objc_nlcatlist
        ) else { return nil }

        guard let categories: [ObjCCategory32] = _readCategories(
            from: __objc_nlcatlist,
            in: machO
        ) else { return nil }

        return categories
    }
}

extension MachOFile.ObjectiveC {
    public var categories2_64: [ObjCCategory64]? {
        guard machO.is64Bit else { return nil }

        guard let __objc_catlist = machO.findObjCSection64(
            for: .__objc_catlist2
        ) else { return nil }

        guard let categories: [ObjCCategory64] = _readCategories(
            from: __objc_catlist,
            in: machO,
            isCatlist2: true
        ) else { return nil }

        return categories
    }

    public var categories2_32: [ObjCCategory32]? {
        guard !machO.is64Bit else { return nil }

        guard let __objc_catlist = machO.findObjCSection32(
            for: .__objc_catlist2
        ) else { return nil }

        guard let categories: [ObjCCategory32] = _readCategories(
            from: __objc_catlist,
            in: machO,
            isCatlist2: true
        ) else { return nil }

        return categories
    }
}

extension MachOFile.ObjectiveC {
    private func _readPointerSection<
        Pointer: FixedWidthInteger,
        Element
    >(
        from section: any SectionProtocol,
        in machO: MachOFile,
        pointerType _: Pointer.Type,
        transform: (ResolvedValue) -> Element?
    ) -> [Element]? {
        guard let fileSlice = machO._fileSliceForSection(section: section) else {
            return nil
        }
        let data = try! fileSlice.readData(
            offset: 0,
            length: section.size
        )

        let baseOffset: UInt64 = if let cache = machO.cache {
            numericCast(section.address) - cache.mainCacheHeader.sharedRegionStart
        } else {
            numericCast(section.offset)
        }

        let pointerSize = MemoryLayout<Pointer>.size
        let sequence: DataSequence<Pointer> = .init(
            data: data,
            numberOfElements: section.size / pointerSize
        )

        return sequence.enumerated().compactMap { index, value in
            let unresolved = UnresolvedValue(
                fieldOffset: numericCast(baseOffset) + pointerSize * index,
                value: numericCast(value)
            )

            guard case let .resolved(resolved) = machO.resolveObjCPointerListTarget(
                unresolved
            ) else {
                return nil
            }

            return transform(resolved)
        }
    }

    func _readCategories<
        Categgory: ObjCCategoryProtocol
    >(
        from section: any SectionProtocol,
        in machO: MachOFile,
        isCatlist2: Bool = false
    ) -> [Categgory]? {
        _readPointerSection(
            from: section,
            in: machO,
            pointerType: Categgory.Layout.Pointer.self
        ) { resolved in
            guard let result = machO.readObjCLayout(
                at: resolved,
                as: Categgory.Layout.self
            ) else {
                return nil
            }

            return .init(
                layout: result.1,
                offset: numericCast(resolved.offset),
                isCatlist2: isCatlist2
            )
        }
    }

    func _readClasses<
        Class: ObjCClassProtocol
    >(
        from section: any SectionProtocol,
        in machO: MachOFile
    ) -> [Class]? {
        _readPointerSection(
            from: section,
            in: machO,
            pointerType: Class.Layout.Pointer.self
        ) { resolved in
            guard let result = machO.readObjCLayout(
                at: resolved,
                as: Class.Layout.self
            ) else {
                return nil
            }

            return .init(
                layout: result.1,
                offset: numericCast(resolved.offset)
            )
        }
    }

    func _readProtocols<
        Protocol: ObjCProtocolProtocol
    >(
        from section: any SectionProtocol,
        in machO: MachOFile
    ) -> [Protocol]? {
        _readPointerSection(
            from: section,
            in: machO,
            pointerType: Protocol.Layout.Pointer.self
        ) { resolved in
            guard let result = machO.readObjCLayout(
                at: resolved,
                as: Protocol.Layout.self
            ) else {
                return nil
            }

            return .init(
                layout: result.1,
                offset: numericCast(resolved.offset)
            )
        }
    }
}

extension MachOFile {
    fileprivate func _fileSliceForSection(
        section: any SectionProtocol
    ) -> File.FileSlice? {
        let text: (any SegmentCommandProtocol)? = loadCommands.text64 ?? loadCommands.text
        guard let text else { return nil }

        let maxFileOffsetToCheck = text.fileOffset + section.address - text.virtualMemoryAddress
        let isWithinFileRange: Bool = fileHandle.size >= maxFileOffsetToCheck

        // 1) text.vmaddr < linkedit.vmaddr
        // 2) fileoff_diff <= vmaddr_diff
        // 3) If both exist in the same file
        //    text.fileoff < linkedit.fileoff <= text.fileoff + vmaddr_diff
        // 4) if fileHandle.size < text.fileoff + vmaddr_diff
        //    both exist in the same file

        // The linkedit data in iOS is stored together in a separate, independent cache.
        // (.0x.linkeditdata)
        if isLoadedFromDyldCache && !isWithinFileRange {
            guard let fullCache = self.fullCache,
                  let fileOffset = fullCache.fileOffset(
                    of: numericCast(section.address)
                  ),
                  let segment = fullCache.fileSegment(
                    forOffset: fileOffset
                  ) else {
                return nil
            }
            return try? segment._file.fileSlice(
                offset: numericCast(fileOffset) - segment.offset,
                length: section.size
            )
        } else {
            return try? fileHandle.fileSlice(
                offset: headerStartOffset + section.offset,
                length: section.size
            )
        }
    }
}
