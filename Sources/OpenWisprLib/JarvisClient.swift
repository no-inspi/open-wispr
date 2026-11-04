import AVFoundation
import Foundation
import Security

enum JarvisError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

/// Envoie une demande à Hermes Agent (API compatible OpenAI, endpoint /v1/responses).
/// Réglages : ~/.config/open-wispr/jarvis.json  ->  {"url": "http://<hôte-tailscale>:8642", "resetAfterMinutes": 10}
/// Clé API : trousseau macOS, service "open-wispr-jarvis".
final class JarvisClient {
    struct Settings: Codable {
        var url: String?
        var resetAfterMinutes: Double?
        var instructions: String?
    }

    static let keychainService = "open-wispr-jarvis"

    private var previousResponseID: String?
    private var lastExchange = Date.distantPast

    private func loadSettings() -> Settings {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/open-wispr/jarvis.json")
        guard let data = try? Data(contentsOf: path),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return settings
    }

    /// À appeler sur le thread principal.
    func ask(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let settings = loadSettings()
        guard let key = Self.apiKey() else {
            completion(.failure(JarvisError.message("Clé API introuvable dans le trousseau (service \(Self.keychainService)).")))
            return
        }
        guard let configuredURL = settings.url, !configuredURL.isEmpty else {
            completion(.failure(JarvisError.message("URL Jarvis absente de ~/.config/open-wispr/jarvis.json.")))
            return
        }
        let base = configuredURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/v1/responses") else {
            completion(.failure(JarvisError.message("URL Jarvis invalide : \(base)")))
            return
        }

        // Nouvelle conversation après un moment d'inactivité.
        if Date().timeIntervalSince(lastExchange) > (settings.resetAfterMinutes ?? 10) * 60 {
            previousResponseID = nil
        }

        var body: [String: Any] = [
            "model": "hermes-agent",
            "input": text,
            "instructions": settings.instructions ?? """
                Tu es Jarvis, l'assistant vocal de Charlie. Ta réponse sera lue à voix haute : \
                réponds en français, en 2 à 4 phrases, sans markdown, sans listes ni code. \
                Pour une tâche longue, lance-la en arrière-plan et dis simplement que c'est en cours.
                """,
        ]
        if let previous = previousResponseID {
            body["previous_response_id"] = previous
        }

        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data = data else {
                completion(.failure(JarvisError.message("Réponse vide de Jarvis.")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                completion(.failure(JarvisError.message("HTTP \(http.statusCode) \(detail)")))
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(.failure(JarvisError.message("Réponse illisible de Jarvis.")))
                return
            }
            let answer = Self.extractText(json)
            let responseID = json["id"] as? String
            DispatchQueue.main.async {
                self?.previousResponseID = responseID
                self?.lastExchange = Date()
            }
            completion(.success(answer))
        }.resume()
    }

    private static func extractText(_ json: [String: Any]) -> String {
        if let text = json["output_text"] as? String, !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var parts: [String] = []
        for item in json["output"] as? [[String: Any]] ?? [] {
            guard (item["type"] as? String) == "message" else { continue }
            for content in item["content"] as? [[String: Any]] ?? [] {
                if let text = content["text"] as? String { parts.append(text) }
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }
}

/// Lit les réponses de Jarvis avec la synthèse vocale de macOS (voix française).
final class JarvisSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: Self.plainText(text))
        utterance.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Retire le markdown que le modèle pourrait quand même produire.
    static func plainText(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (bloc de code) ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "https?://\\S+", with: "un lien", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
        return s
    }
}
