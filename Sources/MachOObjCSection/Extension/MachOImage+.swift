//
//  MachOImage+.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2024/12/10
//  
//

import Foundation
import MachOKit

extension MachOImage {
    func findObjCSection64(for section: ObjCMachOSection) -> Section64? {
        findObjCSection64(for: section.rawValue)
    }

    func findObjCSection32(for section: ObjCMachOSection) -> Section? {
        findObjCSection32(for: section.rawValue)
    }

    // [dyld implementation](https://github.com/apple-oss-distributions/dyld/blob/66c652a1f1f6b7b5266b8bbfd51cb0965d67cc44/common/MachOFile.cpp#L3880)
    func findObjCSection64(for name: String) -> Section64? {
        findObjCSection64AndSegment(for: name)?.section
    }

    func findObjCSection64AndSegment(
        for section: ObjCMachOSection
    ) -> (section: Section64, segment: SegmentCommand64)? {
        findObjCSection64AndSegment(for: section.rawValue)
    }

    func findObjCSection64AndSegment(
        for name: String
    ) -> (section: Section64, segment: SegmentCommand64)? {
        let segmentNames = [
            "__DATA", "__DATA_CONST", "__DATA_DIRTY"
        ]
        let segments = segments64
        for segment in segments {
            guard segmentNames.contains(segment.segmentName) else {
                continue
            }
            if let section = segment._section(for: name, in: self) {
                return (section, segment)
            }
        }
        return nil
    }

    func findObjCSection32(for name: String) -> Section? {
        findObjCSection32AndSegment(for: name)?.section
    }

    func findObjCSection32AndSegment(
        for section: ObjCMachOSection
    ) -> (section: Section, segment: SegmentCommand)? {
        findObjCSection32AndSegment(for: section.rawValue)
    }

    func findObjCSection32AndSegment(
        for name: String
    ) -> (section: Section, segment: SegmentCommand)? {
        let segmentNames = [
            "__DATA", "__DATA_CONST", "__DATA_DIRTY"
        ]
        let segments = segments32
        for segment in segments {
            guard segmentNames.contains(segment.segmentName) else {
                continue
            }
            if let section = segment._section(for: name, in: self) {
                return (section, segment)
            }
        }
        return nil
    }

    /// Resolve the MachOImage that contains the specified pointer.
    ///
    /// `DyldCacheLoaded` only covers images in the dyld shared cache (system frameworks).
    /// App-bundled frameworks (e.g., iWork private frameworks injected into Numbers)
    /// are NOT in the shared cache, so lookups via `DyldCacheLoaded` alone will fail
    /// for classes whose superclass, metaclass, or protocol resides in another
    /// non-cached framework loaded in the same process.
    ///
    /// This method first tries the fast dyld-cache path, then falls back to
    /// `dyld_image_header_containing_address()` which searches ALL loaded images.
    func resolveImage(containing ptr: UnsafeRawPointer) -> MachOImage? {
        if let cache = DyldCacheLoaded.current,
           let machO = cache.machO(containing: ptr) {
            return machO
        }
        #if canImport(Darwin)
        return MachOImage.image(for: ptr)
        #else
        return nil
        #endif
    }
}

extension MachOImage {
    var objcImageIndex: Int? {
#if canImport(MachO)
        guard header.isInDyldCache else { return nil }
        guard let cache = DyldCacheLoaded.current else { return nil }
        if let headerOptimizationRO = cache.headerOptimizationRO64,
           let info = headerOptimizationRO.headerInfo(in: cache, for: self) {
            return info.index
        }
        if let headerOptimizationRO = cache.headerOptimizationRO32,
           let info = headerOptimizationRO.headerInfo(in: cache, for: self) {
            return info.index
        }
#endif
        return nil
    }
}
