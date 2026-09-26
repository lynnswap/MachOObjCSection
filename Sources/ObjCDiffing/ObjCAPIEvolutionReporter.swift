/// Renders an `ObjCAPIEvolution` into a plain-text timeline report. A pure
/// `ObjCAPIEvolution -> String` function — like `ObjCAPIDiffReporter` it
/// reads only names, signatures and the version axis already on the value.
///
/// Layout: a header naming the axis, a per-transition summary with the
/// additive/breaking verdict, then one section per bucket. Every lineage
/// line starts with a per-version presence bitmap (`●` present, `○` absent)
/// and is followed by its events, phrased against the version labels:
///
/// ```
/// Classes:
///   [●●○] NSFoo
///       - removed in 26.0
///       [●○○] - (void)bar;
///           - removed in 18.0
/// ```
public struct ObjCAPIEvolutionReporter: Sendable {
    public init() {}

    public func report(_ evolution: ObjCAPIEvolution) -> String {
        var sections: [String] = [header(evolution), transitionSummary(evolution)]
        appendContainerSection(&sections, "Classes", evolution.classes, evolution)
        appendContainerSection(&sections, "Protocols", evolution.protocols, evolution)
        appendContainerSection(&sections, "Categories", evolution.categories, evolution)
        if evolution.isEmpty {
            sections.append("No ObjC API changes across the axis.")
        }
        if let keyCollisionsByVersion = evolution.keyCollisionsByVersion {
            sections.append(collisionWarningsSection(keyCollisionsByVersion, evolution))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Just the header + per-transition summary, for `--summary-only`.
    public func summary(_ evolution: ObjCAPIEvolution) -> String {
        header(evolution) + "\n\n" + transitionSummary(evolution)
    }

    /// Identity-key collisions per version, surfaced so a lineage is never
    /// quietly weaker than reported (a dropped record was not compared
    /// there).
    private func collisionWarningsSection(_ keyCollisionsByVersion: [[ObjCAPIKeyCollision]], _ evolution: ObjCAPIEvolution) -> String {
        var lines = ["Warnings — identity-key collisions (first record kept, later ones not compared):"]
        for (versionIndex, collisions) in keyCollisionsByVersion.enumerated() {
            for collision in collisions {
                let scope = collision.containerName.map { "\($0) · " } ?? ""
                lines.append("  \(evolution.versions[versionIndex].label) · \(scope)dropped: \(collision.droppedSignatures.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Header & summary

    private func header(_ evolution: ObjCAPIEvolution) -> String {
        let axis = evolution.versions.map(\.label).joined(separator: " → ")
        return "ObjC API evolution across \(evolution.versions.count) versions: \(axis)"
    }

    private func transitionSummary(_ evolution: ObjCAPIEvolution) -> String {
        let compatibilities = evolution.transitionCompatibilities
        var lines = ["Transitions:"]
        for versionIndex in 1 ..< evolution.versions.count {
            let counts = eventCounts(evolution, at: versionIndex)
            let step = "\(evolution.versions[versionIndex - 1].label) → \(evolution.versions[versionIndex].label)"
            if counts.total == 0 {
                lines.append("  \(step): no changes")
            } else {
                var parts: [String] = []
                if counts.added > 0 { parts.append("\(counts.added) added") }
                if counts.removed > 0 { parts.append("\(counts.removed) removed") }
                if counts.modified > 0 { parts.append("\(counts.modified) modified") }
                let verdict = compatibilities[versionIndex - 1] == .breaking ? "API-breaking" : "additive"
                lines.append("  \(step): " + (parts + [verdict]).joined(separator: " · "))
            }
        }
        if let firstBreakingVersionIndex = evolution.firstBreakingVersionIndex {
            let step = "\(evolution.versions[firstBreakingVersionIndex - 1].label) → \(evolution.versions[firstBreakingVersionIndex].label)"
            lines.append("First API-breaking transition: \(step)")
        }
        return lines.joined(separator: "\n")
    }

    private func eventCounts(_ evolution: ObjCAPIEvolution, at versionIndex: Int) -> (added: Int, removed: Int, modified: Int, total: Int) {
        var added = 0, removed = 0, modified = 0
        func count(_ events: [ObjCLineageEvent]) {
            for event in events where event.versionIndex == versionIndex {
                switch event.status {
                case .added: added += 1
                case .removed: removed += 1
                case .modified: modified += 1
                }
            }
        }
        for lineage in evolution.allContainerLineages {
            count(lineage.events)
            for memberLineage in lineage.memberLineages {
                count(memberLineage.events)
            }
        }
        return (added, removed, modified, added + removed + modified)
    }

    // MARK: - Sections

    private func appendContainerSection(
        _ sections: inout [String],
        _ title: String,
        _ lineages: [ObjCContainerLineage],
        _ evolution: ObjCAPIEvolution
    ) {
        guard !lineages.isEmpty else { return }
        var lines = ["\(title):"]
        for lineage in lineages {
            lines.append("  \(bitmap(lineage.presence)) \(lineage.name)")
            for event in lineage.events {
                lines.append("      \(eventLine(event, evolution, signatures: false))")
            }
            for memberLineage in lineage.memberLineages {
                lines.append("      \(bitmap(memberLineage.presence)) \(latestSignature(memberLineage))")
                for event in memberLineage.events {
                    lines.append("          \(eventLine(event, evolution, signatures: true))")
                }
            }
        }
        sections.append(lines.joined(separator: "\n"))
    }

    // MARK: - Lines

    /// The lineage's most recent rendering: the last event's signature (new
    /// side preferred) — every lineage has at least one event by
    /// construction.
    private func latestSignature(_ lineage: ObjCMemberLineage) -> String {
        for event in lineage.events.reversed() {
            if let signature = event.newSignature ?? event.oldSignature {
                return signature
            }
        }
        return lineage.key.rawValue
    }

    /// One event phrased against the axis. `signatures: false` keeps
    /// container events to the bare phrase (containers carry no signature;
    /// their name is already on the lineage line).
    private func eventLine(_ event: ObjCLineageEvent, _ evolution: ObjCAPIEvolution, signatures: Bool) -> String {
        let label = evolution.versions[event.versionIndex].label
        switch event.status {
        case .added:
            return "+ added in \(label)"
        case .removed:
            return "- removed in \(label)"
        case .modified:
            guard signatures, let oldSignature = event.oldSignature, let newSignature = event.newSignature else {
                return "~ modified in \(label)"
            }
            return "~ modified in \(label): \(oldSignature) → \(newSignature)"
        }
    }

    private func bitmap(_ presence: [Bool]) -> String {
        "[" + presence.map { $0 ? "●" : "○" }.joined() + "]"
    }
}
