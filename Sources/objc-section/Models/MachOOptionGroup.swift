import ArgumentParser

/// How to get at the binary: a path on disk, or an image inside a dyld shared
/// cache (the running system's, or a cache file given by path).
///
/// Deliberately identical in spelling to `swift-section`'s option group of the
/// same name — the two tools are used side by side on the same binaries, and
/// having `-p` / `-n` / `--architecture` mean the same thing in both is worth
/// more than any improvement either could make on its own.
struct MachOOptionGroup: ParsableArguments, Sendable {
    @Argument(help: "The path to the Mach-O file or dyld shared cache to dump.", completion: .file())
    var filePath: String?

    @Option(name: [.long, .customShort("p")], help: "The path to the dyld shared cache image. If filePath is a Mach-O file, this option is ignored.")
    var cacheImagePath: String?

    @Option(name: [.long, .customShort("n")], help: "The name of the dyld shared cache image. If filePath is a Mach-O file, this option is ignored.")
    var cacheImageName: String?

    @Flag(name: [.customLong("dyld-shared-cache")], help: "The flag to indicate if the Mach-O file is a dyld shared cache.")
    var isDyldSharedCache: Bool = false

    @Flag(help: "Use the current dyld shared cache instead of the specified one. This option is ignored if filePath is a Mach-O file.")
    var usesSystemDyldSharedCache: Bool = false

    @Option(name: .shortAndLong, help: "The architecture of the Mach-O file. If not specified, the current architecture will be used.")
    var architecture: Architecture?

    /// How to name the analyzed image in a diagnostic: the spelling the caller
    /// actually typed, so the note points back at their own command line rather
    /// than at an install name they never mentioned. (For a plain executable
    /// the Mach-O's own `imagePath` is often the empty string anyway.)
    var imageDescription: String {
        cacheImageName ?? cacheImagePath ?? filePath ?? "the system dyld shared cache"
    }
}
