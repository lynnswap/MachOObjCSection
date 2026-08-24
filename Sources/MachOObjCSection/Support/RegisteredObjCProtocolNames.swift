//
//  RegisteredObjCProtocolNames.swift
//  MachOObjCSection
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

#if canImport(ObjectiveC)
import ObjectiveC
#endif

internal struct RegisteredObjCProtocolNameResolver {
    let protocolAddress: (String) -> UnsafeRawPointer?

    static var runtime: Self? {
#if canImport(ObjectiveC)
        return Self { name in
            guard let objcProtocol = objc_getProtocol(name) else { return nil }
            return UnsafeRawPointer(
                Unmanaged.passUnretained(objcProtocol).toOpaque()
            )
        }
#else
        return nil
#endif
    }
}

internal enum RegisteredObjCProtocolNameLimits {
    static let maximumByteCount = 64 * 1_024
}

internal func readBoundedNullTerminatedUTF8(
    at pointer: UnsafeRawPointer,
    maximumByteCount: Int = RegisteredObjCProtocolNameLimits.maximumByteCount
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
