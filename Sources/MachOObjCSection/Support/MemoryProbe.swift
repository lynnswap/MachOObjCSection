//
//  MemoryProbe.swift
//  MachOObjCSection
//
//  Lightweight check for whether a virtual address is mapped and readable
//  in the current task. The ObjC runtime stores some `class_rw_t` /
//  `class_rw_ext_t` fields as preopt cache offsets that only resolve when
//  the matching dyld shared cache is mapped — when a foreign-platform
//  binary (e.g. an iOS simulator framework) is `dlopen`'d on a macOS host,
//  those fields can contain stale low addresses (`0x...c04001` style) that
//  segfault on dereference. Probing first lets us bail out cleanly.
//

import Foundation
import MachOObjCSectionC
#if canImport(Darwin)
import Darwin
#endif

@inline(__always)
internal func isPointerSafelyReadable(
    _ ptr: UnsafeRawPointer,
    length: Int = 1
) -> Bool {
    MachOObjCSectionIsMemoryReadable(ptr, length)
}

internal enum BoundedCStringReadLimits {
    static let maximumByteCount = 64 * 1_024
}

internal func readBoundedNullTerminatedUTF8(
    at pointer: UnsafeRawPointer,
    maximumByteCount: Int = BoundedCStringReadLimits.maximumByteCount
) -> String? {
    guard maximumByteCount > 0 else { return nil }

#if canImport(Darwin)
    let pageSize = Int(getpagesize())
#else
    let pageSize = 4_096
#endif
    guard pageSize > 0 else { return nil }

    let startAddress = UInt(bitPattern: pointer)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(min(maximumByteCount, pageSize))

    while bytes.count < maximumByteCount {
        let (currentAddress, overflow) = startAddress.addingReportingOverflow(UInt(bytes.count))
        guard !overflow,
              let currentPointer = UnsafeRawPointer(bitPattern: currentAddress) else {
            return nil
        }

        let pageOffset = Int(currentAddress % UInt(pageSize))
        let readableByteCount = min(
            pageSize - pageOffset,
            maximumByteCount - bytes.count
        )
        guard isPointerSafelyReadable(currentPointer, length: readableByteCount) else {
            return nil
        }

        let buffer = UnsafeRawBufferPointer(
            start: currentPointer,
            count: readableByteCount
        )
        if let terminator = buffer.firstIndex(of: 0) {
            bytes.append(contentsOf: buffer[..<terminator])
            return String(bytes: bytes, encoding: .utf8)
        }
        bytes.append(contentsOf: buffer)
    }

    return nil
}
