import Cocoa
import IOKit.pwr_mgt

enum Mode: Codable {
    case off
    case timed(until: Date)
    case indefinite
    case agents(started: Date)
    case limitWait(until: Date, targets: [ResumeTarget])

    var isActive: Bool { if case .off = self { return false } else { return true } }
}

/// Everything needed to pick up where we left off after a quit, crash or restart.
struct PersistedState: Codable {
    var mode: Mode
    var idleSince: Date?
    var scheduledWake: Date?
    var session: SessionLog?
    var handledLimits: [String]
    var notifiedQuestions: [String]
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let monitor = AgentMonitor()
    private let scanQueue = DispatchQueue(label: "agentawake.scan")
    private let store = SessionStore()
    private var timer: Timer?

    private var mode: Mode = .off
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false

    private var lastAgents: [AgentPane] = []
    private var scanInFlight = false
    private var menuOpen = false
    private var idleSince: Date?
    private var lastRecordAt: Date?
    private var scheduledWake: Date?
    private var session: SessionLog?
    private var handledLimits = Set<String>()
    private var notifiedQuestions = Set<String>()
    private weak var batteryLabel: NSTextField?

    private static let sudoersPath = "/etc/sudoers.d/agentawake"
    private static let agentLabel = "local.agentawake"
    private var wakeHelperInstalled: Bool { FileManager.default.fileExists(atPath: Self.sudoersPath) }
    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.agentLabel).plist")
    }

    // MARK: Preferences

    private let defaults = UserDefaults.standard
    private func pref<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }

    private var keepDisplayOn: Bool { get { pref("keepDisplayOn", false) } set { defaults.set(newValue, forKey: "keepDisplayOn") } }
    private var sleepWhenDone: Bool { get { pref("sleepWhenDone", true) } set { defaults.set(newValue, forKey: "sleepWhenDone") } }
    private var sleepAfterTimer: Bool { get { pref("sleepAfterTimer", false) } set { defaults.set(newValue, forKey: "sleepAfterTimer") } }
    private var graceMinutes: Int { get { pref("graceMinutes", 3) } set { defaults.set(newValue, forKey: "graceMinutes") } }
    private var maxAgentHours: Int { get { pref("maxAgentHours", 8) } set { defaults.set(newValue, forKey: "maxAgentHours") } }
    private var includeTerminal: Bool { get { pref("includeTerminal", true) } set { defaults.set(newValue, forKey: "includeTerminal") } }
    private var readTerminals: Bool { get { pref("readTerminals", true) } set { defaults.set(newValue, forKey: "readTerminals") } }
    private var autoResume: Bool { get { pref("autoResume", true) } set { defaults.set(newValue, forKey: "autoResume") } }
    private var batteryLimit: Int { get { pref("batteryLimit", 20) } set { defaults.set(newValue, forKey: "batteryLimit") } }
    private var resumeText: String { defaults.string(forKey: "resumeText") ?? "continue" }
    private func isWatched(_ g: AgentGroup) -> Bool { pref("watch." + g.rawValue, true) }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        waitForOtherInstance()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        restoreState()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if case .limitWait = self.mode {
                self.setAssertion(true) // stay up after the scheduled wake
                self.logEvent(L("evWoke"))
            }
            self.tick()
        }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updateButton()
        tick()
    }

    func applicationWillTerminate(_ n: Notification) {
        saveState()
        setAssertion(false)
    }

    /// When launchd starts a managed copy while another copy is still running, wait for it to hand over.
    private func waitForOtherInstance() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() }
        guard !others.isEmpty else { return }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, others.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if others.contains(where: { !$0.isTerminated }) { exit(0) } // already running
    }

    // MARK: Persistence

    private func saveState() {
        if handledLimits.count > 300 { handledLimits = Set(handledLimits.shuffled().prefix(200)) }
        if notifiedQuestions.count > 300 { notifiedQuestions.removeAll() }
        let st = PersistedState(mode: mode, idleSince: idleSince, scheduledWake: scheduledWake, session: session,
                                handledLimits: Array(handledLimits), notifiedQuestions: Array(notifiedQuestions))
        if let data = try? JSONEncoder().encode(st) { defaults.set(data, forKey: "state") }
    }

    private func restoreState() {
        guard let data = defaults.data(forKey: "state"),
              let st = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        handledLimits = Set(st.handledLimits)
        notifiedQuestions = Set(st.notifiedQuestions)
        session = st.session
        scheduledWake = st.scheduledWake
        switch st.mode {
        case .off:
            session = nil
            return
        case .timed(let until) where until <= Date():
            mode = .off
            _ = endSession(L("timerFinished"))
            return
        default:
            mode = st.mode
            idleSince = st.idleSince
        }
        if session == nil { session = SessionLog(kind: modeLabel(mode)) }
        setAssertion(true)
        logEvent(L("evRestored", modeLabel(mode)))
        notify("AgentAwake", L("resumedState", modeLabel(mode)))
    }

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

    // MARK: Modes & sessions

    private func modeLabel(_ m: Mode) -> String {
        switch m {
        case .off: return L("off")
        case .timed(let until): return L("modeTimed", shortDuration(until.timeIntervalSinceNow))
        case .indefinite: return L("modeIndefinite")
        case .agents: return L("modeAgents")
        case .limitWait: return L("modeLimitWait")
        }
    }

    private func start(_ m: Mode) {
        cancelScheduledWake()
        if session == nil {
            session = SessionLog(kind: modeLabel(m))
            logEvent(L("evStarted", modeLabel(m)))
        } else {
            logEvent(L("evSwitched", modeLabel(m)))
        }
        mode = m
        idleSince = nil
        lastRecordAt = nil
        setAssertion(true)
        if case .agents = m { requestScan() }
        updateButton()
        saveState()
    }

    private func stop() {
        cancelScheduledWake()
        mode = .off
        idleSince = nil
        setAssertion(false)
        updateButton()
        saveState()
    }

    private func logEvent(_ text: String) {
        session?.add(text)
        store.log(text)
    }

    /// Closes the current session, archives it and returns a one-line summary.
    private func endSession(_ reason: String) -> String? {
        guard var s = session else { return nil }
        s.add(L("evEnded", reason))
        store.log(L("evEnded", reason))
        s.end = Date()
        s.endReason = reason
        store.archive(s)
        session = nil
        let line = summaryLine(s)
        store.log("— " + line)
        return line
    }

    private func summaryLine(_ s: SessionLog) -> String {
        L("summaryLine", shortDuration(s.duration), s.agents.count, s.limitHits, s.questions)
    }

    private func finish(message: String, sleep: Bool) {
        let summary = endSession(message)
        stop()
        // Don't yank the Mac out from under someone who's actively using it.
        let tail = summary.map { "\n" + $0 } ?? ""
        if sleep && userIdleSeconds() > 60 {
            notify("AgentAwake", L("sleepingNow", message) + tail)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !self.mode.isActive { Shell.run("/usr/bin/pmset", ["sleepnow"]) }
            }
        } else {
            notify("AgentAwake", L("restored", message) + tail)
        }
    }

    private func userIdleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: Tick

    private func tick() {
        if checkBattery() { return }
        switch mode {
        case .off, .indefinite:
            break
        case .timed(let until):
            if Date() >= until { finish(message: L("timerFinished"), sleep: sleepAfterTimer) }
        case .agents:
            requestScan()
        case .limitWait(let until, let targets):
            if Date() >= until { resumeAfterLimit(targets) }
        }
        updateButton()
        saveState()
    }

    /// Stops when running on battery below the configured level. Returns true if it stopped.
    private func checkBattery() -> Bool {
        guard mode.isActive, batteryLimit > 0, let b = Battery.read(), b.onBattery, b.percent <= batteryLimit else {
            return false
        }
        finish(message: L("batteryLow", b.percent), sleep: true)
        return true
    }

    /// Scans on a background queue (ps, tmux and AppleScript can take a moment).
    private func requestScan() {
        guard !scanInFlight else { return }
        scanInFlight = true
        let groups = Set(AgentGroup.allCases.filter(isWatched))
        let terminal = includeTerminal, read = readTerminals, handled = handledLimits
        scanQueue.async {
            self.monitor.enabledGroups = groups
            self.monitor.includeTerminal = terminal
            self.monitor.readTerminalScreens = read
            self.monitor.handledLimits = handled
            let agents = self.monitor.scan()
            DispatchQueue.main.async {
                self.scanInFlight = false
                self.lastAgents = agents
                if case .agents = self.mode { self.evaluateAgents() }
                self.updateButton()
                if self.menuOpen { self.rebuildMenu() }
                self.saveState()
            }
        }
    }

    private func evaluateAgents() {
        guard case .agents(let started) = mode else { return }
        let now = Date()
        recordSession(now)
        if lastAgents.contains(where: { $0.busy }) {
            idleSince = nil
        } else if idleSince == nil {
            idleSince = now
        }
        if let s = idleSince, now.timeIntervalSince(s) >= Double(graceMinutes * 60) {
            let limited = lastAgents.filter { $0.limitReset != nil && $0.resume != nil }
            if autoResume, let earliest = limited.compactMap(\.limitReset).min(),
               earliest.timeIntervalSinceNow < 24 * 3600 {
                let due = limited.filter { $0.limitReset! <= earliest.addingTimeInterval(120) }
                beginLimitWait(reset: earliest, targets: due.compactMap(\.resume))
            } else {
                var msg = lastAgents.isEmpty ? L("noAgentsRunning") : L("allIdle")
                let asking = lastAgents.filter { $0.question != nil }.count
                if asking > 0 { msg += " · " + L("questionsPending", asking) }
                finish(message: msg, sleep: sleepWhenDone)
            }
        } else if now.timeIntervalSince(started) >= Double(maxAgentHours * 3600) {
            finish(message: L("safetyReached", maxAgentHours), sleep: sleepWhenDone)
        }
    }

    /// Updates per-agent working time and logs state changes (started, finished, asked, hit limit).
    private func recordSession(_ now: Date) {
        guard session != nil else { return }
        let dt = min(30, now.timeIntervalSince(lastRecordAt ?? now))
        lastRecordAt = now
        var events: [String] = []
        for a in lastAgents {
            var st = session!.agents[a.id] ?? AgentStat(label: a.label)
            st.label = a.label
            if a.busy { st.busySeconds += dt }
            let kind = a.state.kind
            if kind != st.lastState {
                switch a.state {
                case .question(let q):
                    session!.questions += 1
                    events.append(L("evQuestion", a.label, q))
                    let key = a.id + "|" + q
                    if notifiedQuestions.insert(key).inserted { notify(L("questionTitle", a.label), q) }
                case .limited(let reset):
                    session!.limitHits += 1
                    events.append(L("evLimit", a.label, timeString(reset)))
                case .working, .cpu:
                    events.append(L("evWorking", a.label))
                case .idle:
                    if st.lastState == "busy" { events.append(L("evFinished", a.label)) }
                }
                st.lastState = kind
            }
            session!.agents[a.id] = st
        }
        events.forEach(logEvent)
    }

    // MARK: Usage limits

    /// Agents hit their usage limit: sleep (with a scheduled wake) or stay awake until the reset.
    private func beginLimitWait(reset: Date, targets: [ResumeTarget]) {
        let resumeAt = max(reset, Date()).addingTimeInterval(60) // small buffer after the reset
        mode = .limitWait(until: resumeAt, targets: targets)
        let when = timeString(resumeAt)
        if sleepWhenDone, userIdleSeconds() > 60, resumeAt.timeIntervalSinceNow > 5 * 60,
           scheduleWake(at: resumeAt.addingTimeInterval(-30)) {
            setAssertion(false)
            session?.sleeps += 1
            logEvent(L("evSleepUntil", when))
            notify("AgentAwake", L("notifyLimitSleep", when, resumeText))
            saveState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if case .limitWait = self.mode { Shell.run("/usr/bin/pmset", ["sleepnow"]) }
            }
        } else {
            setAssertion(true) // no wake permission (or user active): stay awake, display may sleep
            logEvent(L("evAwakeUntil", when))
            notify("AgentAwake", L("notifyLimitAwake", resumeText, when))
        }
        updateButton()
        saveState()
    }

    private func resumeAfterLimit(_ targets: [ResumeTarget]) {
        cancelScheduledWake()
        setAssertion(true)
        targets.compactMap(\.limitKey).forEach { handledLimits.insert($0) }
        let text = resumeText
        scanQueue.async { targets.forEach { self.monitor.resume($0, text: text) } }
        session?.resumes += targets.count
        logEvent(L("evResumed", text, targets.map(\.label).joined(separator: ", ")))
        notify("AgentAwake", L("notifyResumed", targets.count))
        mode = .agents(started: Date())
        idleSince = nil
        lastRecordAt = nil
        saveState()
    }

    private static let pmsetDate: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM/dd/yy HH:mm:ss"; return f
    }()

    /// `pmset schedule wake` needs root; allowed password-less via /etc/sudoers.d/agentawake.
    private func scheduleWake(at date: Date) -> Bool {
        guard wakeHelperInstalled else { return false }
        cancelScheduledWake()
        let ok = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "schedule", "wake",
                                             Self.pmsetDate.string(from: date)]).status == 0
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
        return Shell.appleScript("do shell script \"\(esc)\" with administrator privileges") != nil
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

    // MARK: Status bar button

    private func updateButton() {
        guard let button = statusItem?.button else { return }
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
        let asking = lastAgents.filter { $0.question != nil }.count
        if asking > 0 { title += " ❓\(asking)" }
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

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.locale = Loc.locale
        if !Calendar.current.isDateInToday(d) { f.dateStyle = .short }
        return f.string(from: d)
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        rebuildMenu()
        if case .agents = mode {} else { requestScan() } // refresh the agent list while the menu is open
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func agentDescription(_ a: AgentPane) -> String {
        var text: String
        switch a.state {
        case .idle: text = L("idle")
        case .working: text = L("working")
        case .cpu(let pct): text = L("working") + " · " + L("cpu", String(format: "%.0f", pct))
        case .question(let q): text = L("asking", q)
        case .limited(let d): text = L("limited", timeString(d))
        }
        if a.source == .terminal && !a.screenRead { text += " " + L("cpuOnly") }
        return text
    }

    private func icon(_ a: AgentPane) -> String {
        switch a.state {
        case .working, .cpu: return "●"
        case .question: return "❓"
        case .limited: return "⏸"
        case .idle: return "○"
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // Status
        let status: String
        switch mode {
        case .off: status = L("off")
        case .indefinite: status = L("indefinite")
        case .timed(let until):
            status = L("until", timeString(until), shortDuration(until.timeIntervalSinceNow))
        case .limitWait(let until, _):
            status = L("limitWaitStatus", timeString(until), shortDuration(until.timeIntervalSinceNow))
        case .agents:
            let busy = lastAgents.filter(\.busy).count
            if busy > 0 { status = L("waitingBusy", busy, lastAgents.count) }
            else if let s = idleSince {
                let left = shortDuration(Double(graceMinutes * 60) - Date().timeIntervalSince(s))
                status = L(sleepWhenDone ? "idleSleeping" : "idleReleasing", left)
            } else { status = L("waiting") }
        }
        menu.addItem(disabled(status))
        if case .limitWait = mode, let w = scheduledWake { menu.addItem(disabled(L("limitWakeScheduled", timeString(w)))) }
        menu.addItem(disabled(hasAssertion ? (keepDisplayOn ? L("displayAwake") : L("systemAwake")) : L("noBlock")))
        if let b = Battery.read() {
            menu.addItem(disabled(L(b.onBattery ? "battOn" : (b.charging ? "battCharging" : "battAC"), b.percent)))
        }

        // Agents — tmux and terminals side by side
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
                for a in list { menu.addItem(disabled("  \(icon(a))  \(a.label) — \(agentDescription(a))")) }
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
        if mode.isActive { menu.addItem(item(L("turnOff"), #selector(turnOff), key: "o")) }

        // Summary + settings
        menu.addItem(.separator())
        let summary = NSMenuItem(title: L("summary"), action: nil, keyEquivalent: "")
        summary.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)
        summary.submenu = summaryMenu()
        menu.addItem(summary)
        let settings = NSMenuItem(title: L("settings"), action: nil, keyEquivalent: "")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.submenu = settingsMenu()
        menu.addItem(settings)
        menu.addItem(disabled(L("lidNote")))
        menu.addItem(.separator())
        menu.addItem(item(L("quit"), #selector(quit), key: "q"))
    }

    private func summaryMenu() -> NSMenu {
        let m = NSMenu()
        guard let s = session ?? store.history.last else {
            m.addItem(disabled(L("noSessions")))
            m.addItem(item(L("openLog"), #selector(openLog)))
            return m
        }
        let f = DateFormatter(); f.locale = Loc.locale; f.dateFormat = "d MMM HH:mm"
        let hm = DateFormatter(); hm.locale = Loc.locale; hm.dateFormat = "HH:mm"
        m.addItem(disabled(session != nil ? L("currentSession") : L("lastSession")))
        m.addItem(disabled("  " + L("sumStarted", f.string(from: s.start), shortDuration(s.duration))))
        if let r = s.endReason { m.addItem(disabled("  " + L("evEnded", r))) }
        m.addItem(disabled("  " + L("sumCounts", s.limitHits, s.resumes, s.questions, s.sleeps)))
        for st in s.agents.values.sorted(by: { $0.busySeconds > $1.busySeconds }).prefix(8) {
            m.addItem(disabled("  " + L("sumAgent", st.label, shortDuration(st.busySeconds))))
        }
        if !s.events.isEmpty {
            m.addItem(.separator())
            m.addItem(disabled(L("recentEvents")))
            for e in s.events.suffix(10) { m.addItem(disabled("  \(hm.string(from: e.at))  \(e.text)")) }
        }
        let past = store.history.reversed().filter { $0.start != s.start }.prefix(5)
        if !past.isEmpty {
            m.addItem(.separator())
            m.addItem(disabled(L("history")))
            for p in past { m.addItem(disabled("  \(f.string(from: p.start)) · \(summaryLine(p))")) }
        }
        m.addItem(.separator())
        m.addItem(item(L("openLog"), #selector(openLog)))
        return m
    }

    private func settingsMenu() -> NSMenu {
        let s = NSMenu()
        s.addItem(disabled(L("watchHeader")))
        for (idx, g) in AgentGroup.allCases.enumerated() {
            let key = g == .claude ? "groupClaude" : (g == .codex ? "groupCodex" : "groupOther")
            let i = toggle("  " + L(key), isWatched(g), #selector(toggleGroup(_:))); i.tag = idx; s.addItem(i)
        }
        s.addItem(toggle(L("includeTerminal"), includeTerminal, #selector(toggleTerminal)))
        s.addItem(toggle(L("readTerminals"), readTerminals, #selector(toggleReadTerminals)))
        s.addItem(.separator())
        s.addItem(toggle(L("autoResume"), autoResume, #selector(toggleAutoResume)))
        if wakeHelperInstalled {
            s.addItem(disabled("  ✓ " + L("wakeReady")))
            s.addItem(item("  " + L("wakeRemove"), #selector(removeWakeHelper)))
        } else {
            s.addItem(item("  " + L("wakeSetup"), #selector(installWakeHelper)))
        }
        s.addItem(.separator())
        s.addItem(batterySliderItem())
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
        s.addItem(toggle(L("loginItem"), FileManager.default.fileExists(atPath: launchAgentURL.path),
                         #selector(toggleLaunchAgent)))
        let langItem = NSMenuItem(title: L("language"), action: nil, keyEquivalent: "")
        langItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let langMenu = NSMenu()
        for (idx, lang) in Lang.allCases.enumerated() {
            let i = toggle(lang.label, Loc.choice == lang, #selector(setLanguage(_:))); i.tag = idx; langMenu.addItem(i)
        }
        langItem.submenu = langMenu
        s.addItem(langItem)
        return s
    }

    /// Slider (0 = off … 50 %) for "stop when battery drops to X %".
    private func batterySliderItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 62))
        let label = NSTextField(labelWithString: batteryLabelText())
        label.font = NSFont.menuFont(ofSize: 0)
        label.frame = NSRect(x: 20, y: 40, width: 250, height: 18)
        let note = NSTextField(labelWithString: L("batteryNote"))
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 20, y: 2, width: 250, height: 14)
        let slider = NSSlider(value: Double(batteryLimit), minValue: 0, maxValue: 50,
                              target: self, action: #selector(batterySliderChanged(_:)))
        slider.numberOfTickMarks = 11
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.frame = NSRect(x: 18, y: 17, width: 244, height: 22)
        [label, slider, note].forEach(view.addSubview)
        batteryLabel = label
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func batteryLabelText() -> String {
        batteryLimit == 0 ? L("batteryLimitOff") : L("batteryLimit", batteryLimit)
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
        if monitor.tmuxPath == nil && !includeTerminal { notify("AgentAwake", L("noTmux")); return }
        start(.agents(started: Date()))
    }
    @objc private func startTimed(_ s: NSMenuItem) { start(.timed(until: Date().addingTimeInterval(Double(s.tag * 60)))) }
    @objc private func startIndefinite() { start(.indefinite) }
    @objc private func turnOff() {
        if let line = endSession(L("evStopped")) { notify("AgentAwake", line) }
        stop()
    }
    @objc private func toggleDisplay() { keepDisplayOn.toggle(); if hasAssertion { setAssertion(true) } }
    @objc private func toggleSleepWhenDone() { sleepWhenDone.toggle() }
    @objc private func toggleSleepAfterTimer() { sleepAfterTimer.toggle() }
    @objc private func toggleAutoResume() { autoResume.toggle() }
    @objc private func toggleTerminal() { includeTerminal.toggle() }
    @objc private func toggleReadTerminals() { readTerminals.toggle() }
    @objc private func toggleGroup(_ s: NSMenuItem) {
        let g = AgentGroup.allCases[s.tag]
        defaults.set(!isWatched(g), forKey: "watch." + g.rawValue)
    }
    @objc private func setGrace(_ s: NSMenuItem) { graceMinutes = s.tag }
    @objc private func setMax(_ s: NSMenuItem) { maxAgentHours = s.tag }
    @objc private func batterySliderChanged(_ s: NSSlider) {
        batteryLimit = Int((s.doubleValue / 5).rounded()) * 5
        batteryLabel?.stringValue = batteryLabelText()
    }
    @objc private func setLanguage(_ s: NSMenuItem) {
        Loc.choice = Lang.allCases[s.tag]
        updateButton()
    }
    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: SessionStore.logURL.path) { store.log("AgentAwake log") }
        NSWorkspace.shared.open(SessionStore.logURL)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    /// LaunchAgent: start at login and relaunch after a crash (not after a normal Quit).
    @objc private func toggleLaunchAgent() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentURL.path) {
            try? fm.removeItem(at: launchAgentURL) // takes effect from the next login
            notify("AgentAwake", L("loginOff"))
            return
        }
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": Self.agentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        try? fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: launchAgentURL)) != nil else { return }
        notify("AgentAwake", L("loginOn"))
        saveState()
        // Hand over to the launchd-managed copy so crash-restart works right away.
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Self.agentLabel)"])
        if Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", launchAgentURL.path]).status == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
    }

    private func notify(_ title: String, _ body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        DispatchQueue.global().async {
            _ = Shell.appleScript("display notification \"\(esc(body))\" with title \"\(esc(title))\"")
        }
    }
}
