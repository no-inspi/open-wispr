import Foundation

/// Apprentissage d'une prononciation par la voix :
/// « Jarvis, apprends la prononciation de Tendr », trois prises avec ⌥,
/// Jarvis relit le mot, puis « oui » l'enregistre dans la liste de mots.
struct PronunciationLearning: Equatable {
    static let takesNeeded = 3
    /// Sans nouvelle prise ni réponse pendant ce délai, l'apprentissage est abandonné.
    static let timeout: TimeInterval = 120

    enum Phase: Equatable {
        case recording(word: String, takes: [URL])
        case learning(word: String)
        case confirming(word: String, phonemes: String)
    }

    private(set) var phase: Phase?
    private var lastActivity = Date.distantPast

    var isActive: Bool { phase != nil }

    var word: String? {
        switch phase {
        case .recording(let word, _), .learning(let word), .confirming(let word, _): return word
        case nil: return nil
        }
    }

    var isRecordingTakes: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isConfirming: Bool {
        if case .confirming = phase { return true }
        return false
    }

    /// La prononciation à imposer quand Jarvis relit le mot avant validation.
    var pendingPronunciation: [String: String] {
        if case .confirming(let word, let phonemes) = phase { return [word: phonemes] }
        return [:]
    }

    mutating func start(_ word: String, now: Date = Date()) {
        phase = .recording(word: word, takes: [])
        lastActivity = now
    }

    /// Ajoute une prise ; renvoie les prises quand il y en a assez.
    mutating func addTake(_ url: URL, now: Date = Date()) -> [URL]? {
        guard case .recording(let word, var takes) = phase else { return nil }
        takes.append(url)
        lastActivity = now
        if takes.count >= Self.takesNeeded {
            phase = .learning(word: word)
            return takes
        }
        phase = .recording(word: word, takes: takes)
        return nil
    }

    var takeCount: Int {
        if case .recording(_, let takes) = phase { return takes.count }
        return 0
    }

    mutating func learned(_ phonemes: String, now: Date = Date()) {
        guard case .learning(let word) = phase else { return }
        phase = .confirming(word: word, phonemes: phonemes)
        lastActivity = now
    }

    mutating func cancel() {
        phase = nil
    }

    /// Abandonne un apprentissage resté sans suite. Renvoie vrai s'il a expiré.
    mutating func expireIfIdle(now: Date = Date()) -> Bool {
        guard phase != nil, now.timeIntervalSince(lastActivity) > Self.timeout else { return false }
        phase = nil
        return true
    }
}

/// Le mot à apprendre, tiré de la transcription.
enum PronunciationCommand {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*(?:jarvis[\s,]+)?apprends?[\s,]+(?:(?:à\s+dire|a\s+dire)|(?:la\s+)?prononciation\s+(?:de\s+|du\s+mot\s+|d['’])|le\s+mot)\s*(.+?)[\s.!?,;:]*$"#,
        options: [.caseInsensitive])

    static func word(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let wordRange = Range(match.range(at: 1), in: text) else { return nil }
        let quotes = CharacterSet(charactersIn: "«»\"'“”‘’ ")
        let word = text[wordRange].trimmingCharacters(in: quotes)
        // Un mot ou une courte expression, rien qui casse une ligne de la liste.
        guard !word.isEmpty, word.count <= 40, word.split(separator: " ").count <= 3,
              word.rangeOfCharacter(from: CharacterSet(charactersIn: "=#\n")) == nil,
              word.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return word
    }
}

/// Réponse de Charlie quand Jarvis demande s'il garde la prononciation.
enum PronunciationAnswer: Equatable {
    case keep
    case retry
    case cancel
    /// Autre chose : l'apprentissage est abandonné et la phrase traitée normalement.
    case other

    private static let keepWords: Set<String> = ["oui", "ouais", "ok", "okay", "parfait", "nickel", "top",
                                                  "garde", "valide", "yes"]
    private static let retryWords: Set<String> = ["recommence", "recommencer", "refais", "encore", "reessaie",
                                                  "reessaye"]
    private static let cancelWords: Set<String> = ["non", "annule", "stop", "arrete"]

    static func parse(_ text: String) -> PronunciationAnswer {
        var words = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.first == "jarvis" { words.removeFirst() }
        guard !words.isEmpty, words.count <= 6 else { return .other }
        // « non, recommence » : recommencer l'emporte sur le refus.
        if words.contains(where: retryWords.contains) { return .retry }
        if words.prefix(2) == ["cest", "bon"] || words.prefix(2) == ["cest", "parfait"] { return .keep }
        if keepWords.contains(words[0]) { return .keep }
        if cancelWords.contains(words[0]) || words.prefix(2) == ["laisse", "tomber"] { return .cancel }
        return .other
    }
}

/// Appels au service vocal local (`jarvis-voice/kokoro_server.py`).
enum JarvisVoiceService {
    static let base = URL(string: "http://127.0.0.1:47860")!

    /// Les prises sont lues sur place par le service : il n'accepte que ce dossier.
    static var takesDirectory: URL {
        Config.configDir.appendingPathComponent("learn")
    }

    static func prepare() {
        Task { _ = try? await post("/prepare", [:], timeout: 5) }
    }

    static func learn(_ takes: [URL]) async throws -> String {
        let json = try await post("/learn", ["takes": takes.map(\.path)], timeout: 90)
        guard let phonemes = json["phonemes"] as? String, !phonemes.isEmpty else {
            throw JarvisError.message("je n'ai rien entendu dans les prises")
        }
        return phonemes
    }

    static func saveWord(_ word: String, phonemes: String) async throws {
        _ = try await post("/words", ["word": word, "phonemes": phonemes], timeout: 10)
    }

    private static func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw JarvisError.message("service vocal : HTTP \(code) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
