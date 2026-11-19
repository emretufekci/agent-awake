import Cocoa

/// Reads (and types into) iTerm2 / Terminal.app sessions via AppleScript, keyed by tty name ("ttys002").
/// macOS asks once for Automation permission ("AgentAwake wants to control iTerm2").
enum TerminalScreens {
    enum App: String, Codable, CaseIterable {
        case iterm, terminal
        var bundleID: String { self == .iterm ? "com.googlecode.iterm2" : "com.apple.Terminal" }
    }

    /// Maps the ".app" name found among an agent's ancestor processes to a scriptable terminal.
    static func app(forName name: String?) -> App? {
        guard let n = name?.lowercased() else { return nil }
        if n.hasPrefix("iterm") { return .iterm }
        if n == "terminal" { return .terminal }
        return nil
    }

    static func isRunning(_ app: App) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    /// Last ~150 lines of every session of `app`, keyed by tty name. Never launches the app.
    static func read(_ app: App) -> [String: String] {
        guard isRunning(app) else { return [:] }
        let loop: String
        switch app {
        case .iterm:
            loop = """
                repeat with wi from 1 to count of windows
                  repeat with ti from 1 to count of tabs of window wi
                    repeat with si from 1 to count of sessions of tab ti of window wi
                      try
                        set c to contents of session si of tab ti of window wi
                        set out to out & (tty of session si of tab ti of window wi) & US & my tailOf(c) & RS
                      end try
                    end repeat
                  end repeat
                end repeat
            """
        case .terminal:
            loop = """
                repeat with wi from 1 to count of windows
                  repeat with ti from 1 to count of tabs of window wi
                    try
                      -- inline specifiers: "contents of <variable>" would dereference the variable instead
                      set c to contents of tab ti of window wi
                      set out to out & (tty of tab ti of window wi) & US & my tailOf(c) & RS
                    end try
                  end repeat
                end repeat
            """
        }
        let script = """
        on tailOf(c)
          set ps to paragraphs of c
          set n to count of ps
          if n > 150 then set ps to items (n - 149) thru n of ps
          set AppleScript's text item delimiters to linefeed
          return ps as text
        end tailOf
        set RS to character id 30
        set US to character id 31
        set out to ""
        tell application id "\(app.bundleID)"
        \(loop)
        end tell
        return out
        """
        guard let out = Shell.appleScript(script) else { return [:] }
        var result: [String: String] = [:]
        for record in out.split(separator: "\u{1E}") {
            let parts = record.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let tty = (parts[0].trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
            result[tty] = String(parts[1])
        }
        return result
    }

    /// Types `text` + Enter into the session attached to `tty`.
    static func type(_ text: String, app: App, tty: String) {
        let esc = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let dev = "/dev/" + tty
        let script: String
        switch app {
        case .iterm:
            script = """
            tell application id "com.googlecode.iterm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(dev)" then
                      tell s to write text "\(esc)" newline false
                      delay 0.6
                      tell s to write text ""
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        case .terminal:
            script = """
            tell application id "com.apple.Terminal"
              repeat with wi from 1 to count of windows
                repeat with ti from 1 to count of tabs of window wi
                  set t to tab ti of window wi
                  if tty of t is "\(dev)" then
                    do script "\(esc)" in t
                    return
                  end if
                end repeat
              end repeat
            end tell
            """
        }
        _ = Shell.appleScript(script)
    }
}
