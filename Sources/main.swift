// AgentAwake — menu bar app that keeps your Mac awake for a fixed time,
// indefinitely, or until the AI coding agents (Claude Code, Codex, Gemini,
// Aider, OpenCode, …) running in tmux or a terminal finish, then optionally
// sleeps the Mac. Handles usage limits by sleeping until the reset and resuming.

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
