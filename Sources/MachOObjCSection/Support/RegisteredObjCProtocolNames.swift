//
//  RegisteredObjCProtocolNames.swift
//  MachOObjCSection
//

import Foundation

#if canImport(ObjectiveC)
import ObjectiveC
import os

private final class RegisteredObjCProtocolNames: @unchecked Sendable {
    static let shared = RegisteredObjCProtocolNames()

    // `@unchecked Sendable` is confined to this lock; mutable storage never
    // escapes, and lookups return copied String values.
    private var lock = os_unfair_lock()
    private var namesByAddress: [UInt: String] = [:]

    private init() {}

    func cachedName(for pointer: UnsafeRawPointer) -> String? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return namesByAddress[UInt(bitPattern: pointer)]
    }

    func refresh() {
        var count: UInt32 = 0
        guard let protocols = objc_copyProtocolList(&count) else { return }
        defer { free(UnsafeMutableRawPointer(protocols)) }

        var snapshot: [UInt: String] = [:]
        snapshot.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let objcProtocol = protocols[index]
            let address = UInt(
                bitPattern: Unmanaged.passUnretained(objcProtocol).toOpaque()
            )
            snapshot[address] = String(cString: protocol_getName(objcProtocol))
        }

        os_unfair_lock_lock(&lock)
        namesByAddress.merge(snapshot) { _, refreshed in refreshed }
        os_unfair_lock_unlock(&lock)
    }
}
#endif

internal struct RegisteredObjCProtocolNameResolver {
    let cachedName: (UnsafeRawPointer) -> String?
    let refresh: () -> Void

    static var runtime: Self? {
#if canImport(ObjectiveC)
        let registry = RegisteredObjCProtocolNames.shared
        return Self(
            cachedName: { registry.cachedName(for: $0) },
            refresh: { registry.refresh() }
        )
#else
        return nil
#endif
    }
}
