//
//  ObjCProtocolListProtocol.swift
//
//
//  Created by p-x9 on 2024/07/19
//
//

import Foundation
@_spi(Support) import MachOKit

public protocol ObjCProtocolListHeaderProtocol {
    var count: Int { get }
}

public protocol ObjCProtocolListProtocol {
    associatedtype Header: ObjCProtocolListHeaderProtocol
    associatedtype ObjCProtocol: ObjCProtocolProtocol

    var offset: Int { get }
    var header: Header { get }

    @_spi(Core)
    init(ptr: UnsafeRawPointer, offset: Int)

    func protocols(in machO: MachOImage) -> [(MachOImage, ObjCProtocol)]?
    func protocols(in machO: MachOFile) -> [(MachOFile, ObjCProtocol)]?
}

extension ObjCProtocolListProtocol {
    public var isListOfLists: Bool {
        offset & 1 == 1
    }
}

extension ObjCProtocolListProtocol {
    func _readProtocols<Pointer: FixedWidthInteger>(
        in machO: MachOImage,
        pointerType: Pointer.Type
    ) -> [(MachOImage, ObjCProtocol)]? {
        guard !isListOfLists else { return nil }

        let ptr = machO.ptr.advanced(by: offset)
        let sequnece = MemorySequence(
            basePointer: ptr
                .advanced(by: MemoryLayout<Header>.size)
                .assumingMemoryBound(to: Pointer.self),
            numberOfElements: numericCast(header.count)
        )

        return sequnece
            .compactMap {
                guard let ptr = UnsafeRawPointer(bitPattern: UInt($0)) else {
                    return nil
                }
                let layout = ptr
                    .assumingMemoryBound(to: ObjCProtocol.Layout.self)
                    .pointee

                var targetMachO = machO
                if !targetMachO.contains(ptr: ptr) {
                    guard let cache = DyldCacheLoaded.current,
                          let _targetMachO = cache.machO(containing: ptr) else {
                        return nil
                    }
                    targetMachO = _targetMachO
                }

                let `protocol`: ObjCProtocol = .init(
                    layout: layout,
                    offset: Int(bitPattern: ptr) - Int(bitPattern: targetMachO.ptr)
                )
                return (targetMachO, `protocol`)
            }
    }
}

extension ObjCProtocolListProtocol {
    func _readProtocols<Pointer: FixedWidthInteger>(
        in machO: MachOFile,
        pointerType _: Pointer.Type
    ) -> [(MachOFile, ObjCProtocol)]? {
        guard !isListOfLists else {
            assertionFailure()
            return nil
        }

        guard let (fileHandle, fileOffset) = machO.fileHandleAndOffset(
            forOffset: numericCast(offset)
        ) else {
            return nil
        }

        let sequence: DataSequence<Pointer> = fileHandle.readDataSequence(
            offset: fileOffset + numericCast(MemoryLayout<Header>.size),
            numberOfElements: numericCast(header.count)
        )

        return sequence.enumerated().compactMap { index, value in
            let unresolved = UnresolvedValue(
                fieldOffset: offset
                    + MemoryLayout<Header>.size
                    + MemoryLayout<Pointer>.stride * index,
                value: numericCast(value)
            )

            guard case let .resolved(resolved) = machO.resolveObjCPointerListTarget(
                unresolved
            ),
            let result = machO.readObjCLayout(
                at: resolved,
                as: ObjCProtocol.Layout.self
            ) else {
                return nil
            }

            let `protocol` = ObjCProtocol(
                layout: result.1,
                offset: numericCast(resolved.offset)
            )
            return (result.0, `protocol`)
        }
    }
}
