import ArgumentParser

/// Which palette to colorize terminal output with. `none` emits plain text,
/// which is what a redirected or piped run wants.
enum SemanticColorScheme: String, CaseIterable, ExpressibleByArgument, Sendable {
    case none
    case light
    case dark
}
