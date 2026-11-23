import Foundation

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

/// Repo discovery and per-repo checks. Ported from git-stranded, with structured details for the UI.
enum Scanner {
    static let maxListed = 100

    // MARK: Discovery

    static func discover(root: String, maxDepth: Int, excludes: Set<String>, includeWorktrees: Bool) -> [DiscoveredRepo] {
        var found: [DiscoveredRepo] = []
        walk(root, depth: 0, maxDepth: maxDepth, excludes: excludes, into: &found)

        if includeWorktrees {
            // Compare real paths: git reports /private/var/... where the walk saw /var/... (same folder).
            var known = Set(found.map { realPath($0.path) })
            for repo in found where repo.kind == .standard {
                for wt in linkedWorktrees(of: repo.path) where !known.contains(realPath(wt)) {
                    known.insert(realPath(wt))
                    found.append(DiscoveredRepo(path: wt, kind: .worktree, mainRepoPath: repo.path))
                }
            }
        } else {
            found.removeAll { $0.kind == .worktree }
        }
        // git records a worktree's main repo by its real path; point it at the path we found it under,
        // so worktrees nest under their repo even when the code folder is reached through a symlink.
        let byRealPath = Dictionary(found.map { (realPath($0.path), $0.path) }, uniquingKeysWith: { a, _ in a })
        found = found.map { r in
            guard r.kind == .worktree, let main = r.mainRepoPath, let local = byRealPath[realPath(main)], local != main else { return r }
            return DiscoveredRepo(path: r.path, kind: r.kind, mainRepoPath: local)
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func walk(_ dir: String, depth: Int, maxDepth: Int, excludes: Set<String>, into found: inout [DiscoveredRepo]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        if names.contains(".git") {
            found.append(classify(dir))
            return  // don't descend into a repo
        }
        guard depth < maxDepth else { return }
        for name in names where !name.hasPrefix(".") && !excludes.contains(name) {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeDirectory else { continue }  // skips symlinks
            walk(path, depth: depth + 1, maxDepth: maxDepth, excludes: excludes, into: &found)
        }
    }

    /// A `.git` directory is a normal repo; a `.git` file points at a worktree or submodule git dir.
    static func classify(_ path: String) -> DiscoveredRepo {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir)
        if !isDir.boolValue, let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
           let line = text.lines.first(where: { $0.hasPrefix("gitdir:") }) {
            let gitdir = String(line.dropFirst("gitdir:".count)).trimmed
            if let r = gitdir.range(of: "/.git/worktrees/") {
                return DiscoveredRepo(path: path, kind: .worktree, mainRepoPath: String(gitdir[..<r.lowerBound]))
            }
            if gitdir.contains("/modules/") {
                return DiscoveredRepo(path: path, kind: .submodule, mainRepoPath: nil)
            }
        }
        return DiscoveredRepo(path: path, kind: .standard, mainRepoPath: nil)
    }

    static func linkedWorktrees(of repo: String) -> [String] {
        let out = Git.run(repo, ["worktree", "list", "--porcelain"]).out
        var result: [String] = []
        for block in out.components(separatedBy: "\n\n").dropFirst() {  // first block is the main checkout
            let lines = block.lines
            guard let first = lines.first, first.hasPrefix("worktree ") else { continue }
            if lines.contains(where: { $0 == "bare" || $0.hasPrefix("prunable") }) { continue }
            let path = String(first.dropFirst("worktree ".count))
            if FileManager.default.fileExists(atPath: path) { result.append(path) }
        }
        return result
    }

    // MARK: Scanning

    static func scanAll(_ repos: [DiscoveredRepo], config: ScanConfig) -> [RepoAlert] {
        let now = Date()
        // Worktrees last, so a main repo's copy of a shared alert (branches, stashes, remotes) wins the dedupe below.
        let repos = repos.filter { $0.kind != .worktree } + repos.filter { $0.kind == .worktree }
        let results = Box([[RepoAlert]](repeating: [], count: repos.count))
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: repos.count) { i in
            let r = check(repos[i], config: config, now: now)
            lock.lock(); results.value[i] = r; lock.unlock()
        }
        // Worktrees share branches and stashes with their main repo; keep the first copy of each alert.
        var seen = Set<String>()
        var out: [RepoAlert] = []
        for list in results.value { for a in list where seen.insert(a.id).inserted { out.append(a) } }
        let order = Dictionary(uniqueKeysWithValues: AlertKind.allCases.enumerated().map { ($1, $0) })
        return out.sorted { (order[$0.kind]!, $0.since) < (order[$1.kind]!, $1.since) }
    }

    static func check(_ repo: DiscoveredRepo, config: ScanConfig, now: Date) -> [RepoAlert] {
        let path = repo.path
        // Canonical path: the main repo and its worktrees must agree on it, since shared alerts are keyed by it.
        let common = realPath(Git.run(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).out.trimmed)
        guard !common.isEmpty else { return [] }
        let gitDir = Git.run(path, ["rev-parse", "--path-format=absolute", "--git-dir"]).out.trimmed
        let isWorktree = repo.kind == .worktree

        if config.fetch && !isWorktree {
            Git.run(path, ["fetch", "--all", "--quiet"], timeout: 90)
        }

        var alerts: [RepoAlert] = []
        func add(_ kind: AlertKind, id: String, title: String, since: Date, _ detail: AlertDetail) {
            guard config.passes(kind, since: since, now: now) else { return }
            alerts.append(RepoAlert(id: id, kind: kind, repoPath: path, repoKind: repo.kind,
                                     title: title, since: since, detail: detail))
        }

        let remotes = Git.run(path, ["remote"]).out.lines
        var webURL: URL?
        if let r = remotes.contains("origin") ? "origin" : remotes.first {
            webURL = Git.webURL(forRemote: Git.run(path, ["remote", "get-url", r]).out)
        }

        // --- no remote ---
        if remotes.isEmpty {
            let count = Int(Git.run(path, ["rev-list", "--all", "--count"]).out.trimmed) ?? 0
            if count > 0 {
                let roots = Git.run(path, ["log", "--all", "--max-parents=0", "--format=%ct"]).out.lines.compactMap(Double.init)
                let since = Date(timeIntervalSince1970: roots.min() ?? now.timeIntervalSince1970)
                let head = Git.run(path, ["symbolic-ref", "-q", "--short", "HEAD"]).out.trimmed
                let branches = Git.run(path, ["for-each-ref", "--format=%(refname)", "refs/heads"]).out.lines.count
                add(.noRemote, id: "\(common)|NO-REMOTE",
                    title: "\(count) commit\(count == 1 ? "" : "s") with no backup",
                    since: since,
                    .noRemote(NoRemoteDetail(currentBranch: head.isEmpty ? nil : head, commitCount: count, branchCount: branches)))
            }
        }

        // --- branches: ahead of upstream / on no remote ---
        let fmt = "%(refname:short)%09%(upstream)%09%(upstream:short)%09%(upstream:track)%09%(upstream:remotename)%09%(upstream:remoteref)"
        var refArgs = ["for-each-ref", "--format=\(fmt)"]
        if isWorktree {
            // A worktree only owns its checked-out branch; the main repo reports the rest.
            let head = Git.run(path, ["symbolic-ref", "-q", "HEAD"]).out.trimmed
            if head.isEmpty { refArgs = [] } else { refArgs.append(head) }
        } else {
            refArgs.append("refs/heads")
        }
        if !refArgs.isEmpty {
            for line in Git.run(path, refArgs).out.lines {
                let p = line.components(separatedBy: "\t") + Array(repeating: "", count: 6)
                let (branch, upFull, upShort, track, upRemote, upRef) = (p[0], p[1], p[2], p[3], p[4], p[5])
                let local = "refs/heads/\(branch)"
                var kind: AlertKind?
                var commits: [CommitInfo] = []
                var gone = false

                if !upFull.isEmpty {
                    if track.contains("gone") {
                        gone = true
                        if !remotes.isEmpty { commits = log(path, [local, "--not", "--remotes"]) }
                        if !commits.isEmpty { kind = .unpublished }   // gone but fully merged elsewhere: nothing at risk
                    } else if track.contains("ahead") {
                        commits = log(path, ["\(upFull)..\(local)"])
                        if !commits.isEmpty { kind = .unpushed }
                    }
                } else if !remotes.isEmpty {
                    commits = log(path, [local, "--not", "--remotes"])
                    if !commits.isEmpty { kind = .unpublished }
                }
                guard let kind, let oldest = commits.map(\.date).min() else { continue }

                let n = commits.count
                let s = n == 1 ? "" : "s"
                let title: String
                switch kind {
                case .unpushed: title = "\(branch): \(n) commit\(s) ahead of \(upShort)"
                default: title = gone ? "\(branch): upstream \(upShort) was deleted, \(n) commit\(s) only here"
                                      : "\(branch): \(n) commit\(s) on no remote"
                }
                let detail = BranchDetail(branch: branch,
                                          upstream: upShort.isEmpty ? nil : upShort,
                                          upstreamRemote: upRemote.isEmpty ? nil : upRemote,
                                          upstreamRemoteRef: upRef.isEmpty ? nil : upRef,
                                          upstreamGone: gone,
                                          commits: Array(commits.prefix(maxListed)),
                                          totalCount: n, remotes: remotes, remoteWebURL: webURL)
                add(kind, id: "\(common)|\(kind.rawValue)|\(branch)", title: title, since: oldest, .branch(detail))
            }
        }

        // --- uncommitted changes, with age ---
        let status = Git.run(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]).out
        var changes: [(String, String)] = []
        var skipNext = false
        for e in status.components(separatedBy: "\0") where !e.isEmpty {
            if skipNext { skipNext = false; continue }   // rename/copy: second entry is the old path
            guard e.count > 3 else { continue }
            let code = String(e.prefix(2))
            if code.contains("R") || code.contains("C") { skipNext = true }
            changes.append((code, String(e.dropFirst(3))))
        }
        if !changes.isEmpty {
            var files: [FileChange] = []
            var mtimes: [Date] = []
            let fm = FileManager.default
            for (code, rel) in changes {
                let full = (path as NSString).appendingPathComponent(rel)
                let m = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date
                if let m { mtimes.append(m) }
                if files.count < maxListed { files.append(FileChange(status: code, path: rel, modified: m)) }
            }
            var estimate = false
            if mtimes.isEmpty {   // only deletions: fall back to index time
                estimate = true
                let idx = (gitDir as NSString).appendingPathComponent("index")
                mtimes.append(((try? fm.attributesOfItem(atPath: idx))?[.modificationDate] as? Date) ?? now)
            }
            let oldest = mtimes.min()!, newest = mtimes.max()!
            files.sort { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
            let hasUpstream = !Git.run(path, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]).out.trimmed.isEmpty
            let n = changes.count
            add(.stale, id: "\(path)|STALE",
                title: "\(n) uncommitted file\(n == 1 ? "" : "s"), oldest \(formatAge(now.timeIntervalSince(oldest))) old",
                since: oldest,
                .uncommitted(UncommittedDetail(files: files, totalCount: n, oldest: oldest, newest: newest,
                                               ageIsEstimate: estimate, hasUpstream: hasUpstream)))
        }

        // --- stashes ---
        let stashThreshold = (config.thresholds[.stash] ?? 0) * 3600
        let stashes: [StashInfo] = Git.run(path, ["stash", "list", "--format=%H%x09%ct%x09%gd%x09%gs"]).out.lines.compactMap { line in
            let p = line.components(separatedBy: "\t")
            guard p.count >= 4, let t = Double(p[1]) else { return nil }
            let date = Date(timeIntervalSince1970: t)
            return StashInfo(sha: p[0], ref: p[2], date: date, message: p[3...].joined(separator: "\t"),
                             overThreshold: now.timeIntervalSince(date) >= stashThreshold)
        }
        let old = stashes.filter(\.overThreshold)
        if let oldest = old.map(\.date).min() {
            add(.stash, id: "\(common)|STASH",
                title: "\(old.count) stash\(old.count == 1 ? "" : "es") older than \(formatHours(config.thresholds[.stash] ?? 0))",
                since: oldest, .stashes(stashes))
        }

        return alerts
    }

    static func realPath(_ p: String) -> String {
        guard !p.isEmpty, let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    private static func log(_ repo: String, _ revs: [String]) -> [CommitInfo] {
        let out = Git.run(repo, ["log", "--format=%H%x09%h%x09%ct%x09%an%x09%s"] + revs).out
        return out.lines.compactMap { line in
            let p = line.components(separatedBy: "\t")
            guard p.count >= 5, let t = Double(p[2]) else { return nil }
            return CommitInfo(sha: p[0], shortSHA: p[1], date: Date(timeIntervalSince1970: t),
                              author: p[3], subject: p[4...].joined(separator: "\t"))
        }
    }
}
