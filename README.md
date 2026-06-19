<div align="center">

# waik

**Close the lid. Claude keeps working.**

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/swift-5.9-orange?logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

</div>

<p align="center">
  <img src="docs/hero.png" width="320" alt="waik menu bar popover"/>
</p>

`waik` is a tiny macOS menu bar app that keeps your Mac awake — including with the lid closed — *only* while Claude Code, Codex, or Cursor is mid-turn. You start a long task, shut the laptop, walk away. When you come back, the answer's done.

The moment the agent finishes, sleep is allowed again. No timers, no `caffeinate` you forget to turn off.

## How it works

Claude Code, Codex, and Cursor fire hooks when a turn starts and ends. waik installs into those hooks and keeps the Mac awake from the first event until the last open session closes. Multiple agents and windows count independently.

## Install

### Homebrew (recommended)

```bash
brew tap joshuajomiller/waik
brew install --cask waik
```

### Requirements

- macOS 13 (Ventura) or later
- Apple Silicon or Intel

## First-time setup

1. **Approve the helper.** On first launch, macOS prompts you to enable a background item under **System Settings → Login Items**. This is what lets waik keep the Mac awake with the lid *closed* — not just the display.
2. **Install the hooks.** Click the menu bar icon → **Agent hooks** → **Install** next to each tool you use (`claude`, `codex`, `cursor`). Uninstall from the same menu.

That's it. Submit a prompt and the menu shows "Keep-awake engaged."

## Usage

The menu bar icon flips between two states:

- **`bolt`** (outline) — Idle. Mac is allowed to sleep.
- **`bolt.fill`** (filled) — Engaged. At least one agent session is mid-turn.

The popover gives you:

- **Force keep awake** — pin the assertion on regardless of session state.
- **Pause monitoring** — temporarily ignore hooks.
- **Launch at login** — start waik on boot.
- **Sleep on low battery** — release the assertion below a chosen battery %, even mid-turn. Off by default.
- **Agent hooks** — per-tool install/uninstall + status.

## Privacy

Everything stays on-device.

- No telemetry, no analytics.
- No network code beyond a local loopback listener and Sparkle's update check.
- waik only reads and writes the agent config files it installs hooks into, and only the entries it owns. Uninstall is reversible.

## Troubleshooting

<details>
<summary><strong>Menu shows "Idle" while Claude is clearly running</strong></summary>

Open the menu → **Agent hooks** → check the status badge. If it says `not installed` or `partial`, click **Install**. If you moved or rebuilt waik.app, click **Uninstall** then **Install** to repoint the hooks.
</details>

<details>
<summary><strong>"Daemon awaiting approval" warning</strong></summary>

macOS requires you to opt in to background items. Click **Open Login Items…** in the popover, find `waik`, toggle it on.
</details>

<details>
<summary><strong>Lid-closed sleep happens anyway</strong></summary>

The helper must be approved (see above) — without it, lid-closed sleep wins. If you're stuck in a state where the lid won't sleep even after quitting waik: `sudo pmset -a disablesleep 0` clears the flag. A reboot does too.
</details>

<details>
<summary><strong>Menu stuck on "Keep-awake engaged" after the agent finished</strong></summary>

Usually means a `Stop` hook never fired — terminal closed mid-turn, process force-quit, or a network agent that doesn't emit a finish event. waik garbage-collects sessions older than an hour, but you don't have to wait: toggle **Pause monitoring** on then off, or quit and relaunch waik to reset.
</details>

<details>
<summary><strong>"waik can't be opened" / "Apple cannot check it for malicious software"</strong></summary>

Gatekeeper warning on a release that isn't notarized. Right-click the app in Finder → **Open** → **Open** in the confirmation dialog. macOS remembers the choice after the first time. (Installing via Homebrew avoids this.)
</details>

<details>
<summary><strong>My Codex desktop notifications stopped working</strong></summary>

waik wraps your existing Codex `notify` program rather than replacing it, but if the wrapper got into a bad state, **Agent hooks → Uninstall → Install** for `codex` rewrites it cleanly. Your original `notify` config is preserved across install/uninstall.
</details>

## License

MIT — see [LICENSE](LICENSE).
