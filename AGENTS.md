# AGENTS

Working agreement for coding agents in this repository.

## What this is

`signal-light` drives a real ESP32-C3 traffic light over BLE: a CLI, a launchd
daemon, and a hook forwarder that turns Claude Code / Codex session state into
light colors. A neighbor's light may be in range — the safety rules below exist
because an agent once paired with the wrong one.

## Commands

| Task | Command |
| --- | --- |
| Build | `make build` |
| Test | `make test` |
| Package | `make package` |
| Format / lint / copy check | `make format`, `make lint` (needs `swiftformat` and `swiftlint` from brew) |

- Always build with `--build-system native`; the Makefile and scripts pass it
  for you. CommandLineTools-only machines cannot initialize SwiftPM's default
  engine without it.
- `scripts/test.sh` adds the `Testing.framework` search path on
  CommandLineTools machines; prefer it (or `make test`) over a bare
  `swift test`.

## Layout

- `Sources/SignalLightKit` — the product core: BLE sessions, effects and
  settings, the session registry, the hook protocol (`Bridge/`), agent
  installers. No UI or app concerns belong here.
- `Sources/SignalLightCLI` — commands, interactive menu, daemon runner.
  `run` is the daemon itself.
- `Sources/SignalLightHooks` — fire-and-forget forwarder, one file.
- `Tests/SignalLightKitTests` — Swift Testing. Cover the key behavior (state
  machine, protocol round trip, mappings, stores), never chase percentages.
- `docs/bridge.md` — the socket protocol and the phase mapping. Changing either
  side means changing the doc.

## Hardware safety

Anything that opens BLE evicts the user's daemon (`DaemonPause`) and binds real
hardware.

- Pair, rename, calibrate or flash only when the user asked for it. Never pass
  `--first` when more than one light may be in range; the CLI refuses to guess.
- Do not `service stop`, `service restart` or `unpair` while testing.
- If a process is killed mid-operation the daemon can be left stopped: restore
  it with `signal-light service start` and tell the user.
- Hardware-free end-to-end check, with the daemon running:

  ```bash
  echo '{"hook_event_name":"UserPromptSubmit","session_id":"smoke","cwd":"/tmp"}' \
    | .build/release/signal-light-hooks --source claude
  .build/release/signal-light status   # bucket turns running
  echo '{"hook_event_name":"Stop","session_id":"smoke","cwd":"/tmp"}' \
    | .build/release/signal-light-hooks --source claude
  ```

## Conventions

- Swift 6 language mode with strict concurrency. Prefer actors and value types;
  `@unchecked Sendable` stays rare and always carries the invariant that makes
  it safe.
- User-facing copy is standard, natural Chinese; the 了 particle is banned
  outside 不了 / 为了 / 除了, and `make lint` enforces it. Output states facts
  and never asks for a keypress it does not need.
- Public kit API gets a one-line doc comment; internals do not need ceremony.
- New behavior lands with tests for the paths it actually runs in.

## Git

- Every round that changes files ends with a commit on the branch you are
  working in; one coherent change per commit.
- Subject: `type(scope): what and why`, ≤72 characters, lowercase except
  proper nouns and acronyms (`macOS`, `CLI`, `Bluetooth`).
- Body only when the diff cannot carry the why: `-` bullets, one per change,
  ≤72 characters each, stating the why — never a changelog, a file recap or a
  list of identifiers.
- No attribution lines. Never push, tag or open pull requests unless asked.
