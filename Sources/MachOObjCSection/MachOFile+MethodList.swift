//
//  MachOFile+MethodList.swift
//
//
//  Created by p-x9 on 2024/05/23
//  
//

import Foundation
import MachOKit

extension MachOFile {
    public struct ObjCMethodLists: Sequence {
        public let data: Data
        public let offset: Int
        public let align: Int // 2^align
        public let is64Bit: Bool

        public func makeIterator() -> Iterator {
            .init(
                data: data,
                offset: offset,
                align: align,
                is64Bit: is64Bit
            )
        }
    }
}

extension MachOFile.ObjCMethodLists {
    public struct Iterator: IteratorProtocol {
        public typealias Element = ObjCMethodList

        private let tableStartOffset: Int
        private let data: Data
        private let align: Int
        private let is64Bit: Bool

        private var nextOffset: Int = 0

        init(
            data: Data,
            offset: Int,
            align: Int,
            is64Bit: Bool
        ) {
            self.data = data
            self.tableStartOffset = offset
            self.align = align
            self.is64Bit = is64Bit
        }

        public mutating func next() -> Element? {
            guard nextOffset >= 0, nextOffset < data.count else {
                return nil
            }
            let headerSize = MemoryLayout<Element.Header>.size
            guard headerSize <= data.count - nextOffset else { return nil }
            let header: Element.Header = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: nextOffset, as: Element.Header.self)
            }
            let (listOffset, listOffsetOverflow) = tableStartOffset.addingReportingOverflow(
                nextOffset
            )
            guard !listOffsetOverflow else { return nil }
            let list = Element(
                offset: listOffset,
                header: header,
                is64Bit: is64Bit
            )
            let expectedEntrySize = list.expectedEntrySize(is64Bit: is64Bit)
            guard let listSize = Element.checkedSize(
                for: header,
                expectedEntrySize: expectedEntrySize
            ), listSize <= data.count - nextOffset else {
                return nil
            }
            let (endOffset, endOverflow) = nextOffset.addingReportingOverflow(listSize)
            guard !endOverflow,
                  let followingOffset = checkedAlignedOffset(
                    endOffset,
                    alignmentExponent: align
                  ) else { return nil }
            nextOffset = followingOffset
            return list
        }
    }
}

internal func checkedAlignedOffset(
    _ offset: Int,
    alignmentExponent: Int
) -> Int? {
    guard offset >= 0,
          alignmentExponent >= 0,
          alignmentExponent < Int.bitWidth - 1 else { return nil }
    let alignment = 1 << alignmentExponent
    let remainder = offset % alignment
    guard remainder != 0 else { return offset }
    let (result, overflow) = offset.addingReportingOverflow(alignment - remainder)
    return overflow ? nil : result
}
