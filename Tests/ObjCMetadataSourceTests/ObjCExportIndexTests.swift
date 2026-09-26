import Testing
import Foundation
import MachOKit
import MachOKitExtensions
import MachOObjCSection
import ObjCDump
import ObjCMetadataSource
import ObjectiveC

/// The two symbol prefixes under test, spelled out here rather than reached
/// for through the implementation: a test that borrowed the constant it is
/// checking would pass just as happily with the wrong one.
private enum ExportSymbolPrefix {
    static let objcClass = "_OBJC_CLASS_$_"
    static let objcIvar = "_OBJC_IVAR_$_"
}

/// A framework that is certain to be loaded in the test process, carries a
/// large Objective-C surface, and mixes public and internal classes.
private func loadedFoundationImage() throws -> MachOImage {
    try #require(MachOImage(name: "Foundation"), "Foundation is not loaded in the test process")
}

/// Every class record of an image, 64-bit and 32-bit lists both, lazy and
/// non-lazy both — the same union `ObjCInterfaceIndexer` walks.
private func allClassRecords(in machO: MachOImage) -> [any ObjCClassProtocol] {
    (machO.objc.classes64 ?? []) as [any ObjCClassProtocol]
        + ((machO.objc.classes32 ?? []) as [any ObjCClassProtocol])
        + ((machO.objc.nonLazyClasses64 ?? []) as [any ObjCClassProtocol])
        + ((machO.objc.nonLazyClasses32 ?? []) as [any ObjCClassProtocol])
}

/// The running system's dyld shared cache, whichever architecture this machine
/// is. `nil` when there is none to read, which gates the cache tests off
/// rather than failing them.
private func systemDyldSharedCachePath() -> String? {
    ["arm64e", "x86_64h", "x86_64"]
        .map { "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_\($0)" }
        .first { FileManager.default.fileExists(atPath: $0) }
}

/// Foundation as read out of the shared cache **as a file** — the `MachOFile`
/// path, which reaches the export trie through an entirely different route
/// than the in-process `MachOImage` one.
private func foundationFileInSharedCache() throws -> MachOFile {
    let cachePath = try #require(systemDyldSharedCachePath())
    let cache = try FullDyldCache(url: URL(fileURLWithPath: cachePath))
    return try #require(
        cache.machOFiles().first { $0.imagePath.hasSuffix("/Foundation") },
        "no Foundation image in the shared cache"
    )
}

@Suite("ObjC export index")
struct ObjCExportIndexTests {

    // MARK: - Symbol Spelling

    /// Pins the one assumption the whole index rests on: MachOKit hands back
    /// export trie labels verbatim, so the names carry the linker's leading
    /// underscore. If a MachOKit release ever starts stripping it, every
    /// lookup would silently miss and every class would read as
    /// `notExported` — a wrong answer delivered confidently, with no crash
    /// and no empty result to notice.
    @Test("Export trie symbol names carry the linker's leading underscore")
    func exportTrieSymbolNamesCarryLeadingUnderscore() throws {
        let foundation = try loadedFoundationImage()
        let exportedNames = Set(foundation.exportedSymbols.map(\.name))

        #expect(exportedNames.contains("\(ExportSymbolPrefix.objcClass)NSString"))
        #expect(!exportedNames.contains("OBJC_CLASS_$_NSString"))
    }

    // MARK: - Verdict Spread

    /// A real framework must produce *both* verdicts. All-exported means the
    /// prefix matched something it should not have, or the negative branch is
    /// unreachable; all-unexported means the prefix is wrong and nothing ever
    /// matches. Either way the index would be useless while still returning
    /// plausible-looking values, which is exactly what a count-based check
    /// catches and a spot-check does not.
    @Test("A real framework yields both exported and unexported classes")
    func realFrameworkYieldsBothVerdicts() throws {
        let foundation = try loadedFoundationImage()
        let exportIndex = ObjCExportIndex(machO: foundation)

        var exportedCount = 0
        var notExportedCount = 0
        var noInformationCount = 0

        for classRecord in allClassRecords(in: foundation) {
            guard let className = foundation.objcClassName(of: classRecord) else { continue }
            switch exportIndex.exportStatus(ofClassNamed: className) {
            case .exported: exportedCount += 1
            case .notExported: notExportedCount += 1
            case .imageHasNoExportInformation: noInformationCount += 1
            }
        }

        #expect(exportedCount > 0, "no class of Foundation read as exported")
        #expect(notExportedCount > 0, "no class of Foundation read as unexported")
        #expect(noInformationCount == 0, "Foundation must have export information")
    }

    /// Classes Foundation itself exports, and one that cannot exist.
    @Test("A known public class is exported and an absent one is not")
    func knownPublicClassIsExported() throws {
        let foundation = try loadedFoundationImage()
        let exportIndex = ObjCExportIndex(machO: foundation)

        #expect(exportIndex.exportStatus(ofClassNamed: "NSString") == .exported)
        #expect(exportIndex.exportStatus(ofClassNamed: "NSError") == .exported)
        #expect(exportIndex.exportStatus(ofClassNamed: "NSBundle") == .exported)
        #expect(
            exportIndex.exportStatus(ofClassNamed: "ZZZNoSuchClassCouldPossiblyExist") == .notExported
        )
    }

    /// Pins the per-image semantics, and the trap that comes with them.
    ///
    /// The index answers "does *this* image export this symbol", never "is
    /// this class public anywhere". `NSArray` is as public as a class gets,
    /// yet Foundation returns ``ObjCExportStatus/notExported`` for it — the
    /// class is defined and exported by CoreFoundation, a consequence of
    /// toll-free bridging (`NSDate`, `NSURL` and `NSDictionary` likewise).
    ///
    /// This is correct, and it is why a caller must only ask about classes the
    /// image itself defines. Asking about a superclass name or an adopted
    /// class from a class list would routinely land on another image's class
    /// and read back a "not exported" that means nothing of the sort.
    @Test("A class defined in another image reads as unexported here")
    func classDefinedInAnotherImageReadsAsUnexportedHere() throws {
        let foundation = try loadedFoundationImage()
        let coreFoundation = try #require(
            MachOImage(name: "CoreFoundation"),
            "CoreFoundation is not loaded in the test process"
        )

        #expect(ObjCExportIndex(machO: foundation).exportStatus(ofClassNamed: "NSArray") == .notExported)
        #expect(ObjCExportIndex(machO: coreFoundation).exportStatus(ofClassNamed: "NSArray") == .exported)
    }

    // MARK: - Address Cross-Check

    /// The load-bearing test. Asserting "the symbol is findable" is circular —
    /// the index was built from those very symbols. Asserting that the
    /// exported symbol sits **at the class record's own address** is not: it
    /// fails if the prefix is stripped by the wrong number of characters, if
    /// the name is assembled wrongly, or if two different offset conventions
    /// got mixed. Restricted to classes the index calls exported, since an
    /// unexported one has no symbol to compare against.
    @Test("An exported class symbol sits at that class record's own address")
    func exportedClassSymbolSitsAtClassRecordAddress() throws {
        let foundation = try loadedFoundationImage()
        let exportIndex = ObjCExportIndex(machO: foundation)

        var symbolOffsetByClassName: [String: Int] = [:]
        for exportedSymbol in foundation.exportedSymbols
        where exportedSymbol.name.hasPrefix(ExportSymbolPrefix.objcClass) {
            guard let symbolOffset = exportedSymbol.offset else { continue }
            let className = String(
                exportedSymbol.name.dropFirst(ExportSymbolPrefix.objcClass.count)
            )
            symbolOffsetByClassName[className] = symbolOffset
        }

        var comparedCount = 0
        for classRecord in allClassRecords(in: foundation) {
            guard let className = foundation.objcClassName(of: classRecord),
                  exportIndex.exportStatus(ofClassNamed: className) == .exported,
                  let symbolOffset = symbolOffsetByClassName[className]
            else { continue }

            #expect(
                symbolOffset == classRecord.offset,
                "class \(className): export trie says \(symbolOffset), class record is at \(classRecord.offset)"
            )
            comparedCount += 1
        }

        #expect(comparedCount > 0, "nothing was cross-checked")
    }

    // MARK: - Ivars

    /// Runs the ivar claim backwards, which is what makes it worth writing:
    /// take every `_OBJC_IVAR_$_<class>.<ivar>` the trie exports, split it,
    /// and require that the image really does declare that ivar on *that*
    /// class. It fails if `ObjCClassInfo.ivars` turned out to include
    /// inherited ivars (the symbol belongs to the declaring class, so the
    /// mapping would not line up), and it fails if the qualified key is
    /// assembled with the wrong separator or the wrong class name.
    ///
    /// Only symbols whose class this image also defines are checked — a
    /// framework can export an ivar offset for a class that lives elsewhere.
    @Test("Every exported ivar symbol names an ivar its class actually declares")
    func exportedIvarSymbolsNameDeclaredIvars() throws {
        let foundation = try loadedFoundationImage()

        var declaredIvarNamesByClassName: [String: Set<String>] = [:]
        for classRecord in allClassRecords(in: foundation) {
            guard let className = foundation.objcClassName(of: classRecord),
                  let classInfo = foundation.objcClassInfo(of: classRecord)
            else { continue }
            declaredIvarNamesByClassName[className] = Set(classInfo.ivars.map(\.name))
        }

        var checkedCount = 0
        for exportedSymbol in foundation.exportedSymbols
        where exportedSymbol.name.hasPrefix(ExportSymbolPrefix.objcIvar) {
            let qualifiedName = String(
                exportedSymbol.name.dropFirst(ExportSymbolPrefix.objcIvar.count)
            )
            // Split on the first `.`: neither an ObjC class name nor a Swift
            // mangled runtime name contains one, so the first separator is the
            // one between class and ivar.
            guard let separatorIndex = qualifiedName.firstIndex(of: ".") else { continue }
            let className = String(qualifiedName[qualifiedName.startIndex..<separatorIndex])
            let ivarName = String(qualifiedName[qualifiedName.index(after: separatorIndex)...])

            guard let declaredIvarNames = declaredIvarNamesByClassName[className] else { continue }
            #expect(
                declaredIvarNames.contains(ivarName),
                "\(className) exports an offset for ivar \(ivarName) but does not declare it"
            )
            checkedCount += 1
        }

        #expect(checkedCount > 0, "no exported ivar symbol was cross-checked")
    }

    /// The ivar lookup must be qualified by the declaring class, not by the
    /// ivar name alone. Feeding a real ivar name under a class that does not
    /// declare it has to come back negative — otherwise the key is being built
    /// from the ivar name only, and every class would inherit every verdict.
    @Test("An ivar lookup is qualified by its declaring class")
    func ivarLookupIsQualifiedByDeclaringClass() throws {
        let foundation = try loadedFoundationImage()
        let exportIndex = ObjCExportIndex(machO: foundation)

        var exportedIvar: (className: String, ivarName: String)?
        for exportedSymbol in foundation.exportedSymbols
        where exportedSymbol.name.hasPrefix(ExportSymbolPrefix.objcIvar) {
            let qualifiedName = String(
                exportedSymbol.name.dropFirst(ExportSymbolPrefix.objcIvar.count)
            )
            guard let separatorIndex = qualifiedName.firstIndex(of: ".") else { continue }
            exportedIvar = (
                className: String(qualifiedName[qualifiedName.startIndex..<separatorIndex]),
                ivarName: String(qualifiedName[qualifiedName.index(after: separatorIndex)...])
            )
            break
        }

        let ivar = try #require(exportedIvar, "Foundation exports no ivar offset symbol")

        #expect(
            exportIndex.exportStatus(ofIvarNamed: ivar.ivarName, inClassNamed: ivar.className) == .exported
        )
        #expect(
            exportIndex.exportStatus(
                ofIvarNamed: ivar.ivarName,
                inClassNamed: "ZZZNoSuchClassCouldPossiblyExist"
            ) == .notExported
        )
    }

    // MARK: - dyld Shared Cache, File Mode

    /// The one that decides whether this feature is worth anything to
    /// RuntimeViewer, whose main subject is cache images read as files.
    ///
    /// `MachOFile` reaches the export trie by a completely different route
    /// than `MachOImage`: for an image inside the shared cache the linkedit
    /// segment is not in the file at all, and MachOKit has to redirect the
    /// read through the cache's own segments
    /// (`MachOFile._fileSliceForLinkEditData`). If that redirect ever fails,
    /// the trie reads as empty and every class of every cache image comes back
    /// ``ObjCExportStatus/imageHasNoExportInformation`` — the feature silently
    /// does nothing at all on its primary target.
    @Test(
        "A dyld shared cache image yields export information in file mode",
        .enabled(if: systemDyldSharedCachePath() != nil)
    )
    func cacheImageYieldsExportInformationInFileMode() throws {
        let foundationFile = try foundationFileInSharedCache()
        let exportIndex = ObjCExportIndex(machO: foundationFile)

        #expect(exportIndex.exportStatus(ofClassNamed: "NSString") == .exported)
        #expect(exportIndex.exportStatus(ofClassNamed: "NSError") == .exported)
        #expect(
            exportIndex.exportStatus(ofClassNamed: "ZZZNoSuchClassCouldPossiblyExist") == .notExported
        )
    }

    /// The same image judged both ways must agree on every class. This is what
    /// catches an implementation that leans on something only one mode has —
    /// and it compares whole verdict sets, so a mode that quietly returns
    /// "no information" for everything cannot pass by being trivially
    /// consistent with itself.
    @Test(
        "File mode and image mode agree on every class",
        .enabled(if: systemDyldSharedCachePath() != nil)
    )
    func fileModeAndImageModeAgreeOnEveryClass() throws {
        let foundationImage = try loadedFoundationImage()
        let foundationFile = try foundationFileInSharedCache()

        let imageExportIndex = ObjCExportIndex(machO: foundationImage)
        let fileExportIndex = ObjCExportIndex(machO: foundationFile)

        var comparedCount = 0
        var exportedCount = 0
        for classRecord in allClassRecords(in: foundationImage) {
            guard let className = foundationImage.objcClassName(of: classRecord) else { continue }
            let fromImage = imageExportIndex.exportStatus(ofClassNamed: className)
            let fromFile = fileExportIndex.exportStatus(ofClassNamed: className)
            #expect(fromImage == fromFile, "class \(className) differs between modes")
            if fromImage == .exported { exportedCount += 1 }
            comparedCount += 1
        }

        #expect(comparedCount > 0, "no class was compared")
        #expect(exportedCount > 0, "both modes agreed on nothing being exported")
    }
}
