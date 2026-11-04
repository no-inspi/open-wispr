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

/// Envoie une demande à Hermes Agent (API compatible OpenAI, endpoint /v1/responses en streaming).
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
    private var currentTask: Task<Void, Never>?
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

    /// Interrompt la demande en cours : la déconnexion arrête aussi l'agent sur le serveur.
    /// À appeler sur le thread principal. `completion` n'est alors plus appelé.
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// À appeler sur le thread principal. Les deux closures sont appelées sur le thread principal.
    func ask(_ text: String,
             onTool: @escaping (String) -> Void,
             completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
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
            "stream": true,
            "instructions": settings.instructions ?? """
                Tu es Jarvis, l'assistant vocal de Charlie. Ta réponse sera lue à voix haute : \
                réponds en français, en 2 à 4 phrases, sans markdown, sans listes ni code. \
                Pour une tâche longue, lance-la en arrière-plan et dis simplement que c'est en cours.
                """,
        ]
        if let previous = previousResponseID {
            body["previous_response_id"] = previous
        }

        // Le serveur envoie un keepalive toutes les 10 s : 60 s de silence = connexion perdue,
        // même si la tâche elle-même dure bien plus longtemps.
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        currentTask = Task { [weak self] in
            let result = await Self.stream(request) { name in
                await MainActor.run {
                    if !Task.isCancelled { onTool(name) }
                }
            }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                self?.currentTask = nil
                switch result {
                case .success(let answer):
                    self?.previousResponseID = answer.id
                    self?.lastExchange = Date()
                    completion(.success(answer.text))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private static func stream(_ request: URLRequest,
                               onTool: (String) async -> Void) async -> Result<(id: String?, text: String), Error> {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(JarvisError.message("Réponse vide de Jarvis."))
            }
            guard (200..<300).contains(http.statusCode) else {
                var detail = Data()
                for try await byte in bytes.prefix(200) { detail.append(byte) }
                return .failure(JarvisError.message("HTTP \(http.statusCode) \(String(decoding: detail, as: UTF8.self))"))
            }
            for try await line in bytes.lines {
                switch JarvisStream.parse(line) {
                case .tool(let name):
                    await onTool(name)
                case .completed(let id, let text):
                    return .success((id, text))
                case .failed(let message):
                    return .failure(JarvisError.message(message))
                case nil:
                    continue
                }
            }
            return .failure(JarvisError.message("Connexion à Jarvis interrompue."))
        } catch {
            return .failure(error)
        }
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
