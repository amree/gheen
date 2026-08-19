import XCTest
@testable import Gheen

/// Regression tests for two flavors of the same bug: a poll that can't fully
/// account for a repo must not regress what's displayed for it.
///
/// 1. A hard `gh api` failure on one repo dropped its runs from both the
///    active list and the capped "recently finished" list for that tick,
///    letting another repo's older runs crowd the recently-finished view.
/// 2. GitHub's `actor=` search index can lag a poll behind real state, so a
///    *successful* response can silently omit a still-active run — that read
///    as "finished" and the run flickered off the list, then back on.
///
/// `Monitor.reconcile` is the single function both cases route through.
final class MonitorFallbackTests: XCTestCase {
    private struct DummyError: Error {}

    private func makeRun(id: Int, status: String = "in_progress") -> Run {
        Run(databaseId: id, attempt: 1, status: status, conclusion: nil,
            workflowName: "Deploy", displayTitle: "Deploy to staging",
            headBranch: "main", event: "workflow_dispatch",
            url: "https://example.com/\(id)", createdAt: Date(), updatedAt: Date())
    }

    func testHardFailureCarriesForwardEntireLastKnownList() {
        let active = makeRun(id: 1)
        let finished = makeRun(id: 2, status: "completed")

        let (runs, carriedOver) = Monitor.reconcile(fresh: nil, lastKnown: [active, finished])

        XCTAssertEqual(Set(runs.map(\.databaseId)), [1, 2])
        XCTAssertEqual(Set(carriedOver.map(\.databaseId)), [1, 2])
    }

    func testHardFailureWithNoPriorHistoryYieldsNothing() {
        let (runs, carriedOver) = Monitor.reconcile(fresh: nil, lastKnown: [])
        XCTAssertTrue(runs.isEmpty)
        XCTAssertTrue(carriedOver.isEmpty)
    }

    func testActiveRunMissingFromSuccessfulResponseIsCarriedForward() {
        let stillRunning = makeRun(id: 1)

        let (runs, carriedOver) = Monitor.reconcile(fresh: [], lastKnown: [stillRunning])

        XCTAssertEqual(runs.map(\.databaseId), [1])
        XCTAssertEqual(carriedOver.map(\.databaseId), [1])
    }

    func testFinishedRunMissingFromSuccessfulResponseAgesOutNormally() {
        let agedOut = makeRun(id: 1, status: "completed")

        let (runs, carriedOver) = Monitor.reconcile(fresh: [], lastKnown: [agedOut])

        XCTAssertTrue(runs.isEmpty, "a finished run rolling off a real page is not a bug to paper over")
        XCTAssertTrue(carriedOver.isEmpty)
    }

    func testRunReportedCompletedInFreshResponseIsNotCarriedForward() {
        let wasActive = makeRun(id: 1)
        let nowFinished = makeRun(id: 1, status: "completed")

        let (runs, carriedOver) = Monitor.reconcile(fresh: [nowFinished], lastKnown: [wasActive])

        XCTAssertEqual(runs.map(\.status), ["completed"])
        XCTAssertTrue(carriedOver.isEmpty)
    }

    func testRunStillActiveInFreshResponseIsNotDuplicated() {
        let run = makeRun(id: 1)

        let (runs, carriedOver) = Monitor.reconcile(fresh: [run], lastKnown: [run])

        XCTAssertEqual(runs.map(\.databaseId), [1])
        XCTAssertTrue(carriedOver.isEmpty)
    }
}
