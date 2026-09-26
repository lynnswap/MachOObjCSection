import Foundation

/// The versioned persistence envelope around an `ObjCAPISnapshot` — the
/// on-disk baseline format.
///
/// `ObjCAPISnapshot` itself stays pure API data (its `Equatable` means "same
/// API"); this wrapper adds what persistence needs: a **format version** and
/// optional **provenance**. The key namespace strings (`method:-`, `attr:`,
/// `adopts:`, …) are the de-facto serialization format, so any key-scheme
/// change MUST bump ``currentFormatVersion`` — decoding then fails with a
/// typed, user-facing error instead of silently mis-diffing an old baseline.
public struct ObjCAPISnapshotDocument: Sendable, Codable, Equatable {
    /// Bump on any change to the snapshot schema **or** to the
    /// `ObjCMemberRecord` key scheme.
    ///
    /// History:
    /// - 1: initial versioned format (proposal 0006).
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public var provenance: ObjCAPIProvenance?
    public var snapshot: ObjCAPISnapshot

    public init(provenance: ObjCAPIProvenance? = nil, snapshot: ObjCAPISnapshot) {
        self.formatVersion = Self.currentFormatVersion
        self.provenance = provenance
        self.snapshot = snapshot
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) else {
            throw ObjCAPISnapshotDocumentError.missingFormatVersion
        }
        guard formatVersion == Self.currentFormatVersion else {
            throw ObjCAPISnapshotDocumentError.unsupportedFormatVersion(
                found: formatVersion,
                supported: Self.currentFormatVersion
            )
        }
        self.formatVersion = formatVersion
        self.provenance = try container.decodeIfPresent(ObjCAPIProvenance.self, forKey: .provenance)
        self.snapshot = try container.decode(ObjCAPISnapshot.self, forKey: .snapshot)
    }
}

extension ObjCAPISnapshotDocument {
    /// Decode a persisted baseline, validating the format version first so a
    /// stale or foreign file fails with a clear, typed error.
    public static func decode(from data: Data) throws -> ObjCAPISnapshotDocument {
        try ObjCAPIJSON.decoder().decode(ObjCAPISnapshotDocument.self, from: data)
    }

    /// Encode for persistence. Sorted keys + pretty printing make the
    /// encoding byte-stable for identical documents, so baselines diff
    /// cleanly in git.
    public func encoded() throws -> Data {
        try ObjCAPIJSON.encoder().encode(self)
    }
}

/// Decoding failures of the persisted baseline format.
public enum ObjCAPISnapshotDocumentError: Error, Equatable, CustomStringConvertible {
    /// The file has no `formatVersion` key — it is not an
    /// `ObjCAPISnapshotDocument` (or predates the versioned format).
    case missingFormatVersion
    /// The file was written by a different format version of the tool.
    case unsupportedFormatVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .missingFormatVersion:
            return "The file is not an ObjC API snapshot document (no formatVersion key)."
        case .unsupportedFormatVersion(let found, let supported):
            return "Unsupported ObjC API snapshot format version \(found) (this tool supports \(supported)). Regenerate the snapshot with this tool version."
        }
    }
}

/// The one JSON dialect every ObjCDiffing value speaks when persisted:
/// ISO-8601 dates, sorted keys, pretty printing. Shared by the snapshot
/// document codec and the CLI's `--json` outputs so no two call sites drift.
public enum ObjCAPIJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
