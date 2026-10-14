# AGENTS

Working agreement for coding agents in this repository.

## What this is

`signal-light` drives a real ESP32-C3 traffic light over BLE: a CLI, a launchd
daemon, and a hook forwarder that turns Claude Code / Codex session state into
light colors. A neighbor's light may be in range — the safety rules below exist
because an agent once paired with the wrong one.

## Documentation ownership

- `README.md` is for users: installation, commands, behavior and hardware notes.
- This file is for contributors: code layout, invariants, validation and Git rules.
- `docs/bridge.md` defines the hook socket protocol and phase mapping; update it
  when either side changes.
- Keep implementation details and contributor workflow out of the README. Keep
  user setup and command explanations in the README instead of duplicating them
  here.

## Commands

| Task | Command |
| --- | --- |
| Build | `make build` |
| Install / upgrade locally | `make install` (builds, then runs the CLI's `upgrade`) |
| Test | `make test` |
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
- `Sources/SignalLightCLICore` — commands, interactive menu, daemon runner.
  `run` is the daemon itself. `Sources/SignalLightCLI` is the thin `@main`
  shell that exists only so tests can import the core.
- `Sources/SignalLightHooks` — fire-and-forget forwarder, one file.
- `Tests/SignalLightKitTests` — Swift Testing. Cover the key behavior (state
  machine, protocol round trip, mappings, stores), never chase percentages.
- `Tests/SignalLightCLITests` — the interactive chrome and copy wording (key
  bars, `ScreenLayout` frames, the header segments) plus the session retry
  policy.

## Hardware safety

Anything that opens BLE evicts the user's daemon (`DaemonPause`) and binds real
hardware.

- Pair, rename, calibrate or flash only when the user asked for it. Never pass
  `--first` when more than one light may be in range; the CLI refuses to guess.
- Do not `service stop`, `service restart` or `unpair` while testing.
- `make install`, `upgrade` and `sign` restart a running service by design; do not
  invoke them from automated checks or unrelated testing.
- A fake-`$HOME` run still shares the real per-user launchd label: set
  `SIGNAL_LIGHT_LAUNCHD_LABEL` to a value of its own in sandboxed checks, or a
  fake uninstall/stop boots out the real service. `SIGNAL_LIGHT_HOOKS_BINARY`
  scopes the hooks binary for the same reason.
- If a process is killed mid-operation the daemon can be left stopped: restore
  it with `signal-light service start` and tell the user.
- Hardware-free end-to-end check, with the daemon running:

  ```bash
  echo '{"hook_event_name":"UserPromptSubmit","session_id":"smoke","cwd":"/tmp"}' \
    | .build/release/agent-hooks --source claude
  .build/release/signal-light status   # bucket turns running
  echo '{"hook_event_name":"Stop","session_id":"smoke","cwd":"/tmp"}' \
    | .build/release/agent-hooks --source claude
  ```

## Conventions

- Swift 6 language mode with strict concurrency. Prefer actors and value
  types; `@unchecked Sendable` needs a stated reason — a named lock, queue
  or actor, or a stored type that is itself thread-safe.
- User-facing copy is standard, natural Chinese; the 了 particle is banned
  outside 不了 / 为了 / 除了, and `scripts/check-cli-copy.sh` (part of
  `make lint`) pins the rest: written register over spoken, the one key
  vocabulary (Enter / Space / ↑/↓ / Esc), operation headlines that carry
  their glyph, and no promises of actions that cannot happen. One vocabulary
  for results: 已X for a finished action, X完成 for a finished flow, X失败 for a
  failed one, 无法X for an environment limit, 已取消X for a cancel. Backing
  out of a yes/no question says nothing — the answer is the statement; a
  cancel that interrupts running work says its one line and returns. Only
  output worth reading asks for a keypress.
- Every interactive screen renders through `ScreenLayout` — breadcrumb,
  blank, context, blank, body, blank, key bar, only the footer dimmed —
  so spacing and color roles cannot drift between screens. The breadcrumb
  is menu chrome: bare CLI runs stay Unix-plain and pass no trail. `make
  lint` bans stale hint forms.
- Nothing touches the machine silently: an action that writes files, the
  keychain, or launchd is either a command the user typed or one they
  confirmed first, with the consequences said out loud.
- Every interactive screen shares the same chrome — its breadcrumb and key
  bar come from `Terminal.menuBreadcrumb` / `Terminal.keyBar`; only the
  body changes, and a page lists just the key hints it answers to.
- `VERSION` at the repo root is the human version, `0.Y.Z`: the last digit
  is a build counter — every commit that touches shipped code (`Sources/`,
  `Makefile`, `Package.swift`) increments it in the same commit. The middle
  digit moves only when the user calls a milestone, resetting the last
  digit to zero. Docs, tests and tooling leave it alone; no releases or
  tags, by design. Display only: change detection compares the source
  stamp, not the version.
- Results go to stdout, progress and warnings to stderr, so pipes stay clean.

## Git

- Every round that changes files ends with a commit on the branch you are
  working in; one coherent change per commit.
- Subject: `type(scope): what and why`, ≤72 characters, lowercase except
  proper nouns and acronyms (`macOS`, `CLI`, `Bluetooth`).
- Body only when the diff cannot carry the why: `-` bullets, one per change,
  ≤72 characters each, stating the why — never a changelog, a file recap or a
  list of identifiers.
- No attribution lines. Never push, tag or open pull requests unless asked.
