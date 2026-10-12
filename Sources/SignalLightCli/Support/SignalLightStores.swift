import Foundation
import SignalLightKit

/// Reads the CLI's own small JSON stores (settings, paired device) with one
/// recoverable, spoken-Chinese error apiece.
///
/// Core's stores throw raw `DecodingError`s — English, wrapped around an
/// `NSJSONSerialization` dump. Letting one escape to the top level would print
/// that next to every command that reads settings or the paired device, and
/// leave the user with an exit code and no next step.
enum SignalLightStores {
    static func loadSettings(from url: URL) throws -> SignalLightSettings {
        do {
            return try SignalLightSettingsStore.load(from: url)
        } catch {
            throw CLIError(
                "灯效配置读取失败（文件可能已损坏）。可以运行 signal-light config reset 恢复默认。",
                exitCode: .config
            )
        }
    }

    static func loadPairedDevice(from url: URL) throws -> SignalLightPairedDevice? {
        do {
            return try SignalLightDeviceStore.load(from: url)
        } catch {
            throw CLIError("保存的配对信息读取失败，请重新配对：signal-light pair", exitCode: .config)
        }
    }
}
