import SwiftUI

enum AlertKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case noRemote = "NO-REMOTE"
    case unpublished = "UNPUBLISHED"
    case unpushed = "UNPUSHED"
    case stash = "STASH"
    case stale = "STALE"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noRemote: "No remote"
        case .unpublished: "Unpublished branch"
        case .unpushed: "Unpushed commits"
        case .stash: "Old stashes"
        case .stale: "Stale changes"
        }
    }

    var symbol: String {
        switch self {
        case .noRemote: "externaldrive.badge.xmark"
        case .unpublished: "icloud.slash"
        case .unpushed: "arrow.up.circle.fill"
        case .stash: "tray.full.fill"
        case .stale: "clock.badge.exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .noRemote: .red
        case .unpublished: .pink
        case .unpushed: .orange
        case .stash: .purple
        case .stale: .yellow
        }
    }

    var explanation: String {
        switch self {
        case .noRemote:
            "This repository has no remote, so none of its history is backed up anywhere. A lost or wiped disk loses all of it."
        case .unpublished:
            "These commits exist only on this Mac. The branch has never been pushed, or the branch it tracked was deleted on the remote."
        case .unpushed:
            "This branch has commits its upstream doesn't have yet. Until you push, they exist only on this Mac."
        case .stash:
            "Stashes are never pushed, and they're easy to forget. Old ones often hold work you meant to come back to."
        case .stale:
            "Uncommitted and untracked files have been sitting here past your threshold. They're not in git at all yet."
        }
    }

    /// What the threshold means for this kind, for the settings UI.
    var thresholdLabel: String? {
        switch self {
        case .noRemote: nil
        case .unpublished, .unpushed: "Alert when the oldest unpushed commit is older than"
        case .stash: "Alert when a stash is older than"
        case .stale: "Alert when the oldest uncommitted change is older than"
        }
    }

    var defaultThresholdHours: Double {
        switch self {
        case .noRemote: 0
        case .unpublished, .unpushed: 2
        case .stash, .stale: 24
        }
    }
}

enum RepoKind: String, Codable, Hashable { case standard, worktree, submodule }

struct DiscoveredRepo: Identifiable, Hashable {
    let path: String
    let kind: RepoKind
    /// For worktrees: the main checkout's path.
    let mainRepoPath: String?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct CommitInfo: Hashable {
    let sha: String
    let shortSHA: String
    let date: Date
    let author: String
    let subject: String
}

struct FileChange: Hashable {
    let status: String
    let path: String
    let modified: Date?
}

struct StashInfo: Hashable {
    let sha: String
    let ref: String
    let date: Date
    let message: String
    let overThreshold: Bool
}

struct BranchDetail: Hashable {
    let branch: String
    let upstream: String?          // e.g. origin/main
    let upstreamRemote: String?    // e.g. origin
    let upstreamRemoteRef: String? // e.g. refs/heads/main
    let upstreamGone: Bool
    let commits: [CommitInfo]      // newest first, capped
    let totalCount: Int
    let remotes: [String]
    let remoteWebURL: URL?

    /// Remote to publish to when there's no live upstream.
    var publishRemote: String? {
        if let r = upstreamRemote, remotes.contains(r) { return r }
        return remotes.contains("origin") ? "origin" : remotes.first
    }
}

struct UncommittedDetail: Hashable {
    let files: [FileChange]   // capped
    let totalCount: Int
    let oldest: Date
    let newest: Date
    let ageIsEstimate: Bool
    let hasUpstream: Bool
}

struct NoRemoteDetail: Hashable {
    let currentBranch: String?
    let commitCount: Int
    let branchCount: Int
}

enum AlertDetail: Hashable {
    case branch(BranchDetail)
    case noRemote(NoRemoteDetail)
    case uncommitted(UncommittedDetail)
    case stashes([StashInfo])
}

struct RepoAlert: Identifiable, Hashable {
    let id: String
    let kind: AlertKind
    let repoPath: String
    let repoKind: RepoKind
    let title: String
    let since: Date
    let detail: AlertDetail

    var repoName: String { (repoPath as NSString).lastPathComponent }
    var age: TimeInterval { Date().timeIntervalSince(since) }
}

enum SidebarItem: Hashable {
    case all
    case kind(AlertKind)
    case repo(String)
    case hidden
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}
