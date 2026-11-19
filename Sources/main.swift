// AgentAwake — menu bar app that keeps your Mac awake for a fixed time,
// indefinitely, or until the Claude Code / Codex agents running in tmux finish,
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

// MARK: - tmux agent detection

struct AgentPane {
    let target: String   // e.g. "main:1.0"
    let kind: String     // "claude" / "codex"
    let busy: Bool
    let reason: String
}

final class TmuxMonitor {
    let tmuxPath: String? = [
        "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
        "/run/current-system/sw/bin/tmux",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Strings agents print on screen while a turn is in progress.
    private let busyMarkers = ["esc to interrupt", "ctrl+c to interrupt", "esc to cancel"]
    /// Summed CPU % of the pane's process tree above which we treat it as busy
    /// (catches long-running tool calls such as builds/tests).
    var cpuBusyThreshold = 15.0

    private let agentRegex = try! NSRegularExpression(
        pattern: #"(^|/)(claude|codex)([-_.][^/]*)?$"#, options: [.caseInsensitive])

    func scan() -> [AgentPane] {
        guard let tmux = tmuxPath else { return [] }
        let panes = Shell.run(tmux, ["list-panes", "-a", "-F",
            "#{pane_id}|#{pane_pid}|#{session_name}:#{window_index}.#{pane_index}"])
        guard panes.status == 0 else { return [] }

        // Build process table once.
        var children: [Int32: [Int32]] = [:]
        var procs: [Int32: (cpu: Double, args: String)] = [:]
        for line in Shell.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,args="]).out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            let cpu = Double(f[2].replacingOccurrences(of: ",", with: ".")) ?? 0
            children[ppid, default: []].append(pid)
            procs[pid] = (cpu, String(f[3]))
        }

        var result: [AgentPane] = []
        for line in panes.out.split(separator: "\n") {
            let f = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let root = Int32(f[1]) else { continue }

            // Walk subtree: find agent + total CPU.
            var kind: String?
            var cpu = 0.0
            var stack = [root]
            var seen = Set<Int32>()
            while let pid = stack.popLast(), seen.insert(pid).inserted {
                if let p = procs[pid] {
                    cpu += p.cpu
                    if kind == nil, let k = agentKind(p.args) { kind = k }
                }
                stack.append(contentsOf: children[pid] ?? [])
            }
            guard let agent = kind else { continue }

            let screen = Shell.run(tmux, ["capture-pane", "-p", "-J", "-t", f[0]]).out.lowercased()
            if busyMarkers.contains(where: screen.contains) {
                result.append(AgentPane(target: f[2], kind: agent, busy: true, reason: "working"))
            } else if cpu >= cpuBusyThreshold {
                result.append(AgentPane(target: f[2], kind: agent, busy: true,
                                        reason: String(format: "cpu %.0f%%", cpu)))
            } else {
                result.append(AgentPane(target: f[2], kind: agent, busy: false, reason: "idle"))
            }
        }
        return result
    }

    /// Looks at argv[0] and argv[1] (for `node /path/to/claude`) basenames.
    private func agentKind(_ args: String) -> String? {
        let parts = args.split(separator: " ").prefix(2)
        for part in parts {
            let s = String(part)
            let r = NSRange(s.startIndex..., in: s)
            if agentRegex.firstMatch(in: s, range: r) != nil {
                return s.lowercased().contains("codex") ? "codex" : "claude"
            }
        }
        return nil
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
            "noAgents": "No Claude/Codex agents in tmux",
            "agentsHeader": "tmux agents:",
            "working": "working",
            "idle": "idle",
            "cpu": "CPU %@%%",
            "startAgents": "Wait for tmux agents, then sleep",
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
            "noAgentsRunning": "No tmux agents running",
            "allIdle": "All tmux agents are idle",
            "safetyReached": "Reached %dh safety limit",
            "sleepingNow": "%@ — sleeping now.",
            "restored": "%@ — normal sleep restored.",
            "h": "h", "m": "m",
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
            "noAgents": "tmux'ta Claude/Codex ajanı yok",
            "agentsHeader": "tmux ajanları:",
            "working": "çalışıyor",
            "idle": "boşta",
            "cpu": "CPU %%%@",
            "startAgents": "tmux ajanlarını bekle, sonra uyu",
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
            "noAgentsRunning": "Çalışan tmux ajanı yok",
            "allIdle": "Tüm tmux ajanları boşta",
            "safetyReached": "%d saatlik güvenlik sınırına ulaşıldı",
            "sleepingNow": "%@ — Mac uyutuluyor.",
            "restored": "%@ — normal uyku geri yüklendi.",
            "h": "sa", "m": "dk",
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
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let monitor = TmuxMonitor()
    private var timer: Timer?

    private var mode: Mode = .off
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false

    private var lastAgents: [AgentPane] = []
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
    private var maxAgentHours: Int {
        get { defaults.object(forKey: "maxAgentHours") as? Int ?? 8 }
        set { defaults.set(newValue, forKey: "maxAgentHours") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
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
                finish(message: lastAgents.isEmpty ? L("noAgentsRunning") : L("allIdle"), sleep: sleepWhenDone)
            } else if Date().timeIntervalSince(started) >= Double(maxAgentHours * 3600) {
                finish(message: L("safetyReached", maxAgentHours), sleep: sleepWhenDone)
            }
        }
        updateButton()
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
        if !a.busy { return L("idle") }
        if a.reason.hasPrefix("cpu ") {
            return L("cpu", String(a.reason.dropFirst(4).dropLast()))
        }
        return L("working")
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
        menu.addItem(disabled(hasAssertion
            ? (keepDisplayOn ? L("displayAwake") : L("systemAwake"))
            : L("noBlock")))

        // Agents
        menu.addItem(.separator())
        if monitor.tmuxPath == nil {
            menu.addItem(disabled(L("noTmux")))
        } else if lastAgents.isEmpty {
            menu.addItem(disabled(L("noAgents")))
        } else {
            menu.addItem(disabled(L("agentsHeader")))
            for a in lastAgents {
                menu.addItem(disabled("  \(a.busy ? "●" : "○")  \(a.kind)  \(a.target) — \(agentReason(a))"))
            }
        }

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
        if monitor.tmuxPath == nil { notify("AgentAwake", L("noTmux")); return }
        start(.agents(started: Date()))
    }
    @objc private func startTimed(_ s: NSMenuItem) { start(.timed(until: Date().addingTimeInterval(Double(s.tag * 60)))) }
    @objc private func startIndefinite() { start(.indefinite) }
    @objc private func turnOff() { stop() }
    @objc private func toggleDisplay() { keepDisplayOn.toggle(); if hasAssertion { setAssertion(true) } }
    @objc private func toggleSleepWhenDone() { sleepWhenDone.toggle() }
    @objc private func toggleSleepAfterTimer() { sleepAfterTimer.toggle() }
    @objc private func setGrace(_ s: NSMenuItem) { graceMinutes = s.tag }
    @objc private func setMax(_ s: NSMenuItem) { maxAgentHours = s.tag }
    @objc private func setLanguage(_ s: NSMenuItem) {
        Loc.choice = Lang.allCases[s.tag]
        updateButton() // menu text is rebuilt on next open
    }
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
