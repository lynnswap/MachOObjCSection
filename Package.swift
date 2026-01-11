// swift-tools-version: 5.9

import PackageDescription
import Foundation

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool)
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
            case .package(let path, let isRelative, let isEnabled):
                guard isEnabled else { continue }
                let url = if isRelative {
                    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: currentFilePath))
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path)
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
    ],
    dependencies: [
        .package(
            local: .package(
                path: "../MachOKit",
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachOKit.git",
                branch: "main"
            )
        ),
        .package(
            local: .package(
                path: "../swift-objc-dump",
                isRelative: true,
                isEnabled: false
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/swift-objc-dump.git",
                branch: "main"
            )
        ),
        .package(
            url: "https://github.com/p-x9/swift-fileio.git",
            from: "0.9.0"
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
        .testTarget(
            name: "MachOObjCSectionTests",
            dependencies: ["MachOObjCSection"]
        ),
    ]
)
