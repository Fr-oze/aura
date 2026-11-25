import AppKit
import SwiftUI
import Combine

/// État du serveur local, affiché dans le menu et les réglages.
@MainActor
final class ServerStatus: ObservableObject {
    @Published var state: ServerState = .stopped

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var text: String {
        switch state {
        case .stopped: return "Serveur arrêté"
        case .running(let port): return "À l'écoute sur 127.0.0.1:\(port)"
        case .failed(let message): return message
        }
    }
}

enum TestScenario {
    case working, approval, done, error
}

/// Point central : crée les modules, les relie et route les requêtes des hooks.
@MainActor
final class AppState {
    static let shared = AppState()

    let settings: SettingsStore
    let store: AgentStore
    let serverStatus: ServerStatus
    let audio: AudioEngine
    let palette: HaloPalette
    let echo: ShortcutEcho
    let notices: NotificationWatcher
    let music: MusicState
    let weather: WeatherService
    let calendar: CalendarService
    let pomodoro: Pomodoro
    let battery: BatteryWatcher
    let water: WaterReminder

    private let codexWatcher: CodexWatcher
    private let server: EventServer
    private let nowPlaying: NowPlaying
    private let feedback: Feedback
    private var notch: NotchEngine?
    private var overlay: OverlayController?
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()
    private var started = false
    private var appliedEnabled: Bool?
    private var appliedPort: Int?

    private struct ServerKey: Equatable {
        var enabled: Bool
        var port: Int
        var timeout: Double
    }

    private struct ListenKey: Equatable {
        var keys: Bool
        var media: Bool
    }

    private init() {
        let settings = SettingsStore()
        let palette = HaloPalette()
        let music = MusicState()
        self.settings = settings
        self.music = music
        self.weather = WeatherService(settings: settings)
        self.store = AgentStore(settings: settings)
        self.serverStatus = ServerStatus()
        self.audio = AudioEngine()
        self.palette = palette
        self.echo = ShortcutEcho(settings: settings)
        self.notices = NotificationWatcher(settings: settings)
        self.calendar = CalendarService(settings: settings)
        self.pomodoro = Pomodoro(settings: settings)
        self.battery = BatteryWatcher(settings: settings)
        self.water = WaterReminder(settings: settings)
        self.codexWatcher = CodexWatcher(settings: settings)
        self.server = EventServer()
        self.nowPlaying = NowPlaying(palette: palette, music: music)
        self.feedback = Feedback()
    }

    // MARK: Cycle de vie

    func start() {
        guard !started else { return }
        started = true

        let notch = NotchEngine(store: store, settings: settings, music: music,
                                weather: weather, palette: palette,
                                calendar: calendar, pomodoro: pomodoro, battery: battery)
        notch.model.onMusic = { [weak self] command in
            self?.nowPlaying.send(command)
        }
        notch.model.onActivate = { [weak self] session in
            self?.activate(session)
        }
        notch.model.onDecision = { [weak self] id, verdict in
            self?.store.resolve(id, with: verdict)
        }
        notch.model.onAnswer = { [weak self] id, answer in
            self?.store.answer(id, with: answer)
        }
        notch.model.onOpenNotice = { [weak self] item in
            self?.openNotice(item)
        }
        notch.model.onClearNotices = { [weak self] in
            self?.notices.clear()
        }
        notch.model.onRecopy = { [weak self] clip in
            self?.echo.recopy(clip)
        }
        self.notch = notch

        let overlay = OverlayController(settings: settings, store: store, audio: audio, palette: palette)
        // Le halo d'écran prête sa couleur et ses battements au contour de l'encoche.
        overlay.onAmbient = { [weak notch] color in
            notch?.setAmbient(color)
        }
        overlay.onBeat = { [weak notch] in
            notch?.beat()
        }
        self.overlay = overlay
        notch.model.onHint = { [weak self] in
            self?.grantAccess()
        }

        let status = serverStatus
        server.onState = { state in
            status.state = state
        }
        server.onRequest = { [weak self] request, exchange in
            if let self {
                self.route(request, exchange)
            } else {
                exchange.reply(status: 404, json: "{\"error\":\"not found\"}")
            }
        }

        store.signals
            .sink { [weak self] signal in self?.react(to: signal) }
            .store(in: &bag)

        // Port, délai ou module modifié : on relance le serveur et on met à jour ~/.aura/config.sh.
        settings.$s
            .map { ServerKey(enabled: $0.agentsEnabled, port: $0.port, timeout: $0.approvalTimeout) }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartServer() }
            .store(in: &bag)

        settings.$s
            .map(\.notificationsEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.feedback.requestNotificationPermission() }
            }
            .store(in: &bag)

        wireReactions(notch)
        HookInstaller.installCommand()
        restartServer()
    }

    /// Branche l'écho des raccourcis, le volume, la musique et les notifications sur l'encoche.
    /// Chaque module ne démarre (et ne touche à une autorisation) que s'il est activé.
    private func wireReactions(_ notch: NotchEngine) {
        echo.onEcho = { [weak self] event, inPlace in
            self?.present(event, inPlace: inPlace)
        }
        echo.onUpdate = { [weak self] event in
            self?.notch?.updateEcho(event)
        }
        notices.onPresent = { [weak self] item, priority in
            self?.present(item, priority: priority)
        }
        echo.onNeedsAccess = { [weak self] in
            self?.offerAccess()
        }
        echo.onAccessGranted = { [weak self] in
            self?.accessGranted()
        }
        // Batterie et minuteur : des infos, pas des alertes. Elles s'affichent un peu plus
        // longtemps qu'un ⌘C et ne font pas de bruit.
        battery.onEcho = { [weak self] event in
            self?.presentInfo(event)
        }
        pomodoro.onEcho = { [weak self] event in
            self?.presentInfo(event)
        }
        water.onEcho = { [weak self] event in
            self?.presentInfo(event)
        }
        // Codex vu par son journal de session : même chemin que les hooks des autres agents.
        codexWatcher.onEvent = { [weak self] event in
            self?.store.ingest(event)
        }

        settings.$s
            .map(\.batteryEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled {
                    self?.battery.start()
                } else {
                    self?.battery.stop()
                }
            }
            .store(in: &bag)

        settings.$s
            .map { $0.agentsEnabled && $0.codexEnabled && $0.codexWatch }
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled {
                    self?.codexWatcher.start()
                } else {
                    self?.codexWatcher.stop()
                }
            }
            .store(in: &bag)

        settings.$s
            .map(\.waterEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled {
                    self?.water.start()
                } else {
                    self?.water.stop()
                }
            }
            .store(in: &bag)

        settings.$s
            .map(\.calendarEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.calendar.refresh(force: true) }
            }
            .store(in: &bag)

        echo.$clips
            .sink { [weak notch] clips in notch?.setClips(clips) }
            .store(in: &bag)
        notices.$items
            .sink { [weak notch] items in notch?.setNotices(items) }
            .store(in: &bag)

        // Raccourcis clavier : seulement si l'écho est activé. Volume et luminosité : activés
        // par défaut, tant que l'encoche est là pour les montrer.
        settings.$s
            .map { ListenKey(keys: $0.echoEnabled,
                             media: $0.notchEnabled && ($0.notchVolume || $0.notchBrightness)) }
            .removeDuplicates()
            .sink { [weak self] key in
                self?.echo.apply(keys: key.keys, media: key.media)
            }
            .store(in: &bag)

        // Spotify / Musique : sondés pour l'encoche (titre, pochette) ou pour les couleurs du halo.
        settings.$s
            .map { ($0.notchEnabled && $0.notchMusic) || ($0.haloEnabled && $0.haloColorMode == .artwork) }
            .removeDuplicates()
            .sink { [weak self] wanted in
                if wanted {
                    self?.nowPlaying.start()
                } else {
                    self?.nowPlaying.stop()
                }
            }
            .store(in: &bag)

        settings.$s
            .map(\.clipHistoryEnabled)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                if !enabled { self?.echo.clearClips() }
            }
            .store(in: &bag)

        settings.$s
            .map(\.clipPersist)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                self?.echo.setPersistence(enabled)
            }
            .store(in: &bag)

        settings.$s
            .map(\.noticesEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled {
                    self?.notices.start()
                } else {
                    self?.notices.stop()
                    self?.notices.clear()
                }
            }
            .store(in: &bag)
    }

    /// Écho (raccourci, volume, luminosité) : ailes de l'encoche, puis éclat du halo et clic
    /// selon les réglages. Rien ne sort pendant qu'une validation agent attend.
    private func present(_ event: EchoEvent, inPlace: Bool) {
        guard store.approvals.isEmpty else { return }
        let config = settings.s
        let isLevel = event.key == "volume" || event.key == "brightness"
        notch?.showEcho(event,
                        duration: isLevel ? config.notchHudDuration : config.echoDuration,
                        inPlace: inPlace)
        guard !isLevel else { return }
        if config.echoHaloFlash {
            overlay?.echoFlash()
        }
        if config.echoSound {
            echo.click()
        }
    }

    /// Écho d'information (batterie, minuteur) : affiché sans son ni éclat du halo d'écran.
    private func presentInfo(_ event: EchoEvent) {
        guard store.approvals.isEmpty else { return }
        notch?.showEcho(event, duration: 2.4)
    }

    /// Accessibilité manquante : après l'écho « Copié », l'encoche propose une fois de l'accorder.
    private func offerAccess() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard let self, !self.echo.hasAccess else { return }
            let hint = NotchHint(symbol: "lock.shield.fill",
                                 title: "Autorise Aura dans Accessibilité",
                                 detail: "Pour voir ⌘V, ⌘Z, ⌘S… Clique pour ouvrir les réglages.")
            self.notch?.showHint(hint, duration: 9)
        }
    }

    /// Clic sur le message : demande système (elle ajoute Aura à la liste) et page des réglages.
    private func grantAccess() {
        notch?.hideHint()
        echo.requestTrust()
        PrivacySettings.openAccessibility()
    }

    /// Autorisation accordée pendant qu'Aura tourne : l'écoute du clavier est déjà repartie.
    private func accessGranted() {
        notch?.hideHint()
        let event = EchoEvent(key: "access", symbol: "checkmark.shield.fill",
                              label: "Raccourcis actifs", tint: AuraPalette.done)
        notch?.showEcho(event, duration: 1.8)
    }

    /// Notification d'une autre app : l'encoche la montre (après une éventuelle validation en attente).
    private func present(_ item: NoticeItem, priority: Bool) {
        let config = settings.s
        let duration = config.noticeDuration * (priority ? 2 : 1)
        notch?.showNotice(item, duration: duration)
        if config.noticeSound {
            feedback.play(priority ? "Ping" : "Pop")
        }
        if priority && store.approvals.isEmpty {
            overlay?.echoFlash()
        }
    }

    /// Clic sur une notification : ouvre son app et la retire de la liste d'Aura.
    func openNotice(_ item: NoticeItem) {
        notices.remove(item.id)
        notch?.hideNotice()
        guard let url = AppLookup.url(for: item.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    func shutdown() {
        store.clearAll()
        server.stop()
        audio.stop()
        echo.stop()
        notices.stop()
        nowPlaying.stop()
        battery.stop()
        water.stop()
        codexWatcher.stop()
    }

    /// Applique port, délai et activation du module. Le serveur n'est relancé que si le port
    /// ou l'activation a changé (un simple changement de délai ne coupe pas l'écoute).
    private func restartServer() {
        let config = settings.s
        HookInstaller.refreshConfigIfInstalled(port: config.port, timeout: config.approvalTimeout)
        guard appliedEnabled != config.agentsEnabled || appliedPort != config.port else { return }
        appliedEnabled = config.agentsEnabled
        appliedPort = config.port
        if config.agentsEnabled {
            server.start(port: config.port)
        } else {
            server.stop()
            store.clearAll()
        }
    }

    // MARK: Requêtes des hooks

    private func route(_ request: HTTPRequest, _ exchange: HTTPExchange) {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            exchange.reply(status: 200, json: "{\"ok\":true,\"app\":\"aura\"}")

        case ("POST", "/event"):
            guard let event = HookPayload.event(from: request.body) else {
                // JSON lisible mais sans intérêt pour Aura : on ne fait pas échouer le hook.
                exchange.reply(status: 200, json: "{\"ok\":true,\"ignored\":true}")
                return
            }
            store.ingest(event)
            exchange.reply(status: 200, json: "{\"ok\":true}")

        case ("POST", "/ask"):
            guard let ask = HookPayload.ask(from: request.body) else {
                exchange.reply(status: 400, json: "{\"error\":\"question manquante\"}")
                return
            }
            let askID = store.requestAsk(ask) { answer in
                exchange.reply(status: 200, json: AppState.json(for: answer))
            }
            if let askID {
                exchange.onClientGone { [weak self] in
                    self?.store.cancelAsk(askID)
                }
            }

        case ("POST", "/approve"):
            guard let approval = HookPayload.approval(from: request.body) else {
                exchange.reply(status: 200, json: "{\"decision\":\"pass\"}")
                return
            }
            let id = store.requestApproval(approval) { verdict in
                exchange.reply(status: 200, json: "{\"decision\":\"\(verdict.rawValue)\"}")
            }
            if let id {
                exchange.onClientGone { [weak self] in
                    self?.store.cancelApproval(id)
                }
            }

        default:
            exchange.reply(status: 404, json: "{\"error\":\"not found\"}")
        }
    }

    /// Réponse rendue à la commande `aura ask`.
    private static func json(for answer: AskAnswer) -> String {
        switch answer {
        case .choice(let value):
            return "{\"answer\":\(quote(value)),\"kind\":\"choice\"}"
        case .text(let value):
            return "{\"answer\":\(quote(value)),\"kind\":\"text\"}"
        case .file(let path):
            return "{\"answer\":\(quote(path)),\"kind\":\"file\"}"
        case .cancelled:
            return "{\"answer\":null,\"kind\":\"cancelled\"}"
        }
    }

    /// Chaîne JSON correctement échappée (guillemets, retours à la ligne, accents).
    private static func quote(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let text = String(data: data, encoding: .utf8),
              text.count > 2
        else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    // MARK: Sons et notifications

    private func react(to signal: StoreSignal) {
        let config = settings.s
        switch signal {
        case .acted:
            // Une action d'agent : juste l'onde. Pas de son, pas de notification.
            notch?.pulse()
        case .askRequested(let ask):
            if config.soundEnabled { feedback.play("Funk") }
            if config.notificationsEnabled {
                feedback.notify(title: "\(ask.source.label) te demande quelque chose", body: ask.question)
            }
        case .approvalRequested(let approval):
            if config.soundEnabled { feedback.play("Funk") }
            if config.notificationsEnabled {
                feedback.notify(title: "Validation requise · \(approval.project)", body: approval.command)
            }
        case .attention(let session):
            if config.soundEnabled { feedback.play("Tink") }
            if config.notificationsEnabled {
                feedback.notify(title: "\(session.source.label) attend ta réponse", body: session.project)
            }
        case .finished(let session):
            if config.soundEnabled { feedback.play("Glass") }
            if config.notificationsEnabled {
                feedback.notify(title: "\(session.source.label) a terminé", body: session.project)
            }
        case .failed(let session):
            if config.soundEnabled { feedback.play("Basso") }
            if config.notificationsEnabled {
                feedback.notify(title: "\(session.source.label) : erreur", body: session.project)
            }
        }
    }

    // MARK: Actions

    /// Passe au premier plan l'app qui héberge la session (réglage, sinon app détectée, sinon défaut).
    func activate(_ session: AgentSession) {
        let config = settings.s
        var bundleID: String
        switch session.source {
        case .claude: bundleID = config.claudeApp.trimmed
        case .codex: bundleID = config.codexApp.trimmed
        case .cursor: bundleID = config.cursorApp.trimmed
        case .other: bundleID = ""
        }
        if bundleID.isEmpty { bundleID = session.appBundleID }
        if bundleID.isEmpty { bundleID = session.source.fallbackBundleID }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    func openSettings() {
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(serverStatus)
                .environmentObject(audio)
                .environmentObject(palette)
                .environmentObject(echo)
                .environmentObject(notices)
                .environmentObject(music)
                .environmentObject(calendar)
                .environmentObject(pomodoro)
                .environmentObject(battery)
                .environmentObject(water)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered,
                                  defer: false)
            window.title = "Aura — Réglages"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: AnyView(root))
            window.setContentSize(NSSize(width: 800, height: 580))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Simule un état dans l'encoche (et le halo) sans passer par un agent.
    func runTest(_ scenario: TestScenario) {
        let base = IncomingEvent(source: .claude, session: "test", cwd: "/demo/projet-test",
                                 kind: .working, title: "", detail: "", app: "")
        switch scenario {
        case .working:
            var event = base
            event.detail = "analyse le dépôt"
            store.ingest(event, force: true)
        case .approval:
            let approval = IncomingApproval(source: .claude, session: "test", cwd: "/demo/projet-test",
                                            command: "rm -rf ./build && git push origin main",
                                            app: "", bypass: false)
            store.requestApproval(approval, force: true) { _ in }
        case .done:
            var event = base
            event.kind = .done
            store.ingest(event, force: true)
        case .error:
            var event = base
            event.kind = .error
            event.detail = "limite de requêtes atteinte"
            store.ingest(event, force: true)
        }
    }

    /// Boutons « Tester » des réglages : marchent sans autorisation ni module activé.
    func testEcho(_ shortcut: EchoShortcut) {
        echo.test(shortcut)
    }

    /// Bouton « Tester » : une vraie question dans l'encoche, sans agent.
    func testAsk() {
        let ask = IncomingAsk(source: .claude, session: "test", cwd: "/demo/projet-test",
                              question: "Je garde l'ancienne mise en page ou je refais la page ?",
                              detail: "Exemple de question posée par un agent. Ta réponse est renvoyée à la commande.",
                              choices: ["Refaire", "Garder"],
                              wantsText: false, wantsFile: false, timeout: 120)
        store.requestAsk(ask, force: true) { _ in }
    }

    func testNotice() {
        notices.test()
    }

    func testVolume() {
        echo.testVolume()
    }

    func testBrightness() {
        echo.testBrightness()
    }

    func testBattery() {
        battery.test()
    }

    func testWater() {
        water.test()
    }

    func demoHalo() {
        overlay?.demo()
    }

    func retryAudio() {
        if settings.s.haloEnabled {
            audio.start()
        }
    }
}
