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

@inline(__always)
private func _safeInt(_ value: UInt64) -> Int? {
    Int(exactly: value)
}

@inline(__always)
private func _safeInt(_ value: Int64) -> Int? {
    Int(exactly: value)
}

@inline(__always)
private func _safeSize(_ entrySize: Int, _ numberOfElements: Int) -> Int? {
    guard entrySize >= 0, numberOfElements >= 0 else { return nil }
    let (size, overflow) = entrySize.multipliedReportingOverflow(by: numberOfElements)
    guard !overflow else { return nil }
    return size
}

extension _FileIOProtocol {
    func readDataSequence<Element>(
        offset: UInt64,
        numberOfElements: Int,
        swapHandler: ((inout Data) -> Void)? = nil
    ) /*throws*/ -> DataSequence<Element> where Element: LayoutWrapper {
        guard let offset = _safeInt(offset),
              let size = _safeSize(Element.layoutSize, numberOfElements),
              Element.layoutSize == MemoryLayout<Element>.size,
              var data = try? readData(offset: offset, length: size) else {
            return .init(data: Data(), numberOfElements: 0)
        }
        let actualCount = min(numberOfElements, data.count / Element.layoutSize)
        if let swapHandler { swapHandler(&data) }
        return .init(
            data: data,
            numberOfElements: actualCount
        )
    }

    @_disfavoredOverload
    func readDataSequence<Element>(
        offset: UInt64,
        numberOfElements: Int,
        swapHandler: ((inout Data) -> Void)? = nil
    ) /*throws*/ -> DataSequence<Element> {
        let entrySize = MemoryLayout<Element>.size
        guard let offset = _safeInt(offset),
              let size = _safeSize(entrySize, numberOfElements),
              var data = try? readData(offset: offset, length: size) else {
            return .init(data: Data(), numberOfElements: 0)
        }
        let actualCount = min(numberOfElements, data.count / entrySize)
        if let swapHandler { swapHandler(&data) }
        return .init(
            data: data,
            numberOfElements: actualCount
        )
    }


    func readDataSequence<Element>(
        offset: UInt64,
        entrySize: Int,
        numberOfElements: Int,
        swapHandler: ((inout Data) -> Void)? = nil
    ) -> DataSequence<Element> where Element: LayoutWrapper {
        guard entrySize > 0,
              let offset = _safeInt(offset),
              let size = _safeSize(entrySize, numberOfElements),
              Element.layoutSize == MemoryLayout<Element>.size,
              var data = try? readData(offset: offset, length: size) else {
            return .init(data: Data(), numberOfElements: 0)
        }
        if let swapHandler { swapHandler(&data) }
        return .init(
            data: data,
            entrySize: entrySize
        )
    }


    @_disfavoredOverload
    func readDataSequence<Element>(
        offset: UInt64,
        entrySize: Int,
        numberOfElements: Int,
        swapHandler: ((inout Data) -> Void)? = nil
    ) -> DataSequence<Element> {
        guard entrySize > 0,
              let offset = _safeInt(offset),
              let size = _safeSize(entrySize, numberOfElements),
              var data = try? readData(offset: offset, length: size) else {
            return .init(data: Data(), numberOfElements: 0)
        }
        if let swapHandler { swapHandler(&data) }
        return .init(
            data: data,
            entrySize: entrySize
        )
    }
}

extension _FileIOProtocol {
    @inline(__always)
    func read<Element>(
        offset: UInt64
    ) -> Optional<Element> where Element: LayoutWrapper {
        guard Element.layoutSize == MemoryLayout<Element>.size,
              let offset = _safeInt(offset) else {
            return nil
        }
        return try? read(offset: offset, as: Element.self)
    }

    @inline(__always)
    func read<Element>(
        offset: UInt64
    ) -> Optional<Element> {
        guard let offset = _safeInt(offset) else { return nil }
        return try? read(offset: offset, as: Element.self)
    }


    @_disfavoredOverload
    @inline(__always)
    func read<Element>(
        offset: UInt64
    ) -> Element where Element: LayoutWrapper {
        guard let value: Element = read(offset: offset) else {
            fatalError("Failed to read LayoutWrapper at offset \(offset)")
        }
        return value
    }

    @_disfavoredOverload
    @inline(__always)
    func read<Element>(
        offset: UInt64
    ) -> Element {
        guard let value: Element = read(offset: offset) else {
            fatalError("Failed to read value at offset \(offset)")
        }
        return value
    }
}

extension _FileIOProtocol {
    func read<Element>(
        offset: UInt64,
        swapHandler: ((inout Data) -> Void)?
    ) -> Optional<Element> where Element: LayoutWrapper {
        guard Element.layoutSize == MemoryLayout<Element>.size,
              let offset = _safeInt(offset),
              var data = try? readData(offset: offset, length: Element.layoutSize),
              data.count >= Element.layoutSize else {
            return nil
        }
        if let swapHandler { swapHandler(&data) }
        return data.withUnsafeBytes {
            $0.load(as: Element.self)
        }
    }

    func read<Element>(
        offset: UInt64,
        swapHandler: ((inout Data) -> Void)?
    ) -> Optional<Element> {
        let size = MemoryLayout<Element>.size
        guard let offset = _safeInt(offset),
              var data = try? readData(offset: offset, length: size),
              data.count >= size else {
            return nil
        }
        if let swapHandler { swapHandler(&data) }
        return data.withUnsafeBytes {
            $0.load(as: Element.self)
        }
    }

    @_disfavoredOverload
    func read<Element>(
        offset: UInt64,
        swapHandler: ((inout Data) -> Void)?
    ) -> Element where Element: LayoutWrapper {
        guard let value: Element = read(offset: offset, swapHandler: swapHandler) else {
            fatalError("Failed to read LayoutWrapper at offset \(offset)")
        }
        return value
    }

    @_disfavoredOverload
    func read<Element>(
        offset: UInt64,
        swapHandler: ((inout Data) -> Void)?
    ) -> Element {
        guard let value: Element = read(offset: offset, swapHandler: swapHandler) else {
            fatalError("Failed to read value at offset \(offset)")
        }
        return value
    }
}

extension _FileIOProtocol {
    @_disfavoredOverload
    @inline(__always)
    func readString(
        offset: UInt64,
        size: Int
    ) -> String? {
        guard let offset = _safeInt(offset),
              let data = try? readData(offset: offset, length: size),
              !data.isEmpty else {
            return nil
        }
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
            guard let nextOffset = _safeInt(offset),
                  let new = try? readData(
                    offset: nextOffset,
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
        guard let offset = _safeInt(offset) else { return nil }
        return String(
            cString: ptr
                .advanced(by: offset)
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
