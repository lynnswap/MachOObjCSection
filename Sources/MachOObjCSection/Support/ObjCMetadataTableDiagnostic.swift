//
//  ObjCMetadataTableDiagnostic.swift
//  MachOObjCSection
//

import Foundation

/// A recoverable structural failure while reading an Objective-C metadata table.
///
/// The payload describes only stable source coordinates and parser limits. The library
/// does not log diagnostics; analysis tools decide how to cap, deduplicate, and persist
/// them.
@_spi(Diagnostics)
public struct ObjCMetadataTableDiagnostic: Sendable, Equatable {
    /// The metadata owner whose table or relationship was degraded.
    public let subject: Subject

    /// The member kind, or `nil` for image-root and relationship reads.
    public let kind: Kind?

    /// The referenced loaded layout role, or `nil` for table reads.
    public let relationshipRole: LoadedRelationshipRole?

    /// Whether the failure applies to the complete table or one ordered entry.
    public let location: Location

    /// Source coordinates known at the point where the failure was detected.
    public let provenance: Provenance

    /// The precise structural failure.
    public let failure: Failure

    internal init(
        subject: Subject,
        kind: Kind? = nil,
        relationshipRole: LoadedRelationshipRole? = nil,
        location: Location,
        provenance: Provenance,
        failure: Failure
    ) {
        self.subject = subject
        self.kind = kind
        self.relationshipRole = relationshipRole
        self.location = location
        self.provenance = provenance
        self.failure = failure
    }

    public enum Subject: Sendable, Equatable {
        case `class`(name: String)
        case `protocol`(name: String)
        case category(className: String, name: String)
        case loadedImageRoot(section: LoadedImageRootSection, pointerWidth: PointerWidth)
    }

    public enum LoadedImageRootSection: Sendable, Equatable {
        case classList
        case nonLazyClassList
        case protocolList
        case categoryList
        case nonLazyCategoryList
        case categoryList2
    }

    public enum PointerWidth: Int, Sendable, Equatable {
        case bits32 = 32
        case bits64 = 64
    }

    public enum LoadedRelationshipRole: Sendable, Equatable {
        case metaclass
        case superclass
        case categoryClass
        case categoryStubClass
    }

    public enum Kind: Sendable, Equatable {
        case ivar
        case instanceMethod
        case classMethod
        case optionalInstanceMethod
        case optionalClassMethod
        case instanceProperty
        case classProperty
    }

    public enum Location: Sendable, Equatable {
        case table
        case entry(index: Int)
    }

    /// Coordinates are optional independently: an image read normally has both a
    /// logical offset and an address, while an arithmetic failure may establish only one.
    public struct Provenance: Sendable, Equatable {
        public let logicalOffset: Int?
        public let fileOffset: UInt64?
        public let imageAddress: UInt?

        internal init(
            logicalOffset: Int? = nil,
            fileOffset: UInt64? = nil,
            imageAddress: UInt? = nil
        ) {
            self.logicalOffset = logicalOffset
            self.fileOffset = fileOffset
            self.imageAddress = imageAddress
        }
    }

    public enum Failure: Sendable, Equatable {
        case unsupportedListEncoding
        case invalidListOffset(Int)
        case invalidElementCount(UInt64)
        case invalidSignedElementCount(Int)
        case invalidElementStride(UInt64)
        case elementStrideTooSmall(advertised: Int, minimum: Int)
        case unexpectedElementStride(advertised: Int, expected: Int)
        case misalignedTableOffset(offset: Int, requiredAlignment: Int)
        case misalignedTableAddress(address: UInt, requiredAlignment: Int)
        case excessiveElementCount(actual: Int, maximum: Int)
        case excessiveByteCount(actual: Int, maximum: Int)
        case byteCountOverflow(elementCount: Int, elementSize: Int)
        case rangeOverflow(startOffset: UInt64, byteCount: Int)
        case unreadableFileRange(offset: UInt64, byteCount: Int)
        case unreadableImageRange(address: UInt, byteCount: Int)

        case invalidSectionByteCount(byteCount: UInt64, pointerSize: Int)
        case invalidSectionAddress(rawAddress: UInt64, slide: Int)
        case invalidPointer(rawValue: UInt64)
        case missingReferencedImage(address: UInt)
        case unreadableReferencedLayout(address: UInt, byteCount: Int)
        case invalidEntryArithmetic(baseAddress: UInt, targetAddress: UInt)
    }
}

extension ObjCMetadataTableDiagnostic.Failure {
    internal init(_ failure: ObjCMetadataTableFailure) {
        switch failure {
        case .unsupportedListEncoding:
            self = .unsupportedListEncoding
        case .invalidListOffset(let offset):
            self = .invalidListOffset(offset)
        case .invalidElementCount(let count):
            self = .invalidElementCount(count)
        case .invalidSignedElementCount(let count):
            self = .invalidSignedElementCount(count)
        case .invalidElementStride(let stride):
            self = .invalidElementStride(stride)
        case let .elementStrideTooSmall(advertised, minimum):
            self = .elementStrideTooSmall(advertised: advertised, minimum: minimum)
        case let .unexpectedElementStride(advertised, expected):
            self = .unexpectedElementStride(advertised: advertised, expected: expected)
        case let .misalignedTableOffset(offset, requiredAlignment):
            self = .misalignedTableOffset(
                offset: offset,
                requiredAlignment: requiredAlignment
            )
        case let .misalignedTableAddress(address, requiredAlignment):
            self = .misalignedTableAddress(
                address: address,
                requiredAlignment: requiredAlignment
            )
        case let .excessiveElementCount(actual, maximum):
            self = .excessiveElementCount(actual: actual, maximum: maximum)
        case let .excessiveByteCount(actual, maximum):
            self = .excessiveByteCount(actual: actual, maximum: maximum)
        case let .byteCountOverflow(elementCount, elementSize):
            self = .byteCountOverflow(
                elementCount: elementCount,
                elementSize: elementSize
            )
        case let .rangeOverflow(startOffset, byteCount):
            self = .rangeOverflow(startOffset: startOffset, byteCount: byteCount)
        case let .unreadableFileRange(offset, byteCount):
            self = .unreadableFileRange(offset: offset, byteCount: byteCount)
        case let .unreadableImageRange(address, byteCount):
            self = .unreadableImageRange(address: address, byteCount: byteCount)
        }
    }
}
