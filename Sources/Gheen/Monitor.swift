import Foundation
import Combine

enum Aggregate {
    case idle, active, failure
}

/// Polls watched repos, diffs run state, fires notifications, and publishes
/// UI state. All published mutation happens on the main actor.
@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var activeRuns: [Run] = []
    @Published private(set) var recentRuns: [Run] = []
    @Published private(set) var aggregate: Aggregate = .idle
    @Published private(set) var errorBanner: String?
    @Published private(set) var login: String?

    private let settings: SettingsStore
    private let notifier: NotificationManager
    private var client: GitHubClient

    private var timer: Timer?
    private var isPolling = false
    private var didBaseline = false
    private var seenActiveKeys: Set<String> = []
    private var prevPollStartedAt: Date?
    private var hasUnackedFailure = false

    nonisolated init(settings: SettingsStore, notifier: NotificationManager) {
        self.settings = settings
        self.notifier = notifier
        self.client = GitHubClient(
            overridePath: settings.ghPath.isEmpty ? nil : settings.ghPath)
    }

    var iconName: String {
        switch aggregate {
        case .active:  return "arrow.triangle.2.circlepath"
        case .failure: return "xmark.circle.fill"
        case .idle:    return "circle.dotted"
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
        let timer = Timer(timeInterval: settings.pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Recreate the gh client (e.g. after the user edits the gh-path override).
    func rebuildClient() {
        client = GitHubClient(overridePath: settings.ghPath.isEmpty ? nil : settings.ghPath)
        login = settings.cachedLogin
    }

    /// Called when the dropdown opens — clears the red failure state.
    func acknowledge() {
        if hasUnackedFailure {
            hasUnackedFailure = false
            recomputeAggregate()
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
            prevPollStartedAt = pollStart
            return
        }

        var allRuns: [Run] = []
        var firstError: Error?
        await withTaskGroup(of: Result<[Run], Error>.self) { group in
            for repo in repos {
                group.addTask { [client] in
                    do { return .success(try await client.listRuns(repo: repo, user: user)) }
                    catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case .success(let runs): allRuns.append(contentsOf: runs)
                case .failure(let error): if firstError == nil { firstError = error }
                }
            }
        }

        // All repos failed → surface the error, keep last good state.
        if allRuns.isEmpty, let error = firstError {
            setError(error)
            prevPollStartedAt = pollStart
            return
        }
        // Partial failure → show a banner but still process what we got.
        errorBanner = firstError.map(message(for:))

        process(allRuns, pollStart: pollStart)
        prevPollStartedAt = pollStart
    }

    private func process(_ runs: [Run], pollStart: Date) {
        let active = runs.filter { $0.isActive }
            .sorted { $0.updatedAt > $1.updatedAt }
        let finished = runs.filter { $0.isCompleted }
            .sorted { $0.updatedAt > $1.updatedAt }

        if !didBaseline {
            // First poll: record everything currently finished so we never
            // notify for runs that completed before the app started watching.
            didBaseline = true
            var notified = settings.notifiedKeys
            for run in finished { notified.insert(run.runKey) }
            settings.notifiedKeys = prune(notified)
        } else {
            var notified = settings.notifiedKeys
            let cursor = prevPollStartedAt ?? pollStart
            for run in finished {
                let key = run.runKey
                if notified.contains(key) { continue }
                let wasActive = seenActiveKeys.contains(key)
                // Notify on the normal transition OR for a short run that
                // started+finished between two polls (updatedAt at/after cursor).
                if wasActive || run.updatedAt >= cursor {
                    notifier.notify(
                        title: notificationTitle(run),
                        body: notificationBody(run),
                        url: run.url)
                    notified.insert(key)
                    if run.isFailure { hasUnackedFailure = true }
                }
            }
            settings.notifiedKeys = prune(notified)
        }

        seenActiveKeys = Set(active.map { $0.runKey })
        activeRuns = active
        recentRuns = Array(finished.prefix(10))
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
