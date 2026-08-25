//
//  MachOImage+MethodList.swift
//
//
//  Created by p-x9 on 2024/05/23
//  
//

import Foundation
import MachOKit

extension MachOImage {
    public struct ObjCMethodLists: Sequence {
        public let offset: Int
        public let basePointer: UnsafeRawPointer
        public let tableSize: Int
        public let align: Int // 2^align
        public let is64Bit: Bool

        public func makeIterator() -> Iterator {
            .init(
                offset: offset,
                basePointer: basePointer,
                tableSize: tableSize,
                align: align,
                is64Bit: is64Bit
            )
        }
    }
}

extension MachOImage.ObjCMethodLists {
    public struct Iterator: IteratorProtocol {
        public typealias Element = ObjCMethodList

        private let tableStartOffset: Int
        private let basePointer: UnsafeRawPointer
        private let tableSize: Int
        private let align: Int
        private let is64Bit: Bool

        private var nextOffset: Int = 0

        init(
            offset: Int,
            basePointer: UnsafeRawPointer,
            tableSize: Int,
            align: Int,
            is64Bit: Bool
        ) {
            self.tableStartOffset = offset
            self.basePointer = basePointer
            self.tableSize = tableSize
            self.align = align
            self.is64Bit = is64Bit
        }

        public mutating func next() -> Element? {
            guard tableSize >= 0, nextOffset >= 0, nextOffset < tableSize else {
                return nil
            }
            let baseAddress = UInt(bitPattern: basePointer)
            let (headerAddress, addressOverflow) = baseAddress.addingReportingOverflow(
                UInt(nextOffset)
            )
            guard !addressOverflow else { return nil }
            let headerEntries: [ObjCMetadataTableEntry<Element.Header>]
            switch ObjCMetadataTableReader.readImage(
                address: headerAddress,
                count: 1,
                as: Element.Header.self
            ) {
            case .success(let value): headerEntries = value
            case .failure: return nil
            }
            guard let header = headerEntries.first?.value else { return nil }
            let (listOffset, listOffsetOverflow) = tableStartOffset.addingReportingOverflow(
                nextOffset
            )
            guard !listOffsetOverflow else { return nil }
            let list = ObjCMethodList(
                offset: listOffset,
                header: header,
                is64Bit: is64Bit
            )
            let expectedEntrySize = list.expectedEntrySize(is64Bit: is64Bit)
            guard let listSize = Element.checkedSize(
                for: header,
                expectedEntrySize: expectedEntrySize
            ), listSize <= tableSize - nextOffset else {
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
