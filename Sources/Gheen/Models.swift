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

    var eventLabel: String {
        switch event {
        case "pull_request", "pull_request_target": return "PR"
        case "push":              return "Push"
        case "workflow_dispatch": return "Manual"
        case "schedule":          return "Scheduled"
        case "release":           return "Release"
        default:                  return event
        }
    }

    var isPR: Bool {
        event == "pull_request" || event == "pull_request_target"
    }

    var repoName: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    var timeAgo: String {
        let ref = isActive ? createdAt : updatedAt
        let s = Date().timeIntervalSince(ref)
        if s < 60    { return "just now" }
        if s < 3600  { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
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

}
