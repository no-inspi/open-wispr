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

/// Appels à l'API Runs d'Hermes. Un run tourne sur le VPS indépendamment de la connexion :
/// si le flux d'événements tombe, on interroge le run au lieu d'abandonner.
struct JarvisAPI {
    let base: String
    let key: String

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                         timeout: TimeInterval = 30) throws -> URLRequest {
        guard let url = URL(string: base + path) else {
            throw JarvisError.message("URL Jarvis invalide : \(base)")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    func createRun(_ body: [String: Any]) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request("/v1/runs", method: "POST", body: body))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw JarvisError.message("HTTP \(code) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let runID = json["run_id"] as? String else {
            throw JarvisError.message("Réponse illisible de Jarvis.")
        }
        return runID
    }

    func stop(_ runID: String) async {
        guard let request = try? request("/v1/runs/\(runID)/stop", method: "POST", body: [:]) else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    func messages(_ sessionID: String) async throws -> [JarvisSessionMessage] {
        let (data, _) = try await URLSession.shared.data(
            for: request("/api/sessions/\(sessionID)/messages?order=latest&limit=50"))
        return JarvisStream.parseMessages(data)
    }

    /// Attend la fin du run et retourne son résultat, jamais `.tool`.
    func finish(_ runID: String, onTool: (String) async -> Void) async -> JarvisRunEvent {
        // Le serveur envoie un keepalive toutes les 10 s : 60 s de silence = connexion perdue.
        if let events = try? request("/v1/runs/\(runID)/events", timeout: 60),
           let (bytes, _) = try? await URLSession.shared.bytes(for: events) {
            do {
                for try await line in bytes.lines {
                    switch JarvisStream.parse(line) {
                    case .tool(let name): await onTool(name)
                    case .some(let result): return result
                    case nil: continue
                    }
                }
            } catch {
                // On passe à l'interrogation du run ci-dessous.
            }
        }
        return await poll(runID)
    }

    /// Compte les échecs plutôt que le temps : une veille du Mac ne doit pas passer pour une panne.
    private func poll(_ runID: String) async -> JarvisRunEvent {
        var failures = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            do {
                let (data, response) = try await URLSession.shared.data(for: request("/v1/runs/\(runID)"))
                if (response as? HTTPURLResponse)?.statusCode == 404 {
                    return .failed("Résultat de Jarvis expiré.")
                }
                failures = 0
                if let result = JarvisStream.parseRun(data) { return result }
            } catch {
                failures += 1
                if failures >= 20 {
                    return .failed("Connexion à Jarvis perdue. La tâche continue peut-être sur le VPS.")
                }
            }
        }
        return .cancelled
    }
}

/// Envoie les demandes à Hermes Agent et suit les tâches de fond.
/// Réglages : ~/.config/open-wispr/jarvis.json  ->  {"url": "http://<hôte-tailscale>:8642", "resetAfterMinutes": 10}
/// Clé API : trousseau macOS, service "open-wispr-jarvis".
/// Sauf mention contraire, tout s'appelle sur le thread principal.
final class JarvisClient {
    struct Settings: Codable {
        var url: String?
        var resetAfterMinutes: Double?
        var instructions: String?
    }

    static let keychainService = "open-wispr-jarvis"
    private static let watchInterval: UInt64 = 20_000_000_000
    private static let announcementPrompt = """
        Une tâche de fond vient de se terminer. Annonce son résultat en 1 ou 2 phrases, \
        sans utiliser d'outil.
        """

    /// Appelé quand une tâche de fond est terminée et que Jarvis l'a résumée.
    var onAnnouncement: ((Result<String, Error>) -> Void)?
    /// Faux tant que l'annonce gênerait : dictée en cours, Jarvis en train de parler.
    var canAnnounce: () -> Bool = { true }

    private var tracker = JarvisClient.loadTracker()
    private var lastExchange = Date.distantPast
    private var currentTask: Task<Void, Never>?
    private var currentRun: (api: JarvisAPI, id: String)?
    private var watcher: Task<Void, Never>?
    private var isAnnouncing = false
    private var needsAnnouncement = false

    private static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/open-wispr")
    }

    private func loadSettings() -> Settings {
        let path = Self.configDirectory.appendingPathComponent("jarvis.json")
        guard let data = try? Data(contentsOf: path),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return settings
    }

    private static func loadTracker() -> JarvisBackgroundTracker {
        let path = configDirectory.appendingPathComponent("jarvis-state.json")
        guard let data = try? Data(contentsOf: path),
              let tracker = try? JSONDecoder().decode(JarvisBackgroundTracker.self, from: data) else {
            return JarvisBackgroundTracker()
        }
        return tracker
    }

    private func saveTracker() {
        guard let data = try? JSONEncoder().encode(tracker) else { return }
        try? data.write(to: Self.configDirectory.appendingPathComponent("jarvis-state.json"), options: .atomic)
    }

    private func makeAPI(_ settings: Settings) throws -> JarvisAPI {
        guard let key = Self.apiKey() else {
            throw JarvisError.message("Clé API introuvable dans le trousseau (service \(Self.keychainService)).")
        }
        guard let url = settings.url, !url.isEmpty else {
            throw JarvisError.message("URL Jarvis absente de ~/.config/open-wispr/jarvis.json.")
        }
        return JarvisAPI(base: url.trimmingCharacters(in: CharacterSet(charactersIn: "/")), key: key)
    }

    /// Reprend le suivi des tâches lancées avant un redémarrage de l'app.
    func resume() {
        startWatching()
    }

    /// Arrête la demande en cours. Les sous-agents déjà lancés continuent sur le VPS.
    /// `completion` n'est alors plus appelé.
    func cancel() {
        if let run = currentRun {
            Task { await run.api.stop(run.id) }
        }
        currentRun = nil
        currentTask?.cancel()
        currentTask = nil
        if isAnnouncing {
            isAnnouncing = false
            needsAnnouncement = true
        }
    }

    /// Les deux closures sont appelées sur le thread principal.
    func ask(_ text: String,
             onTool: @escaping (String) -> Void,
             completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        startTurn(text, keepSession: false, onTool: onTool, completion: completion)
    }

    /// Retient une note dans une conversation à part : celle en cours n'est pas touchée.
    /// Les deux closures sont appelées sur le thread principal.
    func remember(_ note: String,
                  onTool: @escaping (String) -> Void,
                  completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        let api: JarvisAPI
        do {
            api = try makeAPI(loadSettings())
        } catch {
            completion(.failure(error))
            return
        }
        let sessionID = "jarvis-note-\(UUID().uuidString.lowercased())"
        let body: [String: Any] = ["input": note, "session_id": sessionID, "instructions": JarvisNote.instructions]
        run(api, body, sessionID, onTool: onTool) { [weak self] result, messages in
            self?.endNote(result, messages, completion)
        }
    }

    /// Repart sur une conversation neuve. Retourne vrai si une tâche de fond ne sera plus annoncée.
    func newConversation() -> Bool {
        cancel()
        let hadPending = tracker.hasPending
        tracker = JarvisBackgroundTracker()
        saveTracker()
        return hadPending
    }

    private func startTurn(_ text: String, keepSession: Bool,
                           onTool: @escaping (String) -> Void,
                           completion: @escaping (Result<String, Error>) -> Void) {
        let settings = loadSettings()
        let api: JarvisAPI
        do {
            api = try makeAPI(settings)
        } catch {
            completion(.failure(error))
            return
        }

        // Nouvelle conversation après un moment d'inactivité, sauf si une tâche de fond
        // doit encore revenir dans celle-ci.
        let inactive = Date().timeIntervalSince(lastExchange) > (settings.resetAfterMinutes ?? 10) * 60
        if tracker.sessionID == nil || (inactive && !keepSession && !tracker.hasPending) {
            tracker = JarvisBackgroundTracker()
            tracker.sessionID = "jarvis-\(UUID().uuidString.lowercased())"
            saveTracker()
        }
        guard let sessionID = tracker.sessionID else { return }

        let body: [String: Any] = [
            "input": text,
            "session_id": sessionID,
            "instructions": settings.instructions ?? """
                Tu es Jarvis, l'assistant vocal de Charlie. Ta réponse sera lue à voix haute : \
                réponds en français, en 2 à 4 phrases, sans markdown, sans listes ni code. \
                Pour une tâche longue, délègue-la à un sous-agent, dis simplement que c'est en cours \
                et termine ton tour : tu seras prévenu quand elle sera finie.
                """,
        ]

        run(api, body, sessionID, onTool: onTool) { [weak self] result, messages in
            self?.endTurn(result, messages, completion)
        }
    }

    private func run(_ api: JarvisAPI, _ body: [String: Any], _ sessionID: String,
                     onTool: @escaping (String) -> Void,
                     finish: @escaping (JarvisRunEvent, [JarvisSessionMessage]) -> Void) {
        currentTask = Task { [weak self] in
            let runID: String
            do {
                runID = try await api.createRun(body)
            } catch {
                await MainActor.run {
                    if !Task.isCancelled { finish(.failed(error.localizedDescription), []) }
                }
                return
            }
            let started: Bool = await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return false }
                self?.currentRun = (api, runID)
                return true
            }
            guard started else {
                await api.stop(runID)
                return
            }

            let result = await api.finish(runID) { name in
                await MainActor.run {
                    if !Task.isCancelled { onTool(name) }
                }
            }
            let messages = (try? await api.messages(sessionID)) ?? []
            await MainActor.run {
                if !Task.isCancelled { finish(result, messages) }
            }
        }
    }

    private func endNote(_ result: JarvisRunEvent, _ messages: [JarvisSessionMessage],
                         _ completion: (Result<String, Error>) -> Void) {
        currentTask = nil
        currentRun = nil
        isAnnouncing = false
        switch result {
        case .completed(let answer) where JarvisNote.saved(messages):
            completion(.success(answer))
        case .failed(let message):
            completion(.failure(JarvisError.message(message)))
        default:
            completion(.failure(JarvisError.message("Je n'ai rien retenu.")))
        }
        startWatching()
    }

    private func endTurn(_ result: JarvisRunEvent, _ messages: [JarvisSessionMessage],
                         _ completion: (Result<String, Error>) -> Void) {
        currentTask = nil
        currentRun = nil
        isAnnouncing = false
        lastExchange = Date()
        ingest(messages)

        switch result {
        case .completed(let answer):
            completion(.success(answer))
        case .failed(let message):
            completion(.failure(JarvisError.message(message)))
        case .cancelled, .tool:
            completion(.failure(JarvisError.message("Demande annulée.")))
        }
        startWatching()
    }

    private func ingest(_ messages: [JarvisSessionMessage]) {
        if tracker.ingest(messages, now: Date()) > 0 {
            needsAnnouncement = true
        }
        saveTracker()
    }

    private func startWatching() {
        guard watcher == nil, tracker.hasPending || needsAnnouncement else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.watchInterval)
                let next: (api: JarvisAPI, sessionID: String)? = await MainActor.run { [weak self] in
                    guard let self = self else { return nil }
                    let settings = self.loadSettings()
                    guard let sessionID = self.tracker.sessionID,
                          let api = try? self.makeAPI(settings) else { return nil }
                    return (api, sessionID)
                }
                let messages = next == nil ? nil : try? await next?.api.messages(next?.sessionID ?? "")
                let done: Bool = await MainActor.run { [weak self] in
                    guard let self = self else { return true }
                    return self.watchTick(messages)
                }
                if done { return }
            }
        }
    }

    /// Retourne vrai quand il n'y a plus rien à suivre.
    private func watchTick(_ messages: [JarvisSessionMessage]?) -> Bool {
        if let messages = messages, currentTask == nil {
            ingest(messages)
        }
        if tracker.expire(now: Date()) > 0 {
            saveTracker()
            onAnnouncement?(.failure(JarvisError.message("Tâche de fond sans nouvelles depuis 24 h.")))
        }
        if needsAnnouncement, currentTask == nil, canAnnounce() {
            needsAnnouncement = false
            isAnnouncing = true
            startTurn(Self.announcementPrompt, keepSession: true, onTool: { _ in }) { [weak self] result in
                self?.onAnnouncement?(result)
            }
        }
        guard !tracker.hasPending, !needsAnnouncement else { return false }
        watcher = nil
        return true
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

    var isSpeaking: Bool { synthesizer.isSpeaking }

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

/// Notification macOS. Le binaire n'est pas un bundle d'app : on passe par osascript,
/// le texte étant transmis en argument pour éviter tout échappement.
enum JarvisNotifier {
    static func notify(_ text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"Jarvis\"",
                             "-e", "end run", text]
        try? process.run()
    }
}
