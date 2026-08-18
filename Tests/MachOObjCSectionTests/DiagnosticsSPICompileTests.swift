import Foundation
import MachOKit
@_spi(Diagnostics) import MachOObjCSection

// Compile-only consumer contract: this file intentionally does not import Core SPI
// or use @testable. A diagnostics consumer can reach all six root overloads from the
// distributed MachOObjCSection product.
private func consumeDiagnostics<
    Class: ObjCClassProtocol,
    Protocol: ObjCProtocolProtocol,
    Category: ObjCCategoryProtocol
>(
    objcClass: Class,
    objcProtocol: Protocol,
    category: Category,
    file: MachOFile,
    image: MachOImage
) -> [ObjCProtocolDiagnostic] {
    objcClass.readInfo(in: file).diagnostics
        + objcClass.readInfo(in: image).diagnostics
        + objcProtocol.readInfo(in: file).diagnostics
        + objcProtocol.readInfo(in: image).diagnostics
        + category.readInfo(in: file).diagnostics
        + category.readInfo(in: image).diagnostics
}

private func consumeMemberListDiagnostics<Class: ObjCClassProtocol>(
    objcClass: Class,
    file: MachOFile,
    image: MachOImage
) -> [ObjCMemberListDiagnostic] {
    objcClass.readInfo(in: file).memberListDiagnostics
        + objcClass.readInfo(in: image).memberListDiagnostics
}
