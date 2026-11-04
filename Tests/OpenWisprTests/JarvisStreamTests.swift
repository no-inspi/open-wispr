import XCTest
@testable import OpenWisprLib

final class JarvisStreamTests: XCTestCase {
    func testIgnoresKeepaliveAndOpenAndIdLines() {
        XCTAssertNil(JarvisStream.parse(": keepalive"))
        XCTAssertNil(JarvisStream.parse(": open"))
        XCTAssertNil(JarvisStream.parse("id: 0"))
        XCTAssertNil(JarvisStream.parse(""))
    }

    func testIgnoresMalformedData() {
        XCTAssertNil(JarvisStream.parse("data: {pas du json"))
    }

    func testToolStartIsReported() {
        let line = #"data: {"event": "tool.started", "run_id": "run_1", "timestamp": 1.0, "tool": "web_search", "preview": "", "tool_call_id": "x", "seq": 0}"#
        XCTAssertEqual(JarvisStream.parse(line), .tool("web_search"))
    }

    func testToolCompletedIsNotReportedAgain() {
        let line = #"data: {"event": "tool.completed", "run_id": "run_1", "tool": "web_search"}"#
        XCTAssertNil(JarvisStream.parse(line))
    }

    func testCompletedCarriesTrimmedOutput() {
        let line = #"data: {"event": "run.completed", "run_id": "run_1", "output": "\n\nBONJOUR !", "usage": {"input_tokens": 1}}"#
        XCTAssertEqual(JarvisStream.parse(line), .completed("BONJOUR !"))
    }

    func testFailedWithErrorObject() {
        let line = #"data: {"event": "run.failed", "error": {"message": "quota dépassé"}}"#
        XCTAssertEqual(JarvisStream.parse(line), .failed("quota dépassé"))
    }

    func testFailedWithErrorString() {
        let line = #"data: {"event": "run.failed", "error": "boom"}"#
        XCTAssertEqual(JarvisStream.parse(line), .failed("boom"))
    }

    func testCancelledIsReported() {
        XCTAssertEqual(JarvisStream.parse(#"data: {"event": "run.cancelled"}"#), .cancelled)
    }

    func testInterruptedIsAFailure() {
        XCTAssertEqual(JarvisStream.parse(#"data: {"event": "run.interrupted", "error": "Gateway shutdown interrupted the run."}"#),
                       .failed("Gateway shutdown interrupted the run."))
    }

    func testPolledRunStillRunningHasNoResult() {
        XCTAssertNil(JarvisStream.parseRun(Data(#"{"object": "hermes.run", "status": "running"}"#.utf8)))
    }

    func testPolledRunCompleted() {
        XCTAssertEqual(JarvisStream.parseRun(Data(#"{"status": "completed", "output": " Fini. "}"#.utf8)), .completed("Fini."))
    }

    func testPolledRunCancelled() {
        XCTAssertEqual(JarvisStream.parseRun(Data(#"{"status": "cancelled"}"#.utf8)), .cancelled)
    }

    func testPolledRunFailed() {
        XCTAssertEqual(JarvisStream.parseRun(Data(#"{"status": "failed", "error": "boom"}"#.utf8)), .failed("boom"))
    }

    func testMessagesAreReadFromDataKey() {
        let body = #"{"object": "list", "data": [{"id": 115, "role": "user", "display_kind": "async_delegation_complete", "content": "[ASYNC DELEGATION BATCH COMPLETE — deleg_94f89354]"}, {"id": 110, "role": "assistant", "display_kind": null, "content": null}]}"#
        XCTAssertEqual(JarvisStream.parseMessages(Data(body.utf8)), [
            JarvisSessionMessage(id: 115, role: "user", kind: "async_delegation_complete", content: "[ASYNC DELEGATION BATCH COMPLETE — deleg_94f89354]"),
            JarvisSessionMessage(id: 110, role: "assistant", kind: nil, content: ""),
        ])
    }

    func testKnownToolsGetShortFrenchLabels() {
        XCTAssertEqual(JarvisStream.toolLabel("web_search"), "Recherche web…")
        XCTAssertEqual(JarvisStream.toolLabel("delegate_task"), "Sous-agent…")
        XCTAssertEqual(JarvisStream.toolLabel("browser_navigate"), "Navigateur…")
    }

    func testUnknownToolShowsItsName() {
        XCTAssertEqual(JarvisStream.toolLabel("cronjob"), "Outil : cronjob")
    }
}

final class JarvisBackgroundTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let dispatched = JarvisSessionMessage(id: 108, role: "tool", kind: nil, content: #"{"status": "dispatched", "mode": "background", "count": 1, "delegation_id": "deleg_94f89354", "goals": ["x"]}"#)
    private let finished = JarvisSessionMessage(id: 115, role: "user", kind: "async_delegation_complete", content: "[ASYNC DELEGATION BATCH COMPLETE — deleg_94f89354]\nA background fan-out unit")

    func testDispatchMakesATaskPending() {
        var tracker = JarvisBackgroundTracker()
        XCTAssertEqual(tracker.ingest([dispatched], now: now), 0)
        XCTAssertEqual(tracker.hasPending, true)
    }

    func testCompletionClearsThePendingTask() {
        var tracker = JarvisBackgroundTracker()
        _ = tracker.ingest([dispatched], now: now)
        XCTAssertEqual(tracker.ingest([finished], now: now), 1)
        XCTAssertEqual(tracker.hasPending, false)
    }

    func testDispatchAndCompletionInOneBatchAreOrderedById() {
        var tracker = JarvisBackgroundTracker()
        XCTAssertEqual(tracker.ingest([finished, dispatched], now: now), 1)
        XCTAssertEqual(tracker.hasPending, false)
    }

    func testAlreadySeenMessagesAreIgnored() {
        var tracker = JarvisBackgroundTracker()
        _ = tracker.ingest([dispatched, finished], now: now)
        XCTAssertEqual(tracker.ingest([dispatched, finished], now: now), 0)
        XCTAssertEqual(tracker.hasPending, false)
    }

    func testRefusedDelegationIsNotPending() {
        var tracker = JarvisBackgroundTracker()
        let refused = JarvisSessionMessage(id: 121, role: "tool", kind: nil, content: #"{"error": "Task 0 output_schema invalid"}"#)
        _ = tracker.ingest([refused], now: now)
        XCTAssertEqual(tracker.hasPending, false)
    }

    func testInterimFailureKeepsTheTaskPending() {
        var tracker = JarvisBackgroundTracker()
        _ = tracker.ingest([dispatched], now: now)
        let interim = JarvisSessionMessage(id: 112, role: "user", kind: "async_delegation_complete", content: "[ASYNC DELEGATION TASK FAILED — deleg_94f89354]")
        XCTAssertEqual(tracker.ingest([interim], now: now), 0)
        XCTAssertEqual(tracker.hasPending, true)
    }

    func testOneOfTwoTasksFinishing() {
        var tracker = JarvisBackgroundTracker()
        let other = JarvisSessionMessage(id: 109, role: "tool", kind: nil, content: #"{"status": "dispatched", "mode": "background", "delegation_id": "deleg_aaaa1111"}"#)
        _ = tracker.ingest([dispatched, other], now: now)
        XCTAssertEqual(tracker.ingest([finished], now: now), 1)
        XCTAssertEqual(tracker.hasPending, true)
    }

    func testStaleTasksExpireAfterADay() {
        var tracker = JarvisBackgroundTracker()
        _ = tracker.ingest([dispatched], now: now)
        XCTAssertEqual(tracker.expire(now: now.addingTimeInterval(23 * 3600)), 0)
        XCTAssertEqual(tracker.expire(now: now.addingTimeInterval(25 * 3600)), 1)
        XCTAssertEqual(tracker.hasPending, false)
    }

    func testStateSurvivesARestart() throws {
        var tracker = JarvisBackgroundTracker()
        tracker.sessionID = "jarvis-1"
        _ = tracker.ingest([dispatched], now: now)
        let restored = try JSONDecoder().decode(JarvisBackgroundTracker.self, from: JSONEncoder().encode(tracker))
        XCTAssertEqual(restored, tracker)
    }
}

final class JarvisPresenterTests: XCTestCase {
    func testProgressShowsWhenScreenIsFree() {
        var presenter = JarvisPresenter()
        XCTAssertEqual(presenter.update(.thinking("Recherche web…"), screenFree: true), .thinking("Recherche web…"))
    }

    func testAnswerDuringDictationIsHeldUntilScreenIsFree() {
        var presenter = JarvisPresenter()
        XCTAssertNil(presenter.update(.answer("Paris"), screenFree: false))
        XCTAssertEqual(presenter.screenFreed(), .answer("Paris"))
    }

    func testHeldAnswerIsDeliveredOnlyOnce() {
        var presenter = JarvisPresenter()
        _ = presenter.update(.answer("Paris"), screenFree: false)
        _ = presenter.screenFreed()
        XCTAssertNil(presenter.screenFreed())
    }

    func testDisplayedAnswerIsNotReplayed() {
        var presenter = JarvisPresenter()
        _ = presenter.update(.answer("Paris"), screenFree: true)
        XCTAssertNil(presenter.screenFreed())
    }

    func testThinkingComesBackAfterDictation() {
        var presenter = JarvisPresenter()
        _ = presenter.update(.thinking(nil), screenFree: true)
        XCTAssertNil(presenter.update(.thinking("Sous-agent…"), screenFree: false))
        XCTAssertEqual(presenter.screenFreed(), .thinking("Sous-agent…"))
    }

    func testFailureDuringDictationIsHeld() {
        var presenter = JarvisPresenter()
        XCTAssertNil(presenter.update(.failure("HTTP 500"), screenFree: false))
        XCTAssertEqual(presenter.screenFreed(), .failure("HTTP 500"))
    }

    func testResetForgetsHeldAnswer() {
        var presenter = JarvisPresenter()
        _ = presenter.update(.answer("Ancienne"), screenFree: false)
        presenter.reset()
        XCTAssertNil(presenter.screenFreed())
    }
}
