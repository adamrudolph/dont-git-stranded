import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let n = state.visibleAlerts.count
        HStack(spacing: 3) {
            Image(systemName: n > 0 ? "exclamationmark.shield.fill" : "checkmark.shield")
            if n > 0 { Text("\(n)") }
        }
        .task {
            state.openWindowAction = openWindow
            if !state.settings.onboarded { state.showMain() }
        }
    }
}

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private let maxRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            content
            if let b = state.banner {
                BannerView(banner: b).padding(8)
            }
            Divider()
            footer.padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: 380)
        .onAppear { state.openWindowAction = openWindow }
    }

    private var header: some View {
        HStack(spacing: 10) {
            let n = state.visibleAlerts.count
            Image(systemName: n > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                .font(.title2)
                .foregroundStyle(n > 0 ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Don't Git Stranded").font(.headline)
                Text(state.summaryLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.isScanning || state.busyAction != nil {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await state.scan() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Scan now")
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !state.settings.onboarded || state.settings.trackedRepos.isEmpty {
            VStack(spacing: 8) {
                Text("No repositories tracked yet").font(.callout)
                Button("Choose repositories…") { state.showMain() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        } else if state.visibleAlerts.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle").font(.title).foregroundStyle(.green)
                Text("Nothing at risk").font(.callout)
                if let t = state.lastScan {
                    Text("Last scan \(t.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        } else {
            // No ScrollView: inside a menu bar panel it collapses to zero height. maxRows rows always fit.
            VStack(spacing: 2) {
                ForEach(state.visibleAlerts.prefix(maxRows)) { a in
                    MenuAlertRow(alert: a)
                }
            }
            .padding(6)
            .fixedSize(horizontal: false, vertical: true)
            if state.visibleAlerts.count > maxRows {
                Button("and \(state.visibleAlerts.count - maxRows) more…") { state.showMain() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Don't Git Stranded") { state.showMain() }
            Spacer()
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Don't Git Stranded")
        }
        .buttonStyle(.borderless)
    }
}

struct MenuAlertRow: View {
    @Environment(AppState.self) private var state
    let alert: RepoAlert
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: alert.kind.symbol)
                .foregroundStyle(alert.kind.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.repoName).font(.callout.weight(.semibold)).lineLimit(1)
                Text(alert.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if hovering, let quick = quickAction {
                Button(quick.0) { Task { await quick.1() } }
                    .controlSize(.small)
                    .disabled(state.busyAction != nil)
            } else {
                Text(formatAge(alert.age)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { state.showMain(selecting: alert.id) }
        .help("Show details")
    }

    /// One-click fix shown on hover, where there is a safe one.
    private var quickAction: (String, () async -> Void)? {
        if case .branch(let d) = alert.detail {
            if alert.kind == .unpushed { return ("Push", { await state.push(alert, d) }) }
            if d.publishRemote != nil { return ("Publish", { await state.push(alert, d) }) }
        }
        return nil
    }
}

struct BannerView: View {
    let banner: Banner
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .red : .green)
            Text(banner.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
