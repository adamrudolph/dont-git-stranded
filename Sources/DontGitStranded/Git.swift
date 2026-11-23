import Foundation

struct GitResult {
    let status: Int32
    let out: String
    let err: String
    var ok: Bool { status == 0 }
    var message: String {
        let e = err.trimmed
        return e.isEmpty ? out.trimmed : e
    }
}

private final class DataBox: @unchecked Sendable { var data = Data() }

/// Runs git as a child process (no shell, arguments passed as-is). Never prompts for credentials.
enum Git {
    static let executable: String = {
        for p in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/bin/git"
    }()

    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "")
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        env["GIT_TERMINAL_PROMPT"] = "0"   // fail instead of waiting for a password; SSH has no terminal to prompt on
        return env
    }()

    /// A repo's own .git/config can set core.fsmonitor to any command, which `git status` would run.
    /// Scanning repos you cloned shouldn't execute their code, so it's always off.
    static let hardening = ["-c", "core.fsmonitor=false"]

    @discardableResult
    static func run(_ dir: String, _ args: [String], timeout: TimeInterval = 60) -> GitResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = hardening + ["-C", dir] + args
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return GitResult(status: -1, out: "", err: error.localizedDescription)
        }
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        killer.cancel()
        return GitResult(status: p.terminationStatus,
                         out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: errBox.data, as: UTF8.self))
    }

    /// Turns a remote URL (ssh or https) into a browsable https URL, if it looks like one.
    static func webURL(forRemote remote: String) -> URL? {
        var s = remote.trimmed
        if s.hasPrefix("git@") || (!s.contains("://") && s.contains(":")) {
            if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
            s = s.replacingOccurrences(of: ":", with: "/", options: [], range: s.range(of: ":"))
            s = "https://" + s
        } else if s.hasPrefix("ssh://") {
            s = String(s.dropFirst(6))
            if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
            // drop a :port
            if let colon = s.firstIndex(of: ":"), let slash = s.firstIndex(of: "/"), colon < slash {
                s.removeSubrange(colon..<slash)
            }
            s = "https://" + s
        } else if s.hasPrefix("https://") || s.hasPrefix("http://") {
            if let schemeEnd = s.range(of: "://"), let at = s[schemeEnd.upperBound...].firstIndex(of: "@"),
               let slash = s[schemeEnd.upperBound...].firstIndex(of: "/"), at < slash {
                s.removeSubrange(schemeEnd.upperBound...at)
            }
        } else {
            return nil
        }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        return URL(string: s)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var lines: [String] { split(whereSeparator: \.isNewline).map(String.init) }
    var tildePath: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}

func formatAge(_ seconds: TimeInterval) -> String {
    let m = Int(max(seconds, 0) / 60)
    if m < 60 { return "\(m)m" }
    let h = m / 60
    if h < 48 { return "\(h)h" }
    let d = h / 24
    return d < 21 ? "\(d)d" : "\(d / 7)w"
}

func formatHours(_ h: Double) -> String {
    if h == 0 { return "immediately" }
    if h < 1 { return "\(Int(h * 60)) min" }
    if h.truncatingRemainder(dividingBy: 24) == 0 && h >= 24 {
        let d = Int(h / 24); return d == 1 ? "1 day" : "\(d) days"
    }
    return h == 1 ? "1 hour" : "\(h.formatted()) hours"
}
