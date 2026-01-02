//
//  DyldCacheLoaded.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2024/11/02
//
//

import Foundation
import MachOKit

#if !canImport(Darwin)
extension DyldCacheLoaded {
    // FIXME: fallback for linux
    public static var current: DyldCacheLoaded? {
        return nil
    }
}
#endif

#if canImport(Darwin)
import os

/// Cache for MachOImage lookups by index to avoid repeated memory accesses
/// Thread-safe with lock protection for atomic check-and-set operations
private final class MachOImageCache: @unchecked Sendable {
    static let shared = MachOImageCache()

    private let cache = NSCache<NSNumber, MachOImageWrapper>()
    private var _lock = os_unfair_lock()

    private init() {}

    /// Get cached MachOImage or compute and cache it atomically
    /// - Parameters:
    ///   - index: The image index
    ///   - compute: Closure to compute the MachOImage if not cached
    /// - Returns: The cached or newly computed MachOImage
    func machO(at index: Int, orCompute compute: () -> MachOImage?) -> MachOImage? {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        let key = NSNumber(value: index)
        if let cached = cache.object(forKey: key) {
            return cached.image
        }
        guard let result = compute() else {
            return nil
        }
        cache.setObject(MachOImageWrapper(result), forKey: key)
        return result
    }

    func invalidate() {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        cache.removeAllObjects()
    }
}

private final class MachOImageWrapper: NSObject {
    let image: MachOImage
    init(_ image: MachOImage) {
        self.image = image
    }
}
#endif


extension DyldCacheLoaded {
    var headerOptimizationRO64: ObjCHeaderOptimizationRO64? {
        guard cpu.is64Bit else {
            return nil
        }
        if let objcOptimization {
            return objcOptimization.headerOptimizationRO64(in: self)
        }
        if let oldObjcOptimization {
            return oldObjcOptimization.headerOptimizationRO64(in: self)
        }
        return nil
    }

    var headerOptimizationRO32: ObjCHeaderOptimizationRO32? {
        guard cpu.is64Bit else {
            return nil
        }
        if let objcOptimization {
            return objcOptimization.headerOptimizationRO32(in: self)
        }
        if let oldObjcOptimization {
            return oldObjcOptimization.headerOptimizationRO32(in: self)
        }
        return nil
    }

    var headerOptimizationRW64: ObjCHeaderOptimizationRW64? {
        guard cpu.is64Bit else {
            return nil
        }
        if let objcOptimization {
            return objcOptimization.headerOptimizationRW64(in: self)
        }
        if let oldObjcOptimization {
            return oldObjcOptimization.headerOptimizationRW64(in: self)
        }
        return nil
    }

    var headerOptimizationRW32: ObjCHeaderOptimizationRW32? {
        guard cpu.is64Bit else {
            return nil
        }
        if let objcOptimization {
            return objcOptimization.headerOptimizationRW32(in: self)
        }
        if let oldObjcOptimization {
            return oldObjcOptimization.headerOptimizationRW32(in: self)
        }
        return nil
    }
}

extension DyldCacheLoaded {
    func machO(at index: Int) -> MachOImage? {
        #if canImport(Darwin)
        return MachOImageCache.shared.machO(at: index) { [self] in
            computeMachO(at: index)
        }
        #else
        return computeMachO(at: index)
        #endif
    }

    private func computeMachO(at index: Int) -> MachOImage? {
        if let ro = headerOptimizationRO64,
           ro.contains(index: index) {
            guard let header = ro.headerInfo(at: index, in: self) else {
                return nil
            }
            return header.machO(in: self)
        }
        if let ro = headerOptimizationRO32,
           ro.contains(index: index) {
            guard let header = ro.headerInfo(at: index, in: self) else {
                return nil
            }
            return header.machO(in: self)
        }
        return nil
    }
}

extension DyldCacheLoaded {
    func machO(containing ptr: UnsafeRawPointer) -> MachOImage? {
        for machO in machOImages() {
            if machO.contains(ptr: ptr) {
                return machO
            }
        }
        return nil
    }

    func machO(containing unslidAddress: UInt64) -> MachOImage? {
        for machO in self.machOImages() {
            if machO.contains(unslidAddress: unslidAddress) {
                return machO
            }
        }
        return nil
    }
}
