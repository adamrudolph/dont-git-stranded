import Foundation

struct AppSettings: Codable, Equatable {
    // Where to look
    var rootPath: String = (NSHomeDirectory() as NSString).appendingPathComponent("code")
    var maxDepth: Int = 3
    var excludes: [String] = ["node_modules", ".venv", "venv", "__pycache__", "Library", ".Trash", "DerivedData"]
    var excludeWorktrees: Bool = true

    // What to track (opt-in)
    var trackedRepos: Set<String> = []
    var knownRepos: Set<String> = []
    var autoTrackNewRepos: Bool = false
    var onboarded: Bool = false

    // Alert rules
    var enabledKinds: Set<AlertKind> = Set(AlertKind.allCases)
    var thresholdHours: [String: Double] = [:]   // keyed by AlertKind.rawValue

    // Scanning & notifications
    var scanIntervalMinutes: Int = 30
    var fetchBeforeScan: Bool = false
    var notificationsEnabled: Bool = true
    var renotifyHours: Double = 24   // 0 = notify once per alert

    // Apps
    var terminalAppPath: String?
    var editorAppPath: String?

    // Per-alert state
    var snoozed: [String: Date] = [:]
    var muted: Set<String> = []

    init() {}

    func threshold(_ kind: AlertKind) -> Double { thresholdHours[kind.rawValue] ?? kind.defaultThresholdHours }
    mutating func setThreshold(_ kind: AlertKind, _ hours: Double) { thresholdHours[kind.rawValue] = max(0, hours) }

    // Tolerant decoding: missing keys fall back to defaults so new settings never wipe old ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        rootPath = v(.rootPath, d.rootPath)
        maxDepth = v(.maxDepth, d.maxDepth)
        excludes = v(.excludes, d.excludes)
        excludeWorktrees = v(.excludeWorktrees, d.excludeWorktrees)
        trackedRepos = v(.trackedRepos, d.trackedRepos)
        knownRepos = v(.knownRepos, d.knownRepos)
        autoTrackNewRepos = v(.autoTrackNewRepos, d.autoTrackNewRepos)
        onboarded = v(.onboarded, d.onboarded)
        enabledKinds = v(.enabledKinds, d.enabledKinds)
        thresholdHours = v(.thresholdHours, d.thresholdHours)
        scanIntervalMinutes = v(.scanIntervalMinutes, d.scanIntervalMinutes)
        fetchBeforeScan = v(.fetchBeforeScan, d.fetchBeforeScan)
        notificationsEnabled = v(.notificationsEnabled, d.notificationsEnabled)
        renotifyHours = v(.renotifyHours, d.renotifyHours)
        terminalAppPath = v(.terminalAppPath, d.terminalAppPath)
        editorAppPath = v(.editorAppPath, d.editorAppPath)
        snoozed = v(.snoozed, d.snoozed)
        muted = v(.muted, d.muted)
    }

    private static let key = "settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var scanConfig: ScanConfig {
        ScanConfig(enabled: enabledKinds,
                   thresholds: Dictionary(uniqueKeysWithValues: AlertKind.allCases.map { ($0, threshold($0)) }),
                   fetch: fetchBeforeScan)
    }
}

struct ScanConfig {
    var enabled: Set<AlertKind>
    var thresholds: [AlertKind: Double]
    var fetch: Bool

    func passes(_ kind: AlertKind, since: Date, now: Date) -> Bool {
        guard enabled.contains(kind) else { return false }
        return now.timeIntervalSince(since) >= (thresholds[kind] ?? 0) * 3600
    }
}
