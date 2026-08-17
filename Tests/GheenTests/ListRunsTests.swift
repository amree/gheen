import XCTest
@testable import Gheen

/// Regression test for the leaked-run bug: GitHub's `actor=` query filter is a
/// coarse pre-filter, not an exact match — it returns runs someone else
/// triggered (Dependabot, scheduled cron, or a `workflow_dispatch` run on a
/// branch the queried user merely authored the HEAD commit of). `parseRuns`
/// must reject anything whose `triggering_actor` isn't the queried user.
final class ListRunsTests: XCTestCase {
    private let sampleJSON = """
    {
      "workflow_runs": [
        {
          "id": 1, "run_attempt": 1, "status": "completed", "conclusion": "success",
          "name": "Deploy", "display_title": "Deploy to prod from main",
          "head_branch": "main", "event": "workflow_dispatch",
          "html_url": "https://github.com/coingecko/coinanalytics/actions/runs/1",
          "created_at": "2026-08-17T04:00:00Z", "updated_at": "2026-08-17T04:01:00Z",
          "triggering_actor": { "login": "amree" }
        },
        {
          "id": 2, "run_attempt": 1, "status": "in_progress", "conclusion": null,
          "name": "Deploy", "display_title": "Deploy to prod from main",
          "head_branch": "main", "event": "workflow_dispatch",
          "html_url": "https://github.com/coingecko/coinanalytics/actions/runs/2",
          "created_at": "2026-08-17T05:00:00Z", "updated_at": "2026-08-17T05:00:00Z",
          "triggering_actor": { "login": "joncmscg" }
        },
        {
          "id": 3, "run_attempt": 1, "status": "completed", "conclusion": "success",
          "name": "Dependabot Updates", "display_title": "Bump foo",
          "head_branch": "dependabot/npm/foo", "event": "dynamic",
          "html_url": "https://github.com/coingecko/coinanalytics/actions/runs/3",
          "created_at": "2026-08-17T03:00:00Z", "updated_at": "2026-08-17T03:01:00Z",
          "triggering_actor": { "login": "dependabot[bot]" }
        }
      ]
    }
    """

    func testKeepsOnlyRunsTriggeredByUser() throws {
        let runs = try GitHubClient.parseRuns(Data(sampleJSON.utf8), user: "amree")
        XCTAssertEqual(runs.map(\.id), [1])
        XCTAssertEqual(runs[0].triggeringActor.login, "amree")
    }
}
