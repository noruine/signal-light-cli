import Foundation

/// Maps each agent's hook vocabulary onto `HookEvent` — the only place the
/// two agents differ. Everything downstream sees one event shape.
public enum HookEventMapper {
    /// `nil` for events the light doesn't consume (and for the agent's own
    /// noise, like Claude subagent hooks, which would otherwise double every
    /// session).
    public static func event(from payload: ClaudeHookPayload) -> HookEvent? {
        if payload.agentID != nil, payload.hookEventName != .subagentStart, payload.hookEventName != .subagentStop {
            return nil
        }

        let kind: HookEvent.Kind
        switch payload.hookEventName {
        case .sessionStart:
            guard payload.source != "compact" else { return nil }
            kind = .sessionStart
        case .userPromptSubmit: kind = .userPromptSubmit
        case .preToolUse:
            guard payload.toolName == "AskUserQuestion" else { return nil }
            kind = .permissionRequest
        case .permissionRequest: kind = .permissionRequest
        case .postToolUse, .postToolUseFailure: kind = .postToolUse
        case .stop: kind = .stop
        case .stopFailure: kind = .stopFailure
        case .sessionEnd: kind = .sessionEnd
        default: return nil
        }

        return HookEvent(
            source: .claude,
            kind: kind,
            sessionID: payload.sessionID,
            isQuestion: kind == .permissionRequest && payload.toolName == "AskUserQuestion"
        )
    }

    public static func event(from payload: CodexHookPayload) -> HookEvent? {
        // Codex.app fires hooks for internal work (conversation titles) that
        // has no transcript and no user watching; those aren't sessions.
        if payload.terminalApp == "Codex.app", (payload.transcriptPath ?? "").isEmpty {
            return nil
        }

        let kind: HookEvent.Kind
        switch payload.hookEventName {
        case .sessionStart: kind = .sessionStart
        case .userPromptSubmit: kind = .userPromptSubmit
        case .permissionRequest:
            if payload.permissionMode == "bypassPermissions" || payload.permissionMode == "dontAsk" {
                return nil
            }
            kind = .permissionRequest
        case .postToolUse: kind = .postToolUse
        case .stop: kind = .stop
        case .sessionEnd: kind = .sessionEnd
        case .interrupt: kind = .interrupt
        default: return nil
        }

        return HookEvent(source: .codex, kind: kind, sessionID: payload.sessionID)
    }
}
