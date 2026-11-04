import Foundation

enum JarvisStreamEvent: Equatable {
    case tool(String)
    case completed(id: String?, text: String)
    case failed(String)
}

/// Lit le flux SSE de /v1/responses, une ligne à la fois. Chaque ligne `data:` porte un JSON
/// complet avec son `type` : on n'a donc besoin ni des lignes `event:`, ni des lignes vides.
enum JarvisStream {
    static func parse(_ line: String) -> JarvisStreamEvent? {
        guard line.hasPrefix("data:"),
              let data = line.dropFirst(5).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else { return nil }

        switch type {
        case "response.output_item.added":
            guard let item = json["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call",
                  let name = item["name"] as? String else { return nil }
            return .tool(name)
        case "response.completed", "response.incomplete":
            guard let response = json["response"] as? [String: Any] else { return nil }
            return .completed(id: response["id"] as? String, text: extractText(response))
        case "response.failed":
            let response = json["response"] as? [String: Any]
            return .failed(errorMessage(response?["error"]))
        default:
            return nil
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

    private static func extractText(_ response: [String: Any]) -> String {
        var parts: [String] = []
        for item in response["output"] as? [[String: Any]] ?? [] {
            guard (item["type"] as? String) == "message" else { continue }
            for content in item["content"] as? [[String: Any]] ?? [] {
                if let text = content["text"] as? String { parts.append(text) }
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func errorMessage(_ error: Any?) -> String {
        if let text = error as? String { return text }
        if let message = (error as? [String: Any])?["message"] as? String { return message }
        return "Erreur inconnue de Jarvis."
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
