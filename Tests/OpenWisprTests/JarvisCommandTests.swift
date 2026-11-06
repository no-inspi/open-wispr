import XCTest
@testable import OpenWisprLib

final class JarvisCommandTests: XCTestCase {
    func testNewConversationPhrases() {
        for text in ["Nouvelle conversation.", "nouvelle conversation", "Jarvis, nouvelle conversation !",
                     "Ouvre une nouvelle conversation.", "Démarre une nouvelle conversation"] {
            XCTAssertEqual(JarvisCommand.parse(text), .newConversation, text)
        }
    }

    func testNewConversationInsideASentenceIsAQuestion() {
        let text = "Résume ma nouvelle conversation avec Paul."
        XCTAssertEqual(JarvisCommand.parse(text), .ask(text))
    }

    func testRememberKeepsTheNoteCase() {
        XCTAssertEqual(JarvisCommand.parse("Retiens que le projet s'écrit Projet V2."),
                       .remember("le projet s'écrit Projet V2."))
        XCTAssertEqual(JarvisCommand.parse("Retiens : Projet V2 est le projet principal"),
                       .remember("Projet V2 est le projet principal"))
        XCTAssertEqual(JarvisCommand.parse("Jarvis, retiens qu'il faut écrire Projet"),
                       .remember("il faut écrire Projet"))
    }

    func testRememberNeedsAWordBoundaryAndANote() {
        for text in ["Retiens-tu mon nom ?", "Retiens.", "Tu retiens que c'est important ?", "Retient ça"] {
            XCTAssertEqual(JarvisCommand.parse(text), .ask(text), text)
        }
    }

    func testOrdinaryQuestionIsAsked() {
        XCTAssertEqual(JarvisCommand.parse("Quels sont mes mails ?"), .ask("Quels sont mes mails ?"))
    }

    private func tool(_ name: String?, _ content: String, role: String = "tool") -> JarvisSessionMessage {
        JarvisSessionMessage(id: 1, role: role, kind: nil, content: content, toolName: name)
    }

    func testNoteIsSavedOnlyWhenMemorySucceeded() {
        XCTAssertTrue(JarvisNote.saved([tool("memory", #"{"success": true, "target": "memory"}"#)]))
    }

    func testNoteIsNotSavedWhenRefusedStagedOrAbsent() {
        XCTAssertFalse(JarvisNote.saved([]))
        XCTAssertFalse(JarvisNote.saved([tool("memory", #"{"error": "jarvis-guard : outil bloqué"}"#)]))
        XCTAssertFalse(JarvisNote.saved([tool("memory", #"{"success": false}"#)]))
        XCTAssertFalse(JarvisNote.saved([tool("memory", #"{"success": true, "staged": true}"#)]))
        XCTAssertFalse(JarvisNote.saved([tool("web_search", #"{"success": true}"#)]))
        XCTAssertFalse(JarvisNote.saved([tool("memory", #"{"success": true}"#, role: "assistant")]))
        XCTAssertFalse(JarvisNote.saved([tool("memory", "pas du JSON")]))
    }

    func testMessagesKeepTheToolName() {
        let data = Data(#"{"data":[{"id":3,"role":"tool","tool_name":"memory","content":"{}"}]}"#.utf8)
        XCTAssertEqual(JarvisStream.parseMessages(data).first?.toolName, "memory")
    }
}
