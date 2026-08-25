//
//  ObjCProtocolRuntimeResolver.swift
//  MachOObjCSection
//

import Foundation
import MachOKit

#if canImport(ObjectiveC) && canImport(Darwin)
import ObjectiveC
#endif
#if canImport(Darwin)
import Darwin
#endif

internal struct ObjCProtocolDyldCacheLocation: Equatable {
    let identity: ObjCProtocolIdentity
    let remainingMappedByteCount: UInt

    init(
        cacheUUID: UUID,
        unslidAddress: UInt64,
        remainingMappedByteCount: UInt
    ) {
        self.identity = .cache(
            uuid: cacheUUID,
            unslidAddress: unslidAddress
        )
        self.remainingMappedByteCount = remainingMappedByteCount
    }
}

internal struct ObjCProtocolRuntimeResolver {
    let protocolAddress: (String) -> UnsafeRawPointer?
    let activeDyldCacheLocation: (UnsafeRawPointer) -> ObjCProtocolDyldCacheLocation?
    let usesSharedCacheProtocolOptimizations: Bool

    init(
        protocolAddress: @escaping (String) -> UnsafeRawPointer?,
        activeDyldCacheLocation: @escaping (UnsafeRawPointer) -> ObjCProtocolDyldCacheLocation? = { _ in nil },
        usesSharedCacheProtocolOptimizations: Bool = false
    ) {
        self.protocolAddress = protocolAddress
        self.activeDyldCacheLocation = activeDyldCacheLocation
        self.usesSharedCacheProtocolOptimizations = usesSharedCacheProtocolOptimizations
    }

    private static let runtimeUsesSharedCacheProtocolOptimizations: Bool = {
#if canImport(ObjectiveC) && canImport(Darwin)
        guard let cache = DyldCacheLoaded.current else { return false }
        return objcRuntimeUsesSharedCacheProtocolOptimizations(in: cache)
#else
        return false
#endif
    }()

    static var runtime: Self? {
#if canImport(ObjectiveC) && canImport(Darwin)
        return Self(
            protocolAddress: { name in
                guard let objcProtocol = objc_getProtocol(name) else { return nil }
                return UnsafeRawPointer(
                    Unmanaged.passUnretained(objcProtocol).toOpaque()
                )
            },
            activeDyldCacheLocation: { pointer in
                DyldCacheLoaded.current?.objcProtocolLocation(containing: pointer)
            },
            usesSharedCacheProtocolOptimizations: runtimeUsesSharedCacheProtocolOptimizations
        )
#else
        return nil
#endif
    }
}

#if canImport(ObjectiveC) && canImport(Darwin)
private func objcRuntimeUsesSharedCacheProtocolOptimizations(
    in cache: DyldCacheLoaded
) -> Bool {
    guard !objcEnvironmentOptionEnabled("OBJC_DISABLE_PREOPTIMIZATION") else {
        return false
    }
    let hasHeaderOptimization = cache.cpu.is64Bit
        ? cache.headerOptimizationRO64 != nil
        : cache.headerOptimizationRO32 != nil
    guard hasHeaderOptimization,
          let handle = dlopen(nil, RTLD_LAZY) else {
        return false
    }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "objc_getProtocol") else {
        return false
    }
    return cache.objcProtocolLocation(containing: UnsafeRawPointer(symbol)) != nil
}

private func objcEnvironmentOptionEnabled(_ name: String) -> Bool {
    guard issetugid() == 0,
          let value = getenv(name) else {
        return false
    }
    switch String(cString: value).lowercased() {
    case "fatal", "halt", "fault", "stochastic-fault", "stochasticfault",
         "yes", "warn", "true", "on", "y", "1":
        return true
    default:
        return false
    }
}
#endif

private extension DyldCacheLoaded {
    func objcProtocolLocation(
        containing pointer: UnsafeRawPointer
    ) -> ObjCProtocolDyldCacheLocation? {
        if let location = locationInOwnMapping(containing: pointer) {
            return location
        }

        guard let subCaches else { return nil }
        for entry in subCaches {
            guard let cacheVMOffset = UInt(exactly: entry.cacheVMOffset) else {
                continue
            }
            let (subcacheAddress, overflow) = UInt(bitPattern: ptr)
                .addingReportingOverflow(cacheVMOffset)
            guard !overflow,
                  let subcachePointer = UnsafeRawPointer(bitPattern: subcacheAddress),
                  isPointerSafelyReadable(
                    subcachePointer,
                    length: MemoryLayout<DyldCacheHeader.Layout>.size
                  ),
                  let subcache = try? DyldCacheLoaded(
                    subcachePtr: subcachePointer,
                    mainCacheHeader: mainCacheHeader
                  ) else {
                continue
            }
            if let location = subcache.locationInOwnMapping(containing: pointer) {
                return location
            }
        }
        return nil
    }

    func locationInOwnMapping(
        containing pointer: UnsafeRawPointer
    ) -> ObjCProtocolDyldCacheLocation? {
        guard let slide,
              let mappingInfos else {
            return nil
        }

        let pointerAddress = UInt(bitPattern: pointer)
        for mapping in mappingInfos {
            guard let unslidStart = UInt(exactly: mapping.address),
                  let loadedStart = addingSignedDisplacement(slide, to: unslidStart),
                  let mappingSize = UInt(exactly: mapping.size),
                  loadedStart <= pointerAddress else {
                continue
            }

            let offset = pointerAddress - loadedStart
            guard offset < mappingSize else { continue }
            let (unslidAddress, overflow) = mapping.address.addingReportingOverflow(UInt64(offset))
            guard !overflow else { continue }

            return .init(
                // Main and subcache mappings share one cache-wide identity namespace.
                cacheUUID: mainCacheHeader.uuid,
                unslidAddress: unslidAddress,
                remainingMappedByteCount: mappingSize - offset
            )
        }
        return nil
    }
}
