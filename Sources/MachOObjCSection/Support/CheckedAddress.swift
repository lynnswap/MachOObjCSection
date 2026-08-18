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
    if displacement >= 0 {
        let (address, overflow) = baseAddress.addingReportingOverflow(UInt(displacement))
        return overflow ? nil : address
    }

    let (address, underflow) = baseAddress.subtractingReportingOverflow(displacement.magnitude)
    return underflow ? nil : address
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
