import Foundation
import Testing
import Semantic
import OutputTransformer
@testable import ObjCOutputTransformer

@Suite("ObjC output transformer")
struct ObjCOutputTransformerTests {
    private func semanticKeywords(_ keywords: [String]) -> SemanticString {
        var components: [AtomicComponent] = []
        for (keywordIndex, keyword) in keywords.enumerated() {
            if keywordIndex > 0 {
                components.append(AtomicComponent(string: " ", type: .standard))
            }
            components.append(AtomicComponent(string: keyword, type: .keyword))
        }
        return SemanticString(components: components)
    }

    @Test("CType replaces the longest pattern first")
    func cTypeReplacesLongestPatternFirst() {
        var module = Transformer.CType(isEnabled: true)
        module.replacements = Transformer.CType.Presets.stdint
        // "unsigned long long" must map to uint64_t, not "unsigned" + int64_t.
        #expect(module.transform(semanticKeywords(["unsigned", "long", "long"])).string == "uint64_t")
        #expect(module.transform(semanticKeywords(["long"])).string == "int64_t")
    }

    @Test("CType leaves non-keyword components untouched")
    func cTypeLeavesNonKeywordComponentsUntouched() {
        var module = Transformer.CType(isEnabled: true)
        module.replacements = [.double: "CGFloat"]
        let input = SemanticString(components: [
            AtomicComponent(string: "double", type: .keyword),
            AtomicComponent(string: " ", type: .standard),
            AtomicComponent(string: "value", type: .variable),
        ])
        #expect(module.transform(input).string == "CGFloat value")
    }

    @Test("CType replacements match a complete primitive and preserve qualifier spacing")
    func cTypeDoesNotReplacePartOfAnotherPrimitive() {
        let module = Transformer.CType(isEnabled: true, replacements: [.long: "Replacement", .char: "Byte", .double: "Float64"])
        #expect(module.transform(semanticKeywords(["long", "double"])).string == "long double")
        #expect(module.transform(semanticKeywords(["unsigned", "char"])).string == "unsigned char")
        #expect(module.transform(semanticKeywords(["const", "double"])).string == "const Float64")
        #expect(module.transform(semanticKeywords(["long"])).string == "Replacement")
    }

    @Test("ObjCIvarOffset renders its template")
    func objcIvarOffsetRendersTemplate() {
        let module = Transformer.ObjCIvarOffset(isEnabled: true)
        #expect(module.transform(.init(offset: 8)) == "offset: 0x8")
    }

    @Test("ObjCConfiguration tolerates missing keys and reports enablement")
    func objcConfigurationDecodingAndEnablement() throws {
        let decoded = try JSONDecoder().decode(
            Transformer.ObjCConfiguration.self,
            from: Data("{}".utf8)
        )
        #expect(decoded == .init())
        #expect(!decoded.hasEnabledModules)

        var configuration = Transformer.ObjCConfiguration()
        configuration.ivarOffset.isEnabled = true
        #expect(configuration.hasEnabledModules)
    }
}
