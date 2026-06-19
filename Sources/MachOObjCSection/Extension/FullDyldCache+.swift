//
//  FullDyldCache+.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2025/09/28
//  
//

import Foundation
import MachOKit
#if compiler(>=6.0) || (compiler(>=5.10) && hasFeature(AccessLevelOnImport))
internal import FileIO
#else
@_implementationOnly import FileIO
#endif

extension FileHandleHolder<FullDyldCache, FullDyldCache.File> {
    fileprivate static let shared: FileHandleHolder<Owner, File> = .init()
}

extension FullDyldCache {
    internal typealias File = ConcatenatedMemoryMappedFile

    var fileHandle: File {
        FileHandleHolder.shared.fileHandle(
            for: self,
            initialize: {
                let mainCache = try! DyldCache(url: url)

                let subCacheSuffixes = mainCache.subCaches?.map {
                    $0.fileSuffix
                } ?? []
                var urls = [url]
                urls += subCacheSuffixes.map {
                    URL(fileURLWithPath: url.path + $0)
                }

                return try! .open(
                    urls: urls,
                    isWritable: false
                )
            }
        )
    }
}

extension FullDyldCache {
    func fileSegment(forOffset offset: UInt64) -> File.FileSegment? {
        try? fileHandle._file(for: numericCast(offset))
    }
}
