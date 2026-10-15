import Foundation
import Testing

@testable import SignalLightKit

@Suite("Session registry")
struct SessionRegistryTests {
    private func event(
        _ kind: HookEvent.Kind,
        session: String = "s1",
        source: HookEvent.Source = .claude,
        question: Bool = false
    ) -> HookEvent {
        HookEvent(source: source, kind: kind, sessionID: session, isQuestion: question)
    }

    @Test("A submitted prompt turns the light running")
    func promptRuns() async {
        let registry = SessionRegistry()
        #expect(await registry.apply(event(.userPromptSubmit)) == .running)
    }

    @Test("A session that starts without activity stays idle")
    func freshSessionIsIdle() async {
        let registry = SessionRegistry()
        #expect(await registry.apply(event(.sessionStart)) == .idle)
    }

    @Test("A permission request outranks running work")
    func approvalOutranksRunning() async {
        let registry = SessionRegistry()
        _ = await registry.apply(event(.userPromptSubmit))
        #expect(await registry.apply(event(.permissionRequest)) == .needsApproval)
    }

    @Test("Questions are distinct from approvals")
    func questionIsAnswer() async {
        let registry = SessionRegistry()
        #expect(await registry.apply(event(.permissionRequest, question: true)) == .needsAnswer)
    }

    @Test("An approval outranks another session's question")
    func approvalOutranksAnswer() async {
        let registry = SessionRegistry()
        _ = await registry.apply(event(.permissionRequest, session: "question", question: true))
        #expect(await registry.apply(event(.permissionRequest, session: "approval")) == .needsApproval)
    }

    @Test("Tool completion clears a pending approval without clearing other sessions")
    func toolCompletionClearsApproval() async {
        let registry = SessionRegistry()
        _ = await registry.apply(event(.permissionRequest, session: "approval"))
        _ = await registry.apply(event(.userPromptSubmit, session: "running"))
        #expect(await registry.bucket() == .needsApproval)

        #expect(await registry.apply(event(.postToolUse, session: "approval")) == .running)
        #expect(await registry.snapshot()["claude:running"]?.phase == .running)
    }

    @Test("Tool start clears a pending Codex approval before execution completes")
    func toolStartClearsApproval() async {
        let registry = SessionRegistry()
        _ = await registry.apply(event(.permissionRequest, source: .codex))

        #expect(await registry.apply(event(.preToolUse, source: .codex)) == .running)
        #expect(await registry.snapshot()["codex:s1"]?.phase == .running)
    }

    @Test("A new prompt clears a pending question in its session")
    func newPromptClearsQuestion() async {
        let registry = SessionRegistry()
        _ = await registry.apply(event(.permissionRequest, question: true))

        #expect(await registry.apply(event(.userPromptSubmit)) == .running)
    }

    @Test("Waiting attention expires after a day")
    func waitingAttentionExpires() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(start)
        let registry = SessionRegistry(now: { clock.now })
        _ = await registry.apply(event(.permissionRequest, question: true))
        #expect(await registry.bucket() == .needsAnswer)

        clock.advance(by: 25 * 60 * 60)
        #expect(await registry.bucket() == .idle)
    }

    @Test("Concurrent updates publish their buckets in registry order")
    func concurrentNotificationsStayOrdered() async {
        let registry = SessionRegistry()
        let recorder = BucketRecorder()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await registry.apply(
                    event(.permissionRequest, session: "waiting"),
                    onStateChange: recorder.append
                )
            }
            group.addTask {
                _ = await registry.apply(
                    event(.userPromptSubmit, session: "running"),
                    onStateChange: recorder.append
                )
            }
        }

        let currentBucket = await registry.bucket()
        #expect(recorder.values.last?.bucket == currentBucket)
        #expect(currentBucket == .needsApproval)
    }

    @Test("Stop, failure and interrupt all return to idle")
    func endingsAreIdle() async {
        for kind in [HookEvent.Kind.stop, .stopFailure, .interrupt] {
            let registry = SessionRegistry()
            _ = await registry.apply(event(.userPromptSubmit))
            #expect(await registry.apply(event(kind)) == .idle)
        }
    }

    @Test("SessionEnd forgets the session")
    func sessionEndForgets() async {
        let registry = SessionRegistry()
        _ = await registry.apply(event(.userPromptSubmit))
        #expect(await registry.apply(event(.sessionEnd)) == .idle)
        #expect(await registry.snapshot().isEmpty)
    }

    @Test("Equal session ids from different agents never collide")
    func agentsDoNotCollide() async {
        let registry = SessionRegistry()
        _ = await registry.apply(event(.userPromptSubmit, session: "same", source: .claude))
        _ = await registry.apply(event(.permissionRequest, session: "same", source: .codex))
        #expect(await registry.bucket() == .needsApproval)

        _ = await registry.apply(event(.stop, session: "same", source: .codex))
        #expect(await registry.bucket() == .running, "the Claude session is still running")
    }

    @Test("Session summary reports each session and the winning phase")
    func summaryReportsSessions() async {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let registry = SessionRegistry(now: { timestamp })
        _ = await registry.apply(event(.userPromptSubmit, session: "work", source: .claude))
        _ = await registry.apply(event(.permissionRequest, session: "question", source: .codex, question: true))

        let summary = await registry.summary()
        #expect(summary.bucket == .needsAnswer)
        #expect(summary.sessions == [
            SessionRegistry.SessionStatus(
                source: .claude,
                sessionID: "work",
                phase: .running,
                lastEventAt: timestamp
            ),
            SessionRegistry.SessionStatus(
                source: .codex,
                sessionID: "question",
                phase: .waitingForAnswer,
                lastEventAt: timestamp
            ),
        ])
    }

    @Test("Claude and Codex sessions survive a daemon restart")
    func sessionsRestoreAfterRestart() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(start)
        let originalRegistry = SessionRegistry(now: { clock.now })
        _ = await originalRegistry.apply(event(.userPromptSubmit, session: "active", source: .claude))
        _ = await originalRegistry.apply(event(.sessionStart, session: "idle", source: .codex))

        clock.advance(by: 3 * 60 * 60)
        let savedSessions = await originalRegistry.summary().sessions
        let restartedRegistry = SessionRegistry(restoring: savedSessions, now: { clock.now })
        let restored = await restartedRegistry.summary()

        #expect(restored.sessions.count == 2)
        #expect(restored.sessions.map(\.phase) == [.idle, .idle])
        #expect(restored.sessions.map(\.lastEventAt) == [start, start])
    }

    @Test("Sessions older than the retention window are discarded on restore")
    func staleSessionsAreDiscardedOnRestore() async {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(timestamp.addingTimeInterval(25 * 60 * 60))
        let registry = SessionRegistry(restoring: [
            SessionRegistry.SessionStatus(
                source: .claude,
                sessionID: "stale",
                phase: .running,
                lastEventAt: timestamp
            ),
        ], now: { clock.now })

        #expect(await registry.snapshot().isEmpty)
    }

    @Test("Future-dated and empty sessions are discarded on restore")
    func invalidSessionsAreDiscardedOnRestore() async {
        let timestamp = Date(timeIntervalSince1970: 1_000_000)
        let registry = SessionRegistry(restoring: [
            SessionRegistry.SessionStatus(
                source: .claude,
                sessionID: "future",
                phase: .running,
                lastEventAt: timestamp.addingTimeInterval(60)
            ),
            SessionRegistry.SessionStatus(
                source: .codex,
                sessionID: "  \n",
                phase: .idle,
                lastEventAt: timestamp
            ),
        ], now: { timestamp })

        #expect(await registry.snapshot().isEmpty)
    }

    @Test("A legacy Codex approval without an event time restores as idle")
    func legacyCodexApprovalRestoresIdle() async {
        let registry = SessionRegistry(restoring: [
            SessionRegistry.SessionStatus(
                source: .codex,
                sessionID: "legacy",
                phase: .waitingForApproval
            ),
        ], fallbackLastEventAt: .now)

        #expect(await registry.summary().bucket == .idle)
    }

    @Test("A running session that never ends goes idle after its lifetime")
    func runningSessionsExpire() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(start)
        let registry = SessionRegistry(now: { clock.now })
        _ = await registry.apply(event(.userPromptSubmit))
        #expect(await registry.bucket() == .running)

        clock.advance(by: 3 * 60 * 60)
        #expect(await registry.bucket() == .idle)
    }

    @Test("Refresh publishes an expired running bucket")
    func refreshPublishesExpiry() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(start)
        let registry = SessionRegistry(now: { clock.now })
        let recorder = BucketRecorder()
        _ = await registry.apply(event(.userPromptSubmit))

        clock.advance(by: 3 * 60 * 60)
        await registry.refresh(onStateChange: recorder.append)

        #expect(recorder.values.map(\.bucket) == [.idle])
    }

    @Test("Refresh waits until the next session transition")
    func nextRefreshDelayTracksSessionTransitions() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(start)
        let registry = SessionRegistry(now: { clock.now })

        #expect(await registry.nextRefreshDelay() == nil)

        _ = await registry.apply(event(.userPromptSubmit))
        #expect(await registry.nextRefreshDelay() == 2 * 60 * 60)

        clock.advance(by: 3 * 60 * 60)
        #expect(await registry.nextRefreshDelay() == 21 * 60 * 60)
    }

    @Test("A new event moves the scheduled session expiry")
    func newEventMovesNextRefreshDelay() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(start)
        let registry = SessionRegistry(now: { clock.now })
        _ = await registry.apply(event(.userPromptSubmit))

        clock.advance(by: 60 * 60)
        _ = await registry.apply(event(.postToolUse))

        #expect(await registry.nextRefreshDelay() == 2 * 60 * 60)
    }

    @Test("A payload version the daemon does not know is dropped")
    func unknownVersionsAreIgnored() async throws {
        let registry = SessionRegistry()
        let json = #"{"version":99,"source":"claude","kind":"UserPromptSubmit","sessionID":"s1","isQuestion":false}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(await registry.apply(event) == .idle)
    }
}

private final class BucketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SessionRegistry.Summary] = []

    var values: [SessionRegistry.Summary] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ summary: SessionRegistry.Summary) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(summary)
    }
}

/// A minimal movable clock for the staleness test.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value.addTimeInterval(interval)
    }
}
