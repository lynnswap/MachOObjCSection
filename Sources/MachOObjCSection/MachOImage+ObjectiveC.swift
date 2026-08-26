//
//  MachOImage+ObjectiveC.swift
//
//
//  Created by p-x9 on 2024/08/03
//  
//

import Foundation
@_spi(Support) import MachOKit

extension MachOImage {
    public struct ObjectiveC: ObjCSectionRepresentable {
        internal let machO: MachOImage

        init(machO: MachOImage) {
            self.machO = machO
        }
    }

    public var objc: ObjectiveC {
        .init(machO: self)
    }
}

#if canImport(MachO)
extension MachOImage.ObjectiveC {
    public var isLoaded: Bool {
        guard let cache: DyldCacheLoaded = .current else { return true } // FIXME: check
        guard let imageIndex = machO.objcImageIndex else { return false }
        guard case .loaded = cache.objcImageLoadState(at: imageIndex) else { return false }
        return true
    }
}
#endif

extension MachOImage.ObjectiveC {
    public var imageInfo: ObjCImageInfo? {
        guard let vmaddrSlide = machO.vmaddrSlide else { return nil }

        let __objc_imageinfo: any SectionProtocol

        if machO.is64Bit,
           let section = machO.findObjCSection64(for: .__objc_imageinfo) {
            __objc_imageinfo = section
        } else if let section = machO.findObjCSection32(for: .__objc_imageinfo) {
            __objc_imageinfo = section
        } else {
            return nil
        }

        guard let start = UnsafeRawPointer(
            bitPattern: __objc_imageinfo.address + vmaddrSlide
        ) else { return nil }

        return start
            .assumingMemoryBound(to: ObjCImageInfo.self)
            .pointee
    }
}

extension MachOImage.ObjectiveC {
    public var methods: MachOImage.ObjCMethodLists? {
        let loadCommands = machO.loadCommands

        if let _text = loadCommands.text64,
           let section = _text.__objc_methlist(in: machO) {
            return methodLists(section: section, text: _text)
        } else if let _text = loadCommands.text,
                  let section = _text.__objc_methlist(in: machO) {
            return methodLists(section: section, text: _text)
        }
        return nil
    }

    private func methodLists(
        section: Section64,
        text: SegmentCommand64
    ) -> MachOImage.ObjCMethodLists? {
        guard let coordinates = checkedObjCSectionCoordinates(section, in: text) else {
            return nil
        }
        return methodLists(section: coordinates)
    }

    private func methodLists(
        section: Section,
        text: SegmentCommand
    ) -> MachOImage.ObjCMethodLists? {
        guard let coordinates = checkedObjCSectionCoordinates(section, in: text) else {
            return nil
        }
        return methodLists(section: coordinates)
    }

    private func methodLists(
        section: CheckedObjCSectionCoordinates
    ) -> MachOImage.ObjCMethodLists? {
        guard let sectionOffset = Int(exactly: section.segmentVirtualMemoryOffset),
              let startAddress = section.loadedImageAddress(
                relativeTo: UInt(bitPattern: machO.ptr)
              ) else {
            return nil
        }
        guard let start = UnsafeRawPointer(bitPattern: startAddress) else { return nil }

        return .init(
            offset: sectionOffset,
            basePointer: start,
            tableSize: section.size,
            align: section.alignmentExponent,
            is64Bit: machO.is64Bit
        )
    }
}

extension MachOImage.ObjectiveC {
    public var protocols64: [ObjCProtocol64]? {
        readProtocols64()?.values
    }

    public var protocols32: [ObjCProtocol32]? {
        readProtocols32()?.values
    }
}

extension MachOImage.ObjectiveC {
    public var classes64: [ObjCClass64]? {
        readClasses64(section: .__objc_classlist, root: .classList)?.values
    }

    public var classes32: [ObjCClass32]? {
        readClasses32(section: .__objc_classlist, root: .classList)?.values
    }

    public var nonLazyClasses64: [ObjCClass64]? {
        readClasses64(section: .__objc_nlclslist, root: .nonLazyClassList)?.values
    }

    public var nonLazyClasses32: [ObjCClass32]? {
        readClasses32(section: .__objc_nlclslist, root: .nonLazyClassList)?.values
    }
}

// MARK: - Category
extension MachOImage.ObjectiveC {
    public var categories64: [ObjCCategory64]? {
        readCategories64(
            section: .__objc_catlist,
            root: .categoryList,
            isCatlist2: false
        )?.values
    }

    public var categories32: [ObjCCategory32]? {
        readCategories32(
            section: .__objc_catlist,
            root: .categoryList,
            isCatlist2: false
        )?.values
    }

    public var nonLazyCategories64: [ObjCCategory64]? {
        readCategories64(
            section: .__objc_nlcatlist,
            root: .nonLazyCategoryList,
            isCatlist2: false
        )?.values
    }

    public var nonLazyCategories32: [ObjCCategory32]? {
        readCategories32(
            section: .__objc_nlcatlist,
            root: .nonLazyCategoryList,
            isCatlist2: false
        )?.values
    }
}

extension MachOImage.ObjectiveC {
    public var categories2_64: [ObjCCategory64]? {
        readCategories64(
            section: .__objc_catlist2,
            root: .categoryList2,
            isCatlist2: true
        )?.values
    }

    public var categories2_32: [ObjCCategory32]? {
        readCategories32(
            section: .__objc_catlist2,
            root: .categoryList2,
            isCatlist2: true
        )?.values
    }
}
