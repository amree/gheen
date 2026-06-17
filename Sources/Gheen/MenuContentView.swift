import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var settings: SettingsStore
    @State private var showSettings = false

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
                if !monitor.activeRuns.isEmpty {
                    Text("\(monitor.activeRuns.count) running")
                        .font(.caption).foregroundStyle(.secondary)
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

    @ViewBuilder
    private var runSections: some View {
        if monitor.activeRuns.isEmpty && monitor.recentRuns.isEmpty {
            Text("No runs you triggered yet.")
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
        }

        if !monitor.activeRuns.isEmpty {
            section("In progress", runs: monitor.activeRuns)
        }
        if !monitor.recentRuns.isEmpty {
            section("Recently finished", runs: monitor.recentRuns)
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

    var body: some View {
        Button {
            if let url = URL(string: run.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(run.rowSymbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.workflowName).font(.callout).fontWeight(.medium)
                    Text("\(run.repo) · \(run.headBranch)")
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
