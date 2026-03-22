import XCTest
@testable import MachOObjCSection
@testable import MachOKit

final class ObjCPointerListResolverTests: XCTestCase {
    func testResolvePrefersResolvedRebase() {
        let unresolved = UnresolvedValue(fieldOffset: 0x40, value: 0x1234)

        let result = ObjCPointerListResolver.resolve(
            unresolved: unresolved,
            resolveRebase: { input in
                XCTAssertEqual(input.fieldOffset, unresolved.fieldOffset)
                return .init(address: 0x200, offset: 0x180)
            },
            resolveBind: { _ in
                XCTFail("bind resolution should not be used when rebase succeeds")
                return nil
            },
            resolveSelfBind: { _, _ in
                XCTFail("self bind resolution should not be used when rebase succeeds")
                return nil
            },
            resolveRaw: { _ in
                XCTFail("raw resolution should not be used when rebase succeeds")
                return nil
            }
        )

        assertResolved(result, address: 0x200, offset: 0x180)
    }

    func testResolveHandlesSelfImageBind() {
        let unresolved = UnresolvedValue(fieldOffset: 0x88, value: 0)

        let result = ObjCPointerListResolver.resolve(
            unresolved: unresolved,
            resolveRebase: { _ in nil },
            resolveBind: { fileOffset in
                XCTAssertEqual(fileOffset, unresolved.fieldOffset)
                return .init(
                    libraryOrdinalType: .dylib_self,
                    symbolName: "_OBJC_CLASS_$_Resolved",
                    addend: 0x10
                )
            },
            resolveSelfBind: { symbolName, addend in
                XCTAssertEqual(symbolName, "_OBJC_CLASS_$_Resolved")
                XCTAssertEqual(addend, 0x10)
                return .init(address: 0x500, offset: 0x500)
            },
            resolveRaw: { _ in
                XCTFail("raw resolution should not be used when bind succeeds")
                return nil
            }
        )

        assertResolved(result, address: 0x500, offset: 0x500)
    }

    func testResolveSkipsExternalBind() {
        let result = ObjCPointerListResolver.resolve(
            unresolved: .init(fieldOffset: 0x20, value: 0),
            resolveRebase: { _ in nil },
            resolveBind: { _ in
                .init(
                    libraryOrdinalType: .dylib_main_executable,
                    symbolName: "_OBJC_CLASS_$_External",
                    addend: 0
                )
            },
            resolveSelfBind: { _, _ in
                XCTFail("external binds must not resolve as self-image symbols")
                return nil
            },
            resolveRaw: { _ in
                XCTFail("external binds must not fall back to raw pointers")
                return nil
            }
        )

        guard case let .skippedExternalBind(symbolName) = result else {
            return XCTFail("expected skippedExternalBind")
        }
        XCTAssertEqual(symbolName, "_OBJC_CLASS_$_External")
    }

    func testResolveReportsUnresolvedSelfBind() {
        let result = ObjCPointerListResolver.resolve(
            unresolved: .init(fieldOffset: 0x20, value: 0),
            resolveRebase: { _ in nil },
            resolveBind: { _ in
                .init(
                    libraryOrdinalType: .dylib_self,
                    symbolName: "_OBJC_CLASS_$_Missing",
                    addend: 0
                )
            },
            resolveSelfBind: { _, _ in nil },
            resolveRaw: { _ in
                XCTFail("failed self binds must not fall back to raw pointers")
                return nil
            }
        )

        guard case let .unresolvedBind(symbolName) = result else {
            return XCTFail("expected unresolvedBind")
        }
        XCTAssertEqual(symbolName, "_OBJC_CLASS_$_Missing")
    }

    private func assertResolved(
        _ result: ObjCPointerListResolveResult,
        address: UInt64,
        offset: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .resolved(resolved) = result else {
            return XCTFail("expected resolved result", file: file, line: line)
        }
        XCTAssertEqual(resolved.address, address, file: file, line: line)
        XCTAssertEqual(resolved.offset, offset, file: file, line: line)
    }
}
