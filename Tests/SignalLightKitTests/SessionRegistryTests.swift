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
                    onBucketChange: recorder.append
                )
            }
            group.addTask {
                _ = await registry.apply(
                    event(.userPromptSubmit, session: "running"),
                    onBucketChange: recorder.append
                )
            }
        }

        let currentBucket = await registry.bucket()
        #expect(recorder.values.last == currentBucket)
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
        await registry.refresh(onBucketChange: recorder.append)

        #expect(recorder.values == [.idle])
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
    private var recorded: [SignalLightBucket] = []

    var values: [SignalLightBucket] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ bucket: SignalLightBucket) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(bucket)
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
