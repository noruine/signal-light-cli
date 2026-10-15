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
        case .elicitation:
            kind = .permissionRequest
        case .elicitationResult: kind = .postToolUse
        case .permissionDenied: kind = .postToolUse
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
            isQuestion: kind == .permissionRequest
                && (payload.toolName == "AskUserQuestion" || payload.hookEventName == .elicitation)
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
        case .sessionStart:
            guard payload.source != "compact" else { return nil }
            kind = .sessionStart
        case .userPromptSubmit: kind = .userPromptSubmit
        case .permissionRequest:
            // The hook runs before Codex's automatic review can resolve the
            // request, so it cannot establish that a user is actually waiting.
            return nil
        case .preToolUse: kind = .preToolUse
        case .postToolUse: kind = .postToolUse
        case .stop: kind = .stop
        case .sessionEnd: kind = .sessionEnd
        case .interrupt: kind = .interrupt
        }

        return HookEvent(source: .codex, kind: kind, sessionID: payload.sessionID)
    }
}
