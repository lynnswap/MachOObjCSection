import Rainbow
import Semantic

extension SemanticString {
    func colorized(using colorScheme: SemanticColorScheme) -> String {
        components.map { $0.string.withColor(for: $0.type, colorScheme: colorScheme) }.joined()
    }

    func printColorfully(using colorScheme: SemanticColorScheme) {
        print(colorized(using: colorScheme))
    }
}

extension String {
    /// The hex color for `type` in `colorScheme`, or `nil` when that kind of
    /// token is left uncolored.
    ///
    /// The palettes match `swift-section`'s so that a Swift dump and an
    /// Objective-C dump of the same binary look like one tool.
    func withColorHex(for type: SemanticType, colorScheme: SemanticColorScheme) -> String? {
        switch colorScheme {
        case .none:
            return nil
        case .light:
            switch type {
            case .comment:
                return "#56606B"
            case .keyword:
                return "#C33381"
            case .type(_, .name):
                return "#2E0D6E"
            case .type(_, .declaration):
                return "#004975"
            case .function(.name),
                 .member(.name):
                return "#5C2699"
            case .function(.declaration),
                 .member(.declaration),
                 .variable:
                return "#0F68A0"
            case .numeric:
                return "#000BFF"
            default:
                return nil
            }
        case .dark:
            switch type {
            case .comment:
                return "#6C7987"
            case .keyword:
                return "#F2248C"
            case .type(_, .name):
                return "#D0A8FF"
            case .type(_, .declaration):
                return "#5DD8FF"
            case .function(.name),
                 .member(.name):
                return "#A167E6"
            case .function(.declaration),
                 .member(.declaration):
                return "#41A1C0"
            case .numeric:
                return "#D0BF69"
            default:
                return nil
            }
        }
    }

    func withColor(for type: SemanticType, colorScheme: SemanticColorScheme) -> String {
        if let colorHex = withColorHex(for: type, colorScheme: colorScheme) {
            return hex(colorHex, to: .bit24)
        } else if type == .error {
            return red
        } else {
            return self
        }
    }
}
