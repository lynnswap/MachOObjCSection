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
    /// The semantic owner of the degraded metadata.
    public let owner: Owner

    /// The exact table, entry, or relationship read site.
    public let site: Site

    /// The precise structural failure.
    public let failure: Failure

    internal init(
        owner: Owner,
        site: Site,
        failure: Failure
    ) {
        self.owner = owner
        self.site = site
        self.failure = failure
    }

    public enum MetadataSubject: Sendable, Equatable {
        /// A named Objective-C class.
        case `class`(name: String)
        /// A named Objective-C protocol.
        case `protocol`(name: String)
        /// A named Objective-C category and its target class.
        case category(className: String, name: String)
    }

    public enum Owner: Sendable, Equatable {
        /// One member table owned by a decoded metadata subject.
        case member(subject: MetadataSubject, kind: MemberKind)
        /// One root pointer section in the loaded image.
        case loadedImageRoot(section: LoadedImageRootSection, pointerWidth: PointerWidth)
        /// One class layout reached through a loaded relationship pointer.
        case loadedRelationship(
            subject: MetadataSubject,
            role: LoadedRelationshipRole
        )
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

    public enum MemberKind: Sendable, Equatable {
        case ivar
        case instanceMethod
        case classMethod
        case optionalInstanceMethod
        case optionalClassMethod
        case instanceProperty
        case classProperty
    }

    public enum Site: Sendable, Equatable {
        /// A failure affecting the complete table.
        case table(Provenance)
        /// A recoverable failure of one ordered table entry.
        case entry(index: Int, provenance: Provenance)
        /// A failure while resolving one relationship pointer.
        case relationship(Provenance)
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
        case invalidSectionCoordinates(
            sectionAddress: UInt64,
            sectionSize: UInt64,
            sectionFileOffset: UInt64,
            segmentAddress: UInt64,
            segmentSize: UInt64,
            segmentFileOffset: UInt64,
            segmentFileSize: UInt64
        )
        case invalidLoadedSectionAddress(
            imageBase: UInt,
            segmentVirtualMemoryOffset: UInt64
        )
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
