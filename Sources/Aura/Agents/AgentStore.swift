import Foundation
import Combine
import SwiftUI

enum AgentSource: String, CaseIterable {
    case claude, codex, cursor, other

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .other: return "Agent"
        }
    }

    /// Symbole SF utilisé comme pictogramme de la source.
    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow"
        case .other: return "bolt.fill"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.93, green: 0.55, blue: 0.38)
        case .codex: return Color(red: 0.45, green: 0.86, blue: 0.74)
        case .cursor: return Color(red: 0.62, green: 0.72, blue: 1.0)
        case .other: return Color(red: 0.8, green: 0.8, blue: 0.85)
        }
    }

    /// App activée au clic quand rien n'est réglé ni détecté.
    var fallbackBundleID: String {
        switch self {
        case .claude, .codex, .other: return "com.apple.Terminal"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        }
    }
}

enum AgentPhase: Equatable {
    case working, waiting, done, error
}

struct AgentSession: Identifiable, Equatable {
    let id: String
    var source: AgentSource
    var cwd: String
    var project: String
    var phase: AgentPhase
    var detail: String
    var appBundleID: String
    var updatedAt: Date
}

struct ApprovalRequest: Identifiable, Equatable {
    let id: UUID
    let sessionKey: String
    let source: AgentSource
    let project: String
    let command: String
    let createdAt: Date
    let timeout: TimeInterval

    var deadline: Date { createdAt.addingTimeInterval(timeout) }
}

/// Demande d'un agent en attente de réponse.
struct AskRequest: Identifiable, Equatable {
    let id: UUID
    let sessionKey: String
    let source: AgentSource
    let project: String
    let question: String
    let detail: String
    let choices: [String]
    let wantsText: Bool
    let wantsFile: Bool
    let createdAt: Date
    let timeout: TimeInterval

    var deadline: Date { createdAt.addingTimeInterval(timeout) }
}

/// Réponse rendue à l'agent.
enum AskAnswer: Equatable {
    case choice(String)
    case text(String)
    case file(String)
    /// Refus, délai dépassé, ou Aura qui s'arrête.
    case cancelled
}

enum StoreSignal {
    case approvalRequested(ApprovalRequest)
    /// Un agent vient de faire une action pendant son tour.
    case acted(AgentSession)
    /// Un agent pose une question.
    case askRequested(AskRequest)
    case attention(AgentSession)
    case finished(AgentSession)
    case failed(AgentSession)
}

/// État en direct des sessions d'agents et des validations en attente.
@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var approvals: [ApprovalRequest] = []
    @Published private(set) var asks: [AskRequest] = []
    let signals = PassthroughSubject<StoreSignal, Never>()

    private let settings: SettingsStore
    private var completions: [UUID: (Verdict) -> Void] = [:]
    private var askCompletions: [UUID: (AskAnswer) -> Void] = [:]
    private var sweepTimer: Timer?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: Événements

    /// `force` sert au bouton « Tester » : il passe même si le module ou la source est coupé.
    func ingest(_ event: IncomingEvent, force: Bool = false) {
        guard force || accepts(event.source) else { return }
        let key = AgentStore.key(event.source, event.session)

        switch event.kind {
        case .ignore:
            return
        case .ended:
            sessions.removeAll { $0.id == key }
        case .idle:
            guard let existing = sessions.first(where: { $0.id == key }), existing.phase == .working else { return }
            upsert(event, phase: .waiting)
        case .working:
            let session = upsert(event, phase: .working)
            if !event.silent {
                signals.send(.acted(session))
            }
        case .waiting:
            let session = upsert(event, phase: .waiting)
            signals.send(.attention(session))
        case .done:
            let session = upsert(event, phase: .done)
            signals.send(.finished(session))
        case .error:
            let session = upsert(event, phase: .error)
            signals.send(.failed(session))
        }
    }

    // MARK: Validations

    /// Traite une demande de validation. `completion` est appelée une seule fois, tout de suite
    /// (règle automatique) ou plus tard (clic, délai dépassé). Renvoie l'identifiant de la demande
    /// quand elle reste en attente.
    @discardableResult
    func requestApproval(_ request: IncomingApproval,
                         force: Bool = false,
                         completion: @escaping (Verdict) -> Void) -> UUID? {
        let config = settings.s
        guard force || (accepts(request.source) && !request.bypass) else {
            completion(.pass)
            return nil
        }

        let event = IncomingEvent(source: request.source, session: request.session, cwd: request.cwd,
                                  kind: .working, title: "", detail: request.command, app: request.app)
        let session = upsert(event, phase: .working)

        if !force {
            switch ApprovalRules.evaluate(request.command,
                                          autoApprove: config.autoApprove,
                                          alwaysAsk: config.alwaysAsk) {
            case .autoAllow:
                completion(.allow)
                return nil
            case .unlisted:
                if config.unlistedPassthrough {
                    completion(.pass)
                    return nil
                }
            case .mustAsk:
                break
            }
        }

        let approval = ApprovalRequest(id: UUID(), sessionKey: session.id, source: request.source,
                                       project: session.project, command: request.command,
                                       createdAt: Date(), timeout: config.approvalTimeout)
        completions[approval.id] = completion
        approvals.append(approval)
        signals.send(.approvalRequested(approval))

        let id = approval.id
        let fallback = config.defaultDecision
        let nanoseconds = UInt64(max(1, config.approvalTimeout) * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.resolve(id, with: fallback)
        }
        return id
    }

    /// Pose une question de l'agent dans l'encoche. `completion` est appelée une seule fois :
    /// réponse de l'utilisateur, délai dépassé, ou arrêt d'Aura.
    @discardableResult
    func requestAsk(_ request: IncomingAsk,
                    force: Bool = false,
                    completion: @escaping (AskAnswer) -> Void) -> UUID? {
        guard force || accepts(request.source) else {
            completion(.cancelled)
            return nil
        }

        let event = IncomingEvent(source: request.source, session: request.session, cwd: request.cwd,
                                  kind: .waiting, title: "", detail: request.question, app: "")
        let session = upsert(event, phase: .waiting)

        let ask = AskRequest(id: UUID(), sessionKey: session.id, source: request.source,
                             project: session.project, question: request.question,
                             detail: request.detail, choices: request.choices,
                             wantsText: request.wantsText, wantsFile: request.wantsFile,
                             createdAt: Date(), timeout: request.timeout)
        askCompletions[ask.id] = completion
        asks.append(ask)
        signals.send(.askRequested(ask))

        let id = ask.id
        let nanoseconds = UInt64(max(1, request.timeout) * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.answer(id, with: .cancelled)
        }
        return id
    }

    /// Rend la réponse à l'agent. Sans effet si la demande a déjà été répondue.
    func answer(_ id: UUID, with answer: AskAnswer) {
        guard let index = asks.firstIndex(where: { $0.id == id }) else { return }
        let ask = asks.remove(at: index)
        let completion = askCompletions.removeValue(forKey: id)
        touch(ask.sessionKey)
        completion?(answer)
    }

    /// L'agent a coupé : on retire la demande sans répondre.
    func cancelAsk(_ id: UUID) {
        guard let index = asks.firstIndex(where: { $0.id == id }) else { return }
        asks.remove(at: index)
        askCompletions.removeValue(forKey: id)
    }

    /// Répond à une demande en attente. Sans effet si elle a déjà reçu sa réponse.
    func resolve(_ id: UUID, with verdict: Verdict) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        let approval = approvals.remove(at: index)
        let completion = completions.removeValue(forKey: id)
        touch(approval.sessionKey)
        completion?(verdict)
    }

    /// L'agent a coupé la connexion (commande annulée) : on retire la demande sans répondre.
    func cancelApproval(_ id: UUID) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        approvals.remove(at: index)
        completions.removeValue(forKey: id)
    }

    /// Vide tout. Les demandes en attente rendent la main à l'agent (`pass`).
    func clearAll() {
        let pending = completions
        let pendingAsks = askCompletions
        completions.removeAll()
        askCompletions.removeAll()
        approvals.removeAll()
        asks.removeAll()
        sessions.removeAll()
        for (_, completion) in pending {
            completion(.pass)
        }
        for (_, completion) in pendingAsks {
            completion(.cancelled)
        }
    }

    // MARK: Interne

    private static func key(_ source: AgentSource, _ session: String) -> String {
        "\(source.rawValue):\(session)"
    }

    private static func projectName(cwd: String, title: String, source: AgentSource) -> String {
        if !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if !name.isEmpty && name != "/" { return name }
        }
        return title.isEmpty ? source.label : title
    }

    private func accepts(_ source: AgentSource) -> Bool {
        let config = settings.s
        guard config.agentsEnabled else { return false }
        switch source {
        case .claude: return config.claudeEnabled
        case .codex: return config.codexEnabled
        case .cursor: return config.cursorEnabled
        case .other: return true
        }
    }

    @discardableResult
    private func upsert(_ event: IncomingEvent, phase: AgentPhase) -> AgentSession {
        let key = AgentStore.key(event.source, event.session)
        let detail = event.detail.isEmpty ? event.title : event.detail

        if let index = sessions.firstIndex(where: { $0.id == key }) {
            var session = sessions[index]
            if !event.cwd.isEmpty {
                session.cwd = event.cwd
                session.project = AgentStore.projectName(cwd: event.cwd, title: event.title, source: event.source)
            }
            if !event.app.isEmpty { session.appBundleID = event.app }
            session.phase = phase
            session.detail = detail
            session.updatedAt = Date()
            sessions[index] = session
            return session
        }

        let session = AgentSession(
            id: key,
            source: event.source,
            cwd: event.cwd,
            project: AgentStore.projectName(cwd: event.cwd, title: event.title, source: event.source),
            phase: phase,
            detail: detail,
            appBundleID: event.app,
            updatedAt: Date()
        )
        sessions.append(session)
        startSweepIfNeeded()
        return session
    }

    private func touch(_ key: String) {
        guard let index = sessions.firstIndex(where: { $0.id == key }) else { return }
        sessions[index].updatedAt = Date()
    }

    private func startSweepIfNeeded() {
        guard sweepTimer == nil else { return }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sweep()
            }
        }
    }

    /// Retire les sessions terminées (après la durée d'affichage) et celles qui ne donnent plus signe de vie.
    private func sweep() {
        let now = Date()
        let keep = settings.s.doneDisplaySeconds
        let pendingKeys = Set(approvals.map(\.sessionKey)).union(asks.map(\.sessionKey))
        let remaining = sessions.filter { session in
            if pendingKeys.contains(session.id) { return true }
            let age = now.timeIntervalSince(session.updatedAt)
            switch session.phase {
            case .done: return age < keep
            case .error: return age < max(keep * 2, 8)
            case .waiting: return age < 1800
            case .working: return age < 900
            }
        }
        if remaining.count != sessions.count {
            sessions = remaining
        }
        if sessions.isEmpty {
            sweepTimer?.invalidate()
            sweepTimer = nil
        }
    }
}
