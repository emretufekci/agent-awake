# AgentAwake

A tiny macOS menu bar app that keeps your Mac awake while your **Claude Code / Codex agents running in tmux** are working — then puts the Mac to sleep when they're done.

Single Swift file, no dependencies, no Xcode project.

## Features

- **Wait for tmux agents, then sleep** — scans every tmux pane for `claude` / `codex` processes. A pane counts as *working* if its screen shows `esc to interrupt` or its process tree uses >15% CPU (long builds/tests). Once every agent has been idle for a grace period (default 3 min), the Mac sleeps.
- **Keep awake for** 15 min – 8 hours, or **indefinitely**.
- The display is allowed to turn off; only system sleep is blocked (optionally keep the display on too).
- Live agent list in the menu (`● claude main:1.0 — working`).
- Safety limit for agent-wait mode (default 8 h).
- Won't force sleep if you've used the keyboard/mouse in the last 60 s.
- Languages: English, Türkçe (or follow system language).

## Install

```bash
git clone https://github.com/emretufekci/agent-awake.git
cd agent-awake
./build.sh --install          # builds, copies to ~/Applications, launches
./build.sh --install --login  # also start at login
```

Requires macOS 11+ and the Xcode Command Line Tools (`xcode-select --install`). tmux is looked up in `/opt/homebrew/bin`, `/usr/local/bin` and `/usr/bin`.

## Notes

- Closing the MacBook lid still sleeps the Mac (unless in clamshell mode with power + external display) — keep the lid open.
- Check the active sleep block with `pmset -g assertions | grep AgentAwake`.

## Adding a language

Add a case to `Lang` and a table to `Loc.strings` in `Sources/main.swift`. Missing keys fall back to English.

## License

MIT
