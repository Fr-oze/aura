import SwiftUI
import AppKit
import ServiceManagement

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, notch, agents, echo, notices, agenda, weather, halo, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "Général"
        case .notch: return "Encoche"
        case .agenda: return "Agenda & rappels"
        case .weather: return "Météo"
        case .agents: return "Agents"
        case .echo: return "Raccourcis"
        case .notices: return "Notifications"
        case .halo: return "Halo"
        case .about: return "À propos"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notch: return "rectangle.topthird.inset.filled"
        case .agenda: return "calendar.badge.clock"
        case .weather: return "cloud.sun"
        case .agents: return "terminal"
        case .echo: return "keyboard"
        case .notices: return "bell.badge"
        case .halo: return "sparkles"
        case .about: return "info.circle"
        }
    }
}

@MainActor
struct SettingsView: View {
    @State private var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsPane.allCases) { item in
                    Button {
                        pane = item
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol)
                                .frame(width: 18)
                            Text(item.label)
                            Spacer()
                        }
                        .font(.system(size: 13, weight: pane == item ? .semibold : .regular))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(pane == item ? Color.accentColor.opacity(0.22) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 176)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))

            Divider()

            Group {
                switch pane {
                case .general: GeneralPane()
                case .notch: NotchPane()
                case .agenda: AgendaPane()
                case .weather: WeatherPane()
                case .agents: AgentsPane()
                case .echo: EchoPane()
                case .notices: NoticesPane()
                case .halo: HaloPane()
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 800, height: 580)
    }
}

// MARK: - Composants

/// Curseur avec son titre et sa valeur affichée à droite.
@MainActor
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                    .frame(minWidth: 180)
                Text(display(value))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }
}

/// Liste de règles : une ligne par règle, un bouton pour retirer, un champ pour ajouter.
@MainActor
struct RuleListEditor: View {
    @Binding var items: [String]
    let placeholder: String
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 8) {
                    Text(item)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Retirer cette règle")
                }
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit {
                        add()
                    }
                Button("Ajouter") {
                    add()
                }
                .disabled(draft.trimmed.isEmpty)
            }
        }
    }

    private func add() {
        let rule = draft.trimmed
        guard !rule.isEmpty else { return }
        if !items.contains(rule) {
            items.append(rule)
        }
        draft = ""
    }

    private func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
    }
}

struct AppPreset: Identifiable {
    let name: String
    let id: String
}

/// Identifiant de bundle à saisir, avec quelques apps courantes en raccourci.
@MainActor
struct AppIdentifierRow: View {
    let title: String
    @Binding var bundleID: String

    private static let presets: [AppPreset] = [
        AppPreset(name: "Automatique (app détectée)", id: ""),
        AppPreset(name: "Terminal", id: "com.apple.Terminal"),
        AppPreset(name: "iTerm", id: "com.googlecode.iterm2"),
        AppPreset(name: "Warp", id: "dev.warp.Warp-Stable"),
        AppPreset(name: "Ghostty", id: "com.mitchellh.ghostty"),
        AppPreset(name: "Cursor", id: "com.todesktop.230313mzl4w4u92"),
        AppPreset(name: "VS Code", id: "com.microsoft.VSCode")
    ]

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField("Automatique", text: $bundleID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 200)
                Menu("Choisir") {
                    ForEach(AppIdentifierRow.presets) { preset in
                        Button(preset.name) {
                            bundleID = preset.id
                        }
                    }
                }
                .fixedSize()
            }
        }
    }
}

// MARK: - Général

@MainActor
struct GeneralPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var launchAtLogin = false
    @State private var loginError = ""
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Démarrage") {
                Toggle("Lancer Aura à l'ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wanted in
                        applyLaunchAtLogin(wanted)
                    }
                if !loginError.isEmpty {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(AuraPalette.error)
                }
            }

            Section("Retours") {
                Toggle("Son discret à chaque changement d'état", isOn: $settings.s.soundEnabled)
                Toggle("Notifications macOS", isOn: $settings.s.notificationsEnabled)
            }

            Section("Écran") {
                Picker("Afficher Aura sur", selection: $settings.s.screenName) {
                    Text("Automatique (écran à encoche)").tag("")
                    ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Text("Vaut pour l'encoche (agents, volume, musique, notifications) et pour le halo. Sur un écran sans encoche, Aura en dessine une virtuelle en haut au centre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Réinitialiser tous les réglages…", role: .destructive) {
                    confirmReset = true
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .confirmationDialog("Remettre tous les réglages d'Aura à leur valeur d'origine ?",
                            isPresented: $confirmReset) {
            Button("Réinitialiser", role: .destructive) {
                settings.reset()
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Les hooks installés chez les agents ne sont pas touchés.")
        }
    }

    private func applyLaunchAtLogin(_ wanted: Bool) {
        let enabled = SMAppService.mainApp.status == .enabled
        guard wanted != enabled else { return }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = ""
        } catch {
            loginError = "Impossible de changer ce réglage : \(error.localizedDescription)"
            launchAtLogin = enabled
        }
    }
}

// MARK: - Agents

@MainActor
struct AgentsPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var serverStatus: ServerStatus

    @State private var installed: [HookTarget: Bool] = [:]
    @State private var hookMessage = ""
    @State private var codexConflict = ""
    @State private var showCodexConflict = false

    var body: some View {
        Form {
            Section("Module") {
                Toggle("Suivre les agents dans l'encoche", isOn: $settings.s.agentsEnabled)
                LabeledContent("Serveur local") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(serverStatus.isRunning ? AuraPalette.done : AuraPalette.error)
                            .frame(width: 7, height: 7)
                        Text(serverStatus.text)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Port") {
                    TextField("47823", value: $settings.s.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }

            Section("Validations") {
                SliderRow(title: "Délai de réponse",
                          value: $settings.s.approvalTimeout,
                          range: 10...300,
                          display: { "\(Int($0.rounded())) s" })
                Picker("Sans réponse dans le délai", selection: $settings.s.defaultDecision) {
                    Text("Demander dans l'agent").tag(Verdict.ask)
                    Text("Autoriser").tag(Verdict.allow)
                    Text("Refuser").tag(Verdict.deny)
                }
                Toggle("Laisser l'agent gérer les commandes hors listes", isOn: $settings.s.unlistedPassthrough)
                Text("Décoché : toute commande qui n'est pas routinière passe par l'encoche. Coché : seules les commandes « toujours demander » y passent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Commandes routinières (autorisées d'office)") {
                RuleListEditor(items: $settings.s.autoApprove, placeholder: "ex. git status  ou  re:^npm run \\w+$")
            }

            Section("Toujours demander") {
                RuleListEditor(items: $settings.s.alwaysAsk, placeholder: "ex. git push")
                Text("Une règle est un début de commande, ou une expression régulière précédée de re:. Une commande composée (&&, |, ;) n'est autorisée d'office que si chaque partie est routinière.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sources") {
                Toggle("Claude Code", isOn: $settings.s.claudeEnabled)
                Toggle("Codex", isOn: $settings.s.codexEnabled)
                Toggle("Cursor", isOn: $settings.s.cursorEnabled)
                Toggle("Voir Codex travailler (journal de session)", isOn: $settings.s.codexWatch)
                    .disabled(!settings.s.codexEnabled)
                Text("Le `notify` de Codex ne signale que la fin d'un tour. Avec ce réglage, Aura regarde la date du journal le plus récent dans ~/.codex/sessions pour afficher aussi « au travail ». Rien n'est lu du contenu, à part le dossier du projet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Affichage") {
                Toggle("Ouvrir les ailes de l'encoche pendant que l'agent travaille", isOn: $settings.s.showWhileWorking)
                SliderRow(title: "Durée d'affichage après « terminé »",
                          value: $settings.s.doneDisplaySeconds,
                          range: 2...15,
                          display: { "\(Int($0.rounded())) s" })
            }

            Section("App à ouvrir au clic sur une session") {
                AppIdentifierRow(title: "Claude Code", bundleID: $settings.s.claudeApp)
                AppIdentifierRow(title: "Codex", bundleID: $settings.s.codexApp)
                AppIdentifierRow(title: "Cursor", bundleID: $settings.s.cursorApp)
            }

            Section("Hooks") {
                ForEach(HookTarget.allCases) { target in
                    hookRow(target)
                }
                HStack {
                    Button("Tout installer") {
                        for target in HookTarget.allCases {
                            install(target, replace: false)
                        }
                    }
                    Button("Désinstaller les hooks") {
                        uninstallAll()
                    }
                    Spacer()
                }
                if !hookMessage.isEmpty {
                    Text(hookMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Chaque fichier est sauvegardé (.bak horodaté) avant d'être modifié. Redémarre l'agent après l'installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Questions posées par tes agents") {
                Text("Aura installe la commande `~/.aura/bin/aura`. Un agent qui l'appelle pose sa question dans l'encoche et attend ta réponse — choix, texte libre ou fichier — sans que tu ouvres son terminal.")
                    .font(.caption)
                Text(AgentBriefing.example)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))

                Label(AgentBriefing.isInstalled ? "Commande installée" : "Commande absente : relance Aura",
                      systemImage: AgentBriefing.isInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AgentBriefing.isInstalled ? .secondary : Color.orange)

                HStack {
                    Button("Copier les consignes pour l'agent") {
                        copy(AgentBriefing.instructions)
                        hookMessage = "Consignes copiées. Colle-les dans le CLAUDE.md, AGENTS.md ou la règle Cursor de ton projet."
                    }
                    Button("Copier l'exemple") {
                        copy(AgentBriefing.example)
                        hookMessage = "Exemple copié."
                    }
                    Button("Tester") {
                        AppState.shared.testAsk()
                    }
                    Spacer()
                }
                Text("À faire une fois par agent : coller ces consignes dans ses instructions. Sans ça, il ne saura jamais que la commande existe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tester l'encoche") {
                HStack {
                    Button("Travail") { AppState.shared.runTest(.working) }
                    Button("Validation") { AppState.shared.runTest(.approval) }
                    Button("Terminé") { AppState.shared.runTest(.done) }
                    Button("Erreur") { AppState.shared.runTest(.error) }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshHooks()
        }
        .alert("Codex a déjà une commande « notify »", isPresented: $showCodexConflict) {
            Button("Remplacer", role: .destructive) {
                install(.codex, replace: true)
            }
            Button("Garder l'actuelle", role: .cancel) { }
        } message: {
            Text("Valeur actuelle :\n\(codexConflict)\n\nSi tu remplaces, l'ancienne ligne est gardée en commentaire et remise à la désinstallation.")
        }
    }

    private func hookRow(_ target: HookTarget) -> some View {
        let isInstalled = installed[target] ?? false
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.label)
                Text("~/" + target.relativePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(isInstalled ? "installé" : "pas installé")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isInstalled ? AuraPalette.done : Color.secondary)
            Button(isInstalled ? "Mettre à jour" : "Installer") {
                install(target, replace: false)
            }
            Button("Retirer") {
                uninstall(target)
            }
            .disabled(!isInstalled)
        }
    }

    private func refreshHooks() {
        var state: [HookTarget: Bool] = [:]
        for target in HookTarget.allCases {
            state[target] = HookInstaller.isInstalled(target)
        }
        installed = state
    }

    private func install(_ target: HookTarget, replace: Bool) {
        let config = settings.s
        let outcome = HookInstaller.install(target,
                                            port: config.port,
                                            timeout: config.approvalTimeout,
                                            replaceCodexNotify: replace)
        switch outcome {
        case .installed(let backup):
            if let backup {
                hookMessage = "\(target.label) : hooks installés. Sauvegarde : \(backup)"
            } else {
                hookMessage = "\(target.label) : hooks installés (fichier créé)."
            }
        case .conflict(let existing):
            codexConflict = existing
            showCodexConflict = true
        case .failed(let message):
            hookMessage = "\(target.label) : échec. \(message)"
        }
        refreshHooks()
    }

    private func uninstall(_ target: HookTarget) {
        if let problem = HookInstaller.uninstall(target) {
            hookMessage = "\(target.label) : échec. \(problem)"
        } else {
            hookMessage = "\(target.label) : hooks retirés."
        }
        refreshHooks()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func uninstallAll() {
        var problems: [String] = []
        for target in HookTarget.allCases {
            if let problem = HookInstaller.uninstall(target) {
                problems.append("\(target.label) : \(problem)")
            }
        }
        hookMessage = problems.isEmpty ? "Tous les hooks d'Aura sont retirés." : problems.joined(separator: "\n")
        refreshHooks()
    }
}

// MARK: - Halo

@MainActor
struct HaloPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var audio: AudioEngine
    @EnvironmentObject private var palette: HaloPalette

    var body: some View {
        Form {
            Section("Halo musical") {
                Toggle("Activer le halo autour de l'écran", isOn: $settings.s.haloEnabled)
                if settings.s.haloEnabled {
                    audioStatus
                }
                HStack(alignment: .center, spacing: 16) {
                    HaloPreview(first: previewColors.0,
                                second: previewColors.1,
                                ratio: settings.s.haloRatio,
                                thickness: settings.s.haloThickness,
                                intensity: settings.s.haloIntensity,
                                corner: settings.s.haloCorner)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Le halo réel suit tes réglages en direct.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Simuler de la musique 6 s") {
                            AppState.shared.demoHalo()
                        }
                        .disabled(!settings.s.haloEnabled)
                    }
                }
            }

            Section("Couleurs") {
                Picker("Source", selection: $settings.s.haloColorMode) {
                    ForEach(HaloColorMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if settings.s.haloColorMode == .artwork {
                    Text(artworkText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !palette.note.isEmpty {
                        Text(palette.note)
                            .font(.caption)
                            .foregroundStyle(AuraPalette.attention)
                    }
                }
                if settings.s.haloColorMode != .spectrum {
                    ColorPicker(colorTitle(1), selection: colorBinding(\.haloColor1), supportsOpacity: false)
                    ColorPicker(colorTitle(2), selection: colorBinding(\.haloColor2), supportsOpacity: false)
                }
                SliderRow(title: "Part de la couleur 1",
                          value: $settings.s.haloRatio,
                          range: 0.15...0.85,
                          display: { "\(Int(($0 * 100).rounded())) %" })
            }

            Section("Forme") {
                SliderRow(title: "Épaisseur",
                          value: $settings.s.haloThickness,
                          range: 12...120,
                          display: { "\(Int($0.rounded())) pt" })
                SliderRow(title: "Intensité",
                          value: $settings.s.haloIntensity,
                          range: 0.1...1,
                          display: { "\(Int(($0 * 100).rounded())) %" })
                SliderRow(title: "Coins arrondis",
                          value: $settings.s.haloCorner,
                          range: 0...SettingsStore.maxHaloCorner,
                          display: { "\(Int($0.rounded())) pt" })
                Text("Rayon intérieur de la lueur. La lueur remplit toujours le coin jusqu'au vrai bord de l'écran ; pour vérifier le contour utilisé, active « Afficher le contour » dans Réglages > Encoche.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Contourner l'encoche", isOn: $settings.s.haloAvoidNotch)
                Toggle("Faire tourner lentement le dégradé pendant la musique", isOn: $settings.s.haloDrift)
            }

            Section("Réaction à la musique") {
                SliderRow(title: "Réactivité",
                          value: $settings.s.haloReactivity,
                          range: 0...1.6,
                          display: { "\(Int(($0 * 100).rounded())) %" })
                SliderRow(title: "Attaque (montée)",
                          value: $settings.s.haloAttack,
                          range: 0.1...1,
                          display: { "\(Int(($0 * 100).rounded())) %" })
                SliderRow(title: "Relâchement (descente)",
                          value: $settings.s.haloRelease,
                          range: 0.02...0.5,
                          display: { "\(Int(($0 * 100).rounded())) %" })
                Picker("Sans musique", selection: $settings.s.haloRest) {
                    ForEach(HaloRest.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section("Avec les agents") {
                Toggle("Orange pulsé quand un agent attend une validation", isOn: $settings.s.haloApprovalPulse)
                Toggle("Éclat vert quand une tâche se termine (rouge en cas d'erreur)", isOn: $settings.s.haloDoneFlash)
                Text("Ces deux effets marchent même si le halo musical est coupé.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Captures") {
                Toggle("Cacher le halo dans les captures et partages d'écran", isOn: $settings.s.haloHideFromCapture)
            }
        }
        .formStyle(.grouped)
    }

    private var previewColors: (RGB, RGB) {
        if settings.s.haloColorMode == .artwork, let first = palette.first, let second = palette.second {
            return (first, second)
        }
        if settings.s.haloColorMode == .spectrum {
            return (RGB(r: 0.55, g: 0.3, b: 1.0), RGB(r: 1.0, g: 0.35, b: 0.75))
        }
        return (settings.s.haloColor1, settings.s.haloColor2)
    }

    private var artworkText: String {
        if palette.first != nil && !palette.track.isEmpty {
            return "Couleurs tirées de : \(palette.track)"
        }
        return "Lance un morceau dans Spotify ou Musique : les couleurs suivront la pochette. En attendant, les deux couleurs ci-dessous servent de repli."
    }

    private func colorTitle(_ number: Int) -> String {
        let suffix = settings.s.haloColorMode == .artwork ? " (sans pochette)" : ""
        return "Couleur \(number)\(suffix)"
    }

    private func colorBinding(_ keyPath: WritableKeyPath<AuraSettings, RGB>) -> Binding<Color> {
        Binding(
            get: { settings.s[keyPath: keyPath].color },
            set: { settings.s[keyPath: keyPath] = RGB(color: $0) }
        )
    }

    @ViewBuilder
    private var audioStatus: some View {
        switch audio.state {
        case .running:
            Label("Écoute du son du Mac en cours", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(AuraPalette.done)
        case .starting:
            Label("Démarrage de l'écoute…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .stopped:
            EmptyView()
        case .needsPermission:
            VStack(alignment: .leading, spacing: 8) {
                Label("Aura a besoin de l'autorisation « Enregistrement de l'écran et de l'audio système » pour entendre la musique. Rien n'est enregistré ni envoyé : seul le niveau sonore est analysé, sur ton Mac.",
                      systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(AuraPalette.attention)
                HStack {
                    Button("Demander l'autorisation") {
                        AudioEngine.requestPermission()
                    }
                    Button("Ouvrir Réglages Système") {
                        HaloPane.openScreenRecordingSettings()
                    }
                    Button("Réessayer") {
                        AppState.shared.retryAudio()
                    }
                }
                Text("Après avoir coché Aura dans la liste, quitte puis relance l'app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Écoute impossible : \(message)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AuraPalette.error)
                HStack {
                    Button("Réessayer") {
                        AppState.shared.retryAudio()
                    }
                    Button("Ouvrir Réglages Système") {
                        HaloPane.openScreenRecordingSettings()
                    }
                }
            }
        }
    }

    private static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Aperçu miniature du halo dans les réglages.
@MainActor
struct HaloPreview: View {
    let first: RGB
    let second: RGB
    let ratio: Double
    let thickness: Double
    let intensity: Double
    let corner: Double

    var body: some View {
        let share = CGFloat(min(max(ratio, 0.15), 0.85))
        let gradient = AngularGradient(
            gradient: Gradient(stops: [
                .init(color: first.color, location: 0),
                .init(color: first.color, location: max(0.02, share - 0.12)),
                .init(color: second.color, location: share),
                .init(color: second.color, location: 0.88),
                .init(color: first.color, location: 1)
            ]),
            center: .center
        )
        let line = CGFloat(max(3, thickness * 0.22))
        let radius = CGFloat(6 + corner * 0.2)

        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.black)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(gradient, lineWidth: line)
                .blur(radius: line * 0.45)
                .opacity(intensity)
        }
        .frame(width: 210, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - À propos

@MainActor
struct AboutPane: View {
    @EnvironmentObject private var settings: SettingsStore

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "aqi.medium")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [settings.s.haloColor1.color, settings.s.haloColor2.color],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
            Text("Aura")
                .font(.system(size: 28, weight: .bold))
            Text("Version \(version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("L'encoche qui se transforme : agents de code, volume, musique, météo, notifications,\net un halo qui respire avec ta musique.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Text("Tout tourne sur ton Mac : le serveur n'écoute que sur 127.0.0.1 et aucun son n'est enregistré.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
