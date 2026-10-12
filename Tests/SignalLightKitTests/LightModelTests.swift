import Foundation
import Testing

@testable import SignalLightKit

@Suite("Light model")
struct LightModelTests {
    @Test("Effect commands survive an encode/decode round trip")
    func effectRoundTrip() throws {
        let effect = SignalLightEffect(type: .breathe, colors: [.yellow, .red], intervalMs: 1200)
        let command = SignalLightCommandEncoder.encode(effect)
        #expect(command == "EFFECT:BREATHE:YR:1200")

        let decoded = try #require(SignalLightCommandEncoder.decode(command))
        #expect(decoded == effect)
    }

    @Test("Malformed effect commands decode to nil, never a crash")
    func malformedEffect() {
        for text in ["", "EFFECT", "EFFECT:NOPE:R:1", "EFFECT:SOLID:X:1", "EFFECT:SOLID:R"] {
            #expect(SignalLightCommandEncoder.decode(text) == nil, "\(text) must not decode")
        }
    }

    @Test("Firmware versions parse and compare numerically")
    func firmwareVersions() throws {
        #expect(SignalLightFirmwareVersion("1.9.0")! < SignalLightFirmwareVersion("1.10.0")!)
        #expect(SignalLightFirmwareVersion("1.2.3")! == SignalLightFirmwareVersion("1.2.3")!)
        #expect(SignalLightFirmwareVersion("2.0") == nil)
        #expect(SignalLightFirmwareVersion("a.b.c") == nil)
    }

    @Test("Bucket raw values are a persisted contract")
    func bucketRawValues() {
        #expect(SignalLightBucket.needsApproval.rawValue == "needsApproval")
        #expect(SignalLightBucket.needsAnswer.rawValue == "needsAnswer")
        #expect(SignalLightBucket.running.rawValue == "running")
        #expect(SignalLightBucket.idle.rawValue == "idle")
    }

    @Test("Settings survive a save/load round trip")
    func settingsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "signal-light-test-\(UUID().uuidString)")
            .appending(path: "settings.json")
        var settings = SignalLightSettings.default
        settings.brightness = 42
        settings.enabled = false
        settings.effects[.needsApproval] = SignalLightEffect(type: .cycle, colors: [.red, .green], intervalMs: 300)

        try SignalLightSettingsStore.save(settings, to: url)
        let loaded = try SignalLightSettingsStore.load(from: url)
        #expect(loaded == settings)

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("A missing settings file loads defaults")
    func settingsMissingFile() throws {
        let url = URL(filePath: "/tmp/signal-light-absent-\(UUID().uuidString)/settings.json")
        let loaded = try SignalLightSettingsStore.load(from: url)
        #expect(loaded == SignalLightSettings.default)
    }

    @Test("Paired device survives a save/load round trip")
    func deviceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "signal-light-test-\(UUID().uuidString)")
            .appending(path: "device.json")
        let device = SignalLightPairedDevice(name: "mylight", identifier: UUID().uuidString)

        try SignalLightDeviceStore.save(device, to: url)
        #expect(try SignalLightDeviceStore.load(from: url) == device)

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("Daemon state survives a save/load round trip")
    func daemonStateRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "signal-light-test-\(UUID().uuidString)")
            .appending(path: "state.json")
        let state = SignalLightDaemonState(
            ble: .connected,
            deviceName: "mylight",
            currentBucket: SignalLightBucket.needsApproval.rawValue,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pid: 4321
        )

        try SignalLightDaemonStateStore.save(state, to: url)
        #expect(try SignalLightDaemonStateStore.load(from: url) == state)

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
