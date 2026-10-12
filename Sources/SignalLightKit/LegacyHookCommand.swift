import Foundation

/// Detects hook commands left behind by an older Open Island / Vibe Island
/// install, so a managed install can replace them.
///
/// Matched on the executable's basename — not a substring of the whole
/// command — so a user's own script that merely mentions these names in a
/// path or an argument is never mistaken for a managed legacy install and
/// deleted.
public enum LegacyHookCommand {
    private static let legacyExecutableNames: Set<String> = [
        "openislandhooks",
        "vibeislandhooks",
        "open-island-bridge",
        "vibe-island-bridge",
    ]

    public static func matches(_ command: String) -> Bool {
        legacyExecutableNames.contains(executableBasename(in: command))
    }

    /// The first token of the command that isn't a `VAR=value` prefix (the
    /// executable), reduced to its lowercased basename.
    private static func executableBasename(in command: String) -> String {
        for token in tokens(in: command) where !token.contains("=") {
            return (token as NSString).lastPathComponent.lowercased()
        }
        return ""
    }

    /// Whitespace-splits while honoring single/double quotes, so a quoted
    /// path with spaces stays one token.
    private static func tokens(in command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?

        for character in command {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
