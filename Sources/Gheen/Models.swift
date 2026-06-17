import Foundation

/// One GitHub Actions workflow run, decoded from `gh run list --json ...`.
/// `repo` is not part of the JSON — it is attached after decode (see GitHubClient).
struct Run: Codable, Identifiable, Hashable, Sendable {
    let databaseId: Int
    let attempt: Int
    let status: String
    let conclusion: String?
    let workflowName: String
    let displayTitle: String
    let headBranch: String
    let event: String
    let url: String
    let createdAt: Date
    let updatedAt: Date

    var repo: String = ""

    // `repo` deliberately excluded — it is set programmatically, not decoded.
    enum CodingKeys: String, CodingKey {
        case databaseId, attempt, status, conclusion, workflowName,
             displayTitle, headBranch, event, url, createdAt, updatedAt
    }

    /// Stable identity that survives reruns: a rerun reuses `databaseId` but bumps `attempt`.
    var runKey: String { "\(databaseId)#\(attempt)" }
    var id: String { runKey }

    static let activeStatuses: Set<String> =
        ["queued", "in_progress", "requested", "waiting", "pending"]

    var isActive: Bool { Run.activeStatuses.contains(status) }
    var isCompleted: Bool { status == "completed" }

    var isFailure: Bool {
        ["failure", "timed_out", "startup_failure"].contains(conclusion ?? "")
    }

    /// Emoji for a finished run's conclusion.
    var conclusionEmoji: String {
        switch conclusion {
        case "success":                                   return "✅"
        case "failure", "timed_out", "startup_failure":   return "❌"
        case "cancelled", "skipped", "stale", "neutral",
             "action_required":                           return "⚪️"
        default:                                          return "⚪️"
        }
    }

    /// Symbol shown in a list row: spinner-ish for active, conclusion emoji otherwise.
    var rowSymbol: String { isActive ? "🟡" : conclusionEmoji }
}
