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

private func consumeFieldDiagnostics<Class: ObjCClassProtocol>(
    objcClass: Class,
    file: MachOFile,
    image: MachOImage
) -> [ObjCMetadataFieldDiagnostic] {
    objcClass.readInfo(in: file).fieldDiagnostics
        + objcClass.readInfo(in: image).fieldDiagnostics
}

private func inspectFieldDiagnostic(
    _ diagnostic: ObjCMetadataFieldDiagnostic
) -> Int {
    let subject: ObjCMetadataFieldDiagnostic.Subject
    let failure: ObjCMetadataFieldDiagnostic.Failure
    let index: Int
    switch diagnostic {
    case .classROData(let details):
        subject = details.subject
        failure = details.failure
        index = details.classObjectOffset
        switch details.role {
        case .instance, .metaclass:
            break
        }
    case .ivarOffset(let details):
        subject = details.subject
        failure = details.failure
        index = details.index
        _ = details.name
    }

    switch subject {
    case .namedClass(let name, let objectOffset):
        _ = name
        _ = objectOffset
    case .classObject(let offset):
        _ = offset
    }
    switch failure {
    case .unresolvedRebase, .missingBackingData:
        break
    case .unreadableFileRange(let offset, let byteCount):
        _ = offset
        _ = byteCount
    case .unreadableImageRange(let address, let byteCount):
        _ = address
        _ = byteCount
    }
    return index
}
