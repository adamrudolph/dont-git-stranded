import SwiftUI
import UniformTypeIdentifiers

extension StashInfo: Identifiable { var id: String { sha } }

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            RepoPickerView()
                .padding(20)
                .tabItem { Label("Repositories", systemImage: "folder") }
            AlertSettings()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
        }
        .frame(width: 680, height: 560)
        .onAppear { state.windowOpened() }
        .onDisappear { state.windowClosed() }
    }
}

// MARK: General

struct GeneralSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Code folder") {
                FolderRow()
            }
            Section("Scanning") {
                Picker("Scan every", selection: $state.settings.scanIntervalMinutes) {
                    ForEach([5, 15, 30, 60, 180, 720], id: \.self) { m in
                        Text(m < 60 ? "\(m) minutes" : m == 60 ? "hour" : "\(m / 60) hours").tag(m)
                    }
                }
                Toggle(isOn: $state.settings.fetchBeforeScan) {
                    Text("Fetch from remotes before each scan")
                    Text("Slower and uses the network, but avoids false alerts for branches you pushed from another machine.")
                }
            }
            Section("Notifications") {
                Toggle("Show notifications for new alerts", isOn: $state.settings.notificationsEnabled)
                Picker("Remind me again", selection: $state.settings.renotifyHours) {
                    Text("Never, notify once").tag(0.0)
                    Text("Every 4 hours").tag(4.0)
                    Text("Every day").tag(24.0)
                    Text("Every week").tag(168.0)
                }
                .disabled(!state.settings.notificationsEnabled)
                if !Notifier.available {
                    Text("Notifications only work when Don't Git Stranded runs as an app bundle (scripts/build-app.sh).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Apps") {
                AppPickerRow(title: "Terminal", path: $state.settings.terminalAppPath, fallback: "Terminal")
                AppPickerRow(title: "Editor", path: $state.settings.editorAppPath, fallback: state.editorName)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

struct FolderRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack {
            Image(systemName: "folder.fill").foregroundStyle(.blue)
            Text(state.settings.rootPath.tildePath).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Choose…") { choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: state.settings.rootPath)
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder that contains your git repositories."
        if panel.runModal() == .OK, let url = panel.url {
            state.settings.rootPath = url.path
        }
    }
}

struct AppPickerRow: View {
    let title: String
    @Binding var path: String?
    let fallback: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(path.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") } ?? "\(fallback) (default)")
                    .foregroundStyle(path == nil ? .secondary : .primary)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
                if path != nil { Button("Reset") { path = nil } }
            }
        }
    }
}

// MARK: Alerts

struct AlertSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section {
                Text("Each check alerts only once its threshold has passed, so work you're in the middle of isn't flagged.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(AlertKind.allCases) { kind in
                Section {
                    Toggle(isOn: Binding(
                        get: { state.settings.enabledKinds.contains(kind) },
                        set: { on in
                            if on { state.settings.enabledKinds.insert(kind) } else { state.settings.enabledKinds.remove(kind) }
                        })) {
                        Label { Text(kind.title).font(.headline) } icon: {
                            Image(systemName: kind.symbol).foregroundStyle(kind.color)
                        }
                        Text(kind.explanation)
                    }
                    if let label = kind.thresholdLabel {
                        ThresholdRow(kind: kind, label: label)
                            .disabled(!state.settings.enabledKinds.contains(kind))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ThresholdRow: View {
    @Environment(AppState.self) private var state
    let kind: AlertKind
    let label: String

    private let presets: [Double] = [0, 1, 2, 4, 8, 24, 48, 72, 168, 336]

    var body: some View {
        let binding = Binding(get: { state.settings.threshold(kind) }, set: { state.settings.setThreshold(kind, $0) })
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", value: binding, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Text("hours").foregroundStyle(.secondary)
                Menu {
                    ForEach(presets, id: \.self) { h in Button(formatHours(h)) { binding.wrappedValue = h } }
                } label: { Image(systemName: "chevron.up.chevron.down") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
        }
    }
}

// MARK: Repositories (also used in onboarding)

struct RepoPickerView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var excludesText = ""

    private var mains: [DiscoveredRepo] {
        state.discovered.filter { $0.kind != .worktree || $0.mainRepoPath.map { m in !state.discovered.contains { $0.path == m } } ?? true }
            .filter { r in
                search.isEmpty || r.path.localizedCaseInsensitiveContains(search)
                    || worktrees(of: r).contains { $0.path.localizedCaseInsensitiveContains(search) }
            }
    }

    private func worktrees(of repo: DiscoveredRepo) -> [DiscoveredRepo] {
        state.discovered.filter { $0.kind == .worktree && $0.mainRepoPath == repo.path }
    }

    private var missing: [String] {
        let found = Set(state.discovered.map(\.path))
        return state.settings.trackedRepos.filter { !found.contains($0) }.sorted()
    }

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    FolderRow()
                    HStack(spacing: 20) {
                        Toggle("Exclude worktrees", isOn: $state.settings.excludeWorktrees)
                            .help("Linked worktrees share branches with their main repo. When included, a new worktree of a tracked repo is tracked automatically.")
                        Toggle("Auto-track new repos", isOn: $state.settings.autoTrackNewRepos)
                            .help("Repos that appear in the code folder later are tracked without asking.")
                        Spacer()
                        Stepper("Depth \(state.settings.maxDepth)", value: $state.settings.maxDepth, in: 1...8)
                            .help("How many folder levels below the code folder to search")
                    }
                    HStack {
                        Text("Skip folders named").foregroundStyle(.secondary)
                        TextField("node_modules, build", text: $excludesText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commitExcludes)
                        Button("Apply", action: commitExcludes)
                            .disabled(parsedExcludes == state.settings.excludes)
                    }
                }
                .padding(4)
            }

            HStack {
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                if state.isDiscovering { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(state.settings.trackedRepos.count) of \(state.discovered.count) tracked")
                    .font(.callout).foregroundStyle(.secondary)
                Button("All") { state.settings.trackedRepos.formUnion(visiblePaths) }
                Button("None") { state.settings.trackedRepos.subtract(visiblePaths) }
                Button { Task { await state.discover() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Search the code folder again")
            }

            List {
                if state.discovered.isEmpty && !state.isDiscovering {
                    Text("No git repositories found in \(state.settings.rootPath.tildePath). Choose another folder or increase the depth.")
                        .foregroundStyle(.secondary)
                }
                ForEach(mains) { repo in
                    RepoToggleRow(repo: repo, root: state.settings.rootPath)
                    ForEach(worktrees(of: repo)) { wt in
                        RepoToggleRow(repo: wt, root: state.settings.rootPath).padding(.leading, 24)
                    }
                }
                if !missing.isEmpty {
                    Section("Tracked but not found") {
                        ForEach(missing, id: \.self) { p in
                            HStack {
                                Image(systemName: "questionmark.folder").foregroundStyle(.secondary)
                                Text(p.tildePath).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Stop tracking") { state.setTracked(p, false) }.controlSize(.small)
                            }
                        }
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
        .onAppear {
            excludesText = state.settings.excludes.joined(separator: ", ")
            if state.discovered.isEmpty { Task { await state.discover() } }
        }
    }

    private var visiblePaths: [String] {
        mains.flatMap { [$0.path] + worktrees(of: $0).map(\.path) }
    }

    private var parsedExcludes: [String] {
        excludesText.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    private func commitExcludes() {
        let e = parsedExcludes
        if e != state.settings.excludes { state.settings.excludes = e }
    }
}

struct RepoToggleRow: View {
    @Environment(AppState.self) private var state
    let repo: DiscoveredRepo
    let root: String

    var body: some View {
        Toggle(isOn: Binding(get: { state.settings.trackedRepos.contains(repo.path) },
                             set: { state.setTracked(repo.path, $0) })) {
            HStack(spacing: 8) {
                Image(systemName: repo.kind == .worktree ? "arrow.triangle.branch" : repo.kind == .submodule ? "shippingbox" : "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(repo.name).font(.body.weight(.medium))
                if repo.kind != .standard {
                    Text(repo.kind.rawValue).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(relative).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                let n = state.visibleAlerts.filter { $0.repoPath == repo.path }.count
                if n > 0 {
                    Label("\(n)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private var relative: String {
        repo.path.hasPrefix(root + "/") ? String(repo.path.dropFirst(root.count + 1)) : repo.path.tildePath
    }
}
