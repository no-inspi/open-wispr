import Foundation

enum JarvisRunEvent: Equatable {
    case tool(String)
    case completed(String)
    case failed(String)
    case cancelled
}

struct JarvisSessionMessage: Equatable {
    let id: Int
    let role: String
    let kind: String?
    let content: String
}

/// Lit les réponses de l'API Runs d'Hermes. Le flux SSE se lit ligne à ligne : chaque ligne
/// `data:` porte un JSON complet, les lignes vides et les commentaires ne servent à rien ici.
enum JarvisStream {
    static func parse(_ line: String) -> JarvisRunEvent? {
        guard line.hasPrefix("data:"),
              let data = line.dropFirst(5).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = json["event"] as? String else { return nil }

        switch event {
        case "tool.started":
            return (json["tool"] as? String).map { .tool($0) }
        case "run.completed":
            return .completed(trimmedOutput(json))
        case "run.failed", "run.interrupted":
            return .failed(errorMessage(json["error"]))
        case "run.cancelled":
            return .cancelled
        default:
            return nil
        }
    }

    /// Réponse de GET /v1/runs/{id} : nil tant que le run n'est pas terminé.
    static func parseRun(_ data: Data) -> JarvisRunEvent? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch json["status"] as? String {
        case "completed":
            return .completed(trimmedOutput(json))
        case "failed", "interrupted":
            return .failed(errorMessage(json["error"]))
        case "cancelled":
            return .cancelled
        default:
            return nil
        }
    }

    static func parseMessages(_ data: Data) -> [JarvisSessionMessage] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? Int else { return nil }
            return JarvisSessionMessage(id: id,
                                        role: row["role"] as? String ?? "",
                                        kind: row["display_kind"] as? String,
                                        content: row["content"] as? String ?? "")
        }
    }

    /// Libellé assez court pour tenir dans la pastille compacte.
    static func toolLabel(_ name: String) -> String {
        if name.hasPrefix("browser_") { return "Navigateur…" }
        switch name {
        case "web_search": return "Recherche web…"
        case "web_extract": return "Lecture web…"
        case "delegate_task": return "Sous-agent…"
        case "terminal", "process": return "Terminal…"
        case "read_file", "write_file", "patch", "search_files": return "Fichiers…"
        case "execute_code": return "Code…"
        case "vision_analyze": return "Analyse d'image…"
        default: return "Outil : \(name)"
        }
    }

    private static func trimmedOutput(_ json: [String: Any]) -> String {
        (json["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func errorMessage(_ error: Any?) -> String {
        if let text = error as? String { return text }
        if let message = (error as? [String: Any])?["message"] as? String { return message }
        return "Erreur inconnue de Jarvis."
    }
}

/// Suit les tâches de fond d'une session à partir de ses messages. Hermes ne relance jamais
/// la conversation seul : c'est au Mac de voir qu'une délégation est terminée.
struct JarvisBackgroundTracker: Codable, Equatable {
    static let maxAge: TimeInterval = 24 * 3600

    var sessionID: String?
    private var cursor = 0
    private var pending: [String: Date] = [:]

    var hasPending: Bool { !pending.isEmpty }

    /// Retourne le nombre de tâches terminées parmi les nouveaux messages.
    mutating func ingest(_ messages: [JarvisSessionMessage], now: Date) -> Int {
        var finished = 0
        for message in messages.sorted(by: { $0.id < $1.id }) where message.id > cursor {
            cursor = message.id
            if message.role == "tool", let id = Self.dispatchedID(message.content) {
                pending[id] = now
            } else if Self.isCompletion(message), let id = Self.delegationID(message.content),
                      pending.removeValue(forKey: id) != nil {
                finished += 1
            }
        }
        return finished
    }

    /// Retire les tâches sans nouvelles depuis trop longtemps et retourne leur nombre.
    mutating func expire(now: Date) -> Int {
        let stale = pending.filter { now.timeIntervalSince($0.value) > Self.maxAge }.keys
        stale.forEach { pending.removeValue(forKey: $0) }
        return stale.count
    }

    private static func dispatchedID(_ content: String) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any],
              (json["status"] as? String) == "dispatched",
              (json["mode"] as? String) == "background" else { return nil }
        return json["delegation_id"] as? String
    }

    /// Un échec intermédiaire d'une tâche n'est pas la fin de sa délégation.
    private static func isCompletion(_ message: JarvisSessionMessage) -> Bool {
        (message.kind ?? "").hasPrefix("async_delegation") && !message.content.contains("TASK FAILED")
    }

    private static func delegationID(_ content: String) -> String? {
        content.range(of: "deleg_[0-9a-f]+", options: .regularExpression).map { String(content[$0]) }
    }
}

/// Décide quand afficher ce que Jarvis produit : une dictée en cours garde la priorité,
/// et le dernier état de Jarvis est rendu dès que l'écran se libère.
struct JarvisPresenter {
    enum Display: Equatable {
        case thinking(String?)
        case answer(String)
        case failure(String)
    }

    private var latest: Display?

    mutating func update(_ display: Display, screenFree: Bool) -> Display? {
        latest = display
        return screenFree ? takeLatest() : nil
    }

    mutating func screenFreed() -> Display? {
        takeLatest()
    }

    mutating func reset() {
        latest = nil
    }

    /// Une réponse ou une erreur ne s'affiche qu'une fois ; « réfléchit » reste à rétablir
    /// tant que Jarvis travaille.
    private mutating func takeLatest() -> Display? {
        let display = latest
        if case .thinking = display { return display }
        latest = nil
        return display
    }
}
