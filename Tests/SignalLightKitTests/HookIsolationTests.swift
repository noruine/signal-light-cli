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

    @Test("Codex compaction does not reset a running session")
    func codexSessionStartMatcherExcludesCompaction() throws {
        let installed = try CodexHookInstaller.installHooksJSON(
            existingData: nil,
            hookCommand: managedCommand
        )
        let contents = try #require(installed.contents)
        let object = try JSONSerialization.jsonObject(with: contents)
        let root = try #require(object as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let groups = try #require(hooks["SessionStart"] as? [[String: Any]])
        let matcher = try #require(groups.first?["matcher"] as? String)

        #expect(matcher == "startup|resume|clear")
        #expect(!matcher.contains("compact"))
    }

    @Test("Managed hooks observe answers and completed tools")
    func managedHooksObserveResolutionEvents() throws {
        #expect(ClaudeHookInstaller.managedEventNames.contains("PreToolUse"))
        #expect(ClaudeHookInstaller.managedEventNames.contains("PostToolUse"))
        #expect(ClaudeHookInstaller.managedEventNames.contains("PostToolUseFailure"))
        #expect(CodexHookInstaller.managedEventNames.contains("PostToolUse"))

        let installed = try ClaudeHookInstaller.installSettingsJSON(
            existingData: nil,
            hookCommand: managedCommand
        )
        let contents = try #require(installed.contents)
        let object = try JSONSerialization.jsonObject(with: contents)
        let root = try #require(object as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let groups = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(groups.contains { $0["matcher"] as? String == "AskUserQuestion" })
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

    @Test("Managed binary install refuses to replace a destination directory")
    func managedBinaryPreservesDestinationDirectory() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let source = scratch.appendingPathComponent("source")
        let destination = scratch.appendingPathComponent("agent-hooks", isDirectory: true)
        let marker = destination.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source)
        try Data("keep".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: scratch) }

        do {
            try ManagedHooksBinary.install(from: source, to: destination)
            Issue.record("Expected install to reject a destination directory.")
        } catch let error as ManagedHooksBinaryError {
            #expect(error == .destinationIsDirectory(destination))
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
    }

    @Test("Uninstall finds managed hooks when the install manifest is missing")
    func uninstallFindsHooksWithoutManifest() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let claudeDirectory = scratch.appendingPathComponent("claude", isDirectory: true)
        let codexDirectory = scratch.appendingPathComponent("codex", isDirectory: true)
        let binaryURL = scratch.appendingPathComponent("bin/agent-hooks")
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let claudeCommand = ClaudeHookInstaller.hookCommand(for: binaryURL.path)
        let claudeSettings = try ClaudeHookInstaller.installSettingsJSON(
            existingData: nil,
            hookCommand: claudeCommand
        )
        try #require(claudeSettings.contents).write(
            to: claudeDirectory.appendingPathComponent("settings.json")
        )

        let codexCommand = CodexHookInstaller.hookCommand(for: binaryURL.path)
        let codexHooks = try CodexHookInstaller.installHooksJSON(existingData: nil, hookCommand: codexCommand)
        try #require(codexHooks.contents).write(to: codexDirectory.appendingPathComponent("hooks.json"))
        let codexConfig = codexDirectory.appendingPathComponent("config.toml")
        try "[features]\nhooks = true\n".write(to: codexConfig, atomically: true, encoding: .utf8)

        let claudeManager = ClaudeHookInstallationManager(
            claudeDirectory: claudeDirectory,
            managedHooksBinaryURL: binaryURL
        )
        let codexManager = CodexHookInstallationManager(
            codexDirectory: codexDirectory,
            managedHooksBinaryURL: binaryURL
        )
        _ = try claudeManager.uninstall()
        _ = try codexManager.uninstall()

        #expect(!FileManager.default.fileExists(atPath: claudeDirectory.appendingPathComponent("settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: codexDirectory.appendingPathComponent("hooks.json").path))
        #expect(try String(contentsOf: codexConfig, encoding: .utf8) == "[features]\nhooks = true\n")
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
