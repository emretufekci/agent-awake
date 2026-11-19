// AgentAwake — menu bar app that keeps your Mac awake for a fixed time,
// indefinitely, or until the AI coding agents (Claude Code, Codex, Gemini,
// Aider, OpenCode, …) running in tmux or directly in a terminal finish,
// then optionally puts the Mac to sleep.

import Cocoa
import IOKit.pwr_mgt

// MARK: - Shell helper

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C" // so `ps` prints 1.5 instead of 1,5
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Agent detection (tmux + plain terminals)

enum AgentGroup: String, CaseIterable {
    case claude, codex, other
}

enum AgentSource { case tmux, terminal }

enum BusyReason {
    case screen          // "esc to interrupt" visible in the tmux pane
    case cpu(Double)     // process tree is burning CPU
    case limited(Date)   // agent hit its usage limit; resets at this time
    case idle
}

struct AgentPane {
    let source: AgentSource
    let target: String   // "main:1.0" for tmux, "Ghostty · ttys003" for terminals
    let name: String     // "claude", "codex", "gemini", …
    let group: AgentGroup
    let reason: BusyReason
    var paneId: String? = nil   // tmux pane id (%3) — needed to type "continue"
    var limitKey: String? = nil
    var busy: Bool {
        switch reason { case .screen, .cpu: return true; case .idle, .limited: return false }
    }
    var limitReset: Date? { if case .limited(let d) = reason { return d } else { return nil } }
}

final class AgentMonitor {
    let tmuxPath: String? = [
        "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
        "/run/current-system/sw/bin/tmux",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Executable names we recognise as coding agents.
    static let knownAgents: [(name: String, group: AgentGroup)] = [
        ("claude", .claude), ("codex", .codex),
        ("gemini", .other), ("aider", .other), ("opencode", .other), ("cursor-agent", .other),
        ("amp", .other), ("goose", .other), ("qwen", .other), ("crush", .other),
        ("copilot", .other), ("droid", .other), ("kiro-cli", .other), ("cline", .other),
    ]
    /// Interpreters whose first argument is the actual tool (`node …/claude`).
    private static let interpreters = ["node", "bun", "deno", "python", "uv", "npx"]

    var enabledGroups: Set<AgentGroup> = Set(AgentGroup.allCases)
    var includeTerminal = true

    /// Strings agents print on screen while a turn is in progress.
    private let busyMarkers = ["esc to interrupt", "ctrl+c to interrupt", "esc to cancel"]
    /// CPU % (of one core, averaged since last scan) above which an agent counts as working.
    /// Measured: working Claude Code ≈ 10–15 %, idle at prompt ≈ 0.3–1.5 %.
    var cpuBusyThreshold = 5.0

    /// Limit messages already handled (resumed), so an old message still on screen is ignored.
    private var handledLimits = Set<String>()
    /// First-seen parsed reset time per limit message (keeps "in 2 hours" from drifting).
    private var limitCache: [String: Date] = [:]

    private struct Proc { let ppid: Int32; let tty: String; let cpuTime: Double; let pcpu: Double; let args: String }
    private var cpuSamples: [String: (cpu: Double, at: Date, pct: Double)] = [:]

    func scan() -> [AgentPane] {
        var procs: [Int32: Proc] = [:]
        var children: [Int32: [Int32]] = [:]
        for line in Shell.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,time=,pcpu=,args="]).out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count == 6, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            procs[pid] = Proc(ppid: ppid, tty: String(f[2]), cpuTime: Self.parseTime(String(f[3])),
                              pcpu: Double(f[4].replacingOccurrences(of: ",", with: ".")) ?? 0,
                              args: String(f[5]))
            children[ppid, default: []].append(pid)
        }

        func subtree(_ root: Int32) -> [Int32] {
            var out: [Int32] = [], queue = [root], seen = Set<Int32>()
            while !queue.isEmpty {
                let pid = queue.removeFirst()
                guard seen.insert(pid).inserted else { continue }
                out.append(pid)
                queue.append(contentsOf: children[pid] ?? [])
            }
            return out // breadth-first: top-most processes first
        }
        func cpuPercent(_ key: String, _ pids: [Int32]) -> Double {
            let total = pids.reduce(0) { $0 + (procs[$1]?.cpuTime ?? 0) }
            let now = Date()
            let pct: Double
            if let prev = cpuSamples[key] {
                let dt = now.timeIntervalSince(prev.at)
                if dt < 3 { return prev.pct } // scanned again right away (menu open)
                pct = max(0, (total - prev.cpu) / dt * 100)
            } else {
                pct = pids.reduce(0) { $0 + (procs[$1]?.pcpu ?? 0) } // first sight: ps estimate
            }
            cpuSamples[key] = (total, now, pct)
            return pct
        }

        var result: [AgentPane] = []
        var usedKeys = Set<String>()
        var tmuxPids = Set<Int32>()

        // 1) tmux panes
        if let tmux = tmuxPath {
            let panes = Shell.run(tmux, ["list-panes", "-a", "-F",
                "#{pane_id}|#{pane_pid}|#{session_name}:#{window_index}.#{pane_index}"])
            if panes.status == 0 {
                for line in panes.out.split(separator: "\n") {
                    let f = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    guard f.count == 3, let root = Int32(f[1]) else { continue }
                    let pids = subtree(root)
                    tmuxPids.formUnion(pids)
                    guard let agent = pids.lazy.compactMap({ procs[$0].flatMap { self.agent(for: $0.args) } }).first,
                          enabledGroups.contains(agent.group) else { continue }
                    let key = "tmux:" + f[0]
                    usedKeys.insert(key)
                    let cpu = cpuPercent(key, pids)
                    let raw = Shell.run(tmux, ["capture-pane", "-p", "-J", "-t", f[0]]).out
                    let screen = raw.lowercased()
                    var reason: BusyReason = .idle
                    var limitKey: String?
                    if busyMarkers.contains(where: screen.contains) {
                        reason = .screen
                    } else if let lim = detectLimit(paneId: f[0], screen: raw) {
                        reason = .limited(lim.reset); limitKey = lim.key
                    } else if cpu >= cpuBusyThreshold {
                        reason = .cpu(cpu)
                    }
                    result.append(AgentPane(source: .tmux, target: f[2], name: agent.name, group: agent.group,
                                            reason: reason, paneId: f[0], limitKey: limitKey))
                }
            }
        }

        // 2) agents started directly in a terminal window (Terminal, iTerm2, Ghostty, VS Code, …)
        if includeTerminal {
            for (pid, p) in procs.sorted(by: { $0.key < $1.key }) {
                guard p.tty != "??", !p.tty.isEmpty, !tmuxPids.contains(pid),
                      !p.args.contains("--bg-"), !p.args.contains(" daemon"),
                      let agent = agent(for: p.args), enabledGroups.contains(agent.group) else { continue }
                // Skip sub-agents: only report the top-most agent process.
                var anc = p.ppid, nested = false, app: String?
                while anc > 1, let a = procs[anc] {
                    if self.agent(for: a.args) != nil { nested = true; break }
                    if app == nil, let r = a.args.range(of: ".app/") {
                        app = (String(a.args[..<r.lowerBound]) as NSString).lastPathComponent
                    }
                    anc = a.ppid
                }
                if nested { continue }
                let key = "pid:\(pid)"
                usedKeys.insert(key)
                let cpu = cpuPercent(key, subtree(pid))
                let target = (app.map { $0 + " · " } ?? "") + p.tty
                result.append(AgentPane(source: .terminal, target: target, name: agent.name,
                                        group: agent.group, reason: cpu >= cpuBusyThreshold ? .cpu(cpu) : .idle))
            }
        }

        cpuSamples = cpuSamples.filter { usedKeys.contains($0.key) }
        return result
    }

    // MARK: Usage limits

    /// Looks at the bottom of a tmux pane for a Claude/Codex usage-limit message.
    private func detectLimit(paneId: String, screen: String) -> (key: String, reset: Date)? {
        let lines = screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines.suffix(25).reversed() where LimitParser.isLimitLine(line) {
            let key = paneId + "|" + line
            if handledLimits.contains(key) { return nil } // newest message already handled
            if let d = limitCache[key] { return (key, d) }
            guard let d = LimitParser.resetDate(in: line) else { continue }
            limitCache[key] = d
            return (key, d)
        }
        return nil
    }

    /// Types the resume message into a tmux pane and remembers the limit message as handled.
    func resume(paneId: String, limitKey: String?, text: String) {
        if let k = limitKey { handledLimits.insert(k) }
        guard let tmux = tmuxPath else { return }
        Shell.run(tmux, ["send-keys", "-t", paneId, "-l", text])
        Thread.sleep(forTimeInterval: 0.6)
        Shell.run(tmux, ["send-keys", "-t", paneId, "Enter"])
    }

    /// Matches argv[0] (or argv[1] after an interpreter) against known agent names.
    private func agent(for args: String) -> (name: String, group: AgentGroup)? {
        let argv = args.split(separator: " ", maxSplits: 2).map { ($0 as NSString).lastPathComponent.lowercased() }
        guard let first = argv.first, !args.contains("language-server") else { return nil }
        var candidates = [first]
        if argv.count > 1, Self.interpreters.contains(where: { first.hasPrefix($0) }) { candidates.append(argv[1]) }
        for c in candidates {
            for k in Self.knownAgents where c == k.name || c.hasPrefix(k.name + "-") || c.hasPrefix(k.name + ".") {
                return k
            }
        }
        return nil
    }

    /// Parses ps `time` output: "MM:SS.ss" or "HH:MM:SS.ss" (and "D-HH:MM:SS").
    private static func parseTime(_ s: String) -> Double {
        var days = 0.0, rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") { days = Double(rest[..<dash]) ?? 0; rest = rest[rest.index(after: dash)...] }
        let secs = rest.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1.replacingOccurrences(of: ",", with: ".")) ?? 0) }
        return days * 86400 + secs
    }
}

// MARK: - Usage-limit message parsing

/// Understands messages such as:
///   Claude: "5-hour limit reached ∙ resets 3pm (Europe/Istanbul)", "You've hit your limit · resets Nov 25, 3:30pm",
///           "Claude AI usage limit reached|1763650800"
///   Codex:  "You've hit your usage limit … try again in 2 hours 13 minutes", "… try again at 3:45 PM"
enum LimitParser {
    static func isLimitLine(_ line: String) -> Bool {
        let l = line.lowercased()
        return (l.contains("limit") && (l.contains("reached") || l.contains("hit your") || l.contains("exceeded")))
            && (l.contains("reset") || l.contains("try again") || l.range(of: #"\|\d{10}"#, options: .regularExpression) != nil)
    }

    static func resetDate(in line: String, now: Date = Date()) -> Date? {
        let l = line.lowercased()
        // 1) Unix epoch: "...limit reached|1763650800"
        if let r = l.range(of: #"\|(\d{10})"#, options: .regularExpression),
           let t = Double(l[r].dropFirst()) { return Date(timeIntervalSince1970: t) }

        // 2) Relative: "try again in 2 hours 13 minutes" / "resets in 4h 5m"
        if let r = l.range(of: #"(try again|resets?) in "#, options: .regularExpression) {
            let rest = String(l[r.upperBound...])
            var secs = 0.0
            let re = try! NSRegularExpression(pattern: #"(\d+)\s*(days?|d\b|hours?|hrs?|h\b|minutes?|mins?|m\b|seconds?|secs?|s\b)"#)
            for m in re.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                let n = Double(rest[Range(m.range(at: 1), in: rest)!]) ?? 0
                let u = rest[Range(m.range(at: 2), in: rest)!]
                secs += n * (u.hasPrefix("d") ? 86400 : u.hasPrefix("h") ? 3600 : u.hasPrefix("m") ? 60 : 1)
            }
            if secs > 0 { return now.addingTimeInterval(secs) }
        }

        // 3) Absolute: "resets 3pm", "resets at 15:00", "try again at nov 25th, 2026 3:45 pm"
        guard let r = l.range(of: #"(resets?( at)?|try again at) "#, options: .regularExpression) else { return nil }
        let rest = String(l[r.upperBound...])
        let re = try! NSRegularExpression(pattern:
            #"^(?:([a-z]{3,9})\.? (\d{1,2})(?:st|nd|rd|th)?,?(?: (\d{4}))?,?(?: at)? )?(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?:\s*\(([^)]+)\))?"#)
        guard let m = re.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) else { return nil }
        func g(_ i: Int) -> String? { Range(m.range(at: i), in: rest).map { String(rest[$0]) } }
        guard var hour = Int(g(4) ?? "") else { return nil }
        let minute = Int(g(5) ?? "0") ?? 0
        if let ap = g(6) {
            if ap.hasPrefix("p") && hour < 12 { hour += 12 }
            if ap.hasPrefix("a") && hour == 12 { hour = 0 }
        }
        guard hour < 24, minute < 60 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        if let tzName = g(7), let tz = TimeZone(identifier: tzName.trimmingCharacters(in: .whitespaces)
            .split(separator: "/").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "/")) {
            cal.timeZone = tz
        }
        var c = cal.dateComponents([.year, .month, .day], from: now)
        c.hour = hour; c.minute = minute; c.second = 0
        var explicitDay = false
        if let mon = g(1), let day = Int(g(2) ?? "") {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            if let mi = months.firstIndex(where: { mon.hasPrefix($0) }) {
                c.month = mi + 1; c.day = day; explicitDay = true
                if let y = Int(g(3) ?? "") { c.year = y }
            }
        }
        guard var date = cal.date(from: c) else { return nil }
        if date < now.addingTimeInterval(-600) {
            date = cal.date(byAdding: explicitDay ? .year : .day, value: 1, to: date) ?? date
        }
        return date
    }
}

// MARK: - Localization

enum Lang: String, CaseIterable {
    case system, en, tr

    /// Native name shown in the Language menu.
    var label: String {
        switch self {
        case .system: return L("systemDefault")
        case .en: return "English"
        case .tr: return "Türkçe"
        }
    }
}

enum Loc {
    static var choice: Lang {
        get { Lang(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }

    /// The concrete language currently in effect.
    static var active: Lang {
        if choice != .system { return choice }
        let pref = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return pref.hasPrefix("tr") ? .tr : .en
    }

    static var locale: Locale { Locale(identifier: active == .tr ? "tr_TR" : "en_US") }

    static let strings: [Lang: [String: String]] = [
        .en: [
            "off": "Off — Mac sleeps normally",
            "indefinite": "Awake indefinitely",
            "until": "Awake until %@ (%@ left)",
            "waitingBusy": "Waiting for agents: %d of %d working",
            "idleSleeping": "Agents idle — sleeping in %@",
            "idleReleasing": "Agents idle — releasing in %@",
            "waiting": "Waiting for agents…",
            "displayAwake": "Display + system kept awake",
            "systemAwake": "System kept awake (display may sleep)",
            "noBlock": "No sleep block active",
            "noTmux": "tmux not found",
            "noAgents": "No coding agents running",
            "tmuxHeader": "tmux:",
            "terminalHeader": "Terminal:",
            "noTmuxShort": "tmux not installed — only terminals are watched",
            "working": "working",
            "idle": "idle",
            "cpu": "CPU %@%%",
            "startAgents": "Wait for agents, then sleep",
            "keepFor": "Keep awake for",
            "minutes": "%d minutes",
            "hour1": "1 hour",
            "hours": "%d hours",
            "keepIndefinitely": "Keep awake indefinitely",
            "turnOff": "Turn off (allow sleep)",
            "settings": "Settings",
            "keepDisplay": "Keep display on too",
            "sleepAgents": "Sleep Mac when agents finish",
            "sleepTimer": "Sleep Mac when timer ends",
            "idleFor": "Agents must be idle for:",
            "minShort": "%d min",
            "safetyLimit": "Agent-wait safety limit:",
            "language": "Language",
            "systemDefault": "System default",
            "lidNote": "Note: closing the lid still sleeps the Mac",
            "quit": "Quit AgentAwake",
            "timerFinished": "Timer finished",
            "noAgentsRunning": "No agents running",
            "allIdle": "All agents are idle",
            "watchHeader": "Watch these agents:",
            "groupClaude": "Claude Code",
            "groupCodex": "Codex",
            "groupOther": "Other (Gemini, Aider, OpenCode, Cursor, Amp…)",
            "includeTerminal": "Also watch agents outside tmux (Terminal, iTerm, …)",
            "nothingToWatch": "Nothing to watch: enable tmux or terminal agents",
            "safetyReached": "Reached %dh safety limit",
            "sleepingNow": "%@ — sleeping now.",
            "restored": "%@ — normal sleep restored.",
            "h": "h", "m": "m",
            "limited": "usage limit · resets %@",
            "limitWaitStatus": "Usage limit — resuming at %@ (%@ left)",
            "limitWakeScheduled": "Auto-wake scheduled for %@",
            "limitAwake": "Keeping Mac awake until then",
            "notifyLimitSleep": "Usage limit hit. Sleeping until %@, then sending “%@”.",
            "notifyLimitAwake": "Usage limit hit. Will send “%@” at %@.",
            "notifyResumed": "Limit reset — resumed %d agent(s).",
            "autoResume": "Auto-resume after usage limit (tmux)",
            "wakeSetup": "Allow waking from sleep for limit resets… (admin, once)",
            "wakeReady": "Waking from sleep for limit resets: enabled",
            "wakeRemove": "Remove wake-from-sleep permission…",
            "wakeSetupFailed": "Could not set up wake-from-sleep.",
            "wakeSetupDone": "Wake-from-sleep enabled.",
        ],
        .tr: [
            "off": "Kapalı — Mac normal şekilde uyur",
            "indefinite": "Süresiz uyanık",
            "until": "%@ saatine kadar uyanık (%@ kaldı)",
            "waitingBusy": "Ajanlar bekleniyor: %d/%d çalışıyor",
            "idleSleeping": "Ajanlar boşta — %@ sonra uyku",
            "idleReleasing": "Ajanlar boşta — %@ sonra normale dönülüyor",
            "waiting": "Ajanlar bekleniyor…",
            "displayAwake": "Ekran ve sistem uyanık tutuluyor",
            "systemAwake": "Sistem uyanık tutuluyor (ekran kapanabilir)",
            "noBlock": "Uyku engeli aktif değil",
            "noTmux": "tmux bulunamadı",
            "noAgents": "Çalışan kodlama ajanı yok",
            "tmuxHeader": "tmux:",
            "terminalHeader": "Terminal:",
            "noTmuxShort": "tmux kurulu değil — sadece terminaller izleniyor",
            "working": "çalışıyor",
            "idle": "boşta",
            "cpu": "CPU %%%@",
            "startAgents": "Ajanları bekle, sonra uyu",
            "keepFor": "Şu süre uyanık tut",
            "minutes": "%d dakika",
            "hour1": "1 saat",
            "hours": "%d saat",
            "keepIndefinitely": "Süresiz uyanık tut",
            "turnOff": "Kapat (uykuya izin ver)",
            "settings": "Ayarlar",
            "keepDisplay": "Ekranı da açık tut",
            "sleepAgents": "Ajanlar bitince Mac'i uyut",
            "sleepTimer": "Süre bitince Mac'i uyut",
            "idleFor": "Ajanların boşta kalma süresi:",
            "minShort": "%d dk",
            "safetyLimit": "Ajan bekleme güvenlik sınırı:",
            "language": "Dil",
            "systemDefault": "Sistem varsayılanı",
            "lidNote": "Not: Kapağı kapatmak Mac'i yine uyutur",
            "quit": "AgentAwake'ten çık",
            "timerFinished": "Süre doldu",
            "noAgentsRunning": "Çalışan ajan yok",
            "allIdle": "Tüm ajanlar boşta",
            "watchHeader": "İzlenecek ajanlar:",
            "groupClaude": "Claude Code",
            "groupCodex": "Codex",
            "groupOther": "Diğer (Gemini, Aider, OpenCode, Cursor, Amp…)",
            "includeTerminal": "tmux dışındaki ajanları da izle (Terminal, iTerm, …)",
            "nothingToWatch": "İzlenecek bir şey yok: tmux veya terminal ajanlarını aç",
            "safetyReached": "%d saatlik güvenlik sınırına ulaşıldı",
            "sleepingNow": "%@ — Mac uyutuluyor.",
            "restored": "%@ — normal uyku geri yüklendi.",
            "h": "sa", "m": "dk",
            "limited": "kullanım limiti · %@ sıfırlanır",
            "limitWaitStatus": "Kullanım limiti — %@ devam edilecek (%@ kaldı)",
            "limitWakeScheduled": "Otomatik uyanma %@ için planlandı",
            "limitAwake": "O zamana kadar Mac uyanık tutuluyor",
            "notifyLimitSleep": "Kullanım limitine takıldı. %@ saatine kadar uyunacak, sonra “%@” gönderilecek.",
            "notifyLimitAwake": "Kullanım limitine takıldı. %2$@ saatinde “%1$@” gönderilecek.",
            "notifyResumed": "Limit sıfırlandı — %d ajan devam ettirildi.",
            "autoResume": "Kullanım limitinden sonra otomatik devam et (tmux)",
            "wakeSetup": "Limit sıfırlanınca uykudan uyanmaya izin ver… (yönetici, bir kez)",
            "wakeReady": "Limit için uykudan uyanma: etkin",
            "wakeRemove": "Uykudan uyanma iznini kaldır…",
            "wakeSetupFailed": "Uykudan uyanma kurulamadı.",
            "wakeSetupDone": "Uykudan uyanma etkinleştirildi.",
        ],
    ]
}

func L(_ key: String, _ args: CVarArg...) -> String {
    let table = Loc.strings[Loc.active] ?? [:]
    let fmt = table[key] ?? Loc.strings[.en]?[key] ?? key
    return args.isEmpty ? fmt : String(format: fmt, locale: Loc.locale, arguments: args)
}

// MARK: - App

enum Mode {
    case off
    case timed(until: Date)
    case indefinite
    case agents(started: Date)
    case limitWait(until: Date, panes: [AgentPane])
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let monitor = AgentMonitor()
    private var timer: Timer?

    private var mode: Mode = .off
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false

    private var lastAgents: [AgentPane] = []
    private var scheduledWake: Date?
    private static let sudoersPath = "/etc/sudoers.d/agentawake"
    private var wakeHelperInstalled: Bool { FileManager.default.fileExists(atPath: Self.sudoersPath) }
    private var idleSince: Date?

    private let defaults = UserDefaults.standard
    private var keepDisplayOn: Bool {
        get { defaults.bool(forKey: "keepDisplayOn") }
        set { defaults.set(newValue, forKey: "keepDisplayOn") }
    }
    private var sleepWhenDone: Bool {
        get { defaults.object(forKey: "sleepWhenDone") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sleepWhenDone") }
    }
    private var sleepAfterTimer: Bool {
        get { defaults.bool(forKey: "sleepAfterTimer") }
        set { defaults.set(newValue, forKey: "sleepAfterTimer") }
    }
    private var graceMinutes: Int {
        get { defaults.object(forKey: "graceMinutes") as? Int ?? 3 }
        set { defaults.set(newValue, forKey: "graceMinutes") }
    }
    private var includeTerminal: Bool {
        get { defaults.object(forKey: "includeTerminal") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "includeTerminal"); applyWatchSettings() }
    }
    private func isWatched(_ g: AgentGroup) -> Bool { defaults.object(forKey: "watch." + g.rawValue) as? Bool ?? true }
    private func applyWatchSettings() {
        monitor.includeTerminal = includeTerminal
        monitor.enabledGroups = Set(AgentGroup.allCases.filter(isWatched))
    }
    private var autoResume: Bool {
        get { defaults.object(forKey: "autoResume") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoResume") }
    }
    private var resumeText: String { defaults.string(forKey: "resumeText") ?? "continue" }
    private var maxAgentHours: Int {
        get { defaults.object(forKey: "maxAgentHours") as? Int ?? 8 }
        set { defaults.set(newValue, forKey: "maxAgentHours") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        applyWatchSettings()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if case .limitWait = self.mode { self.setAssertion(true) } // stay up after the scheduled wake
            self.tick()
        }
        updateButton()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
    }

    func applicationWillTerminate(_ n: Notification) { setAssertion(false) }

    // MARK: Power assertion

    private func setAssertion(_ on: Bool) {
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
            hasAssertion = false
        }
        guard on else { return }
        let type = keepDisplayOn ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
        let rc = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "AgentAwake keeping Mac awake" as CFString, &assertionID)
        hasAssertion = (rc == kIOReturnSuccess)
    }

    // MARK: Mode changes

    private func start(_ m: Mode) {
        mode = m
        idleSince = nil
        setAssertion(true)
        if case .agents = m { tick() }
        updateButton()
    }

    private func stop() {
        cancelScheduledWake()
        mode = .off
        setAssertion(false)
        updateButton()
    }

    private func finish(message: String, sleep: Bool) {
        stop()
        // Don't yank the Mac out from under someone who's actively using it.
        let userIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                              eventType: CGEventType(rawValue: ~0)!)
        if sleep && userIdle > 60 {
            notify("AgentAwake", L("sleepingNow", message))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                Shell.run("/usr/bin/pmset", ["sleepnow"])
            }
        } else {
            notify("AgentAwake", L("restored", message))
        }
    }

    // MARK: Tick

    private func tick() {
        switch mode {
        case .off, .indefinite:
            break
        case .timed(let until):
            if Date() >= until { finish(message: L("timerFinished"), sleep: sleepAfterTimer) }
        case .agents(let started):
            lastAgents = monitor.scan()
            if lastAgents.contains(where: { $0.busy }) {
                idleSince = nil
            } else if idleSince == nil {
                idleSince = Date()
            }
            if let s = idleSince, Date().timeIntervalSince(s) >= Double(graceMinutes * 60) {
                let limited = lastAgents.filter { $0.limitReset != nil && $0.paneId != nil }
                if autoResume, let earliest = limited.compactMap(\.limitReset).min(),
                   earliest.timeIntervalSinceNow < 24 * 3600 {
                    beginLimitWait(reset: earliest,
                                   panes: limited.filter { $0.limitReset! <= earliest.addingTimeInterval(120) })
                } else {
                    finish(message: lastAgents.isEmpty ? L("noAgentsRunning") : L("allIdle"), sleep: sleepWhenDone)
                }
            } else if Date().timeIntervalSince(started) >= Double(maxAgentHours * 3600) {
                finish(message: L("safetyReached", maxAgentHours), sleep: sleepWhenDone)
            }
        case .limitWait(let until, let panes):
            if Date() >= until { resumeAfterLimit(panes) }
        }
        updateButton()
    }

    // MARK: Usage limits

    /// Agents hit their usage limit: sleep (with a scheduled wake) or stay awake until the reset.
    private func beginLimitWait(reset: Date, panes: [AgentPane]) {
        let resumeAt = max(reset, Date()).addingTimeInterval(60) // small buffer after the reset
        mode = .limitWait(until: resumeAt, panes: panes)
        let f = DateFormatter(); f.timeStyle = .short; f.locale = Loc.locale
        let when = f.string(from: resumeAt)
        let userIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                              eventType: CGEventType(rawValue: ~0)!)
        if sleepWhenDone, userIdle > 60, resumeAt.timeIntervalSinceNow > 5 * 60,
           scheduleWake(at: resumeAt.addingTimeInterval(-30)) {
            setAssertion(false)
            notify("AgentAwake", L("notifyLimitSleep", when, resumeText))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if case .limitWait = self.mode { Shell.run("/usr/bin/pmset", ["sleepnow"]) }
            }
        } else {
            setAssertion(true) // no wake permission (or user active): just stay awake, display may sleep
            notify("AgentAwake", L("notifyLimitAwake", resumeText, when))
        }
        updateButton()
    }

    private func resumeAfterLimit(_ panes: [AgentPane]) {
        cancelScheduledWake()
        setAssertion(true)
        let text = resumeText
        DispatchQueue.global().async {
            for p in panes { if let id = p.paneId { self.monitor.resume(paneId: id, limitKey: p.limitKey, text: text) } }
        }
        notify("AgentAwake", L("notifyResumed", panes.count))
        mode = .agents(started: Date())
        idleSince = nil
    }

    private static let pmsetDate: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM/dd/yy HH:mm:ss"; return f
    }()

    /// `pmset schedule wake` needs root; allowed password-less via /etc/sudoers.d/agentawake.
    private func scheduleWake(at date: Date) -> Bool {
        guard wakeHelperInstalled else { return false }
        cancelScheduledWake()
        let ok = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "schedule", "wake", Self.pmsetDate.string(from: date)]).status == 0
        if ok { scheduledWake = date }
        return ok
    }

    private func cancelScheduledWake() {
        guard let d = scheduledWake else { return }
        Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "schedule", "cancel", "wake", Self.pmsetDate.string(from: d)])
        scheduledWake = nil
    }

    private func runAsAdmin(_ shell: String) -> Bool {
        let esc = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return Shell.run("/usr/bin/osascript", ["-e", "do shell script \"\(esc)\" with administrator privileges"]).status == 0
    }

    @objc private func installWakeHelper() {
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *"
        let cmd = "T=$(/usr/bin/mktemp) && /usr/bin/printf '%s\\n' '\(rule)' > $T && /usr/sbin/visudo -cf $T && " +
                  "/usr/bin/install -m 0440 -o root -g wheel $T \(Self.sudoersPath); R=$?; /bin/rm -f $T; exit $R"
        DispatchQueue.global().async {
            let ok = self.runAsAdmin(cmd)
            DispatchQueue.main.async { self.notify("AgentAwake", ok ? L("wakeSetupDone") : L("wakeSetupFailed")) }
        }
    }

    @objc private func removeWakeHelper() {
        DispatchQueue.global().async { _ = self.runAsAdmin("/bin/rm -f \(Self.sudoersPath)") }
    }

    // MARK: UI

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let symbol: String
        var title = ""
        switch mode {
        case .off:
            symbol = "moon.zzz"
        case .indefinite:
            symbol = "cup.and.saucer.fill"; title = " ∞"
        case .timed(let until):
            symbol = "cup.and.saucer.fill"; title = " " + shortDuration(until.timeIntervalSinceNow)
        case .limitWait(let until, _):
            symbol = "hourglass"; title = " ⏸" + shortDuration(until.timeIntervalSinceNow)
        case .agents:
            symbol = "terminal.fill"
            let busy = lastAgents.filter(\.busy).count
            title = " \(busy)/\(lastAgents.count)"
            if busy == 0, let s = idleSince {
                title += " ⏳" + shortDuration(Double(graceMinutes * 60) - Date().timeIntervalSince(s))
            }
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "AgentAwake")
        img?.isTemplate = true
        button.image = img
        button.imagePosition = .imageLeading
        button.title = title
    }

    private func shortDuration(_ secs: TimeInterval) -> String {
        let m = max(0, Int((secs / 60).rounded(.up)))
        return m >= 60 ? "\(m / 60)\(L("h"))\(String(format: "%02d", m % 60))" : "\(m)\(L("m"))"
    }

    private func agentReason(_ a: AgentPane) -> String {
        switch a.reason {
        case .idle: return L("idle")
        case .limited(let d):
            let f = DateFormatter(); f.timeStyle = .short; f.locale = Loc.locale
            if !Calendar.current.isDateInToday(d) { f.dateStyle = .short }
            return L("limited", f.string(from: d))
        case .screen: return L("working")
        case .cpu(let pct): return L("working") + " · " + L("cpu", String(format: "%.0f", pct))
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if case .agents = mode {} else { lastAgents = monitor.scan() }
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let status: String
        switch mode {
        case .off: status = L("off")
        case .limitWait(let until, _):
            let f = DateFormatter(); f.timeStyle = .short; f.locale = Loc.locale
            status = L("limitWaitStatus", f.string(from: until), shortDuration(until.timeIntervalSinceNow))
        case .indefinite: status = L("indefinite")
        case .timed(let until):
            let f = DateFormatter(); f.timeStyle = .short; f.locale = Loc.locale
            status = L("until", f.string(from: until), shortDuration(until.timeIntervalSinceNow))
        case .agents:
            let busy = lastAgents.filter(\.busy).count
            if busy > 0 { status = L("waitingBusy", busy, lastAgents.count) }
            else if let s = idleSince {
                let left = shortDuration(Double(graceMinutes * 60) - Date().timeIntervalSince(s))
                status = L(sleepWhenDone ? "idleSleeping" : "idleReleasing", left)
            } else { status = L("waiting") }
        }
        menu.addItem(disabled(status))
        if case .limitWait = mode, let w = scheduledWake {
            let f = DateFormatter(); f.timeStyle = .short; f.locale = Loc.locale
            menu.addItem(disabled(L("limitWakeScheduled", f.string(from: w))))
        }
        menu.addItem(disabled(hasAssertion
            ? (keepDisplayOn ? L("displayAwake") : L("systemAwake"))
            : L("noBlock")))

        // Agents — tmux and plain terminals side by side
        menu.addItem(.separator())
        if monitor.tmuxPath == nil && !includeTerminal {
            menu.addItem(disabled(L("noTmux")))
        } else if lastAgents.isEmpty {
            menu.addItem(disabled(L("noAgents")))
        } else {
            for (source, header) in [(AgentSource.tmux, L("tmuxHeader")), (.terminal, L("terminalHeader"))] {
                let list = lastAgents.filter { $0.source == source }
                guard !list.isEmpty else { continue }
                menu.addItem(disabled(header))
                for a in list {
                    menu.addItem(disabled("  \(a.busy ? "●" : (a.limitReset != nil ? "⏸" : "○"))  \(a.name)  \(a.target) — \(agentReason(a))"))
                }
            }
        }
        if monitor.tmuxPath == nil && includeTerminal { menu.addItem(disabled(L("noTmuxShort"))) }

        // Actions
        menu.addItem(.separator())
        menu.addItem(item(L("startAgents"), #selector(startAgents), key: "a"))
        let timed = NSMenuItem(title: L("keepFor"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for mins in [15, 30, 60, 120, 180, 240, 480] {
            let label = mins < 60 ? L("minutes", mins) : (mins == 60 ? L("hour1") : L("hours", mins / 60))
            let i = item(label, #selector(startTimed(_:)))
            i.tag = mins
            sub.addItem(i)
        }
        timed.submenu = sub
        menu.addItem(timed)
        menu.addItem(item(L("keepIndefinitely"), #selector(startIndefinite), key: "i"))
        if case .off = mode {} else {
            menu.addItem(item(L("turnOff"), #selector(turnOff), key: "o"))
        }

        // Settings
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L("settings"), action: nil, keyEquivalent: "")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let s = NSMenu()
        s.addItem(disabled(L("watchHeader")))
        for (idx, g) in AgentGroup.allCases.enumerated() {
            let key = g == .claude ? "groupClaude" : (g == .codex ? "groupCodex" : "groupOther")
            let i = toggle("  " + L(key), isWatched(g), #selector(toggleGroup(_:))); i.tag = idx; s.addItem(i)
        }
        s.addItem(toggle(L("includeTerminal"), includeTerminal, #selector(toggleTerminal)))
        s.addItem(.separator())
        s.addItem(toggle(L("autoResume"), autoResume, #selector(toggleAutoResume)))
        if wakeHelperInstalled {
            let ready = disabled("  ✓ " + L("wakeReady")); s.addItem(ready)
            s.addItem(item("  " + L("wakeRemove"), #selector(removeWakeHelper)))
        } else {
            s.addItem(item("  " + L("wakeSetup"), #selector(installWakeHelper)))
        }
        s.addItem(.separator())
        s.addItem(toggle(L("keepDisplay"), keepDisplayOn, #selector(toggleDisplay)))
        s.addItem(toggle(L("sleepAgents"), sleepWhenDone, #selector(toggleSleepWhenDone)))
        s.addItem(toggle(L("sleepTimer"), sleepAfterTimer, #selector(toggleSleepAfterTimer)))
        s.addItem(.separator())
        s.addItem(disabled(L("idleFor")))
        for m in [1, 3, 5, 10, 15] {
            let i = toggle("  " + L("minShort", m), graceMinutes == m, #selector(setGrace(_:))); i.tag = m; s.addItem(i)
        }
        s.addItem(.separator())
        s.addItem(disabled(L("safetyLimit")))
        for h in [2, 4, 8, 12, 24] {
            let i = toggle("  " + L("hours", h), maxAgentHours == h, #selector(setMax(_:))); i.tag = h; s.addItem(i)
        }
        s.addItem(.separator())
        let langItem = NSMenuItem(title: L("language"), action: nil, keyEquivalent: "")
        langItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let langMenu = NSMenu()
        for (idx, lang) in Lang.allCases.enumerated() {
            let i = toggle(lang.label, Loc.choice == lang, #selector(setLanguage(_:)))
            i.tag = idx
            langMenu.addItem(i)
        }
        langItem.submenu = langMenu
        s.addItem(langItem)
        settings.submenu = s
        menu.addItem(settings)
        menu.addItem(disabled(L("lidNote")))
        menu.addItem(.separator())
        menu.addItem(item(L("quit"), #selector(quit), key: "q"))
    }

    private func disabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }
    private func item(_ t: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: key); i.target = self; return i
    }
    private func toggle(_ t: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let i = item(t, sel); i.state = on ? .on : .off; return i
    }

    // MARK: Actions

    @objc private func startAgents() {
        if monitor.tmuxPath == nil && !includeTerminal { notify("AgentAwake", L("nothingToWatch")); return }
        start(.agents(started: Date()))
    }
    @objc private func startTimed(_ s: NSMenuItem) { start(.timed(until: Date().addingTimeInterval(Double(s.tag * 60)))) }
    @objc private func startIndefinite() { start(.indefinite) }
    @objc private func turnOff() { stop() }
    @objc private func toggleDisplay() { keepDisplayOn.toggle(); if hasAssertion { setAssertion(true) } }
    @objc private func toggleSleepWhenDone() { sleepWhenDone.toggle() }
    @objc private func toggleSleepAfterTimer() { sleepAfterTimer.toggle() }
    @objc private func toggleGroup(_ s: NSMenuItem) {
        let g = AgentGroup.allCases[s.tag]
        defaults.set(!isWatched(g), forKey: "watch." + g.rawValue)
        applyWatchSettings()
    }
    @objc private func toggleTerminal() { includeTerminal.toggle() }
    @objc private func setGrace(_ s: NSMenuItem) { graceMinutes = s.tag }
    @objc private func setMax(_ s: NSMenuItem) { maxAgentHours = s.tag }
    @objc private func setLanguage(_ s: NSMenuItem) {
        Loc.choice = Lang.allCases[s.tag]
        updateButton() // menu text is rebuilt on next open
    }
    @objc private func toggleAutoResume() { autoResume.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func notify(_ title: String, _ body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        DispatchQueue.global().async {
            Shell.run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
