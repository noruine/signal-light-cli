import Foundation

/// User-configurable signal-light behavior: which effect each working-state
/// bucket shows, the global brightness, and a master on/off. Mirrors what the
/// macOS app persists in `UserDefaults` (`AppModel.signalLightEffects` /
/// `signalLightBrightness` / `signalLightEnabled`), but stored as a plain
/// JSON file so the CLI daemon and the `config` command share one source of
/// truth without a preferences domain a bare CLI can't reliably own.
public struct SignalLightSettings: Codable, Sendable, Equatable {
    /// Per-bucket effect overrides. A bucket absent here falls back to
    /// `SignalLightEffect.defaultEffect(for:)`, so an older settings file
    /// that predates a new bucket still resolves sensibly.
    public var effects: [SignalLightBucket: SignalLightEffect]
    /// Global brightness percent, 0–100.
    public var brightness: Int
    /// Master switch. When `false`, the daemon sends `OFF` regardless of
    /// session state.
    public var enabled: Bool

    public init(effects: [SignalLightBucket: SignalLightEffect], brightness: Int, enabled: Bool) {
        self.effects = effects
        self.brightness = brightness
        self.enabled = enabled
    }

    /// The out-of-box configuration: every bucket on its default effect,
    /// full brightness, enabled. Matches the app's first-run behavior.
    public static var `default`: SignalLightSettings {
        SignalLightSettings(
            effects: Dictionary(uniqueKeysWithValues: SignalLightBucket.allCases.map { ($0, .defaultEffect(for: $0)) }),
            brightness: 100,
            enabled: true
        )
    }

    /// The effect to display for `bucket`, honoring an override or falling
    /// back to the default. Independent of `enabled` — callers decide whether
    /// to send this or `OFF`.
    public func effect(for bucket: SignalLightBucket) -> SignalLightEffect {
        effects[bucket] ?? .defaultEffect(for: bucket)
    }

    /// Clamps brightness into the valid 0–100 range, so a hand-edited or
    /// out-of-range value can never be sent to the firmware verbatim.
    public var clampedBrightness: Int {
        min(100, max(0, brightness))
    }
}

public enum SignalLightSettingsStore {
    /// Loads settings from `url`, or returns `.default` when the file is
    /// missing — a fresh install behaves exactly like the app's first run.
    public static func load(from url: URL, fileManager: FileManager = .default) throws -> SignalLightSettings {
        guard fileManager.fileExists(atPath: url.path) else {
            return .default
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SignalLightSettings.self, from: data)
    }

    public static func save(_ settings: SignalLightSettings, to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
