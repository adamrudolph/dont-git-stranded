import Foundation

/// `DontGitStranded --scan [root]` prints what the app would alert on, using saved settings. Handy for checking without the UI.
enum HeadlessScan {
    static func run(root: String?) -> Never {
        var s = AppSettings.load()
        if let root { s.rootPath = (root as NSString).expandingTildeInPath }
        let repos = Scanner.discover(root: s.rootPath, maxDepth: s.maxDepth, excludes: Set(s.excludes),
                                     includeWorktrees: !s.excludeWorktrees)
        print("Discovered \(repos.count) repo(s) under \(s.rootPath):")
        for r in repos { print("  [\(r.kind.rawValue)] \(r.path)") }
        let alerts = Scanner.scanAll(repos, config: s.scanConfig)   // all discovered, not just tracked
        print("\n\(alerts.count) alert(s):")
        for a in alerts { print("  [\(a.kind.rawValue)] \(a.repoName): \(a.title)  (\(formatAge(a.age)))") }
        exit(alerts.isEmpty ? 0 : 1)
    }
}
