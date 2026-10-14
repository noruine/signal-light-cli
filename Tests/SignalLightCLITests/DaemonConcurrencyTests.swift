import Dispatch
import Foundation
import Testing
import SignalLightKit

@testable import SignalLightCLICore

@Suite("Daemon update ordering")
struct DaemonConcurrencyTests {
    @Test("A later bucket update cannot overtake a pending light update")
    func lightCommandsStayInStateOrder() async {
        let recorder = BlockingRecorder<DesiredLightState>()
        let controller = LightController(
            settingsURL: URL(fileURLWithPath: "/tmp/signal-light-settings-test.json"),
            log: RestrainedLog(url: URL(fileURLWithPath: "/tmp/signal-light-log-test.log")),
            sendDesiredState: { brightness, effect in
                recorder.append(DesiredLightState(brightness: brightness, effect: effect))
            }
        )

        let firstUpdate = Task.detached { controller.applyBucket(.running) }
        let firstWrite = await waitFor(recorder.firstWriteEntered, timeout: 1)
        #expect(firstWrite == .success)

        let secondAttempted = DispatchSemaphore(value: 0)
        let secondUpdate = Task.detached {
            secondAttempted.signal()
            controller.applyBucket(.needsApproval)
        }
        let secondDidStart = await waitFor(secondAttempted, timeout: 1)
        #expect(secondDidStart == .success)
        let secondWrite = await waitFor(recorder.secondWriteEntered, timeout: 0.05)
        #expect(secondWrite == .timedOut)

        recorder.releaseFirstWrite.signal()
        await firstUpdate.value
        await secondUpdate.value

        let states = recorder.values
        #expect(states.map(\.effect) == [
            .defaultEffect(for: .running),
            .defaultEffect(for: .needsApproval),
        ])
    }

    @Test("Concurrent daemon snapshots are persisted in update order")
    func stateSnapshotsStayInUpdateOrder() async {
        let recorder = BlockingRecorder<SignalLightDaemonState>()
        let writer = DaemonStateWriter(
            paths: SignalLightDaemonPaths(home: URL(fileURLWithPath: "/tmp")),
            saveState: { recorder.append($0) }
        )
        let registry = SessionRegistry()
        _ = await registry.apply(HookEvent(source: .codex, kind: .userPromptSubmit, sessionID: "test"))
        let summary = await registry.summary()

        let firstUpdate = Task.detached { writer.updateBLE(.connected, deviceName: "light") }
        let firstWrite = await waitFor(recorder.firstWriteEntered, timeout: 1)
        #expect(firstWrite == .success)

        let secondAttempted = DispatchSemaphore(value: 0)
        let secondUpdate = Task.detached {
            secondAttempted.signal()
            writer.updateSessionSummary(summary)
        }
        let secondDidStart = await waitFor(secondAttempted, timeout: 1)
        #expect(secondDidStart == .success)
        let secondWrite = await waitFor(recorder.secondWriteEntered, timeout: 0.05)
        #expect(secondWrite == .timedOut)

        recorder.releaseFirstWrite.signal()
        await firstUpdate.value
        await secondUpdate.value

        let states = recorder.values
        #expect(states.count == 2)
        #expect(states[0].ble == .connected)
        #expect(states[0].currentBucket == nil)
        #expect(states[1].ble == .connected)
        #expect(states[1].currentBucket == SignalLightBucket.running.rawValue)
    }
}

private struct DesiredLightState: Sendable {
    let brightness: Int
    let effect: SignalLightEffect?
}

private func waitFor(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
        }
    }
}

private final class BlockingRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    private var writeCount = 0
    let firstWriteEntered = DispatchSemaphore(value: 0)
    let secondWriteEntered = DispatchSemaphore(value: 0)
    let releaseFirstWrite = DispatchSemaphore(value: 0)

    func append(_ value: Value) {
        lock.lock()
        writeCount += 1
        let currentWrite = writeCount
        if currentWrite == 1 { firstWriteEntered.signal() }
        if currentWrite == 2 { secondWriteEntered.signal() }
        lock.unlock()

        if currentWrite == 1 {
            releaseFirstWrite.wait()
        }

        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
