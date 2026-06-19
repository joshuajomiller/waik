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
<summary><strong>Zed / VS Code support</strong></summary>

Not yet. Neither currently exposes a per-turn lifecycle hook waik can install into. They'll land here when those mechanisms ship.
</details>

## License

MIT — see [LICENSE](LICENSE).
