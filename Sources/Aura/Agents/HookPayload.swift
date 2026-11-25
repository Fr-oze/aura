import Foundation

/// Ce qu'un événement d'agent veut dire pour Aura.
enum EventKind {
    case working   // l'agent travaille
    case waiting   // l'agent attend une action dans son interface
    case idle      // l'agent est inactif (ne compte que si une session était au travail)
    case done      // tour terminé
    case error
    case ended     // session fermée : on la retire
    case ignore
}

struct IncomingEvent {
    var source: AgentSource
    var session: String
    var cwd: String
    var kind: EventKind
    var title: String
    var detail: String
    var app: String
    /// Événement de simple rafraîchissement (surveillance de Codex) : il met l'état à jour
    /// mais ne compte pas comme une action, donc il ne fait pas battre l'encoche.
    var silent = false
}

struct IncomingApproval {
    var source: AgentSource
    var session: String
    var cwd: String
    var command: String
    var app: String
    /// L'agent tourne dans un mode où l'utilisateur a choisi de ne rien valider.
    var bypass: Bool
}

/// Ce qu'un agent demande à l'utilisateur, posé dans l'encoche.
struct IncomingAsk {
    var source: AgentSource
    var session: String
    var cwd: String
    var question: String
    var detail: String
    /// Réponses proposées en boutons. Vide = pas de boutons.
    var choices: [String]
    /// Champ de texte libre.
    var wantsText: Bool
    /// Bouton « Choisir un fichier… ».
    var wantsFile: Bool
    var timeout: TimeInterval
}

/// Lecture des JSON reçus sur /event, /approve et /ask.
///
/// Deux formes acceptées :
/// 1. normalisée : {"source","session","cwd","event","title","detail"} (et "command" pour /approve) ;
/// 2. enveloppe du script hook.sh : {"source","hook","app","raw": <JSON brut de l'agent>}.
///
/// Tout ce qui dépend du format propre à Claude Code, Codex ou Cursor est dans ce fichier.
/// Sources vérifiées le 2026-11-25 :
/// - Claude Code : https://code.claude.com/docs/en/hooks
/// - Codex : https://developers.openai.com/codex/config-advanced (redirige vers learn.chatgpt.com)
/// - Cursor : https://cursor.com/docs/agent/hooks
enum HookPayload {

    static func event(from data: Data) -> IncomingEvent? {
        guard let root = object(data) else { return nil }
        let source = AgentSource(rawValue: text(root, "source").lowercased()) ?? .other
        let app = text(root, "app")

        if let raw = root["raw"] as? [String: Any] {
            let hook = text(root, "hook")
            switch source {
            case .claude: return claudeEvent(raw, hook: hook, app: app)
            case .codex: return codexEvent(raw, app: app)
            case .cursor: return cursorEvent(raw, hook: hook, app: app)
            case .other: return nil
            }
        }

        let session = text(root, "session")
        return IncomingEvent(source: source,
                             session: session.isEmpty ? "default" : session,
                             cwd: text(root, "cwd"),
                             kind: normalizedKind(text(root, "event")),
                             title: oneLine(text(root, "title"), limit: 60),
                             detail: oneLine(text(root, "detail"), limit: 160),
                             app: app)
    }

    static func approval(from data: Data) -> IncomingApproval? {
        guard let root = object(data) else { return nil }
        let source = AgentSource(rawValue: text(root, "source").lowercased()) ?? .other
        let app = text(root, "app")

        if let raw = root["raw"] as? [String: Any] {
            switch source {
            case .claude:
                // PreToolUse : tool_input.command porte la commande Bash.
                guard let input = raw["tool_input"] as? [String: Any],
                      let command = input["command"] as? String, !command.trimmed.isEmpty
                else { return nil }
                return IncomingApproval(source: .claude,
                                        session: sessionID(raw, "session_id"),
                                        cwd: text(raw, "cwd"),
                                        command: command,
                                        app: app,
                                        bypass: text(raw, "permission_mode") == "bypassPermissions")
            case .cursor:
                // beforeShellExecution : command + cwd à la racine.
                let command = text(raw, "command")
                guard !command.trimmed.isEmpty else { return nil }
                return IncomingApproval(source: .cursor,
                                        session: sessionID(raw, "conversation_id"),
                                        cwd: cursorRoot(raw),
                                        command: command,
                                        app: app,
                                        bypass: false)
            case .codex, .other:
                return nil
            }
        }

        let command = text(root, "command").isEmpty ? text(root, "detail") : text(root, "command")
        guard !command.trimmed.isEmpty else { return nil }
        let session = text(root, "session")
        return IncomingApproval(source: source,
                                session: session.isEmpty ? "default" : session,
                                cwd: text(root, "cwd"),
                                command: command,
                                app: app,
                                bypass: false)
    }

    /// `/ask` : seulement la forme normalisée, envoyée par la commande `aura`.
    static func ask(from data: Data) -> IncomingAsk? {
        guard let root = object(data) else { return nil }
        let question = oneLine(text(root, "question"), limit: 200)
        guard !question.isEmpty else { return nil }
        let source = AgentSource(rawValue: text(root, "source").lowercased()) ?? .other
        let session = text(root, "session")
        let choices = ((root["choices"] as? [Any]) ?? [])
            .compactMap { $0 as? String }
            .map { oneLine($0, limit: 40) }
            .filter { !$0.isEmpty }
        let timeout = (root["timeout"] as? NSNumber)?.doubleValue ?? 180
        return IncomingAsk(source: source,
                           session: session.isEmpty ? "default" : session,
                           cwd: text(root, "cwd"),
                           question: question,
                           detail: oneLine(text(root, "detail"), limit: 300),
                           choices: Array(choices.prefix(5)),
                           wantsText: (root["text"] as? Bool) ?? false,
                           wantsFile: (root["file"] as? Bool) ?? false,
                           timeout: min(900, max(10, timeout)))
    }

    // MARK: Claude Code

    private static func claudeEvent(_ raw: [String: Any], hook: String, app: String) -> IncomingEvent? {
        let name = text(raw, "hook_event_name").isEmpty ? hook : text(raw, "hook_event_name")
        var event = IncomingEvent(source: .claude,
                                  session: sessionID(raw, "session_id"),
                                  cwd: text(raw, "cwd"),
                                  kind: .ignore,
                                  title: "",
                                  detail: "",
                                  app: app)
        switch name {
        case "UserPromptSubmit":
            event.kind = .working
            event.detail = oneLine(text(raw, "prompt"), limit: 160)
        case "PreToolUse", "PostToolUse":
            event.kind = .working
            let tool = text(raw, "tool_name")
            let command = ((raw["tool_input"] as? [String: Any])?["command"] as? String) ?? ""
            event.detail = oneLine(command.isEmpty ? tool : command, limit: 160)
        case "Notification":
            event.detail = oneLine(text(raw, "message"), limit: 160)
            switch text(raw, "notification_type") {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                event.kind = .waiting
            case "idle_prompt":
                event.kind = .idle
            default:
                event.kind = .ignore
            }
        case "Stop":
            event.kind = .done
            event.detail = oneLine(text(raw, "last_assistant_message"), limit: 160)
        case "StopFailure":
            event.kind = .error
            event.detail = oneLine(text(raw, "error"), limit: 160)
        case "SessionEnd":
            event.kind = .ended
        default:
            event.kind = .ignore
        }
        return event
    }

    // MARK: Codex (notify)

    private static func codexEvent(_ raw: [String: Any], app: String) -> IncomingEvent? {
        // notify n'émet aujourd'hui que "agent-turn-complete".
        guard text(raw, "type") == "agent-turn-complete" else { return nil }
        return IncomingEvent(source: .codex,
                             session: sessionID(raw, "thread-id"),
                             cwd: text(raw, "cwd"),
                             kind: .done,
                             title: "",
                             detail: oneLine(text(raw, "last-assistant-message"), limit: 160),
                             app: app)
    }

    // MARK: Cursor

    private static func cursorEvent(_ raw: [String: Any], hook: String, app: String) -> IncomingEvent? {
        let name = text(raw, "hook_event_name").isEmpty ? hook : text(raw, "hook_event_name")
        var event = IncomingEvent(source: .cursor,
                                  session: sessionID(raw, "conversation_id"),
                                  cwd: cursorRoot(raw),
                                  kind: .ignore,
                                  title: "",
                                  detail: "",
                                  app: app)
        switch name {
        case "afterFileEdit":
            event.kind = .working
            let file = URL(fileURLWithPath: text(raw, "file_path")).lastPathComponent
            event.detail = file.isEmpty ? "modifie un fichier" : "modifie \(file)"
        case "beforeSubmitPrompt":
            event.kind = .working
            event.detail = oneLine(text(raw, "prompt"), limit: 160)
        case "beforeShellExecution":
            event.kind = .working
            event.detail = oneLine(text(raw, "command"), limit: 160)
        case "stop":
            switch text(raw, "status") {
            case "error": event.kind = .error
            case "aborted": event.kind = .ended
            default: event.kind = .done
            }
        default:
            event.kind = .ignore
        }
        return event
    }

    /// Racine du projet Cursor : premier workspace_roots, sinon cwd.
    private static func cursorRoot(_ raw: [String: Any]) -> String {
        if let roots = raw["workspace_roots"] as? [String], let first = roots.first, !first.isEmpty {
            return first
        }
        return text(raw, "cwd")
    }

    // MARK: Outils

    private static func normalizedKind(_ name: String) -> EventKind {
        switch name.lowercased() {
        case "start", "working", "prompt", "tool", "progress": return .working
        case "waiting", "notify", "attention", "input": return .waiting
        case "idle": return .idle
        case "done", "stop", "complete", "completed", "finished": return .done
        case "error", "fail", "failed": return .error
        case "end", "close", "closed": return .ended
        default: return .ignore
        }
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func text(_ dict: [String: Any], _ key: String) -> String {
        (dict[key] as? String) ?? ""
    }

    private static func sessionID(_ dict: [String: Any], _ key: String) -> String {
        let value = text(dict, key)
        return value.isEmpty ? "default" : value
    }

    private static func oneLine(_ value: String, limit: Int) -> String {
        let flat = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmed
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}
