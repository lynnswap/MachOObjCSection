import Foundation

enum ObjCSectionCommandError: LocalizedError {
    case missingFilePath
    case ambiguousCacheImageNameAndCacheImagePath
    case missingCacheImageNameOrCacheImagePath
    case imageNotFound
    case invalidArchitecture
    case fatBinaryRequiresArchitecture(availableArchitectures: [String])
    case unsupportedSystemVersionForDyldSharedCache
    case malformedCTypeReplacement(String)
    case unknownCType(String)
    case declarationNotFound(String)

    var errorDescription: String? {
        switch self {
        case .missingFilePath:
            "The filePath is required when uses-system-dyld-shared-cache is false. Please provide a valid Mach-O file path."
        case .ambiguousCacheImageNameAndCacheImagePath:
            "Both cacheImageName and cacheImagePath are provided, but only one should be specified."
        case .missingCacheImageNameOrCacheImagePath:
            "Either cacheImageName or cacheImagePath must be provided when dyldSharedCache is true."
        case .imageNotFound:
            "The specified image was not found in the dyld shared cache."
        case .invalidArchitecture:
            "The specified architecture is not found or supported."
        case .fatBinaryRequiresArchitecture(let availableArchitectures):
            "The file is a fat (universal) binary. You must specify an architecture using --architecture (-a). Available architectures: \(availableArchitectures.joined(separator: ", "))"
        case .unsupportedSystemVersionForDyldSharedCache:
            "The minimum system version that supports the --uses-system-dyld-shared-cache flag is macOS 11.0. Current system version: \(ProcessInfo.processInfo.operatingSystemVersionString)."
        case .malformedCTypeReplacement(let argument):
            "Malformed --c-type-replacement '\(argument)'. Expected <c-type>=<replacement>, e.g. double=CGFloat."
        case .unknownCType(let name):
            "Unknown C type '\(name)'. Supported: \(CTypeName.allSpellings.joined(separator: ", "))."
        case .declarationNotFound(let name):
            "No class, protocol, category, struct or union named '\(name)' in this binary."
        }
    }
}
