//
//  ObjCMetadataFieldDiagnostic.swift
//  MachOObjCSection
//

import Foundation

/// A recoverable failure while reading one fixed Objective-C metadata field.
///
/// Diagnostics are emitted only for non-null fields whose storage could not be
/// resolved or read. Structurally absent fields do not produce diagnostics.
@_spi(Diagnostics)
public enum ObjCMetadataFieldDiagnostic: Sendable, Equatable {
    /// An instance class or metaclass read-only data layout could not be read.
    case classROData(ClassROData)

    /// The offset value for one instance variable could not be read.
    case ivarOffset(IvarOffset)

    /// The root class whose metadata is being decoded.
    public enum Subject: Sendable, Equatable {
        /// A class whose name and source-relative object offset are readable.
        case namedClass(name: String, objectOffset: Int)

        /// A class identified only by its source-relative object offset.
        case classObject(offset: Int)
    }

    /// Which Objective-C class object owns a read-only data field.
    public enum ClassRole: Sendable, Equatable {
        case instance
        case metaclass
    }

    /// The structural reason a fixed metadata field could not be read.
    public enum Failure: Sendable, Equatable {
        /// The encoded pointer could not be resolved as a rebase.
        case unresolvedRebase

        /// The resolved pointer has no readable file or cache backing.
        case missingBackingData

        /// The complete field does not fit in its file-backed source.
        case unreadableFileRange(offset: UInt64, byteCount: Int)

        /// The complete field is not readable in the current task.
        case unreadableImageRange(address: UInt, byteCount: Int)
    }

    /// Details for an unreadable class read-only data layout.
    public struct ClassROData: Sendable, Equatable {
        /// The logical root class being decoded.
        public let subject: Subject

        /// Whether the failed field belongs to the instance class or metaclass.
        public let role: ClassRole

        /// The source-relative offset of the class object containing the failed field.
        public let classObjectOffset: Int

        /// The precise structural read failure.
        public let failure: Failure

        internal init(
            subject: Subject,
            role: ClassRole,
            classObjectOffset: Int,
            failure: Failure
        ) {
            self.subject = subject
            self.role = role
            self.classObjectOffset = classObjectOffset
            self.failure = failure
        }
    }

    /// Details for an unreadable instance-variable offset value.
    public struct IvarOffset: Sendable, Equatable {
        /// The class that owns the instance variable.
        public let subject: Subject

        /// The declaration-order index of the instance variable.
        public let index: Int

        /// The readable instance-variable name.
        public let name: String

        /// The precise structural read failure.
        public let failure: Failure

        internal init(
            subject: Subject,
            index: Int,
            name: String,
            failure: Failure
        ) {
            self.subject = subject
            self.index = index
            self.name = name
            self.failure = failure
        }
    }
}

/// The internal outcome of reading a fixed metadata field.
///
/// Absence is distinct from malformed non-null storage so callers never need a
/// sentinel value or infer a failure from an optional projection.
internal enum ObjCMetadataFieldRead<Value> {
    case absent
    case value(Value)
    case failure(ObjCMetadataFieldDiagnostic.Failure)

    var value: Value? {
        guard case .value(let value) = self else { return nil }
        return value
    }
}
