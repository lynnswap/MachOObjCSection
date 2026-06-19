//
//  FileHandleHolder.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2026/02/09
//  
//

import Foundation
#if compiler(>=6.0) || (compiler(>=5.10) && hasFeature(AccessLevelOnImport))
internal import FileIO
#else
@_implementationOnly import FileIO
#endif

internal final class FileHandleHolder<
    Owner: AnyObject,
    File: FileIOProtocol & AnyObject
>: @unchecked Sendable {
    private let lock: NSRecursiveLock = .init()

#if canImport(ObjectiveC)
    private let _mapTable: NSMapTable<Owner, File> = .weakToStrongObjects()
#else
    private var _mapTable = WeakKeyStrongValueMap<Owner, File>()
#endif

    init() {}

    @inline(__always)
    @_optimize(speed)
    func fileHandle(
        for owner: Owner,
        initialize: () -> File
    ) -> File {
        lock.lock()
        defer { lock.unlock() }

        if let fileHandle = _mapTable.object(forKey: owner) {
            return fileHandle
        } else {
            let fileHandle = initialize()
            _mapTable.setObject(fileHandle, forKey: owner)
            return fileHandle
        }
    }
}
