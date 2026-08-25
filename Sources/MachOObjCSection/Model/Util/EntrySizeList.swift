//
//  EntrySizeList.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2025/01/26
//  
//

import Foundation
@_spi(Support) import MachOKit

// https://github.com/apple-oss-distributions/objc4/blob/89543e2c0f67d38ca5211cea33f42c51500287d5/runtime/objc-runtime-new.h#L707
public struct EntrySizeListHeader: LayoutWrapper {
    public struct Layout {
        public let entsizeAndFlags: UInt32
        public let count: UInt32
    }
    public var layout: Layout
}

public protocol EntrySizeListProtocol {
    associatedtype Entry

    typealias Header = EntrySizeListHeader

    static var flagMask: UInt32 { get }

    var offset: Int { get }
    var header: EntrySizeListHeader { get }
}

extension EntrySizeListProtocol {
    public var entrySize: Int {
        Int(exactly: header.entsizeAndFlags & ~Self.flagMask) ?? 0
    }

    public var _flags: UInt32 {
        numericCast(header.entsizeAndFlags & Self.flagMask)
    }

    public var count: Int { Int(exactly: header.count) ?? 0 }
}

extension EntrySizeListProtocol {
    /// Returns zero when a legacy caller asks for the size of malformed or
    /// over-budget external metadata. Checked decoders use `checkedSize`
    /// directly and preserve the typed failure instead of this projection.
    public static func size(for header: Header) -> Int {
        checkedSize(for: header) ?? 0
    }

    public var size: Int {
        Self.size(for: header)
    }

    internal static func checkedSize(for header: Header) -> Int? {
        let count: Int
        switch ObjCMetadataTableReader.exactCount(UInt64(header.count)) {
        case .success(let value): count = value
        case .failure: return nil
        }
        guard count > 0 else { return Header.layoutSize }
        let rawEntrySize = UInt64(header.entsizeAndFlags & ~Self.flagMask)
        let entrySize: Int
        switch ObjCMetadataTableReader.exactStride(rawEntrySize) {
        case .success(let value): entrySize = value
        case .failure: return nil
        }
        let byteCount: Int
        switch ObjCMetadataTableReader.checkedByteCount(
            count: count,
            stride: entrySize
        ) {
        case .success(let value): byteCount = value
        case .failure: return nil
        }
        let (size, overflow) = Header.layoutSize.addingReportingOverflow(byteCount)
        return overflow ? nil : size
    }

    internal static func checkedSize(
        for header: Header,
        expectedEntrySize: Int
    ) -> Int? {
        let count: Int
        switch ObjCMetadataTableReader.exactCount(UInt64(header.count)) {
        case .success(let value): count = value
        case .failure: return nil
        }
        guard count > 0 else { return Header.layoutSize }
        guard let advertisedEntrySize = Int(
            exactly: header.entsizeAndFlags & ~Self.flagMask
        ), advertisedEntrySize == expectedEntrySize else {
            return nil
        }
        let byteCount: Int
        switch ObjCMetadataTableReader.checkedByteCount(
            count: count,
            stride: advertisedEntrySize
        ) {
        case .success(let value): byteCount = value
        case .failure: return nil
        }
        let (size, overflow) = Header.layoutSize.addingReportingOverflow(byteCount)
        return overflow ? nil : size
    }
}
