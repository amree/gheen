import Foundation

/// Rolling log at ~/Library/Logs/Gheen/commands.log (last 100 lines). Records every
/// `gh` call plus poll-loop events that make no `gh` call, so a gap between timestamps
/// means a real stall — not idle backoff, an empty repo list, or a skipped tick.
///
/// All writes run on one serial queue: the `GitHubClient` actor and the `@MainActor`
/// Monitor both append here, and the read-modify-write must not interleave.
enum CommandLog {
    static let fileURL: URL? = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/Gheen/commands.log")

    private static let queue = DispatchQueue(label: "com.amree.gheen.commandlog")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Append one timestamped line, keeping only the last 100. Fire-and-forget;
    /// `time` is captured at the call site so ordering matches call order.
    static func append(_ message: String, at time: Date = Date()) {
        guard let file = fileURL else { return }
        queue.async {
            let line = "\(dateFormatter.string(from: time))  \(message)"
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = (try? String(contentsOf: file, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
            lines.append(line)
            if lines.count > 100 { lines = Array(lines.suffix(100)) }
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
