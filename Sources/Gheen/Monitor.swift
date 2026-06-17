import Foundation
import Combine

enum Aggregate {
    case idle, active, failure
}

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var activeRuns: [Run] = []
    @Published private(set) var recentRuns: [Run] = []
    @Published private(set) var aggregate: Aggregate = .idle
    @Published private(set) var errorBanner: String?
    @Published private(set) var login: String?
    @Published private(set) var lastPolledAt: Date?

    private let settings: SettingsStore
    private let notifier: NotificationManager
    private var client: GitHubClient

    private var timer: Timer?
    private var isPolling = false
    private var hasUnackedFailure = false
    private var backoffMultiplier: Double = 1.0
    private let maxBackoffInterval: TimeInterval = 600

    // Per-repo state: baseline, active-key set, and poll-start cursor are all
    // scoped to each repo independently. This prevents a failed repo from
    // corrupting the cursor or seenActiveKeys for repos that did succeed, and
    // ensures a repo added after startup gets its own silent baseline pass.
    private struct RepoState {
        var baselined = false
        var seenActiveKeys: Set<String> = []
        var prevPollStartedAt: Date?
    }
    private var repoStates: [String: RepoState] = [:]

    init(settings: SettingsStore, notifier: NotificationManager) {
        self.settings = settings
        self.notifier = notifier
        self.client = GitHubClient(
            overridePath: settings.ghPath.isEmpty ? nil : settings.ghPath)
    }

    var iconName: String {
        switch aggregate {
        case .active:  return "circle.dotted"
        case .failure: return "circle.fill"
        case .idle:    return "circle"
        }
    }

    // MARK: - Lifecycle

    func start() {
        if login == nil { login = settings.cachedLogin }
        Task { await poll() }
        scheduleTimer()
    }

    func scheduleTimer() {
        timer?.invalidate()
        let interval = min(settings.pollInterval * backoffMultiplier, maxBackoffInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func forgetRepo(_ repo: String) {
        repoStates.removeValue(forKey: repo)
    }

    func rerun(_ run: Run, failedOnly: Bool = false) {
        Task {
            do {
                try await client.rerunRun(id: run.databaseId, repo: run.repo, failedOnly: failedOnly)
                await poll()
            } catch {
                errorBanner = message(for: error)
            }
        }
    }

    func rebuildClient() {
        client = GitHubClient(overridePath: settings.ghPath.isEmpty ? nil : settings.ghPath)
        login = settings.cachedLogin
        backoffMultiplier = 1.0
        scheduleTimer()
    }

    /// Called when the dropdown opens — clears red failure state and resets backoff.
    func acknowledge() {
        if hasUnackedFailure {
            hasUnackedFailure = false
            recomputeAggregate()
        }
        if backoffMultiplier != 1.0 {
            backoffMultiplier = 1.0
            scheduleTimer()
        }
    }

    // MARK: - Polling

    func poll() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        let pollStart = Date()

        if login == nil {
            do {
                let resolved = try await client.currentLogin()
                login = resolved
                settings.cachedLogin = resolved
            } catch {
                setError(error)
                return
            }
        }
        guard let user = login else { return }

        let repos = settings.watchedRepos
        guard !repos.isEmpty else {
            activeRuns = []
            recentRuns = []
            errorBanner = nil
            recomputeAggregate()
            return
        }

        var repoResults: [String: [Run]] = [:]
        var repoErrors: [String: Error] = [:]
        // Serial loop — avoids @MainActor + withTaskGroup result-collection issues in Swift 5.
        // With typical repo counts (1-5) the latency difference is negligible.
        for repo in repos {
            do {
                repoResults[repo] = try await client.listRuns(repo: repo, user: user)
            } catch {
                repoErrors[repo] = error
            }
        }

        if repoResults.isEmpty, let error = repoErrors.values.first {
            setError(error)
            return
        }
        errorBanner = repoErrors.isEmpty ? nil
            : "Some repos failed: \(repoErrors.keys.joined(separator: ", "))"

        processRepos(repoResults, pollStart: pollStart)

        let newMultiplier = activeRuns.isEmpty
            ? min(backoffMultiplier * 2, maxBackoffInterval / max(settings.pollInterval, 1))
            : 1.0
        if newMultiplier != backoffMultiplier {
            backoffMultiplier = newMultiplier
            scheduleTimer()
        }
    }

    private struct PendingNotification {
        let title: String
        let body: String
        let url: String
        let isFailure: Bool
    }

    private func processRepos(_ repoResults: [String: [Run]], pollStart: Date) {
        var notified = settings.notifiedKeys
        var allActive: [Run] = []
        var allFinished: [Run] = []
        var pending: [PendingNotification] = []

        for (repo, runs) in repoResults {
            var state = repoStates[repo, default: RepoState()]
            let active = runs.filter { $0.isActive }
            let finished = runs.filter { $0.isCompleted }

            if !state.baselined {
                // First successful poll for this repo — record all finished runs
                // silently so we never notify for pre-existing completions.
                state.baselined = true
                for run in finished { notified.insert(run.runKey) }
            } else {
                let cursor = state.prevPollStartedAt ?? pollStart
                for run in finished {
                    let key = run.runKey
                    if notified.contains(key) { continue }
                    let wasActive = state.seenActiveKeys.contains(key)
                    // Notify on normal active→completed transition OR short run
                    // that started+finished between polls (updatedAt ≥ cursor).
                    if wasActive || run.updatedAt >= cursor {
                        pending.append(PendingNotification(
                            title: notificationTitle(run),
                            body: notificationBody(run),
                            url: run.url,
                            isFailure: run.isFailure))
                        notified.insert(key)
                        if run.isFailure { hasUnackedFailure = true }
                    }
                }
            }

            state.seenActiveKeys = Set(active.map { $0.runKey })
            state.prevPollStartedAt = pollStart
            repoStates[repo] = state

            allActive.append(contentsOf: active)
            allFinished.append(contentsOf: finished)
        }

        // Fire notifications — batch into one summary if multiple completed this poll.
        if pending.count == 1 {
            let n = pending[0]
            notifier.notify(title: n.title, body: n.body, url: n.url)
        } else if pending.count > 1 {
            let failures = pending.filter(\.isFailure).count
            let successes = pending.count - failures
            var parts: [String] = []
            if successes > 0 { parts.append("\(successes) succeeded") }
            if failures > 0 { parts.append("\(failures) failed") }
            let anchor = pending.first(where: \.isFailure) ?? pending[0]
            notifier.notify(
                title: "\(pending.count) workflows finished",
                body: parts.joined(separator: ", "),
                url: anchor.url)
        }

        settings.notifiedKeys = prune(notified)
        activeRuns = allActive.sorted { $0.updatedAt > $1.updatedAt }
        recentRuns = Array(allFinished.sorted { $0.updatedAt > $1.updatedAt }.prefix(10))
        lastPolledAt = Date()
        recomputeAggregate()
    }

    // MARK: - Helpers

    private func recomputeAggregate() {
        if !activeRuns.isEmpty {
            aggregate = .active
        } else if hasUnackedFailure {
            aggregate = .failure
        } else {
            aggregate = .idle
        }
    }

    private func setError(_ error: Error) {
        errorBanner = message(for: error)
    }

    private func message(for error: Error) -> String {
        (error as? GitHubError)?.errorDescription ?? error.localizedDescription
    }

    private func prune(_ keys: Set<String>) -> Set<String> {
        keys.count > 1000 ? Set(Array(keys).suffix(1000)) : keys
    }

    private func notificationTitle(_ run: Run) -> String {
        "\(run.conclusionEmoji) \(run.workflowName)"
    }

    private func notificationBody(_ run: Run) -> String {
        "\(run.repo) · \(run.headBranch)\n\(run.displayTitle)"
    }
}
