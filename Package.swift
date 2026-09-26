// swift-tools-version: 6.2

@preconcurrency import PackageDescription
import Foundation

func envEnable(_ key: String, default defaultValue: Bool = false) -> Bool {
    let value = Context.environment[key]
    guard let value else {
        return defaultValue
    }
    if value == "1" {
        return true
    } else if value == "0" {
        return false
    } else {
        return defaultValue
    }
}

let usingLocalDependencies = envEnable("USING_LOCAL_DEPENDENCIES")

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool = usingLocalDependencies, traits: Set<PackageDescription.Package.Dependency.Trait> = [.defaults])
    }

    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        let currentFilePath = #filePath

        let isClonedDependency = currentFilePath.contains("/checkouts/") ||
            currentFilePath.contains("/SourcePackages/") ||
            currentFilePath.contains("/.build/")

        if isClonedDependency {
            return remote
        }

        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative, let isEnabled, let traits):
                guard isEnabled else { continue }
                let url = if isRelative {
                    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: currentFilePath))
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path, traits: traits)
                }
            }
        }
        return remote
    }
}

let package = Package(
    name: "MachOObjCSection",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    products: [
        .library(
            name: "MachOObjCSection",
            targets: ["MachOObjCSection"]
        ),
        .library(
            name: "ObjCDeclarationRendering",
            targets: ["ObjCDeclarationRendering"]
        ),
        .library(
            name: "ObjCIndexing",
            targets: ["ObjCIndexing"]
        ),
        .library(
            name: "ObjCInterface",
            targets: ["ObjCInterface"]
        ),
        .library(
            name: "ObjCOutputTransformer",
            targets: ["ObjCOutputTransformer"]
        ),
    ],
    dependencies: [
        .package(
            local: .package(
                path: "../MachOKit",
                isRelative: true
            ),
            remote: .package(
                url: "https://github.com/lynnswap/MachOKit.git",
                revision: "f6a4f85280733a0e77d33f11274e7a12052c7ce1"
            )
        ),
        .package(
            local: .package(
                path: "../swift-objc-dump",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/swift-objc-dump",
                from: "0.8.100"
            )
        ),
        .package(
            url: "https://github.com/p-x9/swift-fileio.git",
            from: "0.14.0"
        ),
        .package(
            local: .package(
                path: "../swift-semantic-string",
                isRelative: true
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/swift-semantic-string",
                from: "0.3.0"
            )
        ),
        .package(
            local: .package(
                path: "../MachOKitExtensions",
                isRelative: true
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachOKitExtensions",
                from: "0.1.0"
            )
        ),
        .package(
            url: "https://github.com/apple/swift-collections",
            from: "1.2.0"
        ),
    ],
    targets: [
        .target(
            name: "MachOObjCSection",
            dependencies: [
                "MachOObjCSectionC",
                "MachOKit",
                .product(name: "FileIO", package: "swift-fileio"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ]
        ),
        .target(
            name: "MachOObjCSectionC"
        ),
        .target(
            name: "ObjCDeclarationRendering",
            dependencies: [
                "MachOObjCSection",
                "MachOKit",
                .product(name: "MachOKitExtensions", package: "MachOKitExtensions"),
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ]
        ),
        .target(
            name: "ObjCIndexing",
            dependencies: [
                "MachOObjCSection",
                "ObjCDeclarationRendering",
                "MachOKit",
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ]
        ),
        .testTarget(
            name: "MachOObjCSectionTests",
            dependencies: ["MachOObjCSection"]
        ),
        // The ObjC-specific transformer modules. They extend the shared
        // `Transformer` namespace from swift-semantic-string, but their
        // vocabulary is Objective-C (C primitive spellings, ivar offsets), so
        // they ship here rather than in a general-purpose string package.
        .target(
            name: "ObjCOutputTransformer",
            dependencies: [
                .product(name: "OutputTransformer", package: "swift-semantic-string"),
                .product(name: "Semantic", package: "swift-semantic-string"),
            ]
        ),
        .target(
            name: "ObjCInterface",
            dependencies: [
                "MachOObjCSection",
                "ObjCDeclarationRendering",
                "ObjCIndexing",
                "MachOKit",
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ]
        ),
        .testTarget(
            name: "ObjCOutputTransformerTests",
            dependencies: [
                "ObjCOutputTransformer",
                .product(name: "OutputTransformer", package: "swift-semantic-string"),
                .product(name: "Semantic", package: "swift-semantic-string"),
            ]
        ),
        .testTarget(
            name: "ObjCInterfaceTests",
            dependencies: [
                "ObjCInterface",
                "ObjCIndexing",
                "ObjCDeclarationRendering",
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ]
        ),
        .testTarget(
            name: "ObjCIndexingTests",
            dependencies: [
                "ObjCIndexing",
                "ObjCDeclarationRendering",
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ]
        ),
        .testTarget(
            name: "ObjCDeclarationRenderingTests",
            dependencies: [
                "ObjCDeclarationRendering",
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ]
        ),
    ]
)
