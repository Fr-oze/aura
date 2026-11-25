import SwiftUI
import AppKit
import Combine

/// Ouvre une page de Réglages Système > Confidentialité et sécurité.
@MainActor
enum PrivacySettings {
    static func open(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openAccessibility() { open("Privacy_Accessibility") }
    static func openInputMonitoring() { open("Privacy_ListenEvent") }
    static func openFullDiskAccess() { open("Privacy_AllFiles") }

    static func openNotifications() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Durée en secondes avec une décimale et une virgule (« 0,9 s »).
private func secondsLabel(_ value: Double) -> String {
    String(format: "%.1f s", value).replacingOccurrences(of: ".", with: ",")
}

// MARK: - Raccourcis

@MainActor
struct EchoPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var echo: ShortcutEcho

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Écho des raccourcis") {
                Toggle("L'encoche réagit à mes raccourcis clavier", isOn: $settings.s.echoEnabled)
                    .onChange(of: settings.s.echoEnabled) { _, enabled in
                        // La demande d'autorisation ne part qu'au moment où tu actives le module.
                        if enabled {
                            echo.refreshTrust()
                            if !echo.hasAccess {
                                echo.requestTrust()
                            }
                        }
                    }
                if settings.s.echoEnabled {
                    accessStatus
                }
                HStack {
                    Button("Tester : Copié") { AppState.shared.testEcho(.copy) }
                    Button("Tester : Capture") { AppState.shared.testEcho(.screenshot) }
                    Spacer()
                }
                Text("L'encoche s'élargit un instant à chaque raccourci (icône à gauche, libellé à droite), puis se referme. La copie est détectée même sans autorisation (compteur du presse-papiers) ; les autres raccourcis demandent Accessibilité. Aura lit seulement la combinaison de touches, jamais ce que tu tapes, et rien ne quitte ton Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Raccourcis reconnus") {
                ForEach(EchoShortcut.allCases) { shortcut in
                    Toggle(isOn: shortcutBinding(shortcut)) {
                        HStack(spacing: 10) {
                            Image(systemName: shortcut.symbol)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            Text(shortcut.label)
                            Spacer()
                            Text(shortcut.keys)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("⌘Tab est toujours ignoré.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rendu") {
                SliderRow(title: "Durée d'affichage",
                          value: $settings.s.echoDuration,
                          range: 0.5...2.5,
                          display: { secondsLabel($0) })
                Toggle("Petit éclat du halo à chaque écho", isOn: $settings.s.echoHaloFlash)
                Toggle("Clic discret à chaque écho", isOn: $settings.s.echoSound)
            }

            Section("Volume et luminosité") {
                Text("Le volume et la luminosité se règlent maintenant dans Réglages > Encoche. Ils marchent même si l'écho des raccourcis est coupé.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Historique du presse-papiers") {
                Toggle("Garder les \(ShortcutEcho.historyLimit) derniers textes copiés", isOn: $settings.s.clipHistoryEnabled)
                Toggle("Le conserver entre deux lancements", isOn: $settings.s.clipPersist)
                    .disabled(!settings.s.clipHistoryEnabled)
                HStack {
                    Text(echo.clips.isEmpty ? "Historique vide" : "\(echo.clips.count) texte(s) en mémoire")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Vider l'historique") {
                        echo.clearClips()
                    }
                    .disabled(echo.clips.isEmpty)
                }
                Text("En mémoire seulement par défaut. Si tu le conserves, il est écrit en clair dans les préférences d'Aura. Les contenus marqués comme mots de passe (1Password, Bitwarden, Trousseau…) ne sont jamais gardés. Survole l'encoche (onglet Presse-papiers) ou ouvre le menu d'Aura pour recopier un ancien texte.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            echo.refreshTrust()
        }
        .onReceive(poll) { _ in
            if settings.s.echoEnabled {
                echo.refreshTrust()
            }
        }
    }

    private func shortcutBinding(_ shortcut: EchoShortcut) -> Binding<Bool> {
        Binding(
            get: { !settings.s.echoDisabled.contains(shortcut.rawValue) },
            set: { enabled in
                var list = settings.s.echoDisabled.filter { $0 != shortcut.rawValue }
                if !enabled {
                    list.append(shortcut.rawValue)
                }
                settings.s.echoDisabled = list
            }
        )
    }

    @ViewBuilder
    private var accessStatus: some View {
        if echo.hasAccess {
            Label(echo.trusted ? "Accessibilité autorisée : Aura voit tes raccourcis."
                               : "Surveillance de l'entrée autorisée : Aura voit tes raccourcis.",
                  systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(AuraPalette.done)
            Text("Si rien ne sort alors que c'est autorisé : quitte et relance Aura. Après une recompilation, retire Aura de la liste puis autorise-la à nouveau.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Autorisation manquante. macOS ne laisse une app voir les raccourcis tapés dans les autres apps que si elle est cochée dans Accessibilité (ou dans Surveillance de l'entrée).",
                      systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(AuraPalette.attention)
                HStack {
                    Button("Ouvrir Accessibilité") {
                        PrivacySettings.openAccessibility()
                    }
                    Button("Ouvrir Surveillance de l'entrée") {
                        PrivacySettings.openInputMonitoring()
                    }
                    Button("Redemander") {
                        echo.requestTrust()
                    }
                }
                Text("Coche Aura dans la liste, puis quitte et relance Aura.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Notifications

enum NoticeAppMode: String, CaseIterable {
    case normal, priority, ignored

    var label: String {
        switch self {
        case .normal: return "Normale"
        case .priority: return "Prioritaire"
        case .ignored: return "Ignorée"
        }
    }
}

@MainActor
struct NoticesPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var notices: NotificationWatcher

    var body: some View {
        Form {
            Section("Notifications dans l'encoche") {
                Toggle("Montrer les notifications des autres apps dans l'encoche", isOn: $settings.s.noticesEnabled)
                if settings.s.noticesEnabled {
                    status
                }
                HStack {
                    Button("Tester une notification") { AppState.shared.testNotice() }
                    Spacer()
                }
                Text("macOS n'offre aucun moyen officiel de lire les notifications des autres apps. Aura lit donc, en lecture seule, la base du Centre de notifications. Rien n'y est modifié et rien ne quitte ton Mac. macOS n'y écrit une notification que quelques secondes après l'avoir reçue : l'encoche s'ouvre avec ce léger retard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Affichage") {
                SliderRow(title: "Durée d'affichage",
                          value: $settings.s.noticeDuration,
                          range: 2...15,
                          display: { "\(Int($0.rounded())) s" })
                Toggle("Ne pas déranger (Aura seulement)", isOn: $settings.s.noticeDND)
                Text("Les notifications sont gardées dans la liste mais l'encoche ne s'ouvre plus, sauf pour les apps prioritaires.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Son discret à l'arrivée", isOn: $settings.s.noticeSound)
            }

            Section("Apps") {
                if notices.knownApps.isEmpty {
                    Text("Les apps apparaîtront ici dès qu'Aura aura vu une de leurs notifications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(notices.knownApps) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: AppLookup.icon(for: app.id))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(app.name)
                                .lineLimit(1)
                            Spacer()
                            Picker("", selection: modeBinding(app.id)) {
                                ForEach(NoticeAppMode.allCases, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }
                    Text("Prioritaire : le panneau reste deux fois plus longtemps et s'ouvre même en « Ne pas déranger ». Ignorée : jamais affichée ni gardée.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Liste") {
                HStack {
                    Text(notices.items.isEmpty ? "Aucune notification gardée" : "\(notices.items.count) notification(s) dans la liste d'Aura")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Tout effacer") {
                        notices.clear()
                    }
                    .disabled(notices.items.isEmpty)
                }
                Text("Survole l'encoche (onglet Notifications) pour voir les dernières. « Tout effacer » vide la liste d'Aura, pas le Centre de notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Astuce") {
                Text("Pour ne voir les notifs d'une app que dans l'encoche : Réglages Système > Notifications > l'app, laisse « Autoriser les notifications » et « Centre de notifications » activés, et décoche « Bureau » (sur macOS 14 : style d'alerte « Aucun »). La bannière de macOS disparaît, la notification reste enregistrée, donc Aura la voit toujours. Si tu décoches aussi « Centre de notifications », macOS ne l'enregistre plus et Aura ne la verra pas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Ouvrir Réglages Système > Notifications") {
                    PrivacySettings.openNotifications()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func mode(of bundleID: String) -> NoticeAppMode {
        let key = bundleID.lowercased()
        if settings.s.noticeIgnored.contains(where: { $0.lowercased() == key }) { return .ignored }
        if settings.s.noticePriority.contains(where: { $0.lowercased() == key }) { return .priority }
        return .normal
    }

    private func modeBinding(_ bundleID: String) -> Binding<NoticeAppMode> {
        Binding(
            get: { mode(of: bundleID) },
            set: { chosen in
                let key = bundleID.lowercased()
                // Une seule écriture : les deux listes changent ensemble.
                var updated = settings.s
                updated.noticeIgnored.removeAll { $0.lowercased() == key }
                updated.noticePriority.removeAll { $0.lowercased() == key }
                switch chosen {
                case .normal: break
                case .priority: updated.noticePriority.append(bundleID)
                case .ignored: updated.noticeIgnored.append(bundleID)
                }
                settings.s = updated
            }
        )
    }

    @ViewBuilder
    private var status: some View {
        switch notices.status {
        case .running:
            Label("Accès complet au disque accordé : Aura lit les notifications.", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(AuraPalette.done)
            if !notices.databasePath.isEmpty {
                Text(notices.databasePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        case .starting, .off:
            Label("Recherche de la base des notifications…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .noAccess:
            VStack(alignment: .leading, spacing: 8) {
                Label("Accès complet au disque manquant. La base des notifications est protégée par macOS : sans cette autorisation, Aura ne peut pas l'ouvrir et le module reste inactif.",
                      systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(AuraPalette.attention)
                accessButtons
                Text("Ajoute ou coche Aura dans la liste, puis quitte et relance Aura.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notFound:
            VStack(alignment: .leading, spacing: 8) {
                Label("Base des notifications introuvable sur ce Mac. Le module reste inactif.",
                      systemImage: "questionmark.folder")
                    .font(.caption)
                    .foregroundStyle(AuraPalette.error)
                accessButtons
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Base des notifications illisible : \(message). Le module reste inactif.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AuraPalette.error)
                    .textSelection(.enabled)
                accessButtons
            }
        }
    }

    private var accessButtons: some View {
        HStack {
            Button("Ouvrir Accès complet au disque") {
                PrivacySettings.openFullDiskAccess()
            }
            Button("Revérifier") {
                notices.recheck()
            }
        }
    }
}
