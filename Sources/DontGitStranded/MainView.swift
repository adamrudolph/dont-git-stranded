import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if !state.settings.onboarded {
                OnboardingView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
                } content: {
                    AlertListView()
                        .navigationSplitViewColumnWidth(min: 280, ideal: 340)
                } detail: {
                    if let a = state.alert(state.selectedAlertID) {
                        AlertDetailView(alert: a).id(a.id)
                    } else {
                        ContentUnavailableView("Select an alert", systemImage: "shield.lefthalf.filled",
                                               description: Text("Details and fixes appear here."))
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let b = state.banner {
                BannerView(banner: b)
                    .frame(maxWidth: 520)
                    .padding()
                    .shadow(radius: 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.banner)
        .onAppear {
            state.openWindowAction = openWindow
            state.windowOpened()
        }
        .onDisappear { state.windowClosed() }
    }
}

// MARK: Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let visible = state.visibleAlerts
        List(selection: $state.sidebar) {
            Section("Alerts") {
                Label("All alerts", systemImage: "tray.2")
                    .badge(visible.count)
                    .tag(SidebarItem.all)
                ForEach(AlertKind.allCases) { k in
                    let n = visible.filter { $0.kind == k }.count
                    Label { Text(k.title) } icon: { Image(systemName: k.symbol).foregroundStyle(k.color) }
                        .badge(n)
                        .tag(SidebarItem.kind(k))
                }
            }
            let repos = Dictionary(grouping: visible, by: \.repoPath)
            if !repos.isEmpty {
                Section("Repositories") {
                    ForEach(repos.keys.sorted(), id: \.self) { path in
                        Label((path as NSString).lastPathComponent, systemImage: "folder")
                            .badge(repos[path]?.count ?? 0)
                            .tag(SidebarItem.repo(path))
                            .help(path.tildePath)
                    }
                }
            }
            Section {
                Label("Snoozed & muted", systemImage: "moon.zzz")
                    .badge(state.hiddenAlerts.count)
                    .tag(SidebarItem.hidden)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.trackedForScan.count) repos tracked")
                if let t = state.lastScan {
                    Text("Scanned \(t.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

// MARK: Alert list

struct AlertListView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings

    private var filtered: [RepoAlert] {
        switch state.sidebar ?? .all {
        case .all: state.visibleAlerts
        case .kind(let k): state.visibleAlerts.filter { $0.kind == k }
        case .repo(let p): state.visibleAlerts.filter { $0.repoPath == p }
        case .hidden: state.hiddenAlerts
        }
    }

    private var heading: String {
        switch state.sidebar ?? .all {
        case .all: "All alerts"
        case .kind(let k): k.title
        case .repo(let p): (p as NSString).lastPathComponent
        case .hidden: "Snoozed & muted"
        }
    }

    var body: some View {
        @Bindable var state = state
        Group {
            if state.settings.trackedRepos.isEmpty {
                ContentUnavailableView {
                    Label("No repositories tracked", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Choose which repositories Don't Git Stranded should watch.")
                } actions: {
                    Button("Choose repositories…") { openSettings() }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView {
                    Label(state.sidebar == .hidden ? "Nothing snoozed" : "All clear",
                          systemImage: state.sidebar == .hidden ? "moon.zzz" : "checkmark.shield")
                } description: {
                    Text(state.sidebar == .hidden ? "Snoozed and muted alerts show up here."
                                                  : "No work at risk in your tracked repositories.")
                }
            } else {
                List(selection: $state.selectedAlertID) {
                    ForEach(filtered) { a in
                        AlertRow(alert: a).tag(a.id)
                    }
                }
            }
        }
        .navigationTitle(heading)
        .toolbar {
            ToolbarItemGroup {
                if state.isScanning {
                    ProgressView().controlSize(.small)
                }
                Menu {
                    Button("Scan now") { Task { await state.scan() } }
                    Button("Fetch from remotes, then scan") { Task { await state.scan(forceFetch: true) } }
                    Divider()
                    Button("Rediscover repositories") { Task { await state.discover(); await state.scan() } }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                } primaryAction: {
                    Task { await state.scan() }
                }
                .disabled(state.isScanning)
                .help("Scan now (click and hold for more)")
            }
        }
    }
}

struct AlertRow: View {
    @Environment(AppState.self) private var state
    let alert: RepoAlert

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: alert.kind.symbol)
                .foregroundStyle(alert.kind.color)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(alert.repoName).font(.body.weight(.semibold))
                    if alert.repoKind == .worktree {
                        Text("worktree").font(.caption2).padding(.horizontal, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(alert.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatAge(alert.age)).font(.callout.monospacedDigit())
                if state.settings.muted.contains(alert.id) {
                    Image(systemName: "bell.slash").foregroundStyle(.secondary).font(.caption)
                } else if state.settings.snoozed[alert.id] != nil {
                    Image(systemName: "moon.zzz").foregroundStyle(.secondary).font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu { AlertUtilityMenu(alert: alert) }
    }
}

/// Snooze / mute / open-in items shared by the context menu and the detail pane.
struct AlertUtilityMenu: View {
    @Environment(AppState.self) private var state
    let alert: RepoAlert

    var body: some View {
        if state.isHidden(alert) {
            Button("Unsnooze / unmute") { state.unhide(alert) }
        } else {
            Menu("Snooze") { SnoozeItems(alert: alert) }
            Button("Mute this alert") { state.mute(alert) }
        }
        Divider()
        Button("Open in Terminal") { state.openInTerminal(alert.repoPath) }
        Button("Open in \(state.editorName)") { state.openInEditor(alert.repoPath) }
        Button("Reveal in Finder") { state.reveal(alert.repoPath) }
        Button("Copy path") { state.copy(alert.repoPath) }
    }
}

struct SnoozeItems: View {
    @Environment(AppState.self) private var state
    let alert: RepoAlert
    var body: some View {
        Button("1 hour") { state.snooze(alert, hours: 1) }
        Button("4 hours") { state.snooze(alert, hours: 4) }
        Button("1 day") { state.snooze(alert, hours: 24) }
        Button("1 week") { state.snooze(alert, hours: 24 * 7) }
    }
}

// MARK: Onboarding

struct OnboardingView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 40)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Don't Git Stranded").font(.largeTitle.bold())
                    Text("Don't Git Stranded watches your repositories for work that exists only on this Mac: unpushed commits, unpublished branches, repos with no remote, old uncommitted changes and forgotten stashes.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Pick your code folder, then turn on the repositories you want watched.")
                .font(.headline)
            RepoPickerView()
            HStack {
                Text("You can change this any time in Settings.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Start watching \(state.settings.trackedRepos.count) repo\(state.settings.trackedRepos.count == 1 ? "" : "s")") {
                    state.settings.onboarded = true
                    Task { await state.scan() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.settings.trackedRepos.isEmpty)
            }
        }
        .padding(28)
    }
}
