import XCTest
@testable import OpenWisprLib

final class JarvisStreamTests: XCTestCase {
    func testIgnoresKeepaliveAndEventLines() {
        XCTAssertNil(JarvisStream.parse(": keepalive"))
        XCTAssertNil(JarvisStream.parse("event: response.created"))
        XCTAssertNil(JarvisStream.parse(""))
    }

    func testIgnoresMalformedData() {
        XCTAssertNil(JarvisStream.parse("data: {pas du json"))
    }

    func testToolStartIsReported() {
        let line = #"data: {"type": "response.output_item.added", "output_index": 0, "item": {"id": "fc_1", "type": "function_call", "status": "in_progress", "name": "web_search", "call_id": "x", "arguments": "{}"}, "sequence_number": 1}"#
        XCTAssertEqual(JarvisStream.parse(line), .tool("web_search"))
    }

    func testMessageItemIsNotATool() {
        let line = #"data: {"type": "response.output_item.added", "item": {"id": "msg_1", "type": "message", "role": "assistant"}}"#
        XCTAssertNil(JarvisStream.parse(line))
    }

    func testToolDoneIsNotReportedAgain() {
        let line = #"data: {"type": "response.output_item.done", "item": {"type": "function_call", "name": "web_search"}}"#
        XCTAssertNil(JarvisStream.parse(line))
    }

    func testCompletedCarriesIdAndTrimmedText() {
        let line = #"data: {"type": "response.completed", "response": {"id": "resp_1", "status": "completed", "output": [{"type": "function_call", "name": "web_search"}, {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "\n\nIl fait nuageux."}]}]}}"#
        XCTAssertEqual(JarvisStream.parse(line), .completed(id: "resp_1", text: "Il fait nuageux."))
    }

    func testIncompleteKeepsPartialText() {
        let line = #"data: {"type": "response.incomplete", "response": {"id": "resp_2", "output": [{"type": "message", "content": [{"type": "output_text", "text": "Début"}]}]}}"#
        XCTAssertEqual(JarvisStream.parse(line), .completed(id: "resp_2", text: "Début"))
    }

    func testFailedWithErrorObject() {
        let line = #"data: {"type": "response.failed", "response": {"id": "r", "error": {"message": "quota dépassé"}}}"#
        XCTAssertEqual(JarvisStream.parse(line), .failed("quota dépassé"))
    }

    func testFailedWithErrorString() {
        let line = #"data: {"type": "response.failed", "response": {"id": "r", "error": "boom"}}"#
        XCTAssertEqual(JarvisStream.parse(line), .failed("boom"))
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
