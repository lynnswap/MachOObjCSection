/// A stable identity for one ObjC container or member, used both to match
/// entities across two binaries and — as the payload key — to detect changes
/// among matched entities.
///
/// Unlike SwiftDiffing's `ABIKey` there is no remangle step and no fallback
/// branch: ObjC identities are plain names and selectors, total by
/// construction. Keys are namespaced strings (`class:`, `protocol:`,
/// `category:`, `method:-`/`method:+`, `property:-`/`property:+`, `ivar:`,
/// `adopts:`, `superclass`) so different member kinds can never collide. The
/// namespace scheme is the de-facto persistence format of
/// `ObjCAPISnapshotDocument` — any change to it must bump
/// `ObjCAPISnapshotDocument.currentFormatVersion`.
public struct ObjCAPIKey: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: ObjCAPIKey, rhs: ObjCAPIKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
