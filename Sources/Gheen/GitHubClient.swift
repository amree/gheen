import Foundation

enum GitHubError: LocalizedError, Sendable {
    case ghNotFound
    case notAuthenticated
    case commandFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "gh CLI not found. Install GitHub CLI or set its path in Settings."
        case .notAuthenticated:
            return "gh is not logged in. Run `gh auth login` in a terminal."
        case .commandFailed(let m):
            return m.isEmpty ? "gh command failed." : m
        case .timeout:
            return "gh command timed out."
        }
    }
}

/// Thin wrapper over the `gh` binary. Resolves the binary path once, then runs
/// it via `Process` with an argument array (no shell interpolation → no injection).
actor GitHubClient {
    private var cachedGhPath: String?
    private let overridePath: String?

    init(overridePath: String?) {
        let trimmed = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.overridePath = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    // MARK: - gh path resolution

    private func ghPath() async throws -> String {
        if let p = cachedGhPath { return p }

        if let o = overridePath {
            // User set an explicit path — honour it strictly, no silent fallback.
            guard FileManager.default.isExecutableFile(atPath: o) else {
                throw GitHubError.ghNotFound
            }
            cachedGhPath = o
            return o
        }
        // Login shell inherits the user's full PATH (GUI apps do not).
        if let resolved = resolveViaLoginShell(),
           FileManager.default.isExecutableFile(atPath: resolved) {
            cachedGhPath = resolved
            return resolved
        }
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                cachedGhPath = candidate
                return candidate
            }
        }
        throw GitHubError.ghNotFound
    }

    /// Constant command string (no user data) → safe to pass through a shell.
    private func resolveViaLoginShell() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v gh"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    // MARK: - Process runner (arg array, with timeout)

    private func run(_ args: [String], timeout: TimeInterval = 20) async throws -> Data {
        let path = try await ghPath()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_PAGER"] = "cat"
        env["GH_PROMPT_DISABLED"] = "1"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let start = Date()
        do { try proc.run() } catch { throw GitHubError.ghNotFound }

        // Read pipes off-thread to avoid deadlock when output exceeds the buffer.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        async let outData = Task.detached { outHandle.readDataToEndOfFile() }.value
        async let errData = Task.detached { errHandle.readDataToEndOfFile() }.value

        // Wait for exit, but never longer than `timeout`. A gh stuck in a syscall can
        // ignore SIGTERM, which then wedges the pipe reads forever and never resets
        // the caller's isPolling guard. On timeout SIGKILL (uncatchable) so the
        // process dies, its pipe write-ends close, the reads unblock, and this call
        // always returns. Kill inside the group so the waitUntilExit child unblocks
        // before the group awaits it.
        let exitedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask { proc.waitUntilExit(); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            if !first { kill(proc.processIdentifier, SIGKILL) }
            group.cancelAll()
            return first
        }

        let out = await outData
        let err = await errData

        let status = exitedInTime ? "exit \(proc.terminationStatus)" : "timeout"
        logCommand(args, start: start, duration: Date().timeIntervalSince(start), status: status)

        if !exitedInTime {
            throw GitHubError.timeout
        }
        if proc.terminationStatus != 0 {
            let msg = (String(data: err, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = msg.lowercased()
            if lower.contains("not logged") || lower.contains("authentication")
                || lower.contains("gh auth login") {
                throw GitHubError.notAuthenticated
            }
            throw GitHubError.commandFailed(msg)
        }
        return out
    }

    // MARK: - Command log

    /// Log one executed `gh` call. Collapses the constant `--json <fields>` blob —
    /// identical every line, pure noise.
    private func logCommand(_ args: [String], start: Date, duration: TimeInterval, status: String) {
        let cmd = ("gh " + args.joined(separator: " "))
            .replacingOccurrences(of: "--json \\S+", with: "--json …", options: .regularExpression)
        CommandLog.append("\(cmd)  (\(String(format: "%.2f", duration))s, \(status))", at: start)
    }

    // MARK: - API

    func currentLogin() async throws -> String {
        let data = try await run(["api", "user", "--jq", ".login"])
        let login = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if login.isEmpty { throw GitHubError.notAuthenticated }
        return login
    }

    func rerunRun(id: Int, repo: String, failedOnly: Bool = false) async throws {
        var args = ["run", "rerun", "\(id)", "-R", repo]
        if failedOnly { args.append("--failed") }
        _ = try await run(args)
    }

    func listRuns(repo: String, user: String) async throws -> [Run] {
        let fields = "databaseId,attempt,status,conclusion,workflowName," +
                     "displayTitle,headBranch,event,url,createdAt,updatedAt"
        let data = try await run([
            "run", "list", "-R", repo, "-u", user, "-L", "100", "--json", fields
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // GitHub's `-u <login>` actor filter leaks runs the user didn't trigger:
        // Dependabot version updates (event "dynamic", actor dependabot[bot]) and
        // scheduled cron runs (event "schedule", actor = whoever owns the schedule).
        // Drop those events so the list stays "runs I triggered".
        let leakedEvents: Set<String> = ["dynamic", "schedule"]
        var runs = try decoder.decode([Run].self, from: data)
            .filter { !leakedEvents.contains($0.event) }
        for i in runs.indices { runs[i].repo = repo }
        return runs
    }
}
