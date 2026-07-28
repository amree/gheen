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
        if let resolved = await resolveViaLoginShell(),
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
    private func resolveViaLoginShell() async -> String? {
        guard let result = await runProcess("/bin/zsh", ["-lc", "command -v gh"], timeout: 5),
              !result.timedOut, result.status == 0 else { return nil }
        let s = String(data: result.out, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    // MARK: - Process runner (non-blocking reads, hard timeout)

    /// Thread-safe accumulator for a subprocess's piped output, shared between the
    /// GCD readability handlers and the awaiting caller. Coordinates a single
    /// continuation resume from whichever finishes first: stdout EOF or the timeout.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var cont: CheckedContinuation<Bool, Never>?
        private var finished = false
        private var timedOutValue = false

        func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
        func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }

        /// Register the awaiting continuation; if completion already fired, resume now.
        func attach(_ c: CheckedContinuation<Bool, Never>) {
            lock.lock()
            if finished { let v = timedOutValue; lock.unlock(); c.resume(returning: v); return }
            cont = c; lock.unlock()
        }

        /// Resume exactly once (EOF → false, timeout → true).
        func finish(timedOut: Bool) {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true; timedOutValue = timedOut
            let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: timedOut)
        }

        var collected: (out: Data, err: Data) {
            lock.lock(); defer { lock.unlock() }; return (out, err)
        }
    }

    /// Run a subprocess with a hard timeout, reading output via non-blocking
    /// readability handlers so no thread ever blocks on a pipe. (A blocking read is
    /// what wedged polling: a gh child inheriting stdout keeps the write-end open, so
    /// `readDataToEndOfFile` never returns.) Completes on stdout EOF — all output
    /// collected — or `timeout`, whichever first; on timeout SIGKILL. The process is
    /// reaped on a detached task so a lingering process can't block the actor.
    /// Returns nil only if the process fails to launch.
    private func runProcess(_ executable: String, _ arguments: [String],
                            environment: [String: String]? = nil,
                            timeout: TimeInterval)
        async -> (out: Data, err: Data, status: Int32, timedOut: Bool)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let environment { proc.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Handlers set before launch so a large, fast writer can't fill the pipe
        // buffer and stall before we start draining.
        let collector = OutputCollector()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        outHandle.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; collector.finish(timedOut: false) }
            else { collector.appendOut(d) }
        }
        errHandle.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collector.appendErr(d) }
        }

        do { try proc.run() } catch { return nil }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            collector.finish(timedOut: true)
        }
        let timedOut = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            collector.attach(c)
        }

        if timedOut { kill(proc.processIdentifier, SIGKILL) }
        // Reap off the actor; waitUntilExit is bounded by process lifetime (SIGKILL
        // guarantees it on timeout), never by the pipes.
        await Task.detached { proc.waitUntilExit() }.value
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil

        let (out, err) = collector.collected
        return (out, err, proc.terminationStatus, timedOut)
    }

    private func run(_ args: [String], timeout: TimeInterval = 20) async throws -> Data {
        let path = try await ghPath()
        var env = ProcessInfo.processInfo.environment
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_PAGER"] = "cat"
        env["GH_PROMPT_DISABLED"] = "1"

        let start = Date()
        guard let result = await runProcess(path, args, environment: env, timeout: timeout) else {
            throw GitHubError.ghNotFound
        }

        let errMsg = (String(data: result.err, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Fold the failure reason into the log line so a future reader sees *why* a
        // call failed (auth, network, rate limit), not just the exit code.
        let status: String
        if result.timedOut {
            status = "timeout"
        } else if result.status != 0 {
            let reason = errMsg.replacingOccurrences(of: "\n", with: " ").prefix(140)
            status = reason.isEmpty ? "exit \(result.status)" : "exit \(result.status): \(reason)"
        } else {
            status = "exit 0"
        }
        logCommand(args, start: start, duration: Date().timeIntervalSince(start), status: status)

        if result.timedOut { throw GitHubError.timeout }
        if result.status != 0 {
            let lower = errMsg.lowercased()
            if lower.contains("not logged") || lower.contains("authentication")
                || lower.contains("gh auth login") {
                throw GitHubError.notAuthenticated
            }
            throw GitHubError.commandFailed(errMsg)
        }
        return result.out
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
