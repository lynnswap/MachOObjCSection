import Testing
import Foundation
import MachOKit
import MachOKitExtensions
import MachOObjCSection
import ObjCDeclarationRendering
import ObjCDump
import ObjCIndexing
import ObjCInterface
import ObjCMetadataSource
import ObjectiveC
import Semantic

/// Anchors the test bundle's own Mach-O so a test can reach it both ways.
///
/// This is the one binary available to the test process that is *both* loaded
/// (so `MachOImage` can see it) and present on disk as a standalone file (so
/// `MachOFile` can open it). System frameworks are not: their install paths
/// live only inside the dyld shared cache, with no file to open.
@objc(ObjCMetadataSourceFixtureHost)
final class ObjCMetadataSourceFixtureHost: NSObject {
    @objc var fixtureCount: Int = 0
    @objc func fixtureMethod(withValue value: Int) -> Int { value }
}

/// Indexes one binary twice — once as a file on disk, once as an image in this
/// process — and holds both results side by side.
///
/// The whole point of `ObjCMetadataSource` is that these two paths produce the
/// same answer, which is exactly the kind of claim that quietly stops being
/// true. Preparing an indexer is slow enough that the pair is built once and
/// shared by every test below.
private actor DualModeFixture {
    static let shared = DualModeFixture()

    enum FixtureError: Swift.Error {
        case imagePathUnavailable
        case imageNotLoaded
        case noMatchingArchitecture
    }

    /// `@unchecked Sendable` for the same reason `ObjCInterfaceIndexer` is:
    /// everything in here is immutable once `prepare()` has returned, and the
    /// tests only read it.
    struct Prepared: @unchecked Sendable {
        let imagePath: String
        let image: MachOImage
        let file: MachOFile
        let imageIndexer: ObjCInterfaceIndexer<MachOImage>
        let fileIndexer: ObjCInterfaceIndexer<MachOFile>
        let imageBuilder: ObjCInterfaceBuilder<MachOImage>
        let fileBuilder: ObjCInterfaceBuilder<MachOFile>
    }

    private var cached: Prepared?

    func load() async throws -> Prepared {
        if let cached { return cached }

        guard let imageNamePointer = class_getImageName(ObjCMetadataSourceFixtureHost.self) else {
            throw FixtureError.imagePathUnavailable
        }
        let imagePath = String(cString: imageNamePointer)

        // Matched by name first: `MachOImage.path` is resolved by dyld and does
        // not always come back byte-identical to what `class_getImageName`
        // reports, so an equality check on the full path is the fallback rather
        // than the rule.
        let imageName = (imagePath as NSString).lastPathComponent
        guard let image = MachOImage(name: imageName) ?? MachOImage.images.first(where: { $0.path == imagePath }) else {
            throw FixtureError.imageNotLoaded
        }

        let file: MachOFile
        switch try MachOKit.loadFromFile(url: URL(fileURLWithPath: imagePath)) {
        case .machO(let machOFile):
            file = machOFile
        case .fat(let fatFile):
            guard let matching = try fatFile.machOFiles().first(where: { $0.header.cpu == image.header.cpu }) else {
                throw FixtureError.noMatchingArchitecture
            }
            file = matching
        }

        let imageIndexer = ObjCInterfaceIndexer(machO: image, imagePath: imagePath)
        try await imageIndexer.prepare()

        let fileIndexer = ObjCInterfaceIndexer(machO: file, imagePath: imagePath)
        try await fileIndexer.prepare()

        let prepared = Prepared(
            imagePath: imagePath,
            image: image,
            file: file,
            imageIndexer: imageIndexer,
            fileIndexer: fileIndexer,
            imageBuilder: ObjCInterfaceBuilder(indexer: imageIndexer, machO: image),
            fileBuilder: ObjCInterfaceBuilder(indexer: fileIndexer, machO: file)
        )
        cached = prepared
        return prepared
    }
}

@Suite("ObjC metadata source parity")
struct ObjCMetadataSourceTests {
    /// The generation options used for every parity check below.
    ///
    /// `stripOverrides` is deliberately left off: it works off the superclass
    /// chain, and the two modes resolve chains to different depths for a
    /// standalone file — see ``superclassChainIsShorterInFileMode``. Every
    /// other switch is on, so the comparison exercises the strip and comment
    /// paths rather than just the bare rendering.
    private static let parityOptions = ObjCGenerationOptions(
        stripProtocolConformance: true,
        stripOverrides: false,
        stripSynthesizedIvars: true,
        stripSynthesizedMethods: true,
        stripCtorMethod: true,
        stripDtorMethod: true,
        addIvarOffsetComments: true,
        addPropertyAttributesComments: true,
        addMethodIMPAddressComments: true,
        addPropertyAccessorAddressComments: true
    )

    // MARK: - Index Parity

    @Test("Both modes find the same classes")
    func classNameParity() async throws {
        let fixture = try await DualModeFixture.shared.load()
        #expect(Set(fixture.imageIndexer.classNames) == Set(fixture.fileIndexer.classNames))
        #expect(fixture.imageIndexer.classNames.contains("ObjCMetadataSourceFixtureHost"))
    }

    @Test("Both modes find the same protocols")
    func protocolNameParity() async throws {
        let fixture = try await DualModeFixture.shared.load()
        #expect(Set(fixture.imageIndexer.protocolNames) == Set(fixture.fileIndexer.protocolNames))
    }

    @Test("Both modes find the same categories")
    func categoryNameParity() async throws {
        let fixture = try await DualModeFixture.shared.load()
        #expect(Set(fixture.imageIndexer.categoryNames) == Set(fixture.fileIndexer.categoryNames))
    }

    @Test("Both modes harvest the same C struct and union definitions")
    func structAndUnionParity() async throws {
        let fixture = try await DualModeFixture.shared.load()
        #expect(Set(fixture.imageIndexer.structNames) == Set(fixture.fileIndexer.structNames))
        #expect(Set(fixture.imageIndexer.unionNames) == Set(fixture.fileIndexer.unionNames))
    }

    // MARK: - Rendering Parity

    @Test("A class renders identically in both modes")
    func classRenderingParity() async throws {
        let fixture = try await DualModeFixture.shared.load()
        let name = "ObjCMetadataSourceFixtureHost"

        let fromImage = try #require(
            fixture.imageBuilder.classInterface(named: name, options: Self.parityOptions)
        )
        let fromFile = try #require(
            fixture.fileBuilder.classInterface(named: name, options: Self.parityOptions)
        )

        #expect(fromImage.string == fromFile.string)
        // The fixture's own members must actually be in there, otherwise this
        // would pass just as well on two empty renderings.
        #expect(fromImage.string.contains("fixtureCount"))
        #expect(fromImage.string.contains("fixtureMethodWithValue:"))
    }

    /// Renders every Objective-C class in the binary both ways and compares
    /// the full output, ivar offsets and IMP addresses included.
    ///
    /// Classes emitted for *pure* Swift types are skipped, because their
    /// `ivar_t` records are the one thing the two readers genuinely disagree
    /// about, in two ways: file mode resolves the offset rebase and reads a
    /// value where image mode reads zero, and image mode drops ivars whose
    /// offset or type it cannot read at all, leaving it with a shorter list.
    /// Both come out of upstream `ObjCIvarProtocol` — this layer forwards to
    /// the same functions it always called — so they are excluded rather than
    /// asserted, which keeps this test honest without freezing upstream
    /// behaviour in place. `@objc` Swift classes with an explicit runtime name
    /// carry ordinary Objective-C ivar records and are compared in full.
    @Test("Every ObjC class in the binary renders identically in both modes")
    func wholeBinaryRenderingParity() async throws {
        let fixture = try await DualModeFixture.shared.load()
        var comparedCount = 0

        for name in fixture.imageIndexer.classNames.sorted() where !name.hasPrefix("_Tt") {
            let fromImage = fixture.imageBuilder.classInterface(named: name, options: Self.parityOptions)
            let fromFile = fixture.fileBuilder.classInterface(named: name, options: Self.parityOptions)
            #expect(fromImage?.string == fromFile?.string, "class \(name) differs between modes")
            comparedCount += 1
        }

        // Guards against the loop quietly comparing nothing.
        #expect(comparedCount > 0)
    }

    // MARK: - IMP Addresses

    /// The raw `imp` field means different things in the two modes — an
    /// absolute runtime pointer versus an already-computed offset — so the
    /// resolution is a protocol requirement rather than shared arithmetic. If
    /// either conformance got its normalization wrong, the two would disagree
    /// here even though the rest of the rendering matched.
    @Test("IMP addresses resolve to the same virtual address in both modes")
    func impAddressParity() async throws {
        let fixture = try await DualModeFixture.shared.load()

        let name = "ObjCMetadataSourceFixtureHost"
        let classInfo = try #require(fixture.imageIndexer.classGroup(forName: name)?.info.first)
        let method = try #require(classInfo.methods.first { $0.name == "fixtureMethodWithValue:" })
        #expect(method.imp != 0)

        let fileClassInfo = try #require(fixture.fileIndexer.classGroup(forName: name)?.info.first)
        let fileMethod = try #require(fileClassInfo.methods.first { $0.name == "fixtureMethodWithValue:" })

        let imageAddress = try #require(fixture.image.objcResolvedIMPAddress(forRawValue: method.imp))
        let fileAddress = try #require(fixture.file.objcResolvedIMPAddress(forRawValue: fileMethod.imp))
        #expect(imageAddress == fileAddress)
    }

    @Test("A zero IMP resolves to nothing in both modes")
    func zeroIMPIsRejected() async throws {
        let fixture = try await DualModeFixture.shared.load()
        #expect(fixture.image.objcResolvedIMPAddress(forRawValue: 0) == nil)
        #expect(fixture.file.objcResolvedIMPAddress(forRawValue: 0) == nil)
        #expect(fixture.image.formattedAddress(forRawValue: 0) == nil)
        #expect(fixture.file.formattedAddress(forRawValue: 0) == nil)
    }

    // MARK: - Documented Difference

    /// The one difference the two modes are *allowed* to have, pinned down so
    /// it stays a known limitation rather than turning into a surprise.
    ///
    /// `NSObject` lives in the shared cache, not next to this bundle on disk,
    /// so file mode cannot follow the fixture's superclass pointer out of the
    /// binary and the chain stops at the class itself. Image mode has every
    /// dependency mapped in and walks all the way up.
    @Test("The superclass chain is shorter in file mode")
    func superclassChainIsShorterInFileMode() async throws {
        let fixture = try await DualModeFixture.shared.load()
        let name = "ObjCMetadataSourceFixtureHost"

        let imageChain = try #require(fixture.imageIndexer.classGroup(forName: name)?.info)
        let fileChain = try #require(fixture.fileIndexer.classGroup(forName: name)?.info)

        #expect(imageChain.count > 1)
        #expect(imageChain.dropFirst().contains { $0.name == "NSObject" })
        #expect(fileChain.count == 1)
    }

    /// And the consequence of it: `stripOverrides` has nothing to strip when
    /// the chain never reached the superclass declaring the member.
    @Test("stripOverrides strips less in file mode")
    func stripOverridesStripsLessInFileMode() async throws {
        let fixture = try await DualModeFixture.shared.load()
        let name = "ObjCMetadataSourceFixtureHost"
        let options = ObjCGenerationOptions(stripOverrides: true)

        let fromImage = try #require(fixture.imageBuilder.classInterface(named: name, options: options))
        let fromFile = try #require(fixture.fileBuilder.classInterface(named: name, options: options))

        // Both still describe the same class; file mode simply keeps members
        // image mode recognized as inherited.
        #expect(fromImage.string.count <= fromFile.string.count)
    }
}
