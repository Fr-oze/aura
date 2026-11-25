import AppKit
import SwiftUI
import Combine

/// Moteur d'encoche : la seule surface d'Aura.
///
/// Une fenêtre transparente à cadre fixe, collée au bord haut de l'écran, porte une forme noire
/// qui part de l'encoche physique, s'étire en ailes ou descend en panneau. Le moteur choisit la
/// scène par ordre de priorité, transforme la forme sur un ressort, accorde le halo d'encoche,
/// et ne laisse capter la souris que sur la forme.
///
/// Priorité : validation agent > notification > message d'Aura > panneau d'accueil (survol) >
/// volume, luminosité, raccourci > agent terminé / en attente > musique en cours >
/// agent au travail > repos.
@MainActor
final class NotchEngine {
    let model: NotchModel

    private let store: AgentStore
    private let settings: SettingsStore
    private let music: MusicState
    private let weather: WeatherService
    private let palette: HaloPalette
    private let calendar: CalendarService
    private let pomodoro: Pomodoro
    private let battery: BatteryWatcher

    private var panel: NotchPanel?
    private var surface: NotchSurfaceView?
    private var metrics = NotchMetrics(hasNotch: false, width: 184, height: 30, centerX: 0)
    private var screenFrame = NSRect.zero
    private var bag = Set<AnyCancellable>()

    // Contenus éphémères : affichés tant que leur échéance n'est pas passée.
    private var noticeDeadline: Date?
    private var echoDeadline: Date?
    private var hintDeadline: Date?
    private var expiryToken = 0

    // Halo d'encoche.
    /// Couleur du halo d'écran quand il est allumé : au repos, l'encoche la reprend sur son contour.
    private var ambient: RGB?
    private var glowScene: NotchScene?

    // Survol.
    private var homeOpen = false
    private var openToken = 0
    private var closeToken = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollTimer: Timer?

    private static let windowWidth: CGFloat = 920
    private static let windowHeight: CGFloat = 440

    init(store: AgentStore, settings: SettingsStore, music: MusicState, weather: WeatherService,
         palette: HaloPalette, calendar: CalendarService, pomodoro: Pomodoro, battery: BatteryWatcher) {
        self.store = store
        self.settings = settings
        self.music = music
        self.weather = weather
        self.palette = palette
        self.calendar = calendar
        self.pomodoro = pomodoro
        self.battery = battery
        self.model = NotchModel()

        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        store.$approvals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        settings.$s
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        music.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        palette.$first
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        model.$tab
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in self?.tabChanged(tab) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.setPolling(true) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.setPolling(false) }
            .store(in: &bag)
    }

    // MARK: Entrées

    /// Affiche un écho. `inPlace` : si le même type d'écho est déjà à l'écran (volume),
    /// on met juste son contenu à jour sans rejouer l'entrée.
    func showEcho(_ event: EchoEvent, duration: TimeInterval, inPlace: Bool = false) {
        let sameKind = inPlace && echoDeadline != nil && model.echo?.key == event.key
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            model.echo = event
            if !sameKind {
                model.echoTick += 1
            }
        }
        echoDeadline = Date().addingTimeInterval(max(0.3, duration))
        refresh()
        // Onde qui part de l'encoche et longe la forme, à chaque écho.
        if model.scene == .echo {
            surface?.ripple()
        }
    }

    /// Complète l'écho en cours (miniature de l'image copiée) s'il est toujours celui affiché.
    func updateEcho(_ event: EchoEvent) {
        guard model.echo?.id == event.id else { return }
        model.echo = event
        refresh()
    }

    func showNotice(_ item: NoticeItem, duration: TimeInterval) {
        model.notice = item
        model.noticeTick += 1
        noticeDeadline = Date().addingTimeInterval(max(1, duration))
        refresh()
    }

    func hideNotice() {
        noticeDeadline = nil
        refresh()
    }

    func setNotices(_ items: [NoticeItem]) {
        model.notices = items
        if items.isEmpty {
            noticeDeadline = nil
        }
        refresh()
    }

    func setClips(_ clips: [ClipItem]) {
        model.clips = clips
    }

    /// Message d'Aura à cliquer (autorisation manquante).
    func showHint(_ hint: NotchHint, duration: TimeInterval) {
        model.hint = hint
        hintDeadline = Date().addingTimeInterval(max(2, duration))
        refresh()
    }

    func hideHint() {
        guard hintDeadline != nil else { return }
        hintDeadline = nil
        refresh()
    }

    /// Le halo d'écran s'allume, s'éteint ou change de couleur : le contour de l'encoche suit.
    /// Le masque du halo d'écran ne contient plus le contour de l'encoche ; c'est ce halo-ci,
    /// animé avec la forme, qui le dessine.
    func setAmbient(_ color: RGB?) {
        guard color != ambient else { return }
        ambient = color
        applyGlow(for: model.scene)
    }

    /// Un agent vient de faire quelque chose (lire un fichier, lancer une commande, éditer) :
    /// une onde part de l'encoche et longe la forme. Entre deux actions, rien ne bouge.
    func pulse() {
        let config = settings.s
        guard config.notchGlow, config.notchAgentPulse else { return }
        switch model.scene {
        case .rest, .agent, .music, .home:
            surface?.ripple()
        case .echo, .hint, .notice, .approval, .ask:
            break
        }
    }

    /// Battement détecté par le halo musical : le liseré de l'encoche s'allume un instant.
    func beat() {
        switch model.scene {
        case .rest, .music, .home, .agent:
            surface?.kick()
        case .echo, .hint, .notice, .approval, .ask:
            break
        }
    }

    // MARK: Fenêtre

    /// Crée ou replace la fenêtre sur l'écran choisi. Renvoie faux si l'encoche est coupée.
    private func prepareWindow() -> Bool {
        let config = settings.s
        guard config.notchEnabled, let screen = ScreenPicker.current(named: config.screenName) else {
            teardownWindow()
            return false
        }

        let measured = ScreenPicker.metrics(on: screen)
        let width = min(screen.frame.width, NotchEngine.windowWidth)
        let height = min(screen.frame.height, NotchEngine.windowHeight)
        let frame = NSRect(x: (screen.frame.minX + measured.centerX - width / 2).rounded(),
                           y: screen.frame.maxY - height,
                           width: width,
                           height: height)

        if panel == nil {
            createWindow(frame: frame)
        }
        guard let panel, let surface else { return false }

        if panel.frame != frame || measured != metrics || screen.frame != screenFrame {
            metrics = measured
            screenFrame = screen.frame
            if panel.frame != frame {
                panel.setFrame(frame, display: true)
            }
            let header: CGFloat = measured.hasNotch ? measured.height : 10
            if model.headerHeight != header {
                model.headerHeight = header
            }
            surface.relayout(centerX: screen.frame.minX + measured.centerX - frame.minX,
                             scale: screen.backingScaleFactor)
            // Nouvelle géométrie : la forme est reposée sans animation.
            let resting = layout(for: model.scene)
            model.layout = resting
            surface.morph(to: resting, animated: false)
            NSLog("Aura encoche : %@", ScreenPicker.describe(screen).replacingOccurrences(of: "\n", with: " | "))
        }
        surface.setDiagnostics(config.notchDiagnostics)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        startTracking()
        return true
    }

    private func createWindow(frame: NSRect) {
        let created = NotchPanel(contentRect: frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        created.isFloatingPanel = true
        created.becomesKeyOnlyIfNeeded = false
        // Au-dessus du halo d'écran : la forme noire le recouvre, son propre halo prend le relais.
        created.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.hidesOnDeactivate = false
        created.isMovable = false
        created.isReleasedWhenClosed = false
        created.animationBehavior = .none
        created.ignoresMouseEvents = true
        created.acceptsMouseMovedEvents = true

        let root = NotchRootView()
            .environmentObject(model)
            .environmentObject(settings)
            .environmentObject(music)
            .environmentObject(weather)
            .environmentObject(calendar)
            .environmentObject(pomodoro)
            .environmentObject(battery)
        let host = NotchHostingView(rootView: AnyView(root))
        host.sizingOptions = []

        let box = NSRect(origin: .zero, size: frame.size)
        let view = NotchSurfaceView(frame: box, content: host)
        view.autoresizingMask = [.width, .height]
        created.contentView = view
        created.setFrame(frame, display: false)

        created.onReturn = { [weak self] in self?.confirmCurrent() }
        created.onEscape = { [weak self] in self?.cancelCurrent() }

        panel = created
        surface = view
        screenFrame = .zero
    }

    private func teardownWindow() {
        stopTracking()
        panel?.orderOut(nil)
        panel = nil
        surface = nil
        homeOpen = false
        model.hovered = false
        if model.scene != .rest {
            model.scene = .rest
        }
    }

    /// ↩ : autorise la validation affichée, ou prend la première réponse d'une question.
    private func confirmCurrent() {
        if let approval = store.approvals.first {
            model.onDecision?(approval.id, .allow)
            return
        }
        guard let ask = store.asks.first, let first = ask.choices.first else { return }
        model.onAnswer?(ask.id, .choice(first))
    }

    /// esc : refuse la validation, ou annule la question (l'agent reprend la main).
    private func cancelCurrent() {
        if let approval = store.approvals.first {
            model.onDecision?(approval.id, .deny)
            return
        }
        guard let ask = store.asks.first else { return }
        model.onAnswer?(ask.id, .cancelled)
    }

    // MARK: Scène

    /// Recalcule ce qu'il faut montrer à partir de l'état courant.
    private func refresh() {
        guard prepareWindow(), let panel, let surface else { return }
        let config = settings.s
        let now = Date()

        let visible = store.sessions.sorted { NotchEngine.rank($0) < NotchEngine.rank($1) }

        // Une notification survolée reste affichée jusqu'à ce que la souris s'en aille.
        if let deadline = noticeDeadline, deadline <= now, !(model.hovered && model.scene == .notice) {
            noticeDeadline = nil
        }
        if let deadline = echoDeadline, deadline <= now {
            echoDeadline = nil
        }
        if let deadline = hintDeadline, deadline <= now, !(model.hovered && model.scene == .hint) {
            hintDeadline = nil
        }

        let scene: NotchScene
        if !store.approvals.isEmpty {
            // Une validation en attente n'est jamais masquée par autre chose.
            scene = .approval
        } else if !store.asks.isEmpty {
            // Une question d'agent passe devant tout le reste, sauf une validation.
            scene = .ask
        } else if noticeDeadline != nil, model.notice != nil {
            scene = .notice
        } else if hintDeadline != nil, model.hint != nil {
            scene = .hint
        } else if homeOpen {
            scene = .home
        } else if echoDeadline != nil, model.echo != nil {
            scene = .echo
        } else if let first = visible.first, first.phase != .working {
            scene = .agent
        } else if config.notchMusic && music.isPlaying {
            scene = .music
        } else if config.showWhileWorking, visible.first != nil {
            scene = .agent
        } else {
            scene = .rest
        }

        if model.sessions != visible {
            model.sessions = visible
        }
        if let approval = store.approvals.first, model.approval != approval {
            model.approval = approval
        }
        if model.pendingCount != store.approvals.count {
            model.pendingCount = store.approvals.count
        }
        if let ask = store.asks.first, model.ask != ask {
            model.ask = ask
        }
        if model.askCount != store.asks.count {
            model.askCount = store.asks.count
        }

        scheduleExpiry()
        // La fenêtre prend le clavier pour ↩ / esc, et pour taper dans le champ d'une question.
        panel.allowsKey = (scene == .approval || scene == .ask)

        let previous = model.scene
        let target = layout(for: scene)
        if scene != previous || target != model.layout {
            // Si la fenêtre avait le clavier (validation), on le rend à l'app de l'utilisateur.
            if (previous == .approval || previous == .ask) && scene != .approval && scene != .ask && panel.isKeyWindow {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.scene = scene
                model.layout = target
            }
            surface.morph(to: target, animated: true)
        }

        applyGlow(for: scene)
        updatePointer()
    }

    /// Ordre d'affichage : ce qui demande ton attention d'abord, puis le plus récent.
    private static func rank(_ session: AgentSession) -> Double {
        let base: Double
        switch session.phase {
        case .waiting: base = 0
        case .error: base = 1
        case .done: base = 2
        case .working: base = 3
        }
        let recency = min(0.999, max(0, Date().timeIntervalSince(session.updatedAt)) / 100_000)
        return base + recency
    }

    /// Dimensions de la forme pour une scène.
    private func layout(for scene: NotchScene) -> NotchLayout {
        let header: CGFloat = metrics.hasNotch ? metrics.height : 10
        switch scene {
        case .rest:
            // Exactement l'encoche physique. Sans encoche : forme rentrée dans le bord de l'écran.
            return NotchLayout(width: metrics.width,
                               height: metrics.hasNotch ? metrics.height : 0,
                               topRadius: 0,
                               bottomRadius: metrics.hasNotch ? 9 : 0)
        case .agent, .music:
            return wings(60)
        case .echo:
            return wings(model.echo?.wing ?? 78)
        case .hint:
            return NotchLayout(width: max(380, metrics.width + 120), height: header + 46,
                               topRadius: 9, bottomRadius: 18)
        case .notice:
            return NotchLayout(width: max(420, metrics.width + 120), height: header + 72,
                               topRadius: 10, bottomRadius: 22)
        case .approval:
            return NotchLayout(width: max(470, metrics.width + 120), height: header + 176,
                               topRadius: 12, bottomRadius: 26)
        case .ask:
            // La hauteur suit ce que la question demande : boutons, champ de texte, fichier.
            // En-tête + question + pied, puis ce que la demande ajoute.
            var body: CGFloat = 126
            if let ask = model.ask {
                if !ask.detail.isEmpty { body += 24 }
                if !ask.choices.isEmpty { body += ask.choices.count > 3 ? 78 : 41 }
                if ask.wantsText { body += 42 }
            }
            return NotchLayout(width: max(520, metrics.width + 160), height: header + body,
                               topRadius: 12, bottomRadius: 26)
        case .home:
            return NotchLayout(width: 660, height: header + 232,
                               topRadius: 14, bottomRadius: 28)
        }
    }

    private func wings(_ wing: CGFloat) -> NotchLayout {
        NotchLayout(width: metrics.width + wing * 2,
                    height: metrics.height,
                    topRadius: 7,
                    bottomRadius: 11,
                    wing: wing)
    }

    // MARK: Halo d'encoche

    /// Couleur, force et rythme liés à l'événement. Le halo porte le même contour que la forme
    /// (voir `NotchSurfaceView.morph`) : ici on ne règle que sa couleur et sa vie.
    private func applyGlow(for scene: NotchScene) {
        guard let surface else { return }
        let config = settings.s
        var color: RGB?
        var strength = 1.0
        var mode = GlowMode.breathe

        switch scene {
        case .approval:
            color = config.notchColorApproval
            mode = .pulse
        case .ask:
            color = config.notchColorApproval
            mode = .breathe
        case .notice:
            // Couleur de l'app qui notifie.
            color = model.notice.flatMap { AppLookup.tint(for: $0.bundleID) } ?? RGB(r: 0.66, g: 0.55, b: 1.0)
            mode = .pulse
        case .hint:
            color = config.notchColorApproval
            strength = 0.8
        case .echo:
            color = model.echo?.glow ?? config.notchColorEcho
            mode = .steady
            // Volume, luminosité : l'intensité du halo suit la valeur.
            if let level = model.echo?.glowLevel {
                strength = 0.3 + 0.9 * min(max(level, 0), 1)
            }
        case .agent:
            switch model.sessions.first?.phase {
            case .done: color = config.notchColorDone
            case .error: color = RGB(r: 1.0, g: 0.3, b: 0.3)
            case .waiting: color = config.notchColorApproval
            case .working, .none:
                // Sans halo d'écran pour donner la couleur, on prend celle de la source :
                // le segment qui tourne doit rester visible même halo d'écran coupé.
                color = ambient ?? model.sessions.first.map { RGB(color: $0.source.tint) }
                strength = 0.6
            }
        case .music:
            // Couleur de la pochette ; les battements du halo musical font briller le liseré.
            color = palette.first ?? ambient
            strength = 0.8
        case .home:
            color = music.isPlaying ? (palette.first ?? ambient) : ambient
            strength = 0.5
        case .rest:
            // Halo d'écran allumé : il se prolonge sur le contour de l'encoche.
            color = ambient
            strength = 0.6
        }

        let changed = glowScene != scene
        glowScene = scene
        guard config.notchGlow, let color else {
            surface.setGlow(color: nil, intensity: 0, mode: .steady, bloom: false)
            return
        }
        surface.setGlow(color: color.cgColor,
                        intensity: Float(config.notchGlowIntensity * strength),
                        mode: mode,
                        bloom: changed)
    }

    // MARK: Échéances

    /// Réveille `refresh()` à la prochaine échéance d'un contenu éphémère.
    private func scheduleExpiry() {
        expiryToken += 1
        let token = expiryToken
        let now = Date()
        var next: Date?
        for deadline in [noticeDeadline, echoDeadline, hintDeadline] {
            guard let deadline, deadline > now else { continue }
            if let current = next {
                next = min(current, deadline)
            } else {
                next = deadline
            }
        }
        guard let next else { return }
        let delay = max(0.02, next.timeIntervalSince(now)) + 0.01
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.expiryToken == token else { return }
            self.refresh()
        }
    }

    // MARK: Souris

    /// Suivi léger de la souris : un moniteur global (les mouvements vont aux autres apps la
    /// plupart du temps) et un moniteur local. Aucun minuteur tant qu'Aura n'est pas au premier plan.
    private func startTracking() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePointer()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePointer()
            }
            return event
        }
        setPolling(NSApp.isActive)
    }

    private func stopTracking() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Quand Aura est au premier plan (réglages ouverts), macOS ne lui envoie pas forcément les
    /// mouvements de souris : on regarde alors la position quelques fois par seconde.
    private func setPolling(_ active: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        guard active, panel != nil else { return }
        let created = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePointer()
            }
        }
        created.tolerance = 0.05
        RunLoop.main.add(created, forMode: .common)
        pollTimer = created
    }

    /// Rectangle de la forme courante en coordonnées d'écran, élargi d'une petite marge.
    private func shapeRect(margin: CGFloat) -> NSRect {
        let layout = model.layout
        let height = max(layout.height, 5)
        let width = layout.width + layout.topRadius * 2
        let centerX = screenFrame.minX + metrics.centerX
        return NSRect(x: centerX - width / 2 - margin,
                      y: screenFrame.maxY - height - margin,
                      width: width + margin * 2,
                      height: height + margin * 2)
    }

    /// La fenêtre ne capte la souris que lorsque le pointeur est sur la forme.
    private func updatePointer() {
        guard let panel else { return }
        let location = NSEvent.mouseLocation
        // Panneau ouvert : marge plus large, pour ne pas le refermer au moindre écart.
        let inside = shapeRect(margin: homeOpen ? 12 : 3).contains(location)
        let interactive = inside && model.scene != .rest
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
        if model.hovered != inside {
            model.hovered = inside
            hoverChanged(inside)
        }
    }

    private func hoverChanged(_ inside: Bool) {
        if inside {
            closeToken += 1
            scheduleOpen()
        } else {
            openToken += 1
            if homeOpen {
                scheduleClose()
            } else {
                // Une notification retenue par le survol peut maintenant expirer.
                refresh()
            }
        }
    }

    private var canOpenHome: Bool {
        switch model.scene {
        case .rest, .agent, .music, .echo: return true
        case .hint, .notice, .approval, .ask, .home: return false
        }
    }

    /// Survol prolongé : ouvre le panneau d'accueil.
    private func scheduleOpen() {
        let config = settings.s
        guard config.notchHover, !homeOpen, canOpenHome else { return }
        openToken += 1
        let token = openToken
        let delay = min(max(config.notchHoverDelay, 0.05), 2)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.openToken == token, self.model.hovered, self.canOpenHome else { return }
            self.openHome()
        }
    }

    private func openHome() {
        // Survol d'un « Copié » : on arrive directement sur le presse-papiers.
        if model.scene == .echo, model.echo?.opensClipboard == true, !model.clips.isEmpty,
           settings.s.clipHistoryEnabled {
            model.tab = .clipboard
        }
        if model.tab == .weather {
            weather.refresh(force: false)
        }
        homeOpen = true
        refresh()
    }

    /// Sortie de la souris : referme le panneau après un court répit.
    private func scheduleClose() {
        closeToken += 1
        let token = closeToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, self.closeToken == token, !self.model.hovered else { return }
            self.homeOpen = false
            self.refresh()
        }
    }

    private func tabChanged(_ tab: HomeTab) {
        if tab == .weather && homeOpen {
            weather.refresh(force: false)
        }
    }
}
