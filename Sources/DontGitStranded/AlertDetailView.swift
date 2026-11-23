import SwiftUI

struct AlertDetailView: View {
    @Environment(AppState.self) private var state
    let alert: RepoAlert

    @State private var showCommit = false
    @State private var showAddRemote = false
    @State private var stashForBranch: StashInfo?
    @State private var stashToDrop: StashInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if state.isHidden(alert) { hiddenNotice }
                actions
                GroupBox {
                    Text(alert.kind.explanation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Label("Why this matters", systemImage: "info.circle")
                }
                details
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle(alert.repoName)
        .sheet(isPresented: $showCommit) { CommitSheet(alert: alert) }
        .sheet(isPresented: $showAddRemote) { AddRemoteSheet(alert: alert) }
        .sheet(item: $stashForBranch) { s in StashBranchSheet(alert: alert, stash: s) }
        .confirmationDialog("Drop \(stashToDrop?.ref ?? "stash")?",
                            isPresented: Binding(get: { stashToDrop != nil }, set: { if !$0 { stashToDrop = nil } }),
                            presenting: stashToDrop) { s in
            Button("Drop stash", role: .destructive) { Task { await state.dropStash(alert, s) } }
        } message: { s in
            Text("“\(s.message)” will be deleted. It can only be recovered with git fsck until git garbage-collects it.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(alert.kind.title, systemImage: alert.kind.symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(alert.kind.color)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(alert.kind.color.opacity(0.15), in: Capsule())
                if alert.repoKind == .worktree {
                    Text("worktree").font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(formatAge(alert.age)).font(.title3.monospacedDigit().weight(.semibold))
                    Text("since \(alert.since.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(alert.title).font(.title2.bold()).textSelection(.enabled)
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(alert.repoPath.tildePath).font(.callout.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var hiddenNotice: some View {
        HStack {
            Image(systemName: state.settings.muted.contains(alert.id) ? "bell.slash" : "moon.zzz")
            if let until = state.settings.snoozed[alert.id], !state.settings.muted.contains(alert.id) {
                Text("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("Muted. You won't be notified about this alert.")
            }
            Spacer()
            Button("Turn back on") { state.unhide(alert) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Actions (CTAs)

    private var busy: Bool { state.busyAction != nil }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                primaryActions
                if let label = state.busyAction {
                    ProgressView().controlSize(.small)
                    Text(label + "…").font(.callout).foregroundStyle(.secondary)
                }
            }
            .controlSize(.large)
            .disabled(busy)

            HStack(spacing: 8) {
                Button { state.openInTerminal(alert.repoPath) } label: { Label("Terminal", systemImage: "terminal") }
                Button { state.openInEditor(alert.repoPath) } label: { Label(state.editorName, systemImage: "chevron.left.forwardslash.chevron.right") }
                Button { state.reveal(alert.repoPath) } label: { Label("Finder", systemImage: "folder") }
                if case .branch(let d) = alert.detail, let url = d.remoteWebURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Remote", systemImage: "safari") }
                        .help(url.absoluteString)
                }
                Spacer()
                if !state.isHidden(alert) {
                    Menu { SnoozeItems(alert: alert) } label: { Label("Snooze", systemImage: "moon.zzz") }
                        .fixedSize()
                    Button { state.mute(alert) } label: { Label("Mute", systemImage: "bell.slash") }
                }
            }
            .controlSize(.regular)
        }
    }

    @ViewBuilder private var primaryActions: some View {
        switch alert.detail {
        case .branch(let d):
            if alert.kind == .unpushed, let up = d.upstream {
                Button { Task { await state.push(alert, d) } } label: {
                    Label("Push \(d.branch) to \(up)", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            } else if let remote = d.publishRemote {
                Button { Task { await state.push(alert, d) } } label: {
                    Label("Publish \(d.branch) to \(remote)", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        case .noRemote:
            Button { showAddRemote = true } label: { Label("Add remote…", systemImage: "link.badge.plus") }
                .buttonStyle(.borderedProminent)
        case .uncommitted:
            Button { showCommit = true } label: { Label("Commit all changes…", systemImage: "checkmark.circle") }
                .buttonStyle(.borderedProminent)
        case .stashes(let list):
            if let oldest = list.filter(\.overThreshold).max(by: { $0.date < $1.date }) ?? list.first {
                Button { stashForBranch = oldest } label: {
                    Label("Save \(oldest.ref) as a branch…", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Details

    @ViewBuilder private var details: some View {
        switch alert.detail {
        case .branch(let d): branchDetails(d)
        case .noRemote(let d): noRemoteDetails(d)
        case .uncommitted(let d): uncommittedDetails(d)
        case .stashes(let list): stashDetails(list)
        }
    }

    private func branchDetails(_ d: BranchDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Branch").foregroundStyle(.secondary); Text(d.branch).monospaced() }
                GridRow {
                    Text("Upstream").foregroundStyle(.secondary)
                    if let up = d.upstream {
                        Text(d.upstreamGone ? "\(up) (deleted on remote)" : up).monospaced()
                    } else {
                        Text("none").foregroundStyle(.secondary)
                    }
                }
                GridRow { Text("Remotes").foregroundStyle(.secondary); Text(d.remotes.joined(separator: ", ")).monospaced() }
            }
            .font(.callout)
            sectionTitle("Commits only on this Mac", count: d.totalCount)
            VStack(spacing: 0) {
                ForEach(Array(d.commits.enumerated()), id: \.element.sha) { i, c in
                    HStack(spacing: 10) {
                        Text(c.shortSHA).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(c.subject).lineLimit(1)
                        Spacer()
                        Text(c.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(formatAge(Date().timeIntervalSince(c.date))).font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(i.isMultiple(of: 2) ? Color.primary.opacity(0.04) : .clear)
                    .contextMenu { Button("Copy SHA") { state.copy(c.sha) } }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            moreNote(shown: d.commits.count, total: d.totalCount)
        }
    }

    private func noRemoteDetails(_ d: NoRemoteDetail) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow { Text("Commits").foregroundStyle(.secondary); Text("\(d.commitCount)") }
            GridRow { Text("Branches").foregroundStyle(.secondary); Text("\(d.branchCount)") }
            GridRow { Text("Checked out").foregroundStyle(.secondary); Text(d.currentBranch ?? "detached HEAD").monospaced() }
        }
        .font(.callout)
    }

    private func uncommittedDetails(_ d: UncommittedDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text("Oldest change \(formatAge(Date().timeIntervalSince(d.oldest))) ago")
                Text("Newest \(formatAge(Date().timeIntervalSince(d.newest))) ago")
            }
            .font(.callout).foregroundStyle(.secondary)
            if d.ageIsEstimate {
                Label("Only deleted files: git has no timestamp for deletions, so the age is estimated from the last git operation.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            sectionTitle("Changed files (oldest first)", count: d.totalCount)
            VStack(spacing: 0) {
                ForEach(Array(d.files.enumerated()), id: \.element.path) { i, f in
                    HStack(spacing: 10) {
                        Text(f.status.replacingOccurrences(of: " ", with: "·"))
                            .font(.callout.monospaced())
                            .foregroundStyle(statusColor(f.status))
                            .frame(width: 26, alignment: .leading)
                            .help(statusHelp(f.status))
                        Text(f.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(f.modified.map { formatAge(Date().timeIntervalSince($0)) } ?? "deleted")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(i.isMultiple(of: 2) ? Color.primary.opacity(0.04) : .clear)
                    .contextMenu {
                        let full = (alert.repoPath as NSString).appendingPathComponent(f.path)
                        if f.modified != nil {
                            Button("Open in \(state.editorName)") { state.openInEditor(full) }
                            Button("Reveal in Finder") { state.reveal(full) }
                        }
                        Button("Copy path") { state.copy(full) }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            moreNote(shown: d.files.count, total: d.totalCount)
        }
    }

    private func stashDetails(_ list: [StashInfo]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Stashes", count: list.count)
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.sha) { i, s in
                    HStack(spacing: 10) {
                        Text(s.ref).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(s.message).lineLimit(1)
                        Spacer()
                        Text(formatAge(Date().timeIntervalSince(s.date)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(s.overThreshold ? AnyShapeStyle(AlertKind.stash.color) : AnyShapeStyle(.secondary))
                        Button("Save as branch…") { stashForBranch = s }
                            .controlSize(.small)
                        Button(role: .destructive) { stashToDrop = s } label: { Image(systemName: "trash") }
                            .controlSize(.small)
                            .help("Drop this stash")
                    }
                    .disabled(busy)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(i.isMultiple(of: 2) ? Color.primary.opacity(0.04) : .clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Text("Saving as a branch keeps the stash and gives it a branch you can push. Drop the stash afterwards if you no longer need it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Text("\(count)").font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }

    @ViewBuilder private func moreNote(shown: Int, total: Int) -> some View {
        if total > shown {
            Text("Showing \(shown) of \(total).").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statusColor(_ s: String) -> Color {
        if s == "??" { return .secondary }
        if s.contains("D") { return .red }
        if s.contains("A") { return .green }
        return .orange
    }

    private func statusHelp(_ s: String) -> String {
        if s == "??" { return "Untracked" }
        var parts: [String] = []
        let names: [Character: String] = ["M": "modified", "A": "added", "D": "deleted", "R": "renamed", "C": "copied", "U": "conflict", "T": "type changed"]
        let chars = Array(s)
        if chars.count == 2 {
            if let n = names[chars[0]] { parts.append("\(n) (staged)") }
            if let n = names[chars[1]] { parts.append("\(n) (not staged)") }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: Sheets

struct CommitSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let alert: RepoAlert
    @State private var message = "WIP: save work in progress"
    @State private var push = true

    private var hasUpstream: Bool {
        if case .uncommitted(let d) = alert.detail { return d.hasUpstream }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit all changes in \(alert.repoName)").font(.title3.bold())
            Text("Stages everything, including untracked files (`git add -A`), and commits it on the current branch. Check the file list first if the repo might contain secrets or build output that isn't gitignored.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Commit message", text: $message, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            Toggle("Push after committing", isOn: $push)
                .disabled(!hasUpstream)
            if !hasUpstream {
                Text("This branch has no upstream, so the commit stays local. Don't Git Stranded will then show it as unpublished, with a Publish button.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Commit") {
                    let msg = message.trimmed, doPush = push && hasUpstream
                    dismiss()
                    Task { await state.commitAll(alert, message: msg, push: doPush) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(message.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct AddRemoteSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let alert: RepoAlert
    @State private var name = "origin"
    @State private var url = ""
    @State private var pushAll = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a remote to \(alert.repoName)").font(.title3.bold())
            Text("Create an empty repository on GitHub, GitLab or your own server first, then paste its URL here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name)
                TextField("URL", text: $url, prompt: Text("git@github.com:you/\(alert.repoName).git"))
                Toggle("Push all branches and set upstreams", isOn: $pushAll)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add remote") {
                    let n = name.trimmed, u = url.trimmed, p = pushAll
                    dismiss()
                    Task { await state.addRemote(alert, name: n, url: u, pushAll: p) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!AppState.isValidRemoteName(name.trimmed) || !AppState.isValidRemoteURL(url.trimmed))
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct StashBranchSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let alert: RepoAlert
    let stash: StashInfo
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save \(stash.ref) as a branch").font(.title3.bold())
            Text("“\(stash.message)”").font(.callout).foregroundStyle(.secondary)
            Text("Creates a branch pointing at the stash. Your working tree and the stash are left alone. Don't Git Stranded will then offer to publish the branch.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create branch") {
                    let n = name.trimmed
                    dismiss()
                    Task { await state.branchFromStash(alert, stash, name: n) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmed.isEmpty || name.contains(" "))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            let day = stash.date.formatted(.iso8601.year().month().day())
            name = "stash/\(day)-\(stash.sha.prefix(7))"
        }
    }
}
