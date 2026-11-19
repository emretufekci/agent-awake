# AgentAwake

A tiny macOS menu bar app that keeps your Mac awake while your **AI coding agents** (Claude Code, Codex, Gemini, Aider, OpenCode, …) are working — in **tmux** or **directly in a terminal** — then puts the Mac to sleep when they're done.

Single Swift file, no dependencies, no Xcode project.

## Features

- **Wait for agents, then sleep** — watches agents in two places, side by side:
  - **tmux** panes: *working* if the pane shows `esc to interrupt`, or its process tree uses ≥5% CPU.
  - **Terminal** (Terminal.app, iTerm2, Ghostty, VS Code, …): *working* if the agent's process tree uses ≥5% CPU (a working Claude Code uses ~10–15%, an idle one ~0–1.5%).

  Once every agent has been idle for a grace period (default 3 min), the Mac sleeps.
- **Agent groups** you can toggle in Settings: Claude Code, Codex, and **Other** (Gemini, Aider, OpenCode, Cursor Agent, Amp, Goose, Qwen, Crush, Copilot CLI, Droid, Kiro, Cline).
- **Keep awake for** 15 min – 8 hours, or **indefinitely**.
- The display is allowed to turn off; only system sleep is blocked (optionally keep the display on too).
- Live agent list in the menu, grouped by tmux / Terminal (`● claude  iTerm · ttys002 — working`).
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

## Adding an agent

Add its executable name to `AgentMonitor.knownAgents` in `Sources/main.swift`.

## Adding a language

Add a case to `Lang` and a table to `Loc.strings` in `Sources/main.swift`. Missing keys fall back to English.

## License

MIT
