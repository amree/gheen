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

    private func makeRun(id: Int, status: String = "in_progress") -> Run {
        Run(databaseId: id, attempt: 1, status: status, conclusion: nil,
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

    // MARK: - reconcileActive (actor-index-lag flapping)

    func testRunMissingFromResponseIsCarriedForwardAsActive() {
        let run = makeRun(id: 1)
        let reconciled = Monitor.reconcileActive(runs: [], previouslyActive: [run])
        XCTAssertEqual(reconciled.map(\.databaseId), [1])
    }

    func testRunReportedCompletedIsNotCarriedForward() {
        let active = makeRun(id: 1)
        let finishedVersion = makeRun(id: 1, status: "completed")

        let reconciled = Monitor.reconcileActive(runs: [finishedVersion], previouslyActive: [active])

        XCTAssertTrue(reconciled.isEmpty)
    }

    func testRunStillActiveInResponseIsNotDuplicated() {
        let run = makeRun(id: 1)
        let reconciled = Monitor.reconcileActive(runs: [run], previouslyActive: [run])
        XCTAssertEqual(reconciled.map(\.databaseId), [1])
    }
}
