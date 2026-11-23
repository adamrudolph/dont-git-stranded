import SwiftUI

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    var settings: AppSettings {
        didSet { settingsChanged(from: oldValue) }
    }
    var alerts: [RepoAlert] = []
    var discovered: [DiscoveredRepo] = []
    var isScanning = false
    var isDiscovering = false
    var lastScan: Date?
    var sidebar: SidebarItem? = .all
    var selectedAlertID: String?
    var banner: Banner?
    var busyAction: String?

    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var openWindowCount = 0
    @ObservationIgnored private var notified: [String: Date]

    private static let notifiedKey = "notified.v1"

    init() {
        settings = AppSettings.load()
        let raw = UserDefaults.standard.dictionary(forKey: Self.notifiedKey) as? [String: Date]
        notified = raw ?? [:]
    }

    // MARK: Derived

    func isHidden(_ a: RepoAlert) -> Bool {
        if settings.muted.contains(a.id) { return true }
        if let until = settings.snoozed[a.id], until > Date() { return true }
        return false
    }

    var visibleAlerts: [RepoAlert] { alerts.filter { !isHidden($0) } }
    var hiddenAlerts: [RepoAlert] { alerts.filter { isHidden($0) } }

    func alert(_ id: String?) -> RepoAlert? { id.flatMap { id in alerts.first { $0.id == id } } }

    var summaryLine: String {
        if settings.trackedRepos.isEmpty { return "No repositories tracked" }
        let v = visibleAlerts
        if isScanning && lastScan == nil { return "Scanning…" }
        if v.isEmpty { return "All clear · \(trackedForScan.count) repos" }
        let repos = Set(v.map(\.repoPath)).count
        return "\(v.count) alert\(v.count == 1 ? "" : "s") in \(repos) repo\(repos == 1 ? "" : "s")"
    }

    /// Tracked repos that still exist, worktrees last so the main repo's copy of a shared alert wins.
    var trackedForScan: [DiscoveredRepo] {
        let byPath = Dictionary(discovered.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let repos: [DiscoveredRepo] = settings.trackedRepos.compactMap { p in
            if let r = byPath[p] {
                return (settings.excludeWorktrees && r.kind == .worktree) ? nil : r
            }
            guard FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent(".git")) else { return nil }
            let r = Scanner.classify(p)
            return (settings.excludeWorktrees && r.kind == .worktree) ? nil : r
        }
        return repos.sorted { ($0.kind == .worktree ? 1 : 0, $0.path) < ($1.kind == .worktree ? 1 : 0, $1.path) }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if settings.notificationsEnabled { Notifier.requestAuthorization() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))   // let the network come back
                await AppState.shared.scan()
            }
        }
        Task {
            await discover()
            await scan()
        }
        restartTimer()
    }

    private func restartTimer() {
        timerTask?.cancel()
        let minutes = max(settings.scanIntervalMinutes, 1)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                if Task.isCancelled { break }
                await self?.scan()
            }
        }
    }

    private func settingsChanged(from old: AppSettings) {
        settings.save()
        let s = settings
        if s.rootPath != old.rootPath || s.maxDepth != old.maxDepth || s.excludes != old.excludes
            || s.excludeWorktrees != old.excludeWorktrees {
            debounce { await $0.discover(); await $0.scan() }
        } else if s.trackedRepos != old.trackedRepos || s.enabledKinds != old.enabledKinds
                    || s.thresholdHours != old.thresholdHours {
            debounce { await $0.scan() }
        }
        if s.scanIntervalMinutes != old.scanIntervalMinutes && started { restartTimer() }
        if s.notificationsEnabled && !old.notificationsEnabled { Notifier.requestAuthorization() }
    }

    private func debounce(_ work: @escaping @MainActor (AppState) async -> Void) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            await work(self)
        }
    }

    // MARK: Discovery & scanning

    func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        let s = settings
        let found = await Task.detached(priority: .utility) {
            Scanner.discover(root: s.rootPath, maxDepth: s.maxDepth, excludes: Set(s.excludes),
                             includeWorktrees: !s.excludeWorktrees)
        }.value
        discovered = found

        var next = settings
        for r in found where !next.knownRepos.contains(r.path) {
            if r.kind == .worktree, let main = r.mainRepoPath, next.trackedRepos.contains(main) {
                next.trackedRepos.insert(r.path)   // new worktree of a tracked repo
            } else if next.autoTrackNewRepos && next.onboarded {
                next.trackedRepos.insert(r.path)
            }
        }
        next.knownRepos.formUnion(found.map(\.path))
        if next != settings { settings = next }
    }

    func scan(forceFetch: Bool = false) async {
        guard !isScanning else { return }
        if discovered.isEmpty && !settings.trackedRepos.isEmpty { await discover() }
        isScanning = true
        defer { isScanning = false }
        let repos = trackedForScan
        var config = settings.scanConfig
        if forceFetch { config.fetch = true }
        let result = await Task.detached(priority: .utility) { Scanner.scanAll(repos, config: config) }.value
        alerts = result
        lastScan = Date()

        // Drop expired snoozes and selection of resolved alerts.
        let now = Date()
        let live = settings.snoozed.filter { $0.value > now }
        if live.count != settings.snoozed.count { settings.snoozed = live }
        if let sel = selectedAlertID, alert(sel) == nil { selectedAlertID = nil }
        notifyIfNeeded()
    }

    // MARK: Notifications

    private func notifyIfNeeded() {
        let current = Set(alerts.map(\.id))
        notified = notified.filter { current.contains($0.key) }   // resolved alerts can notify again later
        defer { UserDefaults.standard.set(notified, forKey: Self.notifiedKey) }
        guard settings.notificationsEnabled else { return }

        let now = Date()
        let due = visibleAlerts.filter { a in
            guard let last = notified[a.id] else { return true }
            return settings.renotifyHours > 0 && now.timeIntervalSince(last) >= settings.renotifyHours * 3600
        }
        guard !due.isEmpty else { return }
        for a in due { notified[a.id] = now }

        if due.count <= 3 {
            for a in due {
                Notifier.post(id: a.id, title: "\(a.kind.title) · \(a.repoName)", body: a.title, alertID: a.id)
            }
        } else {
            let repos = Set(due.map(\.repoPath)).count
            Notifier.post(id: "summary", title: "Don't Git Stranded: \(due.count) alerts",
                          body: "Work at risk in \(repos) repo\(repos == 1 ? "" : "s"). Click to review.", alertID: nil)
        }
    }

    // MARK: Windows

    func showMain(selecting id: String? = nil) {
        if let id {
            sidebar = .all
            if let a = alert(id), isHidden(a) { sidebar = .hidden }
            selectedAlertID = id
        }
        openWindowAction?(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show a Dock icon while a window is open so it can be Cmd-Tabbed to; menu-bar-only otherwise.
    func windowOpened() {
        openWindowCount += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowClosed() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: Alert state

    func snooze(_ a: RepoAlert, hours: Double) {
        settings.snoozed[a.id] = Date().addingTimeInterval(hours * 3600)
        flash("Snoozed until \(Date().addingTimeInterval(hours * 3600).formatted(date: .abbreviated, time: .shortened))")
    }

    func mute(_ a: RepoAlert) {
        settings.muted.insert(a.id)
        flash("Muted. Find it under Snoozed & muted to turn it back on.")
    }

    func unhide(_ a: RepoAlert) {
        settings.snoozed[a.id] = nil
        settings.muted.remove(a.id)
    }

    func setTracked(_ path: String, _ on: Bool) {
        if on { settings.trackedRepos.insert(path) } else { settings.trackedRepos.remove(path) }
    }

    func flash(_ message: String, error: Bool = false) {
        let b = Banner(message: message, isError: error)
        banner = b
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(error ? 8 : 4))
            if !Task.isCancelled, self?.banner == b { self?.banner = nil }
        }
    }
}
