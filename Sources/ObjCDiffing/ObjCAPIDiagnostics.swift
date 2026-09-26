/// One identity-key collision the first-wins keying resolved silently: two
/// records in the same keying scope (one container's members, or one
/// container axis) carried the same identity, so only the first was compared
/// and the rest were dropped.
///
/// A dropped record can hide a change — most realistically a removal
/// classified as compatible. The one known-legitimate source is a duplicate
/// class: the runtime allows two same-named ObjC classes in one image, and
/// real binaries contain them.
public struct ObjCAPIKeyCollision: Sendable, Codable, Equatable {
    /// The identity that collided.
    public let key: ObjCAPIKey
    /// The owning container's reporting name; `nil` for a container-level
    /// collision.
    public let containerName: String?
    /// Human-readable renderings of the records that were dropped (the first
    /// record with the key was kept and compared).
    public let droppedSignatures: [String]

    public init(key: ObjCAPIKey, containerName: String?, droppedSignatures: [String]) {
        self.key = key
        self.containerName = containerName
        self.droppedSignatures = droppedSignatures
    }
}

/// The diagnostics side-channel of an `ObjCAPIDiff`: everything the
/// comparison had to resolve silently, surfaced so a verdict is never
/// quietly weaker than it looks. `nil` on the diff when there is nothing to
/// report. (SwiftDiffing's second diagnostics dimension — remangle
/// fallbacks — has no ObjC counterpart: there is no remangle step.)
public struct ObjCAPIDiffDiagnostics: Sendable, Codable, Equatable {
    /// Collisions found while keying the old side's snapshot.
    public let oldSideKeyCollisions: [ObjCAPIKeyCollision]
    /// Collisions found while keying the new side's snapshot.
    public let newSideKeyCollisions: [ObjCAPIKeyCollision]

    public init(
        oldSideKeyCollisions: [ObjCAPIKeyCollision],
        newSideKeyCollisions: [ObjCAPIKeyCollision]
    ) {
        self.oldSideKeyCollisions = oldSideKeyCollisions
        self.newSideKeyCollisions = newSideKeyCollisions
    }

    public var isEmpty: Bool {
        oldSideKeyCollisions.isEmpty && newSideKeyCollisions.isEmpty
    }
}

extension ObjCAPISnapshot {
    /// Every identity-key collision the first-wins keying would silently
    /// resolve when this snapshot is diffed: duplicate container keys within
    /// one axis, and duplicate member identities within one container.
    /// Deterministically ordered (container name, then key).
    public func keyCollisions() -> [ObjCAPIKeyCollision] {
        var collisions: [ObjCAPIKeyCollision] = []
        for axis in [classes, protocols, categories] {
            collectContainerKeyCollisions(axis, into: &collisions)
            for container in axis {
                collectMemberKeyCollisions(container.members, containerName: container.name, into: &collisions)
            }
        }
        return collisions.sorted {
            ($0.containerName ?? "", $0.key.rawValue) < ($1.containerName ?? "", $1.key.rawValue)
        }
    }

    /// Two containers with the same key on one axis (dropped ones surface by
    /// name — a container has no signature).
    private func collectContainerKeyCollisions(_ containers: [ObjCContainerSnapshot], into collisions: inout [ObjCAPIKeyCollision]) {
        var firstSeen: Set<ObjCAPIKey> = []
        var droppedNamesByKey: [ObjCAPIKey: [String]] = [:]
        for container in containers {
            if firstSeen.contains(container.key) {
                droppedNamesByKey[container.key, default: []].append(container.name)
            } else {
                firstSeen.insert(container.key)
            }
        }
        for (key, droppedNames) in droppedNamesByKey {
            collisions.append(ObjCAPIKeyCollision(key: key, containerName: nil, droppedSignatures: droppedNames))
        }
    }

    private func collectMemberKeyCollisions(_ members: [ObjCMemberRecord], containerName: String?, into collisions: inout [ObjCAPIKeyCollision]) {
        var firstSeen: Set<ObjCAPIKey> = []
        var droppedSignaturesByKey: [ObjCAPIKey: [String]] = [:]
        for member in members {
            if firstSeen.contains(member.identityKey) {
                droppedSignaturesByKey[member.identityKey, default: []].append(member.signature)
            } else {
                firstSeen.insert(member.identityKey)
            }
        }
        for (key, droppedSignatures) in droppedSignaturesByKey {
            collisions.append(ObjCAPIKeyCollision(key: key, containerName: containerName, droppedSignatures: droppedSignatures))
        }
    }
}
