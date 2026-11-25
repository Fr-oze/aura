import SwiftUI
import AppKit

/// Icône de la barre de menus : elle change selon ce que font les agents.
@MainActor
struct MenuBarIcon: View {
    @EnvironmentObject private var store: AgentStore

    private var symbol: String {
        if !store.approvals.isEmpty { return "exclamationmark.circle.fill" }
        if store.sessions.contains(where: { $0.phase == .waiting }) { return "exclamationmark.circle" }
        if store.sessions.contains(where: { $0.phase == .working }) { return "ellipsis.circle" }
        return "aqi.medium"
    }

    var body: some View {
        Image(systemName: symbol)
    }
}

/// Contenu de la fenêtre qui s'ouvre depuis la barre de menus.
@MainActor
struct MenuView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var store: AgentStore
    @EnvironmentObject private var audio: AudioEngine
    @EnvironmentObject private var serverStatus: ServerStatus
    @EnvironmentObject private var echo: ShortcutEcho
    @EnvironmentObject private var notices: NotificationWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            sessionsSection
            Divider()
            Toggle("Agents dans l'encoche", isOn: $settings.s.agentsEnabled)
                .toggleStyle(.switch)
            Toggle("Halo musical", isOn: $settings.s.haloEnabled)
                .toggleStyle(.switch)
            if settings.s.haloEnabled {
                haloSection
            }
            Toggle("Écho des raccourcis", isOn: $settings.s.echoEnabled)
                .toggleStyle(.switch)
            if settings.s.echoEnabled && !echo.hasAccess {
                Text("Autorise Aura dans Réglages > Raccourcis.")
                    .font(.system(size: 11))
                    .foregroundStyle(AuraPalette.attention)
            }
            Toggle("Notifications dans l'encoche", isOn: $settings.s.noticesEnabled)
                .toggleStyle(.switch)
            if settings.s.noticesEnabled {
                noticesSection
            }
            if settings.s.clipHistoryEnabled && !echo.clips.isEmpty {
                Divider()
                clipboardSection
            }
            Divider()
            HStack {
                Button("Réglages…") {
                    AppState.shared.openSettings()
                }
                Spacer()
                Button("Quitter") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 310)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "aqi.medium")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AuraPalette.working)
            Text("Aura")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statusColor: Color {
        if !settings.s.agentsEnabled { return .gray }
        return serverStatus.isRunning ? AuraPalette.done : AuraPalette.error
    }

    private var statusText: String {
        if !settings.s.agentsEnabled { return "Agents coupés" }
        return serverStatus.isRunning ? "Port \(String(settings.s.port))" : "Serveur hors service"
    }

    @ViewBuilder
    private var sessionsSection: some View {
        if store.sessions.isEmpty && store.approvals.isEmpty {
            Text("Aucun agent actif")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !store.approvals.isEmpty {
                    Label("\(store.approvals.count) validation(s) en attente", systemImage: "hand.raised.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AuraPalette.attention)
                }
                ForEach(store.sessions) { session in
                    Button {
                        AppState.shared.activate(session)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: session.source.symbol)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(session.source.tint)
                                .frame(width: 16)
                            Text(session.project)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(MenuView.phaseLabel(session.phase))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Circle()
                                .fill(AuraPalette.color(for: session.phase))
                                .frame(width: 7, height: 7)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private static func phaseLabel(_ phase: AgentPhase) -> String {
        switch phase {
        case .working: return "au travail"
        case .waiting: return "attend ta réponse"
        case .done: return "terminé"
        case .error: return "erreur"
        }
    }

    @ViewBuilder
    private var noticesSection: some View {
        switch notices.status {
        case .noAccess:
            Text("Autorise l'Accès complet au disque dans Réglages > Notifications.")
                .font(.system(size: 11))
                .foregroundStyle(AuraPalette.attention)
        case .notFound, .failed:
            Text("Base des notifications illisible (voir Réglages > Notifications).")
                .font(.system(size: 11))
                .foregroundStyle(AuraPalette.error)
        case .off, .starting, .running:
            HStack {
                Toggle("Ne pas déranger", isOn: $settings.s.noticeDND)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                if !notices.items.isEmpty {
                    Button("Effacer (\(notices.items.count))") {
                        notices.clear()
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }

    /// Historique du presse-papiers : un clic recopie le texte.
    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Presse-papiers")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Vider") {
                    echo.clearClips()
                }
                .font(.system(size: 11))
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(echo.clips) { clip in
                        Button {
                            echo.recopy(clip)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(clip.preview)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Recopier ce texte")
                    }
                }
            }
            .frame(height: min(150, CGFloat(echo.clips.count) * 23))
        }
    }

    @ViewBuilder
    private var haloSection: some View {
        switch audio.state {
        case .running:
            MiniVisualizer(audio: audio)
        case .starting:
            Text("Démarrage de l'écoute…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .needsPermission:
            Text("Autorise l'enregistrement de l'écran dans Réglages > Halo.")
                .font(.system(size: 11))
                .foregroundStyle(AuraPalette.attention)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(AuraPalette.error)
                .lineLimit(2)
        case .stopped:
            EmptyView()
        }
    }
}

/// Petit spectre en barres, redessiné une vingtaine de fois par seconde tant que le menu est ouvert.
@MainActor
struct MiniVisualizer: View {
    let audio: AudioEngine
    @State private var visible = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !visible)) { _ in
            let bars = audio.snapshot().bars
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<bars.count, id: \.self) { index in
                    Capsule()
                        .fill(AuraPalette.working.opacity(0.45 + 0.55 * Double(bars[index])))
                        .frame(height: 3 + CGFloat(bars[index]) * 30)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 34, alignment: .bottom)
        }
        .frame(height: 34)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}
