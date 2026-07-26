import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var monitor: Monitor
    var onClose: () -> Void

    @State private var newRepo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { monitor.rebuildClient(); onClose() }
            }

            Divider()

            Text("WATCHED REPOSITORIES")
                .font(.caption2).foregroundStyle(.secondary)

            if settings.watchedRepos.isEmpty {
                Text("None yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(settings.watchedRepos, id: \.self) { repo in
                    HStack {
                        Text(repo).font(.callout)
                        Spacer()
                        Button { remove(repo) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                TextField("owner/repo", text: $newRepo)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(!isValid(newRepo))
            }

            Divider()

            HStack {
                Text("Poll interval")
                Spacer()
                Picker("", selection: $settings.pollInterval) {
                    Text("15s").tag(15.0)
                    Text("30s").tag(30.0)
                    Text("60s").tag(60.0)
                    Text("2m").tag(120.0)
                }
                .labelsHidden()
                .frame(width: 80)
                .onChange(of: settings.pollInterval) { _ in
                    monitor.scheduleTimer()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("gh path (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("/opt/homebrew/bin/gh", text: $settings.ghPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { monitor.rebuildClient() }
            }

            Divider()

            Button("Open Command Log", action: openLog)
                .buttonStyle(.borderless)
        }
    }

    /// Opens the gh command log, or reveals its folder if no poll has logged yet.
    private func openLog() {
        guard let url = GitHubClient.logFileURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func isValid(_ s: String) -> Bool {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: "/")
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    private func add() {
        let repo = newRepo.trimmingCharacters(in: .whitespaces)
        guard isValid(repo), !settings.watchedRepos.contains(repo) else { return }
        settings.watchedRepos.append(repo)
        newRepo = ""
        Task { await monitor.poll() }
    }

    private func remove(_ repo: String) {
        settings.watchedRepos.removeAll { $0 == repo }
        monitor.forgetRepo(repo)
        Task { await monitor.poll() }
    }
}
