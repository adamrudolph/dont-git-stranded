import SwiftUI
import ServiceManagement

extension AppState {
    // MARK: Git actions (CTAs)

    /// Runs git steps in order, stops on the first failure, reports, then rescans.
    @discardableResult
    func runGit(_ label: String, in repo: String, _ steps: [[String]]) async -> Bool {
        busyAction = label
        let outcome: (Bool, String) = await Task.detached(priority: .userInitiated) {
            for step in steps {
                let r = Git.run(repo, step, timeout: 180)
                if !r.ok { return (false, r.message) }
            }
            return (true, "")
        }.value
        busyAction = nil
        if outcome.0 {
            flash("\(label): done")
        } else {
            flash("\(label) failed: \(outcome.1.isEmpty ? "git exited with an error" : outcome.1)", error: true)
        }
        await scan()
        return outcome.0
    }

    func push(_ a: RepoAlert, _ d: BranchDetail) async {
        if a.kind == .unpushed, let remote = d.upstreamRemote, let ref = d.upstreamRemoteRef {
            await runGit("Push \(d.branch)", in: a.repoPath, [["push", remote, "refs/heads/\(d.branch):\(ref)"]])
        } else if let remote = d.publishRemote {
            await runGit("Publish \(d.branch) to \(remote)", in: a.repoPath, [["push", "-u", remote, "refs/heads/\(d.branch):refs/heads/\(d.branch)"]])
        }
    }

    func commitAll(_ a: RepoAlert, message: String, push: Bool) async {
        var steps = [["add", "-A"], ["commit", "-m", message]]
        if push { steps.append(["push"]) }
        await runGit(push ? "Commit & push" : "Commit", in: a.repoPath, steps)
    }

    /// Remote names end up as command-line arguments (`git push -u <name>`), so one starting with "-"
    /// would be read as an option. Allow only what a remote name normally looks like.
    nonisolated static func isValidRemoteName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && name.count <= 100
            && name.allSatisfy { $0.isLetter || $0.isNumber || "._-/".contains($0) }
            && !name.contains("..") && !name.hasSuffix("/") && !name.hasSuffix(".lock")
    }

    nonisolated static func isValidRemoteURL(_ url: String) -> Bool {
        !url.isEmpty && !url.hasPrefix("-") && !url.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    func addRemote(_ a: RepoAlert, name: String, url: String, pushAll: Bool) async {
        guard Self.isValidRemoteName(name), Self.isValidRemoteURL(url) else {
            flash("That remote name or URL isn't valid.", error: true)
            return
        }
        var steps = [["remote", "add", name, url]]
        if pushAll { steps.append(["push", "-u", name, "--all"]) }
        await runGit("Add remote \(name)", in: a.repoPath, steps)
    }

    func branchFromStash(_ a: RepoAlert, _ s: StashInfo, name: String) async {
        let check = Git.run(a.repoPath, ["check-ref-format", "--branch", name])
        guard check.ok, !name.hasPrefix("-") else {
            flash("“\(name)” isn't a valid branch name.", error: true)
            return
        }
        await runGit("Create branch \(name)", in: a.repoPath, [["branch", name, s.sha]])
    }

    func dropStash(_ a: RepoAlert, _ s: StashInfo) async {
        // stash@{n} shifts when stashes change; make sure it still points at the stash we showed.
        let current = Git.run(a.repoPath, ["rev-parse", s.ref]).out.trimmed
        guard current == s.sha else {
            flash("Stashes changed since the last scan. Rescanning; try again.", error: true)
            await scan()
            return
        }
        await runGit("Drop \(s.ref)", in: a.repoPath, [["stash", "drop", s.ref]])
    }

    // MARK: Opening things

    func openInTerminal(_ path: String) {
        let app = settings.terminalAppPath.map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        guard let app else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    var editorAppURL: URL? {
        if let p = settings.editorAppPath { return URL(fileURLWithPath: p) }
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4"] {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u }
        }
        return nil
    }

    var editorName: String {
        editorAppURL.map { $0.deletingPathExtension().lastPathComponent } ?? "Editor"
    }

    func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if let app = editorAppURL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied")
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                flash("Couldn't change login item: \(error.localizedDescription)", error: true)
            }
        }
    }
}
