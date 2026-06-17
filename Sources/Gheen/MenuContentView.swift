import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var settings: SettingsStore
    @State private var showSettings = false
    @State private var filterPR = false

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
                if !monitor.activeRuns.isEmpty || !monitor.recentRuns.isEmpty {
                    Picker("", selection: $filterPR) {
                        Text("All").tag(false)
                        Text("PRs").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)
                }
            }

            if let banner = monitor.errorBanner {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if settings.watchedRepos.isEmpty {
                Text("Add a repo in Settings to start watching.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                runSections
            }

            Divider()

            HStack {
                Button("Settings") { showSettings = true }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
    }

    private var filteredActive: [Run] {
        filterPR ? monitor.activeRuns.filter(\.isPR) : monitor.activeRuns
    }

    private var filteredRecent: [Run] {
        filterPR ? monitor.recentRuns.filter(\.isPR) : monitor.recentRuns
    }

    @ViewBuilder
    private var runSections: some View {
        if filteredActive.isEmpty && filteredRecent.isEmpty {
            Text(filterPR ? "No PR runs yet." : "No runs you triggered yet.")
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
        }

        if !filteredActive.isEmpty {
            section("In progress", runs: filteredActive)
        }
        if !filteredRecent.isEmpty {
            section("Recently finished", runs: filteredRecent)
        }
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
                    Text(run.workflowName).font(.callout).fontWeight(.medium)
                    Text("\(run.repo) · \(run.headBranch) · \(run.eventLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
