# AgentAwake

A tiny macOS menu bar app that keeps your Mac awake while your **AI coding agents** (Claude Code, Codex, Gemini, Aider, OpenCode, …) are working — in **tmux**, **iTerm2** or **Terminal** — and puts the Mac to sleep when they're done. If an agent hits its usage limit, AgentAwake sleeps until the limit resets, wakes the Mac and types `continue`.

Plain Swift, no dependencies, no Xcode project.

## Install

**Homebrew**

```bash
brew tap emretufekci/tap
brew trust emretufekci/tap   # Homebrew 7+ asks you to trust third-party taps
brew install --cask agent-awake
```

**From source** (needs Xcode Command Line Tools: `xcode-select --install`)

```bash
git clone https://github.com/emretufekci/agent-awake.git
cd agent-awake
./build.sh --install    # universal build → ~/Applications, then launches
```

Requires macOS 11+.

## Features

- **Wait for agents, then sleep.** Watches agents side by side in:
  - **tmux** panes, iTerm2 and Terminal.app windows. AgentAwake reads the screen: `esc to interrupt` means the agent is working.
  - **Other terminals** (Ghostty, VS Code, …). These are judged by CPU only: ≥5 % of one core means working. A working Claude Code uses about 10–15 %; an idle one uses 0–1.5 %.

  Once every agent has been idle for a grace period (default 3 min), the Mac sleeps.
- **Questions in the menu bar.** When an agent waits for your answer (a permission prompt, a question, `y/n`), the menu bar shows `❓1`, a notification shows the question, and the agent list shows it. A waiting agent counts as idle, so the Mac may still sleep.
- **Auto-resume after usage limits.** When Claude Code or Codex hits its 5-hour or session limit, AgentAwake reads the reset time from the screen (`resets 3pm`, `try again in 2 hours 13 minutes`, `try again at 3:45 PM`, …). It sleeps the Mac until then, wakes it and types `continue` into the agent's pane or window.
  - Waking from sleep needs `pmset schedule wake`, which needs root. *Settings → Allow waking from sleep… (admin, once)* installs `/etc/sudoers.d/agentawake`, which allows only `pmset schedule wake` and `pmset schedule cancel wake` without a password. Without it, the Mac stays awake with the display off until the reset.
  - To change the message: `defaults write local.agentawake resumeText "please continue"`.
- **Picks up where it left off.** The current mode, timers, limit waits and the session are saved continuously and restored when the app is relaunched. *Settings → Start at login, reopen if it crashes* installs a LaunchAgent that starts the app at login and restarts it after a crash.
- **Battery limit slider.** Stops keeping the Mac awake when, on battery, the charge drops to the level you set (off to 50 %, default 20 %).
- **Session summary.** Shows how long each agent worked, the limits hit, resumes, questions, sleeps, recent events and past sessions. The full log is in `~/Library/Logs/AgentAwake.log`.
- **Keep awake for** 15 min – 8 h, or **indefinitely**. The display may turn off; only system sleep is blocked. You can keep the display on too.
- **Agent groups** you can toggle: Claude Code, Codex, and Other (Gemini, Aider, OpenCode, Cursor Agent, Amp, Goose, Qwen, Crush, Copilot CLI, Droid, Kiro, Cline).
- **Safety:** an agent-wait limit (default 8 h), and the app never forces sleep while you're using the keyboard or mouse.
- **Languages:** English and Türkçe, or the system language.

## Notes

- Closing the MacBook lid still sleeps the Mac (unless it's in clamshell mode with power and an external display), so keep the lid open.
- The first time AgentAwake reads iTerm2 or Terminal, macOS asks for Automation permission. To turn this off: *Settings → Read iTerm2 / Terminal screens*.
- To check the sleep block: `pmset -g assertions | grep AgentAwake`.

## Development

- `Sources/AgentMonitor.swift`: finds agents (process tree, tmux, terminals) and works out what each is doing.
- `Sources/TerminalScreens.swift`: AppleScript for reading and typing into iTerm2 and Terminal.
- `Sources/LimitParser.swift`: parses usage-limit messages.
- `Sources/AppDelegate.swift`: modes, menu, persistence, sleep and wake.
- To add an agent, add its executable name to `AgentMonitor.knownAgents`.
- To add a language, add a case to `Lang` and a table to `Loc.strings`. Missing keys fall back to English.
- To release, run `./release.sh 1.2.0`. It builds, publishes a GitHub release and updates the Homebrew tap.

## License

MIT
