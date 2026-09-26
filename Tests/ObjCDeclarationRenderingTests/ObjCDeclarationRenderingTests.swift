import Testing
import Foundation
import MachOKit
import MachOObjCSection
import ObjCDump
import ObjCTypeDecodeKit
import Semantic
@testable import ObjCDeclarationRendering

/// Renders declarations out of an image that is already loaded into this very
/// process, so the tests need no fixture binary on disk.
@Suite("ObjC declaration rendering")
struct ObjCDeclarationRenderingTests {
    /// A class that is guaranteed to exist in Foundation and to have both ivars
    /// and methods, so one fixture exercises most of the renderer.
    private static let sampleClassName = "NSString"

    private static func foundationImage() throws -> MachOImage {
        try #require(MachOImage(name: "Foundation"))
    }

    private static func classInfo(named name: String) throws -> ObjCClassInfo {
        let machO = try foundationImage()
        let classes = try #require(machO.objc.classes64)
        for objcClass in classes {
            guard let info = objcClass.info(in: machO) else { continue }
            if info.name == name { return info }
        }
        Issue.record("\(name) not found in Foundation")
        throw RenderingTestError.classNotFound
    }

    @Test("Array fields retain their declarator without leaking into the next field")
    func arrayFieldDeclarator() throws {
        let context = ObjCRenderingContext(machO: try Self.foundationImage())
        let array = ObjCField(type: .array(type: .char, size: 16), name: "bytes")
        let scalar = ObjCField(type: .int, name: "count")
        #expect(array.semanticString(fallbackName: "unused", context: context).string == "char bytes[16];")
        #expect(scalar.semanticString(fallbackName: "unused", context: context).string == "int count;")
        #expect(context.currentArray == nil)
    }

    // `Swift.Error` spelled out: `Semantic` exports an `Error` component that
    // would otherwise shadow the protocol here.
    enum RenderingTestError: Swift.Error {
        case classNotFound
    }

    @Test("Renders an @interface block for a real class")
    func rendersInterfaceBlock() throws {
        let machO = try Self.foundationImage()
        let info = try Self.classInfo(named: Self.sampleClassName)

        let context = ObjCRenderingContext(machO: machO)
        let rendered = info.semanticString(using: context).string

        #expect(rendered.hasPrefix("@interface \(Self.sampleClassName)"))
        #expect(rendered.hasSuffix("@end"))
    }

    @Test("C type replacements substitute the rendered spelling")
    func appliesCTypeReplacements() throws {
        let machO = try Self.foundationImage()
        let info = try Self.classInfo(named: Self.sampleClassName)

        let plain = ObjCRenderingContext(machO: machO)
        let substituted = ObjCRenderingContext(
            machO: machO,
            cTypeReplacements: [.ulongLong: "NSUInteger"]
        )

        let plainOutput = info.semanticString(using: plain).string
        let substitutedOutput = info.semanticString(using: substituted).string

        // NSString exposes `unsigned long long` members (encoding parameters),
        // so the substitution must actually change the output.
        #expect(plainOutput.contains("unsigned long long"))
        #expect(!substitutedOutput.contains("unsigned long long"))
        #expect(substitutedOutput.contains("NSUInteger"))
    }

    @Test("Ivar offset comments fall back to a decimal offset")
    func ivarOffsetCommentDefaultsToDecimal() throws {
        let machO = try Self.foundationImage()
        // NSError has ivars; NSString's are hidden in the modern runtime.
        let info = try Self.classInfo(named: "NSError")

        var options = ObjCGenerationOptions.default
        options.addIvarOffsetComments = true
        let context = ObjCRenderingContext(machO: machO, options: options)

        let rendered = info.semanticString(using: context).string
        #expect(rendered.contains("offset: "))
    }

    @Test("Ivar offset comments use the supplied builder")
    func ivarOffsetCommentUsesBuilder() throws {
        let machO = try Self.foundationImage()
        let info = try Self.classInfo(named: "NSError")

        var options = ObjCGenerationOptions.default
        options.addIvarOffsetComments = true
        let context = ObjCRenderingContext(
            machO: machO,
            options: options,
            ivarOffsetCommentBuilder: { offset in "ivar @ 0x\(String(offset, radix: 16, uppercase: true))" }
        )

        let rendered = info.semanticString(using: context).string
        #expect(rendered.contains("ivar @ 0x"))
    }

    @Test("Generation options decode tolerantly from an empty object")
    func generationOptionsDecodesFromEmptyObject() throws {
        let decoded = try JSONDecoder().decode(
            ObjCGenerationOptions.self,
            from: Data("{}".utf8)
        )
        #expect(decoded == .default)
    }
}
