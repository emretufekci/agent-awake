import Foundation

enum Shell {
    /// Runs a program and returns its exit status and stdout.
    /// `cLocale` forces LC_ALL=C (so `ps` prints 1.5 instead of 1,5); osascript needs UTF-8 instead.
    @discardableResult
    static func run(_ path: String, _ args: [String], input: String? = nil, cLocale: Bool = true) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if cLocale { env["LC_ALL"] = "C" } else { env["LANG"] = "en_US.UTF-8" }
        p.environment = env
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        let inPipe = input == nil ? nil : Pipe()
        if let inPipe { p.standardInput = inPipe }
        do { try p.run() } catch { return (-1, "") }
        if let input, let inPipe {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Runs an AppleScript; nil on error (e.g. Automation permission denied).
    static func appleScript(_ source: String) -> String? {
        let r = run("/usr/bin/osascript", ["-"], input: source, cLocale: false)
        return r.status == 0 ? r.out : nil
    }
}
