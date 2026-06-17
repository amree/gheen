import Foundation
import Combine

/// User-facing settings + small persisted state, backed by UserDefaults.
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var watchedRepos: [String] {
        didSet { defaults.set(watchedRepos, forKey: Keys.repos) }
    }
    @Published var pollInterval: Double {
        didSet { defaults.set(pollInterval, forKey: Keys.interval) }
    }
    @Published var ghPath: String {
        didSet { defaults.set(ghPath, forKey: Keys.ghPath) }
    }

    var cachedLogin: String? {
        get { defaults.string(forKey: Keys.login) }
        set { defaults.set(newValue, forKey: Keys.login) }
    }

    /// Runs already notified, keyed by `databaseId#attempt`. Prevents re-notify across launches.
    var notifiedKeys: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.notified) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.notified) }
    }

    private enum Keys {
        static let repos = "watchedRepos"
        static let interval = "pollInterval"
        static let ghPath = "ghPath"
        static let login = "cachedLogin"
        static let notified = "notifiedKeys"
    }

    init() {
        watchedRepos = defaults.stringArray(forKey: Keys.repos) ?? []
        let stored = defaults.double(forKey: Keys.interval)
        pollInterval = stored > 0 ? stored : 30
        ghPath = defaults.string(forKey: Keys.ghPath) ?? ""
    }
}
