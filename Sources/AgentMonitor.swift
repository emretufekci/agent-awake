import Cocoa

enum AgentGroup: String, CaseIterable, Codable { case claude, codex, other }
enum AgentSource: String, Codable { case tmux, terminal }

enum AgentState: Equatable {
    case working            // screen shows the agent is mid-turn ("esc to interrupt")
    case cpu(Double)        // process tree is burning CPU
    case question(String)   // agent is waiting for the user's answer
    case limited(Date)      // hit its usage limit; resets at this time
    case idle

    var kind: String {
        switch self {
        case .working, .cpu: return "busy"
        case .question: return "question"
        case .limited: return "limited"
        case .idle: return "idle"
        }
    }
}

/// Where to type "continue" once a usage limit resets.
struct ResumeTarget: Codable, Equatable {
    let source: AgentSource
    let handle: String               // tmux pane id ("%3") or tty ("ttys002")
    let app: TerminalScreens.App?    // for terminal sessions
    let limitKey: String?
    let label: String
}

struct AgentPane {
    let id: String          // "tmux:%3" / "tty:ttys002"
    let source: AgentSource
    let target: String      // "main:1.0" / "iTerm · ttys002"
    let name: String        // "claude", "codex", "gemini", …
    let group: AgentGroup
    let state: AgentState
    let screenRead: Bool    // false → judged by CPU only
    let resume: ResumeTarget?

    var label: String { "\(name) \(target)" }
    var busy: Bool { state.kind == "busy" }
    var limitReset: Date? { if case .limited(let d) = state { return d } else { return nil } }
    var question: String? { if case .question(let q) = state { return q } else { return nil } }
}

/// Finds coding agents in tmux panes and terminal windows and decides what each one is doing.
/// Not thread-safe: use from a single (background) queue.
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
    var readTerminalScreens = true
    /// Limit messages already resumed, so an old message still on screen is ignored.
    var handledLimits = Set<String>()

    /// Strings agents print on screen while a turn is in progress.
    private let busyMarkers = ["esc to interrupt", "ctrl+c to interrupt"]
    /// CPU % (of one core, averaged since last scan) above which an agent counts as working.
    /// Measured: working Claude Code ≈ 10–15 %, idle at prompt ≈ 0.3–1.5 %.
    var cpuBusyThreshold = 5.0

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
                    let raw = Shell.run(tmux, ["capture-pane", "-p", "-J", "-t", f[0]], cLocale: false).out
                    let (state, limitKey) = classify(key: key, screen: raw, cpu: cpu)
                    let label = "\(agent.name) \(f[2])"
                    result.append(AgentPane(
                        id: key, source: .tmux, target: f[2], name: agent.name, group: agent.group,
                        state: state, screenRead: true,
                        resume: ResumeTarget(source: .tmux, handle: f[0], app: nil, limitKey: limitKey, label: label)))
                }
            }
        }

        // 2) agents started directly in a terminal window (Terminal, iTerm2, Ghostty, VS Code, …)
        guard includeTerminal else {
            cpuSamples = cpuSamples.filter { usedKeys.contains($0.key) }
            return result
        }
        var candidates: [(pid: Int32, tty: String, agent: (name: String, group: AgentGroup), app: String?)] = []
        for (pid, p) in procs.sorted(by: { $0.key < $1.key }) {
            guard p.tty != "??", !p.tty.isEmpty, !tmuxPids.contains(pid),
                  !p.args.contains("--bg-"), !p.args.contains(" daemon"),
                  let agent = agent(for: p.args), enabledGroups.contains(agent.group) else { continue }
            // Only the top-most agent process (skip sub-agents) and find the hosting .app.
            var anc = p.ppid, nested = false, app: String?
            while anc > 1, let a = procs[anc] {
                if self.agent(for: a.args) != nil { nested = true; break }
                if app == nil, let r = a.args.range(of: ".app/") {
                    app = (String(a.args[..<r.lowerBound]) as NSString).lastPathComponent
                }
                anc = a.ppid
            }
            if !nested { candidates.append((pid, p.tty, agent, app)) }
        }

        var screens: [TerminalScreens.App: [String: String]] = [:]
        if readTerminalScreens {
            for app in Set(candidates.compactMap({ TerminalScreens.app(forName: $0.app) })) {
                screens[app] = TerminalScreens.read(app)
            }
        }
        for c in candidates {
            let key = "tty:" + c.tty
            usedKeys.insert(key)
            let cpu = cpuPercent(key, subtree(c.pid))
            let termApp = TerminalScreens.app(forName: c.app)
            let raw = termApp.flatMap { screens[$0]?[c.tty] }
            let (state, limitKey) = classify(key: key, screen: raw, cpu: cpu)
            let target = (c.app.map { $0 + " · " } ?? "") + c.tty
            let label = "\(c.agent.name) \(target)"
            result.append(AgentPane(
                id: key, source: .terminal, target: target, name: c.agent.name, group: c.agent.group,
                state: state, screenRead: raw != nil,
                resume: termApp.map { ResumeTarget(source: .terminal, handle: c.tty, app: $0, limitKey: limitKey, label: label) }))
        }

        cpuSamples = cpuSamples.filter { usedKeys.contains($0.key) }
        return result
    }

    /// Screen first (working → question → usage limit), then CPU.
    private func classify(key: String, screen: String?, cpu: Double) -> (AgentState, String?) {
        if let screen {
            let lines = screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let bottom = Array(lines.suffix(14))
            let low = bottom.joined(separator: "\n").lowercased()
            if busyMarkers.contains(where: low.contains) { return (.working, nil) }
            if let q = QuestionDetector.detect(bottom) { return (.question(q), nil) }
            if let lim = detectLimit(key: key, lines: Array(lines.suffix(25))) { return (.limited(lim.reset), lim.key) }
        }
        return (cpu >= cpuBusyThreshold ? .cpu(cpu) : .idle, nil)
    }

    private func detectLimit(key: String, lines: [String]) -> (key: String, reset: Date)? {
        for line in lines.reversed() where LimitParser.isLimitLine(line) {
            let k = key + "|" + line
            if handledLimits.contains(k) { return nil } // newest message already handled
            if let d = limitCache[k] { return (k, d) }
            guard let d = LimitParser.resetDate(in: line) else { continue }
            limitCache[k] = d
            return (k, d)
        }
        return nil
    }

    /// Types the resume message (e.g. "continue") into a tmux pane or terminal session.
    func resume(_ t: ResumeTarget, text: String) {
        switch t.source {
        case .tmux:
            guard let tmux = tmuxPath else { return }
            Shell.run(tmux, ["send-keys", "-t", t.handle, "-l", text], cLocale: false)
            Thread.sleep(forTimeInterval: 0.6)
            Shell.run(tmux, ["send-keys", "-t", t.handle, "Enter"])
        case .terminal:
            if let app = t.app { TerminalScreens.type(text, app: app, tty: t.handle) }
        }
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

    /// Parses ps `time` output: "MM:SS.ss", "HH:MM:SS.ss" or "D-HH:MM:SS".
    private static func parseTime(_ s: String) -> Double {
        var days = 0.0, rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") { days = Double(rest[..<dash]) ?? 0; rest = rest[rest.index(after: dash)...] }
        let secs = rest.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1.replacingOccurrences(of: ",", with: ".")) ?? 0) }
        return days * 86400 + secs
    }
}

/// Recognises "the agent is waiting for your answer" screens
/// (Claude Code permission prompts / questions, Codex approvals, y/n prompts).
enum QuestionDetector {
    private static let markers = [
        "do you want to proceed", "do you want to make", "do you want to create", "do you want to allow",
        "do you want to run", "would you like to run", "would you like to make", "allow command?",
        "yes, and don't ask again", "no, and tell ", "(y/n)", "[y/n]", "press enter to confirm",
        "approve this", "allow this",
    ]
    private static let junk = CharacterSet(charactersIn: "│┃║╭╮╰╯─━═▌■●❯›>⏺ \t")

    static func detect(_ lines: [String]) -> String? {
        let low = lines.map { $0.lowercased() }
        let hasMarker = low.contains { l in markers.contains(where: l.contains) }
        // Option list ("❯ 1. Yes") under a line that ends with "?"
        let hasOptions = low.contains { $0.hasPrefix("❯ 1.") || $0.hasPrefix("› 1.") }
            && lines.contains { clean($0).hasSuffix("?") }
        guard hasMarker || hasOptions else { return nil }
        if let q = lines.last(where: { clean($0).hasSuffix("?") }) { return String(clean(q).prefix(90)) }
        if let m = lines.first(where: { l in markers.contains(where: l.lowercased().contains) }) {
            return String(clean(m).prefix(90))
        }
        return "?"
    }

    private static func clean(_ s: String) -> String { s.trimmingCharacters(in: junk) }
}
