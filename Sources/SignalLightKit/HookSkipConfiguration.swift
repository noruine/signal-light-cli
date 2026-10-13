import Foundation

/// The per-process skip switch wrappers use to keep one child out of the
/// light — without changing the installed hooks.
public enum HookSkipConfiguration {
    public static let skipKey = "SIGNAL_LIGHT_SKIP_HOOKS"

    public static func shouldSkipHooks(environment: [String: String]) -> Bool {
        isTruthy(environment[skipKey])
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
