import Foundation

/// The slice of Claude Code's hook payload the light consumes.
///
/// Claude sends far more per hook (tool IO, transcripts, terminal hints);
/// none of that changes which color a light should show, and this product has
/// no UI to render it in.
public struct ClaudeHookPayload: Codable, Sendable, Equatable {
    public var cwd: String
    public var hookEventName: ClaudeHookEventName
    public var sessionID: String
    public var source: String?
    public var toolName: String?
    /// Set on hooks fired by subagents. The parent session reports subagent
    /// activity itself, so these are dropped to avoid duplicate sessions.
    public var agentID: String?

    public init(
        cwd: String,
        hookEventName: ClaudeHookEventName,
        sessionID: String,
        source: String? = nil,
        toolName: String? = nil,
        agentID: String? = nil
    ) {
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.source = source
        self.toolName = toolName
        self.agentID = agentID
    }

    private enum CodingKeys: String, CodingKey {
        case cwd
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case source
        case toolName = "tool_name"
        case agentID = "agent_id"
    }
}

/// Every event name Claude Code can send. Names the light doesn't consume are
/// still decodable: a hook left in a user's settings by an older install must
/// not fail the whole payload.
public enum ClaudeHookEventName: String, Codable, Sendable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case permissionDenied = "PermissionDenied"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case preCompact = "PreCompact"
}
