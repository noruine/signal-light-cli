import Foundation

/// The slice of Codex's hook payload the light consumes.
public struct CodexHookPayload: Codable, Sendable, Equatable {
    public var cwd: String
    public var hookEventName: CodexHookEventName
    public var sessionID: String
    public var terminalApp: String?
    public var transcriptPath: String?

    public init(
        cwd: String,
        hookEventName: CodexHookEventName,
        sessionID: String,
        terminalApp: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.terminalApp = terminalApp
        self.transcriptPath = transcriptPath
    }

    private enum CodingKeys: String, CodingKey {
        case cwd
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case terminalApp = "terminal_app"
        case transcriptPath = "transcript_path"
    }
}

/// Every event name Codex can send; see `ClaudeHookEventName` for why the
/// unconsumed ones are decoded anyway.
public enum CodexHookEventName: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
    case interrupt = "Interrupt"
}
