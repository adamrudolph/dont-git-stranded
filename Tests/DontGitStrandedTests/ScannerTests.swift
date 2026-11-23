import XCTest
@testable import DontGitStranded

/// End-to-end checks against real throwaway repos.
final class ScannerTests: XCTestCase {
    private var root: URL!
    private var code: String { root.appendingPathComponent("code").path }
    private let old = "2020-01-01T10:00:00"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dgs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("code"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    @discardableResult
    private func git(_ dir: String, _ args: String..., date: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Git.executable)
        p.arguments = ["-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@example.com"
        env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@example.com"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        if let date { env["GIT_AUTHOR_DATE"] = date; env["GIT_COMMITTER_DATE"] = date }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func path(_ rel: String) -> String { (code as NSString).appendingPathComponent(rel) }

    private func write(_ file: String, _ text: String = "x\n", age: TimeInterval? = nil) throws {
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        if let age {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file)
        }
    }

    /// New repo with one old commit on main.
    private func makeRepo(_ rel: String) throws -> String {
        let dir = path(rel)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try git(dir, "init", "-q", "-b", "main")
        try write(dir + "/a")
        try git(dir, "add", "a")
        try git(dir, "commit", "-qm", "init", date: old)
        return dir
    }

    private func makeBareRemote() throws -> String {
        let bare = root.appendingPathComponent("remote.git").path
        try git(root.path, "init", "-q", "--bare", bare)
        return bare
    }

    private func scan(_ config: ScanConfig = AppSettings().scanConfig, worktrees: Bool = false) -> [RepoAlert] {
        let repos = Scanner.discover(root: code, maxDepth: 3, excludes: ["node_modules"], includeWorktrees: worktrees)
        return Scanner.scanAll(repos, config: config)
    }

    private func kinds(_ alerts: [RepoAlert], repo: String) -> Set<AlertKind> {
        Set(alerts.filter { $0.repoName == repo }.map(\.kind))
    }

    // MARK: Tests

    func testFlagsEachKind() throws {
        let remote = try makeBareRemote()
        let pushed = try makeRepo("pushed")
        try git(pushed, "remote", "add", "origin", remote)
        try git(pushed, "push", "-q", "-u", "origin", "main")

        // Unpushed: an old commit ahead of upstream.
        try write(pushed + "/b")
        try git(pushed, "add", "b")
        try git(pushed, "commit", "-qm", "old unpushed", date: old)
        // Unpublished: a branch with no upstream.
        try git(pushed, "checkout", "-qb", "feature")
        try write(pushed + "/c")
        try git(pushed, "add", "c")
        try git(pushed, "commit", "-qm", "feature", date: old)
        try git(pushed, "checkout", "-q", "main")

        _ = try makeRepo("group/noremote")

        let stale = try makeRepo("stale")
        try write(stale + "/a", "changed\n", age: 3 * 86400)
        try write(stale + "/new.txt", age: 3 * 86400)

        let stashy = try makeRepo("stashy")
        try write(stashy + "/a", "stashed\n")
        try git(stashy, "stash", "-q", date: old)

        let alerts = scan()
        XCTAssertEqual(kinds(alerts, repo: "pushed"), [.unpushed, .unpublished])
        XCTAssertEqual(kinds(alerts, repo: "noremote"), [.noRemote])
        XCTAssertTrue(kinds(alerts, repo: "stale").contains(.stale))
        XCTAssertTrue(kinds(alerts, repo: "stashy").contains(.stash))

        let unpushed = try XCTUnwrap(alerts.first { $0.kind == .unpushed })
        guard case .branch(let d) = unpushed.detail else { return XCTFail("expected branch detail") }
        XCTAssertEqual(d.branch, "main")
        XCTAssertEqual(d.totalCount, 1)
        XCTAssertEqual(d.commits.first?.subject, "old unpushed")
    }

    func testRecentWorkIsNotFlagged() throws {
        let remote = try makeBareRemote()
        let repo = try makeRepo("fresh")
        try git(repo, "remote", "add", "origin", remote)
        try git(repo, "push", "-q", "-u", "origin", "main")
        try write(repo + "/b")
        try git(repo, "add", "b")
        try git(repo, "commit", "-qm", "just now")      // under the 2h threshold
        try write(repo + "/wip.txt")                    // under the 24h threshold
        XCTAssertTrue(scan().isEmpty)
    }

    func testThresholdZeroFlagsImmediately() throws {
        let repo = try makeRepo("wip")
        try git(repo, "remote", "add", "origin", try makeBareRemote())
        try git(repo, "push", "-q", "-u", "origin", "main")
        try write(repo + "/wip.txt")
        var config = AppSettings().scanConfig
        config.thresholds[.stale] = 0
        XCTAssertEqual(kinds(scan(config), repo: "wip"), [.stale])
    }

    func testDeletedUpstreamOnlyFlaggedWithLocalOnlyCommits() throws {
        let remote = try makeBareRemote()
        let repo = try makeRepo("gone")
        try git(repo, "remote", "add", "origin", remote)
        try git(repo, "push", "-q", "-u", "origin", "main")
        for b in ["merged", "work"] {
            try git(repo, "checkout", "-qb", b, "main")
            try git(repo, "push", "-q", "-u", "origin", b)
        }
        try write(repo + "/local")
        try git(repo, "add", "local")
        try git(repo, "commit", "-qm", "local only", date: old)
        try git(repo, "checkout", "-q", "main")
        try git(repo, "push", "-q", "origin", "--delete", "merged", "work")
        try git(repo, "fetch", "-q", "--prune")

        let alerts = scan().filter { $0.kind == .unpublished }
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(alerts[0].title.hasPrefix("work:"), alerts[0].title)
    }

    func testSkipsExcludedFoldersAndHandlesWorktrees() throws {
        _ = try makeRepo("proj/node_modules/dep")
        let main = try makeRepo("main")
        try git(main, "worktree", "add", "-q", path("main-wt"), "-b", "wt")
        try write(path("main-wt") + "/w", age: 3 * 86400)

        let without = Scanner.discover(root: code, maxDepth: 3, excludes: ["node_modules"], includeWorktrees: false)
        XCTAssertEqual(without.map(\.name), ["main"])

        let with = Scanner.discover(root: code, maxDepth: 3, excludes: ["node_modules"], includeWorktrees: true)
        XCTAssertEqual(Set(with.map(\.name)), ["main", "main-wt"])
        XCTAssertEqual(with.first { $0.name == "main-wt" }?.kind, .worktree)

        // The worktree reports its own stale files; the no-remote alert is shared and reported once.
        let alerts = scan(worktrees: true)
        XCTAssertEqual(alerts.filter { $0.kind == .noRemote }.count, 1)
        XCTAssertEqual(kinds(alerts, repo: "main-wt"), [.stale])
    }

    /// A cloned repo's .git/config must not be able to run commands when we scan it.
    func testRepoFsmonitorCommandIsNeverRun() throws {
        let repo = try makeRepo("hostile")
        let marker = root.appendingPathComponent("pwned").path
        let hook = root.appendingPathComponent("hook.sh").path
        try write(hook, "#!/bin/sh\ntouch '\(marker)'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        try git(repo, "config", "core.fsmonitor", hook)
        try write(repo + "/a", "changed\n", age: 3 * 86400)

        _ = scan()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "scan executed core.fsmonitor from repo config")
    }

    func testCLIAgreesWithApp() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("git-stranded").path
        _ = try makeRepo("noremote")
        let stale = try makeRepo("stale")
        try write(stale + "/a", "changed\n", age: 3 * 86400)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script, "--root", code, "--json"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = root.path   // no ~/.config/git-stranded/config.json from the person running the tests
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 1, "exit 1 means issues found")

        struct Report: Decodable { struct Issue: Decodable { let kind: String }; let issues: [Issue] }
        let cli = Set(try JSONDecoder().decode(Report.self, from: data).issues.map(\.kind))
        let app = Set(scan().map(\.kind.rawValue))
        XCTAssertEqual(cli, app)
    }
}

final class ValidationTests: XCTestCase {
    func testRemoteNames() {
        for ok in ["origin", "upstream", "my-fork", "team/backup", "a.b_c"] {
            XCTAssertTrue(AppState.isValidRemoteName(ok), ok)
        }
        for bad in ["", "-x", "--upload-pack=evil", "a b", "a..b", "x/", "x.lock", "a;b"] {
            XCTAssertFalse(AppState.isValidRemoteName(bad), bad)
        }
    }

    func testRemoteURLs() {
        XCTAssertTrue(AppState.isValidRemoteURL("git@github.com:me/repo.git"))
        XCTAssertTrue(AppState.isValidRemoteURL("https://github.com/me/repo.git"))
        XCTAssertFalse(AppState.isValidRemoteURL("--upload-pack=touch /tmp/x"))
        XCTAssertFalse(AppState.isValidRemoteURL("https://x y"))
        XCTAssertFalse(AppState.isValidRemoteURL(""))
    }

    func testWebURL() {
        XCTAssertEqual(Git.webURL(forRemote: "git@github.com:me/repo.git")?.absoluteString, "https://github.com/me/repo")
        XCTAssertEqual(Git.webURL(forRemote: "ssh://git@gitlab.com:2222/me/repo.git")?.absoluteString, "https://gitlab.com/me/repo")
        XCTAssertEqual(Git.webURL(forRemote: "https://user:token@github.com/me/repo.git")?.absoluteString, "https://github.com/me/repo")
        XCTAssertNil(Git.webURL(forRemote: "/local/path/repo.git"))
        XCTAssertNil(Git.webURL(forRemote: "../relative.git"))
    }

    func testSettingsDecodeIsTolerant() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"maxDepth": 5}"#.utf8))
        XCTAssertEqual(s.maxDepth, 5)
        XCTAssertEqual(s.scanIntervalMinutes, AppSettings().scanIntervalMinutes)
        XCTAssertEqual(s.threshold(.stale), 24)
    }
}
