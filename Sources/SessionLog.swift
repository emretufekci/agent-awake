import Foundation

struct SessionEvent: Codable {
    let at: Date
    let text: String
}

struct AgentStat: Codable {
    var label: String
    var busySeconds: Double = 0
    var lastState: String = ""
}

/// One keep-awake session: from starting a mode until it finishes or is turned off.
struct SessionLog: Codable {
    var start = Date()
    var end: Date?
    var kind: String
    var agents: [String: AgentStat] = [:]
    var limitHits = 0
    var resumes = 0
    var questions = 0
    var sleeps = 0
    var events: [SessionEvent] = []
    var endReason: String?

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }

    mutating func add(_ text: String) {
        events.append(SessionEvent(at: Date(), text: text))
        if events.count > 300 { events.removeFirst(events.count - 300) }
    }
}

/// Keeps past sessions (Application Support/AgentAwake/history.json) and a readable log (~/Library/Logs/AgentAwake.log).
final class SessionStore {
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentAwake")
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AgentAwake.log")
    private static var historyURL: URL { supportDir.appendingPathComponent("history.json") }

    private(set) var history: [SessionLog] = []
    private let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    init() {
        if let data = try? Data(contentsOf: Self.historyURL),
           let h = try? JSONDecoder().decode([SessionLog].self, from: data) { history = h }
    }

    func log(_ line: String) {
        let text = "\(stamp.string(from: Date()))  \(line)\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: Self.logURL) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: Self.logURL, atomically: true, encoding: .utf8)
        }
    }

    func archive(_ s: SessionLog) {
        history.append(s)
        if history.count > 50 { history.removeFirst(history.count - 50) }
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: Self.historyURL, options: .atomic) }
    }
}
