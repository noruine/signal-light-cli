import Foundation

public struct ClaudeHookInstallerManifest: Equatable, Codable, Sendable {
    public static let fileName = "signal-light-claude-hooks-install.json"

    public var hookCommand: String
    public var installedAt: Date

    public init(hookCommand: String, installedAt: Date = .now) {
        self.hookCommand = hookCommand
        self.installedAt = installedAt
    }
}

public struct ClaudeHookFileMutation: Equatable, Sendable {
    public var contents: Data?
    public var changed: Bool
    public var managedHooksPresent: Bool
    public var hasClaudeIslandHooks: Bool

    public init(
        contents: Data?,
        changed: Bool,
        managedHooksPresent: Bool,
        hasClaudeIslandHooks: Bool
    ) {
        self.contents = contents
        self.changed = changed
        self.managedHooksPresent = managedHooksPresent
        self.hasClaudeIslandHooks = hasClaudeIslandHooks
    }
}

public enum ClaudeHookInstallerError: Error, LocalizedError {
    case invalidSettingsJSON

    public var errorDescription: String? {
        switch self {
        case .invalidSettingsJSON:
            "The existing Claude settings.json is not valid JSON."
        }
    }
}

public enum ClaudeHookInstaller {
    public static let managedTimeout = 86_400

    /// Tracks submitted prompts, approval requests, user questions, tool
    /// completion and turn/session endings for the signal light.
    private static let eventSpecs: [(name: String, matcher: String?, timeout: Int?)] = [
        ("SessionStart", "startup|resume|clear|fork", nil),
        ("UserPromptSubmit", nil, nil),
        ("PreToolUse", "AskUserQuestion", managedTimeout),
        ("PermissionRequest", "*", managedTimeout),
        ("PostToolUse", nil, managedTimeout),
        ("PostToolUseFailure", nil, managedTimeout),
        ("Stop", nil, nil),
        ("StopFailure", nil, nil),
        ("SessionEnd", nil, nil),
    ]

    /// The event names the managed install writes — exposed so the CLI can
    /// show exactly what "安装 hooks" hooked up.
    public static var managedEventNames: [String] {
        eventSpecs.map(\.name)
    }

    public static func hookCommand(for binaryPath: String, source: String = "claude") -> String {
        "\(shellQuote(binaryPath)) --source \(source)"
    }

    public static func installSettingsJSON(
        existingData: Data?,
        hookCommand: String
    ) throws -> ClaudeHookFileMutation {
        var rootObject = try loadRootObject(from: existingData)
        let existingHooksObject = rootObject["hooks"] as? [String: Any] ?? [:]
        var hooksObject: [String: Any] = [:]

        for (eventName, value) in existingHooksObject {
            let existingGroups = value as? [Any] ?? []
            let cleanedGroups = sanitizeForInstall(groups: existingGroups, replacingCommand: hookCommand)

            if !cleanedGroups.isEmpty {
                hooksObject[eventName] = cleanedGroups
            }
        }

        for spec in eventSpecs {
            let existingGroups = hooksObject[spec.name] as? [Any] ?? []
            let cleanedGroups = sanitizeForInstall(groups: existingGroups, replacingCommand: hookCommand)
            hooksObject[spec.name] = cleanedGroups + [managedGroup(matcher: spec.matcher, timeout: spec.timeout, hookCommand: hookCommand)]
        }

        rootObject["hooks"] = hooksObject
        let data = try serialize(rootObject)

        return ClaudeHookFileMutation(
            contents: data,
            changed: data != existingData,
            managedHooksPresent: true,
            hasClaudeIslandHooks: containsClaudeIslandHook(in: hooksObject)
        )
    }

    public static func uninstallSettingsJSON(
        existingData: Data?,
        managedCommand: String?
    ) throws -> ClaudeHookFileMutation {
        guard let existingData else {
            return ClaudeHookFileMutation(
                contents: nil,
                changed: false,
                managedHooksPresent: false,
                hasClaudeIslandHooks: false
            )
        }

        var rootObject = try loadRootObject(from: existingData)
        var hooksObject = rootObject["hooks"] as? [String: Any] ?? [:]
        var mutated = false

        // Scan every event in the file, not just the ones this installer
        // currently writes: installs from older versions may have left
        // managed hooks under events the minimal set no longer uses.
        for eventName in Array(hooksObject.keys) {
            let existingGroups = hooksObject[eventName] as? [Any] ?? []
            let cleanedGroups = sanitize(groups: existingGroups, managedCommand: managedCommand)

            // Only a hook that is actually ours counts as a change: `sanitize`
            // also drops malformed or empty foreign entries, and a file whose
            // hooks all belong to somebody else must come back byte-for-byte
            // untouched (a no-op uninstall may never reformat or claim to have
            // removed anything).
            if containsManagedHook(in: existingGroups, managedCommand: managedCommand) {
                mutated = true
            }

            if cleanedGroups.isEmpty {
                hooksObject.removeValue(forKey: eventName)
            } else {
                hooksObject[eventName] = cleanedGroups
            }
        }

        // Nothing of ours in the file: hand back the original bytes and claim
        // no change. Callers must never rewrite — let alone reformat — another
        // tool's config just because `signal-light hooks uninstall` ran.
        guard mutated else {
            return ClaudeHookFileMutation(
                contents: existingData,
                changed: false,
                managedHooksPresent: false,
                hasClaudeIslandHooks: containsClaudeIslandHook(in: hooksObject)
            )
        }

        if hooksObject.isEmpty {
            rootObject.removeValue(forKey: "hooks")
        } else {
            rootObject["hooks"] = hooksObject
        }

        let contents = rootObject.isEmpty ? nil : try serialize(rootObject)
        return ClaudeHookFileMutation(
            contents: contents,
            changed: true,
            managedHooksPresent: true,
            hasClaudeIslandHooks: containsClaudeIslandHook(in: hooksObject)
        )
    }

    private static func loadRootObject(from data: Data?) throws -> [String: Any] {
        guard let data else {
            return [:]
        }

        // Any parse failure — not just a valid-JSON non-object root — is this
        // product's "your config isn't usable" case, and must surface as that
        // typed error rather than as `JSONSerialization`'s Cocoa error, which
        // the caller would otherwise show verbatim.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let rootObject = object as? [String: Any] else {
            throw ClaudeHookInstallerError.invalidSettingsJSON
        }

        return rootObject
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func sanitize(groups: [Any], managedCommand: String?) -> [[String: Any]] {
        groups.compactMap { item in
            guard var group = item as? [String: Any] else {
                return nil
            }

            let existingHooks = group["hooks"] as? [Any] ?? []
            let filteredHooks = existingHooks.compactMap { hook -> [String: Any]? in
                guard let hook = hook as? [String: Any] else {
                    return nil
                }

                return isManagedHook(hook, managedCommand: managedCommand) ? nil : hook
            }

            guard !filteredHooks.isEmpty else {
                return nil
            }

            group["hooks"] = filteredHooks
            return group
        }
    }

    private static func sanitizeForInstall(groups: [Any], replacingCommand: String) -> [[String: Any]] {
        groups.compactMap { item in
            guard var group = item as? [String: Any] else {
                return nil
            }

            let existingHooks = group["hooks"] as? [Any] ?? []
            let filteredHooks = existingHooks.compactMap { hook -> [String: Any]? in
                guard let hook = hook as? [String: Any] else {
                    return nil
                }

                return isManagedHook(hook, managedCommand: replacingCommand) ? nil : hook
            }

            guard !filteredHooks.isEmpty else {
                return nil
            }

            group["hooks"] = filteredHooks
            return group
        }
    }

    private static func containsManagedHook(in groups: [Any], managedCommand: String?) -> Bool {
        groups.contains { item in
            guard let group = item as? [String: Any],
                  let hooks = group["hooks"] as? [Any] else {
                return false
            }

            return hooks.contains { hook in
                guard let hook = hook as? [String: Any] else {
                    return false
                }

                return isManagedHook(hook, managedCommand: managedCommand)
            }
        }
    }

    private static func containsClaudeIslandHook(in hooksObject: [String: Any]) -> Bool {
        hooksObject.values.contains { value in
            let groups = value as? [Any] ?? []
            return groups.contains { item in
                guard let group = item as? [String: Any],
                      let hooks = group["hooks"] as? [Any] else {
                    return false
                }

                return hooks.contains { hook in
                    guard let hook = hook as? [String: Any],
                          let command = hook["command"] as? String else {
                        return false
                    }

                    return command.contains("claude-island-state.py")
                }
            }
        }
    }

    private static func managedGroup(
        matcher: String?,
        timeout: Int?,
        hookCommand: String
    ) -> [String: Any] {
        var hook: [String: Any] = [
            "type": "command",
            "command": hookCommand,
        ]
        if let timeout {
            hook["timeout"] = timeout
        }

        var group: [String: Any] = [
            "hooks": [hook],
        ]

        if let matcher {
            group["matcher"] = matcher
        }

        return group
    }

    private static func isManagedHook(_ hook: [String: Any], managedCommand: String?) -> Bool {
        guard let managedCommand, let command = hook["command"] as? String else {
            return false
        }
        return command == managedCommand
    }

    private static func shellQuote(_ string: String) -> String {
        guard !string.isEmpty else {
            return "''"
        }

        return "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
