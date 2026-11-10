import Foundation

/// Commandes reconnues dans la transcription du micro, avant tout envoi à Jarvis.
/// Elles ne viennent que de la voix : un mail lu par Jarvis ne peut pas les déclencher.
enum JarvisCommand: Equatable {
    case ask(String)
    case newConversation
    case remember(String)
    case learnPronunciation(String)

    private static let newConversationPhrases: Set<String> = [
        "nouvelle conversation", "une nouvelle conversation", "ouvre une nouvelle conversation",
        "commence une nouvelle conversation", "demarre une nouvelle conversation",
    ]
    private static let remember = try! NSRegularExpression(
        pattern: #"^\s*(?:jarvis[\s,]+)?retiens(?=[\s:,]|$)[\s:,]*(?:que\s+|qu['’])?(.*\S)\s*$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    static func parse(_ text: String) -> JarvisCommand {
        if newConversationPhrases.contains(spoken(text)) {
            return .newConversation
        }
        let range = NSRange(text.startIndex..., in: text)
        if let match = remember.firstMatch(in: text, range: range),
           let note = Range(match.range(at: 1), in: text),
           text[note].rangeOfCharacter(from: .alphanumerics) != nil {
            return .remember(String(text[note]))
        }
        if let word = PronunciationCommand.word(in: text) {
            return .learnPronunciation(word)
        }
        return .ask(text)
    }

    /// Sans casse, accents, ponctuation de bord ni « Jarvis » en tête.
    private static func spoken(_ text: String) -> String {
        let edges = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: edges)
        guard folded.hasPrefix("jarvis") else { return folded }
        return String(folded.dropFirst("jarvis".count)).trimmingCharacters(in: edges)
    }
}

/// Une note passe dans sa propre conversation, qui n'a rien lu : `jarvis-guard` y laisse `memory`.
enum JarvisNote {
    static let instructions = """
        Charlie te dicte une note à retenir. Enregistre-la avec l'outil memory, sans utiliser \
        aucun autre outil. Puis répète en une phrase courte ce que tu as retenu : ta réponse \
        sera lue à voix haute, sans markdown.
        """

    /// Jarvis peut annoncer une note qu'il n'a pas écrite : seul le résultat de l'outil compte.
    static func saved(_ messages: [JarvisSessionMessage]) -> Bool {
        messages.contains { message in
            guard message.role == "tool", message.toolName == "memory",
                  let data = message.content.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return false
            }
            return json["success"] as? Bool == true && json["staged"] as? Bool != true
        }
    }
}
