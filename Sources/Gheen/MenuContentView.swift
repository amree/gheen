import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var settings: SettingsStore
    @State private var showSettings = false
    @State private var filterEvent: String = ""

    var body: some View {
        Group {
            if showSettings {
                SettingsView(onClose: { showSettings = false })
            } else {
                mainView
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear {
            monitor.acknowledge()
            Task { await monitor.poll() }
        }
    }

    private var mainView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gheen").font(.headline)
                Spacer()
                if availableEventLabels.count > 1 {
                    Picker("", selection: $filterEvent) {
                        Text("All").tag("")
                        ForEach(availableEventLabels, id: \.self) { label in
                            Text(label).tag(label)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if let banner = monitor.errorBanner {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if settings.watchedRepos.isEmpty {
                    Text("Add a repo in Settings to start watching.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else if filteredActive.isEmpty && filteredRecent.isEmpty {
                    Text(filterEvent.isEmpty ? "No runs you triggered yet." : "No \(filterEvent) runs.")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
                } else {
                    if !filteredActive.isEmpty {
                        section("In progress", runs: filteredActive)
                    }
                    if !filteredRecent.isEmpty {
                        section("Recently finished", runs: filteredRecent)
                    }
                }
            }

            Divider()

            HStack {
                Button("Settings") { showSettings = true }
                if let t = monitor.lastPolledAt {
                    Text("· Updated \(timeAgo(t))")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
    }

    private var availableEventLabels: [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for run in monitor.activeRuns + monitor.recentRuns {
            let label = run.eventLabel
            if seen.insert(label).inserted { labels.append(label) }
        }
        return labels
    }

    private var filteredActive: [Run] {
        filterEvent.isEmpty ? monitor.activeRuns
            : monitor.activeRuns.filter { $0.eventLabel == filterEvent }
    }

    private var filteredRecent: [Run] {
        filterEvent.isEmpty ? monitor.recentRuns
            : monitor.recentRuns.filter { $0.eventLabel == filterEvent }
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60    { return "just now" }
        if s < 3600  { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }

    private func section(_ title: String, runs: [Run]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(runs) { run in
                RunRow(run: run)
            }
        }
    }
}

private struct RunRow: View {
    let run: Run
    @EnvironmentObject var monitor: Monitor

    private var dotColor: Color {
        if run.isActive { return .yellow }
        switch run.conclusion {
        case "success":                                  return .green
        case "failure", "timed_out", "startup_failure": return .red
        default:                                         return .secondary
        }
    }

    var body: some View {
        Button {
            if let url = URL(string: run.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: run.isActive ? "circle.dotted" : "circle.fill")
                    .foregroundStyle(dotColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.isPR ? run.headBranch : run.workflowName)
                        .font(.callout).fontWeight(.medium)
                    Text(run.isPR
                        ? "\(run.repoName) · \(run.workflowName)"
                        : "\(run.repoName) · \(run.headBranch) · \(run.eventLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(run.timeAgo)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(run.isPR ? run.displayTitle : "")
        .contextMenu {
            if run.isCompleted {
                Button("Open in Browser") {
                    if let url = URL(string: run.url) { NSWorkspace.shared.open(url) }
                }
                Divider()
                if run.isFailure {
                    Button("Rerun Failed Jobs") { monitor.rerun(run, failedOnly: true) }
                }
                Button("Rerun All Jobs") { monitor.rerun(run) }
            }
        }
    }
}
