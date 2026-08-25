//
//  ObjCIvarProtocol.swift
//
//
//  Created by p-x9 on 2024/08/22
//  
//

import Foundation
import MachOObjCSectionC
@_spi(Support) import MachOKit

public protocol ObjCIvarProtocol: _FixupResolvable
where LayoutField == ObjCIvarLayoutField,
      Layout: _ObjCIvarLayoutProtocol
{
    // var layout: Layout { get }
    var offset: Int { get }

    @_spi(Core)
    init(layout: Layout, offset: Int)

    func offset(in machO: MachOFile) -> UInt32?
    func name(in machO: MachOFile) -> String?
    func type(in machO: MachOFile) -> String?

    func offset(in machO: MachOImage) -> UInt32?
    func name(in machO: MachOImage) -> String
    func type(in machO: MachOImage) -> String?
}

extension ObjCIvarProtocol {
    // https://github.com/apple-oss-distributions/objc4/blob/01edf1705fbc3ff78a423cd21e03dfc21eb4d780/runtime/objc-runtime-new.h#L1312
    public var alignment: UInt32 {
        if layout.alignment == ~UInt32.zero {
            return 1 << WORD_SHIFT
        }
        return 1 << layout.alignment
    }
}

extension ObjCIvarProtocol {
    public func offset(in machO: MachOFile) -> UInt32? {
        readOffset(in: machO).value
    }

    internal func readOffset(
        in machO: MachOFile
    ) -> ObjCMetadataFieldRead<UInt32> {
        guard layout.offset > 0 else { return .absent }

        let unresolved = unresolvedValue(of: .offset)
        guard let resolved = machO.resolveRebase(unresolved) else {
            return .failure(.unresolvedRebase)
        }

        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
            return .failure(.missingBackingData)
        }

        guard let offset = fileHandle.readLayout(
            offset: fileOffset,
            as: UInt32.self
        ) else {
            return .failure(
                .unreadableFileRange(
                    offset: fileOffset,
                    byteCount: MemoryLayout<UInt32>.size
                )
            )
        }
        return .value(offset)
    }

    public func name(in machO: MachOFile) -> String? {
        let unresolved = unresolvedValue(of: .name)
        guard let resolved = machO.resolveRebase(unresolved) else { return nil }

        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
            return nil
        }

        return fileHandle.readString(
            offset: fileOffset
        )
    }

    public func type(in machO: MachOFile) -> String? {
        guard layout.type > 0 else { return nil }

        let unresolved = unresolvedValue(of: .type)
        guard let resolved = machO.resolveRebase(unresolved) else { return nil }

        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(forResolvedValue: resolved) else {
            return nil
        }

        return fileHandle.readString(
            offset: fileOffset
        )
    }
}

extension ObjCIvarProtocol {
    public func offset(in machO: MachOImage) -> UInt32? {
        readOffset(in: machO).value
    }

    internal func readOffset(
        in machO: MachOImage
    ) -> ObjCMetadataFieldRead<UInt32> {
        guard layout.offset > 0 else { return .absent }
        guard let address = UInt(exactly: layout.offset),
              let ptr = UnsafeRawPointer(bitPattern: address) else {
            return .failure(.missingBackingData)
        }
        let byteCount = MemoryLayout<UInt32>.size
        guard isPointerSafelyReadable(ptr, length: byteCount) else {
            return .failure(
                .unreadableImageRange(address: address, byteCount: byteCount)
            )
        }
        return .value(ptr.loadUnaligned(as: UInt32.self))
    }

    public func name(in machO: MachOImage) -> String {
        let ptr = UnsafeRawPointer(
            bitPattern: UInt(layout.name)
        )
        return .init(cString: ptr!.assumingMemoryBound(to: CChar.self))
    }

    public func type(in machO: MachOImage) -> String? {
        guard layout.type > 0 else { return nil }
        let ptr = UnsafeRawPointer(
            bitPattern: UInt(layout.type)
        )
        return .init(cString: ptr!.assumingMemoryBound(to: CChar.self))
    }
}
