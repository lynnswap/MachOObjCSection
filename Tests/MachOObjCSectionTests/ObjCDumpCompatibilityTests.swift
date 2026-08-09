import XCTest
@testable import MachOObjCSection

final class ObjCDumpCompatibilityTests: XCTestCase {
    func testPropertyAdapterPreservesAttributesForHeaderRendering() {
        let property = ObjCProperty(
            name: "handler",
            attributes: "T@?<v@?i>,C"
        )

        let info = property.info()

        XCTAssertEqual(info.name, "handler")
        XCTAssertEqual(info.attributesString, "T@?<v@?i>,C")
        XCTAssertEqual(info.headerString, "@property(copy) void (^handler)(int);")
    }

    func testMethodAdapterPreservesSelectorWhenEncodingIsUnknown() {
        let method = ObjCMethod(
            name: "doThing:withValue:",
            types: "!",
            imp: 0x1234
        )

        let info = method.info()

        XCTAssertEqual(info.name, "doThing:withValue:")
        XCTAssertEqual(info.typeEncoding, "!")
        XCTAssertFalse(info.isClassMethod)
        XCTAssertEqual(
            info.headerString,
            "- (void * /* unknown */)doThing:"
                + "(void * /* unknown */)arg0 withValue:"
                + "(void * /* unknown */)arg1;"
                + " /* unknown method encoding: ! */"
        )
    }
}
