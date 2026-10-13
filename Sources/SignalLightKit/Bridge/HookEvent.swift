import Foundation

/// One normalized hook fact, as it crosses the socket between
/// `agent-hooks` and the daemon.
///
/// The agents' own payload shapes stop at the hook binary: what the daemon
/// sees is one event shape, one session id, one phase trigger — never Claude
/// JSON or Codex JSON.
public struct HookEvent: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case claude
        case codex
    }

    public enum Kind: String, Codable, Sendable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case permissionRequest = "PermissionRequest"
        case postToolUse = "PostToolUse"
        case stop = "Stop"
        case stopFailure = "StopFailure"
        case sessionEnd = "SessionEnd"
        case interrupt = "Interrupt"
    }

    /// Bumped only when the payload shape changes incompatibly; the daemon
    /// drops versions it doesn't know rather than guessing at their meaning.
    public static let currentVersion = 1

    public let version: Int
    public let source: Source
    public let kind: Kind
    public let sessionID: String
    /// Claude's `AskUserQuestion` arrives as a permission request but is a
    /// question: the light shows 「等待回答」, not 「等待审批」.
    public let isQuestion: Bool

    public init(source: Source, kind: Kind, sessionID: String, isQuestion: Bool = false) {
        self.version = Self.currentVersion
        self.source = source
        self.kind = kind
        self.sessionID = sessionID
        self.isQuestion = isQuestion
    }
}
