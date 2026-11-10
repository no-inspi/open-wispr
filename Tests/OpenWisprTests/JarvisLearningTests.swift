import XCTest
@testable import OpenWisprLib

final class JarvisLearningTests: XCTestCase {
    func testLearnCommandPhrasings() {
        let cases = [
            "Jarvis, apprends la prononciation de Tendr.": "Tendr",
            "apprends la prononciation du mot Kubernetes": "Kubernetes",
            "Apprends le mot « Cyrus »": "Cyrus",
            "Apprends à dire Tendr !": "Tendr",
            "Apprends la prononciation d'Argo": "Argo",
            "Apprends la prononciation de pull request": "pull request",
            // Whisper écrit souvent « apprend » sans s.
            "Jarvis apprend la prononciation de Cyrus.": "Cyrus",
        ]
        for (text, word) in cases {
            XCTAssertEqual(JarvisCommand.parse(text), .learnPronunciation(word), text)
        }
    }

    func testLearnCommandRejectsSentencesAndBrokenWords() {
        for text in ["Apprends-moi le Python", "Tu apprends le mot Tendr ?",
                     "Apprends la prononciation de ce mot très long que je vais dire maintenant",
                     "Apprends le mot a=b", "Apprends le mot."] {
            XCTAssertEqual(JarvisCommand.parse(text), .ask(text), text)
        }
    }

    func testAnswers() {
        for text in ["Oui.", "oui, garde-le", "C'est bon", "Parfait !", "Jarvis, ok", "Nickel"] {
            XCTAssertEqual(PronunciationAnswer.parse(text), .keep, text)
        }
        for text in ["Recommence", "Non, recommence.", "Refais-le", "encore une fois"] {
            XCTAssertEqual(PronunciationAnswer.parse(text), .retry, text)
        }
        for text in ["Non.", "Annule", "Laisse tomber"] {
            XCTAssertEqual(PronunciationAnswer.parse(text), .cancel, text)
        }
        for text in ["Quels sont mes mails Tendr ?", "Ouvre le dashboard Linear de l'équipe produit maintenant"] {
            XCTAssertEqual(PronunciationAnswer.parse(text), .other, text)
        }
    }

    func testThreeTakesThenConfirmation() {
        var learning = PronunciationLearning()
        let now = Date()
        learning.start("Tendr", now: now)
        XCTAssertTrue(learning.isRecordingTakes)
        XCTAssertNil(learning.addTake(URL(fileURLWithPath: "/a"), now: now))
        XCTAssertNil(learning.addTake(URL(fileURLWithPath: "/b"), now: now))
        XCTAssertEqual(learning.takeCount, 2)
        XCTAssertEqual(learning.addTake(URL(fileURLWithPath: "/c"), now: now)?.count, 3)
        XCTAssertFalse(learning.isRecordingTakes)
        XCTAssertEqual(learning.pendingPronunciation, [:])
        learning.learned("tɛndøʁ", now: now)
        XCTAssertTrue(learning.isConfirming)
        XCTAssertEqual(learning.pendingPronunciation, ["Tendr": "tɛndøʁ"])
    }

    func testIdleLearningExpires() {
        var learning = PronunciationLearning()
        let start = Date()
        learning.start("Tendr", now: start)
        XCTAssertFalse(learning.expireIfIdle(now: start.addingTimeInterval(60)))
        XCTAssertTrue(learning.expireIfIdle(now: start.addingTimeInterval(PronunciationLearning.timeout + 1)))
        XCTAssertFalse(learning.isActive)
    }

    func testRetryRestartsTheTakes() {
        var learning = PronunciationLearning()
        learning.start("Tendr")
        _ = learning.addTake(URL(fileURLWithPath: "/a"))
        learning.start("Tendr")
        XCTAssertEqual(learning.takeCount, 0)
    }
}
