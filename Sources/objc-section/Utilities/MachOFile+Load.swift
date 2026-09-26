import Foundation
import MachOKit
import MachOKitExtensions

extension MachOFile {
    /// Resolves ``MachOOptionGroup`` into the binary to analyze: either a
    /// thin/fat Mach-O file at `filePath` (picking `architecture` out of a fat
    /// one), or an image extracted from a dyld shared cache — the running
    /// system's, or the cache file at `filePath`.
    ///
    /// This is the same shape as `swift-section`'s loader, which is private to
    /// that executable and so cannot be shared. Should the two keep converging,
    /// the natural home for it is `MachOKitExtensions`, which both already
    /// depend on.
    static func load(
        filePath: String?,
        isDyldSharedCache: Bool,
        usesSystemDyldSharedCache: Bool,
        cacheImageName: String?,
        cacheImagePath: String?,
        architecture: Architecture?
    ) throws -> MachOFile {
        if isDyldSharedCache || usesSystemDyldSharedCache {
            let dyldCache: DyldCache
            if usesSystemDyldSharedCache {
                if let host = DyldCache.host {
                    dyldCache = host
                } else {
                    throw ObjCSectionCommandError.unsupportedSystemVersionForDyldSharedCache
                }
            } else {
                let url = try URL(fileURLWithPath: required(filePath, error: ObjCSectionCommandError.missingFilePath))
                dyldCache = try DyldCache(url: url)
            }

            if cacheImagePath != nil, cacheImageName != nil {
                throw ObjCSectionCommandError.ambiguousCacheImageNameAndCacheImagePath
            } else if let cacheImageName {
                return try required(dyldCache.machOFile(by: .name(cacheImageName)), error: ObjCSectionCommandError.imageNotFound)
            } else if let cacheImagePath {
                return try required(dyldCache.machOFile(by: .path(cacheImagePath)), error: ObjCSectionCommandError.imageNotFound)
            } else {
                throw ObjCSectionCommandError.missingCacheImageNameOrCacheImagePath
            }
        } else {
            let url = try URL(fileURLWithPath: required(filePath, error: ObjCSectionCommandError.missingFilePath))
            let file = try File.loadFromFile(url: url)
            switch file {
            case .machO(let machOFile):
                return machOFile
            case .fat(let fatFile):
                let machOFiles = try fatFile.machOFiles()
                guard let architecture else {
                    let availableArchitectures = machOFiles.map { machOFile -> String in
                        Architecture(cpu: machOFile.header.cpu)?.rawValue ?? machOFile.header.cpu.description
                    }
                    throw ObjCSectionCommandError.fatBinaryRequiresArchitecture(availableArchitectures: availableArchitectures)
                }
                return try required(machOFiles.first { $0.header.cpu.subtype == architecture.cpu }, error: ObjCSectionCommandError.invalidArchitecture)
            }
        }
    }

    static func load(options: MachOOptionGroup) throws -> MachOFile {
        try load(
            filePath: options.filePath,
            isDyldSharedCache: options.isDyldSharedCache,
            usesSystemDyldSharedCache: options.usesSystemDyldSharedCache,
            cacheImageName: options.cacheImageName,
            cacheImagePath: options.cacheImagePath,
            architecture: options.architecture
        )
    }
}
