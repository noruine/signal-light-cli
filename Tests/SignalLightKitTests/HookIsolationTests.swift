import Foundation
import Testing

@testable import SignalLightKit

/// Installing or removing this tool's hooks must never rewrite entries that
/// another product wrote: an entry is recognized only by this tool's own
/// command or status message, so a foreign hook — whatever it looks like —
/// survives both flows untouched.
@Suite("Hook isolation")
struct HookIsolationTests {
    private let managedCommand = "'/Users/tester/.signal-light/bin/agent-hooks' --source claude"
    private let foreignCommand = "'/Users/tester/Applications/SomeOtherApp.app/Helpers/SomeOtherHooks'"
    private let foreignStatusMessage = "Managed by Some Other App"

    private func foreignSettingsJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": foreignCommand, "statusMessage": foreignStatusMessage]]],
                ],
            ],
        ])
    }

    /// Every hook command in the serialized hooks object. Compares parsed
    /// values on purpose: the encoder escapes `/` as `\/` in the JSON text,
    /// which agents decode away when they read the config.
    private func hookCommands(in data: Data) throws -> [String] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return hooks.values.flatMap { value -> [String] in
            ((value as? [Any]) ?? []).flatMap { item -> [String] in
                let group = item as? [String: Any] ?? [:]
                return ((group["hooks"] as? [Any]) ?? []).compactMap { hook in
                    (hook as? [String: Any])?["command"] as? String
                }
            }
        }
    }

    @Test("Claude install adds ours and leaves the foreign hook alone")
    func claudeInstallKeepsForeign() throws {
        let mutation = try ClaudeHookInstaller.installSettingsJSON(
            existingData: try foreignSettingsJSON(),
            hookCommand: managedCommand
        )
        let commands = try hookCommands(in: try #require(mutation.contents))
        let text = String(decoding: try #require(mutation.contents), as: UTF8.self)

        #expect(mutation.changed)
        #expect(commands.contains(foreignCommand))
        #expect(commands.contains(managedCommand))
        #expect(text.contains(foreignStatusMessage))
    }

    @Test("Claude uninstall removes only the hook it wrote")
    func claudeUninstallRemovesOnlyOurs() throws {
        let installed = try ClaudeHookInstaller.installSettingsJSON(
            existingData: try foreignSettingsJSON(),
            hookCommand: managedCommand
        )
        let removed = try ClaudeHookInstaller.uninstallSettingsJSON(
            existingData: try #require(installed.contents),
            managedCommand: managedCommand
        )
        let commands = try hookCommands(in: try #require(removed.contents))

        #expect(commands.contains(foreignCommand))
        #expect(!commands.contains(managedCommand))
        #expect(removed.changed)
    }

    @Test("Claude uninstall without our hooks leaves the file byte-for-byte alone")
    func claudeUninstallNoOpLeavesForeignFileUntouched() throws {
        let existing = try foreignSettingsJSON()
        let removed = try ClaudeHookInstaller.uninstallSettingsJSON(
            existingData: existing,
            managedCommand: managedCommand
        )

        #expect(!removed.changed)
        #expect(removed.contents == existing)
        #expect(!removed.managedHooksPresent)
    }

    @Test("Codex install and uninstall touch only this tool's entries")
    func codexRoundTripKeepsForeign() throws {
        let installed = try CodexHookInstaller.installHooksJSON(
            existingData: try foreignSettingsJSON(),
            hookCommand: managedCommand
        )
        var commands = try hookCommands(in: try #require(installed.contents))
        #expect(commands.contains(foreignCommand))
        #expect(commands.contains(managedCommand))

        let removed = try CodexHookInstaller.uninstallHooksJSON(
            existingData: try #require(installed.contents),
            managedCommand: managedCommand
        )
        commands = try hookCommands(in: try #require(removed.contents))
        #expect(commands.contains(foreignCommand))
        #expect(!commands.contains(managedCommand))
    }

    @Test("Codex uninstall without our hooks leaves the file byte-for-byte alone")
    func codexUninstallNoOpLeavesForeignFileUntouched() throws {
        let existing = try foreignSettingsJSON()
        let removed = try CodexHookInstaller.uninstallHooksJSON(
            existingData: existing,
            managedCommand: managedCommand
        )

        #expect(!removed.changed)
        #expect(removed.contents == existing)
    }

    @Test("The managed hook command carries --source codex")
    func codexHookCommandCarriesSource() {
        #expect(CodexHookInstaller.hookCommand(for: "/Users/tester/.signal-light/bin/agent-hooks")
            == "'/Users/tester/.signal-light/bin/agent-hooks' --source codex")
    }

    @Test("The managed hooks binary installs inside the tool's own root")
    func managedBinaryIsOwned() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".signal-light", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("agent-hooks")
        #expect(ManagedHooksBinary.defaultURL().standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test("The locator honors SIGNAL_LIGHT_HOOKS_BINARY and ignores the old key")
    func locatorEnvOverride() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let tools = scratch.appendingPathComponent("tools", isDirectory: true)
        let empty = scratch.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let binary = tools.appendingPathComponent("agent-hooks")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let viaNewKey = HooksBinaryLocator.locate(
            currentDirectory: empty,
            executableDirectory: empty,
            environment: ["SIGNAL_LIGHT_HOOKS_BINARY": binary.path]
        )
        #expect(viaNewKey == binary.standardizedFileURL)

        let viaOldKey = HooksBinaryLocator.locate(
            currentDirectory: empty,
            executableDirectory: empty,
            environment: ["OPEN_ISLAND_HOOKS_BINARY": binary.path]
        )
        #expect(viaOldKey != binary.standardizedFileURL)
    }
}
