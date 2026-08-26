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

private func consumeLoadedRootDiagnostics(
    image: MachOImage
) -> [ObjCMetadataTableDiagnostic] {
    image.objc.readRoots().tableDiagnostics
}

private func inspectTableDiagnostic(
    _ diagnostic: ObjCMetadataTableDiagnostic
) -> Int {
    switch diagnostic.owner {
    case let .member(subject, kind):
        inspectMetadataSubject(subject)
        switch kind {
        case .ivar,
             .instanceMethod,
             .classMethod,
             .optionalInstanceMethod,
             .optionalClassMethod,
             .instanceProperty,
             .classProperty:
            break
        }
    case let .loadedImageRoot(section, pointerWidth):
        switch section {
        case .classList,
             .nonLazyClassList,
             .protocolList,
             .categoryList,
             .nonLazyCategoryList,
             .categoryList2:
            break
        }
        switch pointerWidth {
        case .bits32, .bits64:
            break
        }
    case let .loadedRelationship(subject, role):
        inspectMetadataSubject(subject)
        switch role {
        case .metaclass, .superclass, .categoryClass, .categoryStubClass:
            break
        }
    }

    let provenance: ObjCMetadataTableDiagnostic.Provenance
    let index: Int
    switch diagnostic.site {
    case .table(let value), .relationship(let value):
        provenance = value
        index = 0
    case let .entry(entryIndex, value):
        provenance = value
        index = entryIndex
    }
    _ = provenance.logicalOffset
    _ = provenance.fileOffset
    _ = provenance.imageAddress

    switch diagnostic.failure {
    case .unsupportedListEncoding:
        break
    case .invalidListOffset(let offset),
         .invalidSignedElementCount(let offset):
        _ = offset
    case .invalidElementCount(let count),
         .invalidElementStride(let count):
        _ = count
    case let .elementStrideTooSmall(advertised, minimum):
        _ = advertised
        _ = minimum
    case let .unexpectedElementStride(advertised, expected):
        _ = advertised
        _ = expected
    case let .misalignedTableOffset(offset, requiredAlignment):
        _ = offset
        _ = requiredAlignment
    case let .misalignedTableAddress(address, requiredAlignment):
        _ = address
        _ = requiredAlignment
    case let .excessiveElementCount(actual, maximum),
         let .excessiveByteCount(actual, maximum):
        _ = actual
        _ = maximum
    case let .byteCountOverflow(elementCount, elementSize):
        _ = elementCount
        _ = elementSize
    case let .rangeOverflow(startOffset, byteCount):
        _ = startOffset
        _ = byteCount
    case let .unreadableFileRange(offset, byteCount):
        _ = offset
        _ = byteCount
    case let .unreadableImageRange(address, byteCount),
         let .unreadableReferencedLayout(address, byteCount):
        _ = address
        _ = byteCount
    case let .invalidSectionByteCount(byteCount, pointerSize):
        _ = byteCount
        _ = pointerSize
    case let .invalidSectionCoordinates(
        sectionAddress,
        sectionSize,
        sectionFileOffset,
        segmentAddress,
        segmentSize,
        segmentFileOffset,
        segmentFileSize
    ):
        _ = sectionAddress
        _ = sectionSize
        _ = sectionFileOffset
        _ = segmentAddress
        _ = segmentSize
        _ = segmentFileOffset
        _ = segmentFileSize
    case let .invalidLoadedSectionAddress(imageBase, segmentVirtualMemoryOffset):
        _ = imageBase
        _ = segmentVirtualMemoryOffset
    case .invalidPointer(let rawValue):
        _ = rawValue
    case .missingReferencedImage(let address):
        _ = address
    case let .invalidEntryArithmetic(baseAddress, targetAddress):
        _ = baseAddress
        _ = targetAddress
    }
    return index
}

private func inspectMetadataSubject(
    _ subject: ObjCMetadataTableDiagnostic.MetadataSubject
) {
    switch subject {
    case .class(let name), .protocol(let name):
        _ = name
    case let .category(className, name):
        _ = className
        _ = name
    }
}
