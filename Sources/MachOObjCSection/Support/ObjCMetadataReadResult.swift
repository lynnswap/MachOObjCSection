//
//  ObjCMetadataReadResult.swift
//  MachOObjCSection
//

import Foundation

/// A decoded Objective-C metadata value together with recoverable protocol diagnostics.
///
/// This SPI is intended for analysis tools that must distinguish absent metadata from
/// malformed protocol references. It has no ABI stability guarantee.
@_spi(Diagnostics)
public struct ObjCMetadataReadResult<Value> {
    /// The decoded value, or `nil` when the subject itself could not be decoded.
    public let value: Value?

    /// Recoverable protocol failures in deterministic discovery order.
    public let diagnostics: [ObjCProtocolDiagnostic]

    internal init(
        value: Value?,
        diagnostics: [ObjCProtocolDiagnostic]
    ) {
        self.value = value
        self.diagnostics = diagnostics
    }
}

/// A recoverable failure observed while reading or traversing Objective-C protocols.
///
/// Diagnostics describe degradation of one root metadata read. The library never logs
/// them itself; SPI consumers decide how and where to report them.
@_spi(Diagnostics)
public enum ObjCProtocolDiagnostic: Sendable, Equatable {
    /// A protocol list or one of its entries could not be read.
    case unreadableList(UnreadableList)

    /// A reference points back to a protocol already active on the current path.
    case cycle(Cycle)

    /// Following the reference would exceed the hard traversal ceiling.
    case recursionLimit(RecursionLimit)

    /// A root protocol object has no checked canonical traversal identity.
    case invalidIdentity(InvalidIdentity)

    /// The root metadata subject that owns a diagnostic.
    public enum Subject: Sendable, Equatable {
        /// An Objective-C class.
        case `class`(name: String)

        /// An Objective-C protocol.
        case `protocol`(name: String)

        /// An Objective-C category.
        case category(className: String, name: String)
    }

    /// Details for an unreadable protocol list or skipped protocol-list entry.
    public struct UnreadableList: Sendable, Equatable {
        /// The root subject being decoded.
        public let subject: Subject

        /// Protocol names from the root protocol, if any, to the list owner.
        public let protocolPath: [String]

        /// The list offset in the source's native offset convention.
        public let listOffset: Int

        /// The precise read failure.
        public let failure: Failure

        internal init(
            subject: Subject,
            protocolPath: [String],
            listOffset: Int,
            failure: Failure
        ) {
            self.subject = subject
            self.protocolPath = protocolPath
            self.listOffset = listOffset
            self.failure = failure
        }

        /// A whole-table failure or a recoverable failure of one table entry.
        public enum Failure: Sendable, Equatable {
            /// A relative-list marker reached a direct-list reader.
            case unsupportedListEncoding

            /// The list offset cannot be represented as a readable nonnegative address.
            case invalidListOffset(Int)

            /// The raw count cannot be represented by `Int`.
            case invalidElementCount(UInt64)

            /// A custom protocol-list header supplied a negative count.
            case invalidSignedElementCount(Int)

            /// A protocol list exceeds the parser's finite entry budget.
            case excessiveElementCount(actual: Int, maximum: Int)

            /// A strided table exceeds the parser's finite byte budget.
            case excessiveByteCount(actual: Int, maximum: Int)

            /// A non-null list pointer could not be rebased or canonicalized.
            case unresolvedListPointer

            /// A resolved list pointer has no readable backing source.
            case missingListBackingData

            /// A file-backed list header is not entirely readable.
            case unreadableFileHeader(offset: UInt64, byteCount: Int)

            /// A loaded-image list header is not entirely readable.
            case unreadableImageHeader(address: UInt, byteCount: Int)

            /// A relative-list header advertises an entry stride smaller than its layout.
            case invalidRelativeEntrySize(advertised: UInt32, minimum: Int)

            /// A relative-list entry cannot be mapped to its file/cache location.
            case invalidRelativeListLocation

            /// A relative-list entry's load state or loaded cache image is unavailable.
            case relativeImageUnavailable(imageIndex: Int)

            /// Multiplying the element count by pointer size overflowed.
            case byteCountOverflow(elementCount: Int, elementSize: Int)

            /// Adding the table start and byte count overflowed.
            case rangeOverflow(startOffset: UInt64, byteCount: Int)

            /// A file-backed pointer table is not entirely readable.
            case unreadableFileRange(offset: UInt64, byteCount: Int)

            /// A loaded-image pointer table is not entirely readable.
            case unreadableImageRange(address: UInt, byteCount: Int)

            /// One pointer entry could not be rebased.
            case unresolvedRebase(entryIndex: Int)

            /// The field offset for one pointer entry overflowed.
            case invalidEntryOffset(entryIndex: Int)

            /// One loaded-image pointer value did not identify an object.
            case invalidPointer(entryIndex: Int)

            /// One protocol reference has no canonical traversal identity.
            case invalidIdentity(entryIndex: Int)

            /// One rebased pointer has no available backing data.
            case missingBackingData(entryIndex: Int)

            /// One file-backed protocol layout is not entirely readable.
            case unreadableFileLayout(entryIndex: Int, offset: UInt64, byteCount: Int)

            /// One loaded protocol layout is not entirely readable.
            case unreadableImageLayout(entryIndex: Int, address: UInt, byteCount: Int)
        }
    }

    /// Details for a cycle cut at one protocol-reference edge.
    public struct Cycle: Sendable, Equatable {
        /// The root subject being decoded.
        public let subject: Subject

        /// The active protocol path followed by the repeated shallow leaf.
        public let protocolPath: [String]

        internal init(subject: Subject, protocolPath: [String]) {
            self.subject = subject
            self.protocolPath = protocolPath
        }
    }

    /// Details for an edge cut by the hard recursion ceiling.
    public struct RecursionLimit: Sendable, Equatable {
        /// The root subject being decoded.
        public let subject: Subject

        /// The active protocol path followed by the shallow limit leaf.
        public let protocolPath: [String]

        /// The maximum number of traversed reference edges.
        public let maximumDepth: Int

        internal init(
            subject: Subject,
            protocolPath: [String],
            maximumDepth: Int
        ) {
            self.subject = subject
            self.protocolPath = protocolPath
            self.maximumDepth = maximumDepth
        }
    }

    /// Details for a root protocol whose address cannot be canonicalized.
    public struct InvalidIdentity: Sendable, Equatable {
        /// The root protocol being decoded.
        public let subject: Subject

        /// The source-relative protocol offset that was rejected.
        public let protocolOffset: Int

        internal init(subject: Subject, protocolOffset: Int) {
            self.subject = subject
            self.protocolOffset = protocolOffset
        }
    }
}
