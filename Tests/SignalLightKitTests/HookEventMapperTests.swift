import Foundation
import Testing

@testable import SignalLightKit

@Suite("Hook event mapping")
struct HookEventMapperTests {
    @Test("Claude permission requests map to approvals")
    func claudeApproval() throws {
        let payload = try decodeClaude(#"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/tmp","tool_name":"Bash"}"#)
        let event = try #require(HookEventMapper.event(from: payload))
        #expect(event.source == .claude)
        #expect(event.kind == .permissionRequest)
        #expect(event.isQuestion == false)
    }

    @Test("Claude questions map to answers")
    func claudeQuestion() throws {
        let payload = try decodeClaude(#"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/tmp","tool_name":"AskUserQuestion"}"#)
        let event = try #require(HookEventMapper.event(from: payload))
        #expect(event.isQuestion)
    }

    @Test("Claude AskUserQuestion starts waiting from PreToolUse")
    func claudePreToolQuestion() throws {
        let payload = try decodeClaude(#"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp","tool_name":"AskUserQuestion"}"#)
        let event = try #require(HookEventMapper.event(from: payload))
        #expect(event.kind == .permissionRequest)
        #expect(event.isQuestion)
    }

    @Test("Claude unrelated pre-tool hooks are ignored")
    func claudeUnrelatedPreTool() throws {
        let payload = try decodeClaude(#"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp","tool_name":"Bash"}"#)
        #expect(HookEventMapper.event(from: payload) == nil)
    }

    @Test("Claude failed tool completion maps to running activity")
    func claudeFailedToolCompletion() throws {
        let payload = try decodeClaude(#"{"hook_event_name":"PostToolUseFailure","session_id":"s1","cwd":"/tmp","tool_name":"Bash"}"#)
        let event = try #require(HookEventMapper.event(from: payload))
        #expect(event.kind == .postToolUse)
    }

    @Test("Claude subagent hooks are dropped")
    func claudeSubagent() throws {
        let payload = try decodeClaude(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/tmp","agent_id":"sub"}"#)
        #expect(HookEventMapper.event(from: payload) == nil)
    }

    @Test("Claude events the light ignores map to nothing")
    func claudeIgnored() throws {
        let payload = try decodeClaude(#"{"hook_event_name":"PreCompact","session_id":"s1","cwd":"/tmp"}"#)
        #expect(HookEventMapper.event(from: payload) == nil)
    }

    @Test("Claude compaction does not reset the session to idle")
    func claudeCompactionSessionStart() throws {
        let compact = try decodeClaude(
            #"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/tmp","source":"compact"}"#
        )
        let startup = try decodeClaude(
            #"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/tmp","source":"startup"}"#
        )

        #expect(HookEventMapper.event(from: compact) == nil)
        #expect(HookEventMapper.event(from: startup)?.kind == .sessionStart)
    }

    @Test("Codex events map onto the same shape")
    func codexApproval() throws {
        let payload = try decodeCodex(#"{"hook_event_name":"PermissionRequest","session_id":"c1","cwd":"/tmp"}"#)
        let event = try #require(HookEventMapper.event(from: payload))
        #expect(event.source == .codex)
        #expect(event.kind == .permissionRequest)
    }

    @Test("Codex compaction does not reset the session to idle")
    func codexCompactionSessionStart() throws {
        let compact = try decodeCodex(
            #"{"hook_event_name":"SessionStart","session_id":"c1","cwd":"/tmp","source":"compact"}"#
        )
        let startup = try decodeCodex(
            #"{"hook_event_name":"SessionStart","session_id":"c1","cwd":"/tmp","source":"startup"}"#
        )

        #expect(HookEventMapper.event(from: compact) == nil)
        #expect(HookEventMapper.event(from: startup)?.kind == .sessionStart)
    }

    @Test("Codex automatic permission modes do not wait for approval")
    func codexAutomaticPermissionModes() throws {
        for mode in ["bypassPermissions", "dontAsk"] {
            let payload = try decodeCodex(
                #"{"hook_event_name":"PermissionRequest","session_id":"c1","cwd":"/tmp","permission_mode":"\#(mode)"}"#
            )
            #expect(HookEventMapper.event(from: payload) == nil)
        }
    }

    @Test("Codex.app internal hooks are dropped")
    func codexAppNoise() throws {
        let payload = try decodeCodex(#"{"hook_event_name":"UserPromptSubmit","session_id":"c1","cwd":"/tmp","terminal_app":"Codex.app"}"#)
        #expect(HookEventMapper.event(from: payload) == nil)
    }

    @Test("Codex.app hooks with a transcript are real sessions")
    func codexAppWithTranscript() throws {
        let payload = try decodeCodex(#"{"hook_event_name":"UserPromptSubmit","session_id":"c1","cwd":"/tmp","terminal_app":"Codex.app","transcript_path":"/tmp/t.jsonl"}"#)
        let event = try #require(HookEventMapper.event(from: payload))
        #expect(event.kind == .userPromptSubmit)
    }

    private func decodeClaude(_ json: String) throws -> ClaudeHookPayload {
        try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
    }

    private func decodeCodex(_ json: String) throws -> CodexHookPayload {
        try JSONDecoder().decode(CodexHookPayload.self, from: Data(json.utf8))
    }
}
