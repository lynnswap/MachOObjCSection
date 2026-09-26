//
//  _FileIOProtocol+.swift
//  MachOKit
//
//  Created by p-x9 on 2025/05/06
//
//

// Copied from https://github.com/p-x9/MachOKit/blob/e5c946ad1c9d5d07798d9885b2b66946b5db88c6/Sources/MachOKit/Extension/_FileIOProtocol%2B.swift

import Foundation
@_spi(Support) import MachOKit
#if compiler(>=6.0) || (compiler(>=5.10) && hasFeature(AccessLevelOnImport))
internal import FileIO
#else
@_implementationOnly import FileIO
#endif

extension _FileIOProtocol {
    @inline(__always)
    func readLayout<Layout>(
        offset: UInt64,
        as layoutType: Layout.Type
    ) -> Layout? {
        let byteCount = MemoryLayout<Layout>.size
        guard let readOffset = Int(exactly: offset),
              readOffset <= size,
              byteCount <= size - readOffset,
              let data = try? readData(offset: readOffset, length: byteCount) else {
            return nil
        }
        return data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(as: layoutType)
        }
    }
}

extension _FileIOProtocol {
    @_disfavoredOverload
    @inline(__always)
    func readString(
        offset: UInt64,
        size: Int
    ) -> String? {
        let data = try! readData(
            offset: numericCast(offset),
            length: size
        )
        return String(cString: data)
    }

    @_disfavoredOverload
    @inline(__always)
    func readString(
        offset: UInt64,
        step: Int = 10
    ) -> String? {
        var data = Data()
        var offset = offset
        while true {
            guard let new = try? readData(
                offset: numericCast(offset),
                upToCount: step
            ) else { break }
            if new.isEmpty { break }
            data.append(new)
            if new.contains(0) { break }
            offset += UInt64(new.count)
        }

        return String(cString: data)
    }
}

extension MemoryMappedFile {
    @inline(__always)
    func readString(
        offset: UInt64
    ) -> String? {
        String(
            cString: ptr
                .advanced(by: numericCast(offset))
                .assumingMemoryBound(to: CChar.self)
        )
    }

    @inline(__always)
    func readString(
        offset: UInt64,
        size: Int // ignored
    ) -> String? {
        readString(offset: offset)
    }

    @inline(__always)
    func readString(
        offset: UInt64,
        step: Int = 10 // ignored
    ) -> String? {
        readString(offset: offset)
    }
}

extension _FileIOProtocol {
    @inline(__always)
    func readAllData() throws -> Data {
        try readData(offset: 0, length: size)
    }
}
