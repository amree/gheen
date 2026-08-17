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

    /// Signals once the process's `terminationHandler` fires, or once a hard
    /// deadline passes — whichever first. Guards against `waitUntilExit()`
    /// (and its non-blocking `terminationHandler` cousin) never firing: seen in
    /// production as dozens of `Task.detached { proc.waitUntilExit() }` calls
    /// parked forever on the cooperative thread pool after SIGKILL, starving the
    /// whole app of threads and silently killing all polling.
    private final class ExitWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Bool, Never>?
        private var finished = false
        private var reapedValue = false

        func finish(reaped: Bool) {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true; reapedValue = reaped
            let c = cont; cont = nil
            lock.unlock()
            c?.resume(returning: reaped)
        }

        func attach(_ c: CheckedContinuation<Bool, Never>) {
            lock.lock()
            if finished { let v = reapedValue; lock.unlock(); c.resume(returning: v); return }
            cont = c; lock.unlock()
        }
    }

    /// Run a subprocess with a hard timeout, reading output via non-blocking
    /// readability handlers so no thread ever blocks on a pipe. (A blocking read is
    /// what wedged polling: a gh child inheriting stdout keeps the write-end open, so
    /// `readDataToEndOfFile` never returns.) Completes on stdout EOF — all output
    /// collected — or `timeout`, whichever first; on timeout SIGKILL. Reaped via
    /// `terminationHandler` (non-blocking) with its own hard deadline, so a lost
    /// reap notification can't block a thread or hang this call forever.
    /// Returns nil only if the process fails to launch.
    /// Internal (not private) so GheenTests can exercise it directly.
    func runProcess(_ executable: String, _ arguments: [String],
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

        let exitWaiter = ExitWaiter()
        proc.terminationHandler = { _ in exitWaiter.finish(reaped: true) }

        do { try proc.run() } catch { return nil }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            collector.finish(timedOut: true)
        }
        let timedOut = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            collector.attach(c)
        }

        if timedOut { kill(proc.processIdentifier, SIGKILL) }
        // Non-blocking reap via terminationHandler — never a blocking waitUntilExit()
        // on a cooperative-pool thread. A second deadline bounds the wait itself, in
        // case the termination notification never arrives.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            exitWaiter.finish(reaped: false)
        }
        let reaped = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            exitWaiter.attach(c)
        }
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil

        let (out, err) = collector.collected
        // terminationStatus throws if the process never actually got reaped.
        let status: Int32 = reaped ? proc.terminationStatus : -1
        return (out, err, status, timedOut)
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

    /// One run as returned by `GET /repos/{repo}/actions/runs` (REST shape,
    /// snake_case) — `gh run list --json` has no equivalent field, only this
    /// raw endpoint exposes `triggering_actor`.
    struct APIRun: Decodable {
        struct Actor: Decodable { let login: String }
        let id: Int
        let runAttempt: Int
        let status: String
        let conclusion: String?
        let name: String?
        let displayTitle: String
        let headBranch: String
        let event: String
        let htmlUrl: String
        let createdAt: Date
        let updatedAt: Date
        let triggeringActor: Actor

        enum CodingKeys: String, CodingKey {
            case id, status, conclusion, name, event
            case runAttempt = "run_attempt"
            case displayTitle = "display_title"
            case headBranch = "head_branch"
            case htmlUrl = "html_url"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case triggeringActor = "triggering_actor"
        }
    }

    /// Decode the REST run-list body and keep only runs `user` actually
    /// triggered. GitHub's `actor=` query param is a coarse pre-filter, not an
    /// exact match — it leaks runs where `user` merely authored the branch's
    /// HEAD commit but someone else dispatched the run, plus Dependabot version
    /// updates and scheduled cron runs. `triggering_actor` is the one field
    /// that reflects who actually triggered this run/attempt, so it replaces
    /// all of the above with one precise check instead of an event blocklist.
    /// A free function (not actor-isolated) so tests can call it directly.
    static func parseRuns(_ data: Data, user: String) throws -> [APIRun] {
        struct Envelope: Decodable { let workflowRuns: [APIRun]
            enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Envelope.self, from: data).workflowRuns
            .filter { $0.triggeringActor.login == user }
    }

    func listRuns(repo: String, user: String) async throws -> [Run] {
        // `gh api` defaults to POST once any -f/-F param is present — this
        // endpoint is GET-only, so --method must be explicit or it 404s.
        let data = try await run([
            "api", "repos/\(repo)/actions/runs", "--method", "GET",
            "-f", "actor=\(user)", "-F", "per_page=100"
        ])
        var runs = try Self.parseRuns(data, user: user).map { r in
            Run(databaseId: r.id, attempt: r.runAttempt, status: r.status,
                conclusion: r.conclusion, workflowName: r.name ?? "",
                displayTitle: r.displayTitle, headBranch: r.headBranch,
                event: r.event, url: r.htmlUrl, createdAt: r.createdAt, updatedAt: r.updatedAt)
        }
        for i in runs.indices { runs[i].repo = repo }
        return runs
    }
}
