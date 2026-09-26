/// Renders an `ObjCAPIDiff` into a plain-text, `git`-style report:
/// `+` added, `-` removed, `~` modified. A pure `ObjCAPIDiff -> String`
/// function — it reads only the names and signatures already on the diff, so
/// it needs no model and no Mach-O.
public struct ObjCAPIDiffReporter: Sendable {
    public init() {}

    public func report(_ diff: ObjCAPIDiff) -> String {
        var sections: [String] = []
        appendContainerSection(&sections, "Classes", diff.classes)
        appendContainerSection(&sections, "Protocols", diff.protocols)
        appendContainerSection(&sections, "Categories", diff.categories)

        var report = sections.isEmpty ? "No ObjC API changes." : sections.joined(separator: "\n\n")
        if let diagnostics = diff.diagnostics, !diagnostics.isEmpty {
            report += "\n\n" + warningsSection(diagnostics)
        }
        return report
    }

    /// Diagnostics surfaced so the verdict is never quietly weaker than it
    /// looks: a collision-dropped record was not compared (see
    /// `ObjCAPIKeyCollision`).
    private func warningsSection(_ diagnostics: ObjCAPIDiffDiagnostics) -> String {
        var lines = ["Warnings — identity-key collisions (first record kept, later ones not compared):"]
        for (sideName, collisions) in [("old", diagnostics.oldSideKeyCollisions), ("new", diagnostics.newSideKeyCollisions)] {
            for collision in collisions {
                let scope = collision.containerName.map { "\($0) · " } ?? ""
                lines.append("  \(sideName) · \(scope)dropped: \(collision.droppedSignatures.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Sections

    private func appendContainerSection(_ sections: inout [String], _ title: String, _ changes: [ObjCContainerChange]) {
        guard !changes.isEmpty else { return }
        var lines = ["\(title):"]
        for change in changes {
            lines.append("  \(sigil(change.status)) \(change.name)")
            for memberChange in change.memberChanges {
                lines.append("      \(memberLine(memberChange))")
            }
        }
        sections.append(lines.joined(separator: "\n"))
    }

    // MARK: - Lines

    private func memberLine(_ change: ObjCMemberChange) -> String {
        let detail: String
        switch change.status {
        case .added:
            detail = change.newSignature ?? change.key.rawValue
        case .removed:
            detail = change.oldSignature ?? change.key.rawValue
        case .modified:
            detail = "\(change.oldSignature ?? change.key.rawValue) → \(change.newSignature ?? change.key.rawValue)"
        }
        return "\(sigil(change.status)) \(detail)"
    }

    private func sigil(_ status: ObjCChangeStatus) -> String {
        switch status {
        case .added: return "+"
        case .removed: return "-"
        case .modified: return "~"
        }
    }
}
