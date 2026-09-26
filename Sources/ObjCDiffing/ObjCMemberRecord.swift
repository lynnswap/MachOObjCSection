import ObjCDump
import ObjCTypeDecodeKit

/// The kind of a diffed member, used for reporting and to keep members of
/// different kinds in distinct identity namespaces.
public enum ObjCMemberKind: Sendable, Codable, Equatable {
    case instanceMethod
    case classMethod
    case instanceProperty
    case classProperty
    case ivar
    /// A directly adopted protocol (`adopts:` namespace) — only ever
    /// added/removed, never modified.
    case protocolAdoption
    /// A class container's superclass, projected as a pseudo-member so a
    /// reparenting reports the class as modified (old → new) instead of
    /// removed + added.
    case superclass
}

/// A diff-ready projection of one member.
///
/// Two keys drive the algorithm:
/// - `identityKey` matches members across the two sides (added / removed /
///   common). It is the member's runtime identity: `+`/`-` plus the selector
///   for methods, `+`/`-` plus the name for properties, the name for ivars.
/// - `payloadKey` detects a change *among matched* members. It folds in every
///   comparison-relevant attribute the identity does not already encode: the
///   type encoding for methods and ivars, the normalized attribute string for
///   properties (with the synthesized backing-ivar `V` attribute stripped —
///   ivar renames are the ivar axis's story), and the required/optional flag
///   for protocol members (so a requiredness migration reports `.modified`).
///
/// Deliberately excluded from both keys: `ObjCMethodInfo.imp` (an address,
/// different on every build), `ObjCIvarInfo.offset` (slid by the non-fragile
/// runtime, and one mid-list insertion would cascade-modify every later
/// ivar), and `ObjCClassInfo.instanceSize` / `.imageName` (derived values).
public struct ObjCMemberRecord: Sendable, Codable, Equatable {
    public let identityKey: ObjCAPIKey
    public let payloadKey: ObjCAPIKey
    public let kind: ObjCMemberKind
    /// Human-readable rendering, surfaced on `ObjCMemberChange`.
    public let signature: String
    /// Protocol members only: whether the requirement is `@optional`.
    /// Verdict metadata for the compatibility refinement (a required
    /// requirement added to a protocol breaks existing conformers), never
    /// part of the keys — the keys carry it separately. `nil` for anything
    /// that is not a protocol member.
    public let isOptionalRequirement: Bool?

    public init(
        identityKey: ObjCAPIKey,
        payloadKey: ObjCAPIKey,
        kind: ObjCMemberKind,
        signature: String,
        isOptionalRequirement: Bool? = nil
    ) {
        self.identityKey = identityKey
        self.payloadKey = payloadKey
        self.kind = kind
        self.signature = signature
        self.isOptionalRequirement = isOptionalRequirement
    }
}

// MARK: - Projection from the ObjCDump model

extension ObjCMemberRecord {
    /// A method, keyed on its dispatch identity (`+`/`-` + selector) with the
    /// type encoding as payload. Unlike SwiftDiffing — where a re-signed
    /// function is a new mangled symbol and honestly reports removed + added —
    /// an ObjC method's entry point *is* its selector, so an encoding change
    /// at the same selector reports `.modified` (old → new side by side).
    public static func make(_ methodInfo: ObjCMethodInfo, isOptionalRequirement: Bool? = nil) -> ObjCMemberRecord {
        let selectorPrefix = methodInfo.isClassMethod ? "+" : "-"
        return ObjCMemberRecord(
            identityKey: ObjCAPIKey(rawValue: "method:\(selectorPrefix)\(methodInfo.name)"),
            payloadKey: ObjCAPIKey(rawValue: "enc:\(methodInfo.typeEncoding)" + optionalitySuffix(isOptionalRequirement)),
            kind: methodInfo.isClassMethod ? .classMethod : .instanceMethod,
            signature: methodInfo.headerString,
            isOptionalRequirement: isOptionalRequirement
        )
    }

    /// A property, keyed on `+`/`-` + name with the normalized attribute list
    /// as payload. The `V<ivarName>` attribute (the synthesized backing ivar)
    /// is stripped from the payload: it is an implementation detail whose
    /// changes the ivar axis already reports, and folding it in would turn
    /// every backing-ivar rename into property noise.
    public static func make(_ propertyInfo: ObjCPropertyInfo, isOptionalRequirement: Bool? = nil) -> ObjCMemberRecord {
        let propertyPrefix = propertyInfo.isClassProperty ? "+" : "-"
        let normalizedAttributes = propertyInfo.attributes
            .filter { attribute in
                if case .ivar = attribute { return false }
                return true
            }
            .map { $0.encoded() }
            .joined(separator: ",")
        return ObjCMemberRecord(
            identityKey: ObjCAPIKey(rawValue: "property:\(propertyPrefix)\(propertyInfo.name)"),
            payloadKey: ObjCAPIKey(rawValue: "attr:\(normalizedAttributes)" + optionalitySuffix(isOptionalRequirement)),
            kind: propertyInfo.isClassProperty ? .classProperty : .instanceProperty,
            signature: propertyInfo.headerString,
            isOptionalRequirement: isOptionalRequirement
        )
    }

    /// An ivar, keyed by name with the type encoding as payload. The offset is
    /// deliberately not folded in (see the type doc).
    public static func make(_ ivarInfo: ObjCIvarInfo) -> ObjCMemberRecord {
        ObjCMemberRecord(
            identityKey: ObjCAPIKey(rawValue: "ivar:\(ivarInfo.name)"),
            payloadKey: ObjCAPIKey(rawValue: "enc:\(ivarInfo.typeEncoding)"),
            kind: .ivar,
            signature: ivarInfo.headerString
        )
    }

    /// A directly adopted protocol. Identity equals payload — an adoption can
    /// only appear or disappear.
    public static func makeProtocolAdoption(protocolName: String) -> ObjCMemberRecord {
        let key = ObjCAPIKey(rawValue: "adopts:\(protocolName)")
        return ObjCMemberRecord(
            identityKey: key,
            payloadKey: key,
            kind: .protocolAdoption,
            signature: "adopts <\(protocolName)>"
        )
    }

    /// A class's superclass as a pseudo-member: stable identity, the
    /// superclass name as payload, so a reparenting reports `.modified` with
    /// both sides visible. A root class carries an empty payload name.
    public static func makeSuperclass(superclassName: String?) -> ObjCMemberRecord {
        ObjCMemberRecord(
            identityKey: ObjCAPIKey(rawValue: "superclass"),
            payloadKey: ObjCAPIKey(rawValue: "super:\(superclassName ?? "")"),
            kind: .superclass,
            signature: "superclass: \(superclassName ?? "(root)")"
        )
    }

    /// The record-level compatibility refinement shared by the two-sided
    /// differ and the evolution builder (one rule, so N == 2 verdicts cannot
    /// disagree). `nil` means "no refinement — use the status rule".
    ///
    /// A protocol member **added as required** is breaking: existing
    /// conformers lack the implementation, so callers relying on the new
    /// contract hit `unrecognized selector`. Added as optional stays additive
    /// (the plain status rule).
    static func compatibilityOverride(old: ObjCMemberRecord?, new: ObjCMemberRecord?) -> ObjCCompatibility? {
        if old == nil, let newRecord = new, newRecord.isOptionalRequirement == false {
            return .breaking
        }
        return nil
    }

    private static func optionalitySuffix(_ isOptionalRequirement: Bool?) -> String {
        guard let isOptionalRequirement else { return "" }
        return "|optional:" + (isOptionalRequirement ? "1" : "0")
    }
}
