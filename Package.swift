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
            name: "ObjCMetadataSource",
            targets: ["ObjCMetadataSource"]
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
        .library(
            name: "ObjCDiffing",
            targets: ["ObjCDiffing"]
        ),
        .executable(
            name: "objc-section",
            targets: ["objc-section"]
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
                revision: "4d272878ad8d721bb6827e5183a1358eeeb0973d"
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
        // Already in the graph before this line existed — `swift-objc-dump`'s
        // `ObjCTypeDecodeKit` depends on `FoundationToolbox`. Declaring it
        // directly costs nothing in resolution or build time and lets the
        // targets below drop their hand-rolled copies of `Mutex` and
        // `uppercasedFirst` — see proposal 0005.
        .package(
            local: .package(
                path: "../FrameworkToolbox",
                isRelative: true
            ),
            remote: .package(
                url: "https://github.com/Mx-Iris/FrameworkToolbox",
                from: "0.9.0"
            )
        ),
        // Command-line only. The library targets stay free of both.
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.5.1"
        ),
        .package(
            url: "https://github.com/onevcat/Rainbow",
            from: "4.0.0"
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
        // The generic entry point onto Objective-C metadata. It restates
        // MachOObjCSection's parallel `MachOFile` / `MachOImage` overloads as
        // requirements taking `Self`, which is what lets everything above it be
        // written once instead of twice. Kept out of the core target on
        // purpose — see proposal 0002's "Alternatives considered".
        .target(
            name: "ObjCMetadataSource",
            dependencies: [
                "MachOObjCSection",
                "MachOKit",
                .product(name: "MachOKitExtensions", package: "MachOKitExtensions"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ]
        ),
        .target(
            name: "ObjCDeclarationRendering",
            dependencies: [
                "MachOObjCSection",
                "ObjCMetadataSource",
                "MachOKit",
                .product(name: "MachOKitExtensions", package: "MachOKitExtensions"),
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
                // For `.box.uppercasedFirst()` / `.box.lowercasedFirst()`.
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ]
        ),
        .target(
            name: "ObjCIndexing",
            dependencies: [
                "MachOObjCSection",
                "ObjCMetadataSource",
                "ObjCDeclarationRendering",
                "MachOKit",
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
                // For `@Mutex`. Deliberately `SwiftStdlibToolbox` rather than
                // `OSToolbox`: the split that moves `Mutex` down a layer is not
                // released yet, and once it is, this target re-exports it.
                .product(name: "SwiftStdlibToolbox", package: "FrameworkToolbox"),
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
        // The ObjC API diff engine (proposal 0006). Pure value computation
        // over the ObjCDump info model — deliberately independent of the
        // rendering and indexing layers, mirroring how MachOSwiftSection's
        // SwiftDiffing sits on SwiftDeclaration alone. ObjCMetadataSource is
        // here only for the model-derived accessors (`uniqueName` & co.).
        .target(
            name: "ObjCDiffing",
            dependencies: [
                "ObjCMetadataSource",
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ]
        ),
        .target(
            name: "ObjCInterface",
            dependencies: [
                "MachOObjCSection",
                "ObjCMetadataSource",
                "ObjCDeclarationRendering",
                "ObjCIndexing",
                "ObjCDiffing",
                "MachOKit",
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
                // For `.box.uppercasedFirst()`.
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ]
        ),
        .executableTarget(
            name: "objc-section",
            dependencies: [
                "MachOObjCSection",
                "ObjCMetadataSource",
                "ObjCDeclarationRendering",
                "ObjCIndexing",
                "ObjCInterface",
                "ObjCOutputTransformer",
                "ObjCDiffing",
                "MachOKit",
                .product(name: "MachOKitExtensions", package: "MachOKitExtensions"),
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "OutputTransformer", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Rainbow", package: "Rainbow"),
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
                "ObjCDiffing",
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
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
            name: "ObjCMetadataSourceTests",
            dependencies: [
                "ObjCMetadataSource",
                "ObjCIndexing",
                "ObjCInterface",
                "ObjCDeclarationRendering",
                .product(name: "MachOKitExtensions", package: "MachOKitExtensions"),
                .product(name: "Semantic", package: "swift-semantic-string"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ]
        ),
        .testTarget(
            name: "ObjCSectionCommandTests",
            dependencies: [
                "objc-section",
                "ObjCDeclarationRendering",
                "ObjCOutputTransformer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ObjCDiffingTests",
            dependencies: [
                "ObjCDiffing",
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
