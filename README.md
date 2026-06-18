<div align="center">

# waik

**Close the lid. Claude keeps working.**

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/swift-5.9-orange?logo=swift)](https://swift.org)
[![Build](https://img.shields.io/badge/build-SwiftPM-blue)](https://swift.org/package-manager/)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

</div>

<p align="center">
  <img src="docs/hero.png" width="320" alt="waik menu bar popover"/>
</p>

`waik` is a tiny macOS menu bar app that keeps your Mac awake — including with the lid closed — *only* while Claude Code or Codex is mid-turn. You start a long task, shut the laptop, walk away. When you come back, the answer's done.

The moment the agent finishes, the assertion drops and your Mac is free to sleep again. No timers. No "stay awake until I remember to undo it." No `caffeinate` sitting there for three days.

---

## How it works

Both Claude Code and Codex already fire hooks at the lifecycle moments waik cares about — when a turn starts, when it ends, when it pauses for user input. waik installs into those hook configs and listens on a loopback socket. Activity becomes a direct signal instead of an inferred one.

```
┌────────────────────┐    hooks      ┌──────────────────┐
│ Claude / Codex     │ ────────────▶ │ waik-hook (CLI)  │
│ (lifecycle events) │               │ small, no-op if  │
└────────────────────┘               │ waik not running │
                                     └────────┬─────────┘
                                              │ POST /event
                                              ▼
                                     ┌──────────────────┐
                                     │ HookServer       │
                                     │   sessions[tool/ │
                                     │   session_id]    │
                                     └────────┬─────────┘
                                              │
                                              ▼
                                     ┌──────────────────┐
                                     │ AppCoordinator   │
                                     │   engaged ⇔      │
                                     │   any session    │
                                     │   open           │
                                     └────────┬─────────┘
                                              │
                       ┌──────────────────────┼─────────────────────┐
                       ▼                      ▼                     ▼
              ┌──────────────┐      ┌──────────────────┐   ┌─────────────────┐
              │ IOPMAssertion│      │ XPC helper       │   │ Menu bar UI     │
              │ (idle sleep) │      │ SleepDisabled    │   │ live state      │
              └──────────────┘      │ (system + lid)   │   └─────────────────┘
                                    └──────────────────┘
```

The keep-awake stays on as long as `sessions` is non-empty. Multiple windows of Claude and Codex running concurrently? Each is its own entry; only when the last one closes does the Mac get to sleep.

## Install

### Homebrew (recommended)

```bash
brew tap joshuajomiller/waik
brew install --cask waik
```

### From source

```bash
git clone https://github.com/joshuajomiller/waik.git
cd waik
Scripts/build.sh
open build/waik.app
```

### Requirements

- macOS 13 (Ventura) or later.
- Apple Silicon or Intel.
- Swift 5.9+ toolchain (Xcode 15 or `xcode-select --install`).

## First-time setup

1. **Approve the helper daemon.** On first launch, macOS prompts you to enable a background item under **System Settings → Login Items**. The helper is what lets waik keep the Mac awake with the lid *closed*, not just the display. Without it, lid-closed sleep wins and your agent stops.
2. **Install the hooks.** Click the menu bar icon → **Agent hooks** → **Install** for `claude` and `codex`. waik adds entries to:
   - `~/.claude/settings.json` (Claude Code hooks)
   - `~/.codex/config.toml` (Codex `notify`, chained so your existing notify program keeps working)
   - `~/Library/Application Support/waik/waik-hook` (the launcher binary the hooks point at)

   Uninstall from the same menu — waik tracks its own entries and removes only those.

That's it. The first turn after install should show "Keep-awake engaged" in the menu the moment you submit a prompt.

## Usage

The menu bar icon flips between two states:

- **`bolt`** (outline) — Idle. Mac is allowed to sleep.
- **`bolt.fill`** (filled) — Engaged. At least one agent session is mid-turn.

Click for:

- **Status** — `Idle`, `Keep-awake engaged · claude · 2 sessions`, `Forced awake`, `Monitoring paused`.
- **Force keep awake** — pin the assertion on regardless of session state.
- **Pause monitoring** — temporarily ignore hooks (useful while debugging).
- **Sleep on low battery** — release the assertion below a chosen battery %, even mid-turn. Off by default.
- **Agent hooks** — per-tool install/uninstall + status.

Set it and forget it. Most users open the menu twice: once to install hooks, once to enable launch-at-login.

## Architecture notes

For the curious or the contributors:

- **`HookServer`** binds `127.0.0.1` on a kernel-assigned ephemeral port, writes the port + a per-launch HMAC-style token to `~/Library/Application Support/waik/control.port`. The CLI reads the file, the server requires the token. No JSON-on-internet drama, no certificates, no kernel extension.
- **`waik-hook`** is a ~80-line Swift CLI bundled in the .app. Hook entries point at a *stable* path under `~/Library/Application Support/waik/`, which waik refreshes from the bundle on every launch — moving the .app doesn't strand the hooks.
- **`HookInstaller`** owns the JSON/TOML editing. Claude entries are tagged with `_waik: true` so uninstall is precise. Codex `notify` gets wrapped by a generated bash script that calls waik-hook *and* forwards to your previous notify program — your Codex desktop notifications keep firing.
- **The helper daemon** is a privileged on-demand LaunchDaemon. Its entire XPC surface is two methods: `ping()` and `setSleepDisabled(Bool)`. It exists because lid-closed sleep requires a system power setting (`SleepDisabled`) the unprivileged app can't write.

Event mapping:

| Claude hook         | Codex notify type     | waik event           | Effect                      |
|---------------------|-----------------------|----------------------|------------------------------|
| `UserPromptSubmit`  | —                     | `turn_start`         | Add session, engage         |
| `Stop`              | `agent-turn-complete` | `turn_end`           | Remove session              |
| `Notification`      | `approval-requested`, `plan-mode-prompt` | `waiting_for_input` | Remove session (you're back) |
| `SubagentStop`      | —                     | `subagent_end`       | Logged, ignored for state   |

## Privacy

Everything stays on-device.

- No telemetry, no analytics.
- No network code beyond the local loopback listener and Sparkle's update check.
- Hook events that flow over loopback contain the agent's tool name, session ID, current working directory, and event kind. Nothing else.
- waik reads and writes two files in your home directory (`~/.claude/settings.json`, `~/.codex/config.toml`), and only the entries it owns. Uninstall is reversible: backups of the prior Codex `notify` live at `~/Library/Application Support/waik/codex-notify-original.json`.

## Building

```bash
# Debug build (ad-hoc signed, fine for local use)
Scripts/build.sh

# Release build
CONFIG=release Scripts/build.sh

# Signed for distribution
SIGN_ID="Developer ID Application: Your Name (TEAMID)" Scripts/build.sh
```

Output is a self-contained `build/waik.app` with the helper daemon under `Contents/Library/LaunchDaemons` and `waik-hook` under `Contents/MacOS`. SMAppService handles helper registration at first launch.

For tagged releases, Developer ID signing, notarization, Sparkle auto-updates, and the Homebrew cask pipeline: see [docs/RELEASING.md](docs/RELEASING.md).

### Project layout

| Path | What's in it |
|---|---|
| `Sources/WaikApp` | Menu bar app — coordinator, `HookServer`, `HookInstaller`, SwiftUI. |
| `Sources/waik-hook` | Tiny CLI invoked from external hooks. |
| `Sources/WaikHelper` | Privileged helper daemon — XPC wrapper around the unpublished `IOPMSetSystemPowerSetting`. |
| `Sources/WaikShared` | XPC protocol + constants shared between app and helper. |
| `Resources` | Info.plist, daemon plist, entitlements. |
| `Scripts/build.sh` | Assembles + signs the .app bundle. |

## Troubleshooting

<details>
<summary><strong>Menu shows "Idle" while Claude is clearly running</strong></summary>

Hooks aren't installed (or were installed pointing at a stale bundle path). Open the menu → **Agent hooks** → check the status badge. If it says `not installed` or `partial`, click **Install**. If you moved or rebuilt waik.app since the last install, the hooks may still point at the old path — `Uninstall` then `Install` to repoint them at the stable launcher.
</details>

<details>
<summary><strong>"Daemon awaiting approval" warning</strong></summary>

macOS requires you to opt in to background items. Click **Open Login Items…** in the popover, find `waik`, toggle it on. The warning clears within a few seconds. Until then, lid-closed sleep wins and waik can only delay *idle* sleep — display sleep with the lid open is still suppressed.
</details>

<details>
<summary><strong>Lid-closed sleep happens anyway</strong></summary>

Two things to check, in order. First, the helper daemon must be approved (see above) — without it, the `SleepDisabled` system flag never gets written. Second, the build must be Developer ID signed; ad-hoc signed dev builds can't register the daemon at all. `Scripts/build.sh` without `SIGN_ID` is ad-hoc.

If you're stuck in a state where the lid won't sleep even after quitting waik: `sudo pmset -a disablesleep 0` clears the system flag. A reboot does too.
</details>

<details>
<summary><strong>I use a custom Codex <code>notify</code> program</strong></summary>

waik wraps it, not replaces it. The installer writes a small bash chain script that calls waik-hook *then* `exec`s your original notify program with the original args. Codex desktop notifications, Slack pings, whatever you had — still works. The original command is saved at `~/Library/Application Support/waik/codex-notify-original.json` and restored on uninstall.
</details>

<details>
<summary><strong>Cursor / Zed / VS Code support</strong></summary>

Not in this release. The first version of waik scraped network connections, which let it cover any process that talked to api.anthropic.com — but at the cost of false positives, polling overhead, and DNS guesswork. The hook-based approach is precise and instant, but limited to tools that fire lifecycle hooks. Cursor and Zed land here when they grow comparable mechanisms.

If you need network-scraping coverage today, the `pre-hooks-backup` branch on this repo has the last commit before the rewrite.
</details>

## Contributing

PRs welcome. The most useful additions are around the hook installer — particularly support for new agents as they ship hook APIs. Please:

1. Confirm the agent's hook payload shape with a manual test (echo the JSON into `waik-hook <tool> <event>`).
2. Add the agent to `Preferences.supportedTools` and extend `HookInstaller` with the install/uninstall path for its config file.
3. Note in the PR description which hook events you mapped to which waik event and why.

## License

MIT — see [LICENSE](LICENSE).
