//
//  CheckedObjCSectionCoordinates.swift
//  MachOObjCSection
//

import Foundation
import MachOKit

internal struct CheckedObjCSectionCoordinates {
    let address: UInt64
    let size: Int
    let fileOffset: Int
    let alignmentExponent: Int
    let segmentVirtualMemoryOffset: UInt64
    let mappedFileOffset: UInt64

    func loadedImageAddress(relativeTo imageBase: UInt) -> UInt? {
        guard let displacement = UInt(exactly: segmentVirtualMemoryOffset) else {
            return nil
        }
        let (address, overflow) = imageBase.addingReportingOverflow(displacement)
        return overflow ? nil : address
    }
}

@inline(__always)
internal func exactObjCSectionCoordinate(
    _ value: UInt64,
    maximumIntValue: UInt64 = UInt64(Int.max)
) -> Int? {
    guard value <= maximumIntValue else { return nil }
    return Int(exactly: value)
}

@inline(__always)
internal func checkedObjCSectionAlignmentExponent(
    _ value: UInt64,
    maximumIntValue: UInt64 = UInt64(Int.max),
    intBitWidth: Int = Int.bitWidth
) -> Int? {
    guard intBitWidth > 1,
          let exponent = exactObjCSectionCoordinate(
            value,
            maximumIntValue: maximumIntValue
          ),
          exponent < intBitWidth - 1 else { return nil }
    return exponent
}

internal func checkedObjCSectionCoordinates(
    _ section: Section64,
    in segment: SegmentCommand64
) -> CheckedObjCSectionCoordinates? {
    checkedObjCSectionCoordinates(
        address: section.layout.addr,
        size: section.layout.size,
        fileOffset: UInt64(section.layout.offset),
        alignmentExponent: UInt64(section.layout.align),
        segmentVirtualMemoryAddress: segment.layout.vmaddr,
        segmentVirtualMemorySize: segment.layout.vmsize,
        segmentFileOffset: segment.layout.fileoff,
        segmentFileSize: segment.layout.filesize
    )
}

internal func checkedObjCSectionCoordinates(
    _ section: Section,
    in segment: SegmentCommand
) -> CheckedObjCSectionCoordinates? {
    checkedObjCSectionCoordinates(
        address: UInt64(section.layout.addr),
        size: UInt64(section.layout.size),
        fileOffset: UInt64(section.layout.offset),
        alignmentExponent: UInt64(section.layout.align),
        segmentVirtualMemoryAddress: UInt64(segment.layout.vmaddr),
        segmentVirtualMemorySize: UInt64(segment.layout.vmsize),
        segmentFileOffset: UInt64(segment.layout.fileoff),
        segmentFileSize: UInt64(segment.layout.filesize)
    )
}

private func checkedObjCSectionCoordinates(
    address: UInt64,
    size rawSize: UInt64,
    fileOffset rawFileOffset: UInt64,
    alignmentExponent rawAlignmentExponent: UInt64,
    segmentVirtualMemoryAddress: UInt64,
    segmentVirtualMemorySize: UInt64,
    segmentFileOffset: UInt64,
    segmentFileSize: UInt64
) -> CheckedObjCSectionCoordinates? {
    guard let size = exactObjCSectionCoordinate(rawSize),
          let fileOffset = exactObjCSectionCoordinate(rawFileOffset),
          let alignmentExponent = checkedObjCSectionAlignmentExponent(rawAlignmentExponent),
          address >= segmentVirtualMemoryAddress,
          rawFileOffset >= segmentFileOffset else { return nil }

    let virtualDelta = address - segmentVirtualMemoryAddress
    let fileDelta = rawFileOffset - segmentFileOffset
    let (mappedFileOffset, mappedFileOffsetOverflow) = segmentFileOffset.addingReportingOverflow(
        virtualDelta
    )
    guard virtualDelta <= segmentVirtualMemorySize,
          rawSize <= segmentVirtualMemorySize - virtualDelta,
          fileDelta <= segmentFileSize,
          rawSize <= segmentFileSize - fileDelta,
          !mappedFileOffsetOverflow else { return nil }

    return .init(
        address: address,
        size: size,
        fileOffset: fileOffset,
        alignmentExponent: alignmentExponent,
        segmentVirtualMemoryOffset: virtualDelta,
        mappedFileOffset: mappedFileOffset
    )
}
