import XCTest
@testable import Gheen

/// Regression test for the poll-wedging bug: `runProcess` used to reap via a
/// blocking `Task.detached { proc.waitUntilExit() }`. In production that call
/// sometimes never returned (Foundation's reap notification silently lost),
/// parking a cooperative-pool thread forever — enough of those piling up
/// starved the whole app and killed polling with no error logged.
///
/// This can't force that exact Foundation-internal race deterministically, but
/// it pins the actual safety net: `runProcess` must never take meaningfully
/// longer than `timeout` + the reap deadline, no matter how long the child
/// process itself keeps running.
final class GitHubClientRunProcessTests: XCTestCase {
    func testFastCommandReturnsOutputAndStatus() async throws {
        let client = GitHubClient(overridePath: nil)
        let raw = await client.runProcess("/bin/echo", ["hello"], timeout: 5)
        let result = try XCTUnwrap(raw)
        XCTAssertEqual(String(data: result.out, encoding: .utf8), "hello\n")
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testSlowCommandIsBoundedByTimeoutPlusReapDeadline() async throws {
        let client = GitHubClient(overridePath: nil)
        let start = Date()
        let raw = await client.runProcess("/bin/sh", ["-c", "sleep 30"], timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        let result = try XCTUnwrap(raw)

        XCTAssertTrue(result.timedOut)
        // timeout(1s) + 5s reap deadline + slack. If this creeps toward 30s,
        // runProcess is blocking on the reap again.
        XCTAssertLessThan(elapsed, 10)
    }
}
