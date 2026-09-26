//
//  CheckedAddress.swift
//  MachOObjCSection
//

import Foundation

@inline(__always)
internal func addingSignedDisplacement(
    _ displacement: Int,
    to baseAddress: UInt
) -> UInt? {
    guard let displacement = Int64(exactly: displacement) else { return nil }
    return addingSignedDisplacement(displacement, to: baseAddress)
}

@inline(__always)
internal func addingSignedDisplacement(
    _ displacement: Int64,
    to baseAddress: UInt
) -> UInt? {
    if displacement >= 0 {
        guard let magnitude = UInt(exactly: displacement) else { return nil }
        let (address, overflow) = baseAddress.addingReportingOverflow(magnitude)
        return overflow ? nil : address
    }

    guard let magnitude = UInt(exactly: displacement.magnitude) else { return nil }
    let (address, underflow) = baseAddress.subtractingReportingOverflow(magnitude)
    return underflow ? nil : address
}

@inline(__always)
internal func addingSignedDisplacement(
    _ displacement: Int64,
    to baseOffset: Int
) -> Int64? {
    guard let baseOffset = Int64(exactly: baseOffset) else { return nil }
    let (result, overflow) = baseOffset.addingReportingOverflow(displacement)
    return overflow ? nil : result
}

@inline(__always)
internal func signedDisplacement(
    from baseAddress: UInt,
    to address: UInt
) -> Int? {
    if address >= baseAddress {
        return Int(exactly: address - baseAddress)
    }

    let magnitude = baseAddress - address
    if magnitude == UInt(Int.max) + 1 {
        return Int.min
    }
    guard let value = Int(exactly: magnitude) else { return nil }
    return -value
}
