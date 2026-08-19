import XCTest
@testable import Gheen

/// Regression test for the flickering-active-run bug: when repo A succeeds and
/// repo B's `gh api` call has a one-off transient failure, `poll()` used to
/// rebuild `activeRuns` from only the repos that succeeded *this* tick — so
/// repo B's still-running job vanished from the UI for that cycle, even though
/// nothing changed on GitHub. A failed repo must fall back to its last-known
/// active runs instead of being dropped.
final class MonitorFallbackTests: XCTestCase {
    private struct DummyError: Error {}

    private func makeRun(id: Int) -> Run {
        Run(databaseId: id, attempt: 1, status: "in_progress", conclusion: nil,
            workflowName: "Deploy", displayTitle: "Deploy to staging",
            headBranch: "main", event: "workflow_dispatch",
            url: "https://example.com/\(id)", createdAt: Date(), updatedAt: Date())
    }

    func testFailedRepoFallsBackToLastKnownActiveRuns() {
        let staleRun = makeRun(id: 1)
        var results: [String: [Run]] = ["repoA": [makeRun(id: 2)]]
        let errors: [String: Error] = ["repoB": DummyError()]

        Monitor.applyFallback(results: &results, errors: errors, lastActive: ["repoB": [staleRun]])

        XCTAssertEqual(results["repoB"]?.map(\.databaseId), [1])
        XCTAssertEqual(results["repoA"]?.map(\.databaseId), [2])
    }

    func testFailedRepoWithNoPriorActiveRunsStaysAbsent() {
        var results: [String: [Run]] = [:]
        let errors: [String: Error] = ["repoB": DummyError()]

        Monitor.applyFallback(results: &results, errors: errors, lastActive: [:])

        XCTAssertNil(results["repoB"])
    }
}
