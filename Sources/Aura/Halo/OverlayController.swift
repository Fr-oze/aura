import AppKit
import QuartzCore
import Combine

/// Fenêtre du halo : elle couvre tout l'écran, barre de menus et encoche comprises.
final class HaloWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit ramène sinon la fenêtre sous la barre de menus : le halo partait alors du bas
    /// de la barre au lieu du vrai bord de l'écran. On garde exactement le cadre demandé.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Fenêtre plein écran transparente qui porte le halo, et logique qui l'anime.
@MainActor
final class OverlayController {
    private let settings: SettingsStore
    private let store: AgentStore
    private let audio: AudioEngine
    private let palette: HaloPalette

    private var window: NSWindow?
    private var glow: GlowView?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    private var geometryKey = ""
    private var colorKey = ""

    /// Couleur du halo quand il est allumé, nil quand il est éteint : l'encoche la reprend
    /// sur son contour (le masque du halo ne contient plus le contour de l'encoche).
    var onAmbient: ((RGB?) -> Void)?
    /// Battement détecté dans la musique.
    var onBeat: (() -> Void)?
    private var currentFirst: RGB?
    private var ambientKey = "?"

    // Enveloppes lissées
    private var levelEnvelope: Float = 0
    private var bassEnvelope: Float = 0
    private var highEnvelope: Float = 0
    private var beatEnvelope: Float = 0
    private var balance: Float = 0.5
    private var lastBeat = 0
    private var lastActive: CFTimeInterval = 0
    private var resting = true
    private var tickCount = 0

    private static let orange = CGColor(srgbRed: 1.0, green: 0.58, blue: 0.1, alpha: 1)
    private static let green = CGColor(srgbRed: 0.2, green: 0.9, blue: 0.45, alpha: 1)
    private static let red = CGColor(srgbRed: 1.0, green: 0.3, blue: 0.3, alpha: 1)

    init(settings: SettingsStore, store: AgentStore, audio: AudioEngine, palette: HaloPalette) {
        self.settings = settings
        self.store = store
        self.audio = audio
        self.palette = palette

        settings.$s
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &bag)

        palette.$first
            .combineLatest(palette.$second)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyColors(duration: 1.0) }
            .store(in: &bag)

        store.$approvals
            .map { !$0.isEmpty }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyAlert() }
            .store(in: &bag)

        store.signals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signal in self?.react(to: signal) }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &bag)
    }

    /// Lance une simulation de musique pendant quelques secondes (bouton des réglages).
    func demo() {
        audio.demo(seconds: 6)
    }

    // MARK: Application des réglages

    private func rebuild() {
        teardownWindow()
        apply()
    }

    private func apply() {
        let config = settings.s
        let needed = config.haloEnabled || config.haloApprovalPulse || config.haloDoneFlash
            || (config.echoEnabled && config.echoHaloFlash) || config.notchDiagnostics

        guard needed, let screen = ScreenPicker.current(named: config.screenName) else {
            teardownWindow()
            stopTimer()
            audio.stop()
            publishAmbient()
            return
        }

        ensureWindow(on: screen)
        let sharing: NSWindow.SharingType = config.haloHideFromCapture ? .none : .readOnly
        window?.sharingType = sharing

        // Quand le moteur d'encoche tourne, c'est son halo, animé avec la forme, qui dessine la
        // lueur autour de l'encoche : un contour figé dans le masque resterait à la taille du repos
        // pendant que la forme s'élargit. Le contour n'entre dans le masque que si l'encoche
        // d'Aura est coupée (même constructeur de tracé que la forme).
        let metrics = ScreenPicker.metrics(on: screen)
        var notch: CGPath?
        if config.haloAvoidNotch && metrics.hasNotch && !config.notchEnabled {
            let resting = NotchLayout(width: metrics.width, height: metrics.height, topRadius: 0, bottomRadius: 9)
            notch = NotchShape.path(centerX: metrics.centerX, top: screen.frame.height, layout: resting)
        }
        let corner = min(max(config.haloCorner, 0), 24)
        let key = "\(screen.frame)|\(config.haloThickness)|\(corner)|\(config.haloAvoidNotch)|\(config.notchEnabled)|\(metrics.width)|\(metrics.centerX)"
        if key != geometryKey {
            geometryKey = key
            glow?.configure(size: screen.frame.size,
                            thickness: CGFloat(config.haloThickness),
                            corner: CGFloat(corner),
                            notch: notch,
                            scale: screen.backingScaleFactor)
        }
        glow?.setDiagnostics(config.notchDiagnostics)

        applyColors(duration: 0.35)
        applyAlert()

        if config.haloEnabled {
            audio.start()
            startTimer()
            if !config.haloDrift {
                glow?.removeDrift()
            }
            if resting {
                enterRest()
            } else if config.haloDrift {
                glow?.setDrift(true)
            }
        } else {
            stopTimer()
            audio.stop()
            resting = true
            glow?.stopBreathing()
            glow?.removeDrift()
            glow?.setLevels(base: 0, bloom: 0, duration: 0.4)
        }
        publishAmbient()
    }

    /// Prévient l'encoche de la couleur à reprendre sur son contour (nil = halo éteint).
    private func publishAmbient() {
        let config = settings.s
        var color: RGB?
        if window != nil, config.haloEnabled, config.haloAvoidNotch, !(resting && config.haloRest == .off) {
            color = currentFirst
        }
        let key = color.map { "\($0.r),\($0.g),\($0.b)" } ?? "off"
        guard key != ambientKey else { return }
        ambientKey = key
        onAmbient?(color)
    }

    private func ensureWindow(on screen: NSScreen) {
        if let window {
            if window.frame != screen.frame {
                window.setFrame(screen.frame, display: true)
                glow?.frame = NSRect(origin: .zero, size: screen.frame.size)
                geometryKey = ""
                logFrame(of: window, on: screen)
            }
            return
        }

        let created = HaloWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.ignoresMouseEvents = true
        created.level = .screenSaver
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        created.isReleasedWhenClosed = false
        created.animationBehavior = .none

        let view = GlowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        created.contentView = view
        created.setFrame(screen.frame, display: true)
        created.orderFrontRegardless()
        // Après l'affichage : c'est là qu'AppKit pouvait décaler la fenêtre sous la barre de menus.
        created.setFrame(screen.frame, display: true)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        logFrame(of: created, on: screen)

        window = created
        glow = view
        geometryKey = ""
        colorKey = ""
        resting = true
    }

    /// Trace de contrôle (Console.app, filtre « Aura halo ») : la fenêtre doit couvrir tout l'écran.
    private func logFrame(of window: NSWindow, on screen: NSScreen) {
        let matches = window.frame == screen.frame
        NSLog("Aura halo : fenêtre %@ / écran %@ → %@",
              NSStringFromRect(window.frame),
              NSStringFromRect(screen.frame),
              matches ? "identiques" : "DIFFÉRENTS")
    }

    private func teardownWindow() {
        window?.orderOut(nil)
        window = nil
        glow = nil
        geometryKey = ""
        colorKey = ""
    }

    // MARK: Couleurs

    private func applyColors(duration: CFTimeInterval) {
        guard let glow else { return }
        let config = settings.s
        var first = config.haloColor1
        var second = config.haloColor2

        switch config.haloColorMode {
        case .manual:
            break
        case .artwork:
            if let a = palette.first, let b = palette.second {
                first = a
                second = b
            }
        case .spectrum:
            let pair = spectrumPair()
            first = pair.0
            second = pair.1
        }

        currentFirst = first
        publishAmbient()
        let key = "\(first.r),\(first.g),\(first.b)|\(second.r),\(second.g),\(second.b)|\(config.haloRatio)"
        guard key != colorKey else { return }
        let animated = colorKey.isEmpty ? 0 : duration
        colorKey = key
        glow.setColors(first.cgColor, second.cgColor, ratio: CGFloat(config.haloRatio), duration: animated)
    }

    /// Mode Spectre : la teinte suit l'équilibre graves / aigus (violet pour les graves, orangé pour les aigus).
    private func spectrumPair() -> (RGB, RGB) {
        let hue = Double(0.76 - 0.7 * min(max(balance, 0), 1))
        var other = hue + 0.16
        if other > 1 { other -= 1 }
        return (ColorExtractor.fromHSV(h: max(0, hue), s: 0.85, v: 1),
                ColorExtractor.fromHSV(h: other, s: 0.8, v: 1))
    }

    // MARK: Alertes des agents

    private func applyAlert() {
        guard let glow else { return }
        if settings.s.haloApprovalPulse && !store.approvals.isEmpty {
            glow.startAlert(color: OverlayController.orange)
        } else {
            glow.stopAlert()
        }
    }

    /// Petit éclat du halo à chaque écho de raccourci (ignoré pendant une validation en attente).
    func echoFlash() {
        guard let glow else { return }
        let config = settings.s
        var color = config.haloColor1
        if config.haloColorMode == .artwork, let first = palette.first {
            color = first
        }
        glow.flash(color: color.cgColor, peak: 0.38, duration: 0.55)
    }

    private func react(to signal: StoreSignal) {
        guard let glow else { return }
        switch signal {
        case .finished:
            if settings.s.haloDoneFlash {
                glow.flash(color: OverlayController.green)
            }
        case .failed:
            if settings.s.haloDoneFlash {
                glow.flash(color: OverlayController.red)
            }
        case .approvalRequested, .attention, .acted, .askRequested:
            // Les actions d'un agent n'intéressent que l'encoche : le halo d'écran reste calme.
            break
        }
    }

    // MARK: Suivi audio (30 fois par seconde)

    private func startTimer() {
        guard timer == nil else { return }
        let created = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        created.tolerance = 0.004
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static func follow(_ current: Float, _ target: Float, attack: Float, release: Float) -> Float {
        let rate = target > current ? attack : release
        return current + (target - current) * rate
    }

    private func tick() {
        guard let glow else { return }
        let config = settings.s
        guard config.haloEnabled else { return }

        let levels = audio.snapshot()
        let now = CACurrentMediaTime()
        if levels.level > 0.02 {
            lastActive = now
        }
        let active = now - lastActive < 1.2

        guard active else {
            if !resting {
                resting = true
                enterRest()
                publishAmbient()
            }
            return
        }

        if resting {
            resting = false
            publishAmbient()
            glow.stopBreathing()
            if config.haloDrift {
                glow.setDrift(true)
            }
        }

        let attack = Float(min(max(config.haloAttack, 0.05), 1))
        let release = Float(min(max(config.haloRelease, 0.01), 1))
        levelEnvelope = OverlayController.follow(levelEnvelope, levels.level, attack: attack, release: release)
        bassEnvelope = OverlayController.follow(bassEnvelope, levels.bass, attack: attack, release: release)
        highEnvelope = OverlayController.follow(highEnvelope, levels.high, attack: attack, release: release)

        if levels.beatCount != lastBeat {
            lastBeat = levels.beatCount
            beatEnvelope = 1
            onBeat?()
        }
        beatEnvelope *= 0.86

        let intensity = Float(config.haloIntensity)
        let reactivity = Float(config.haloReactivity)
        let base = intensity * min(1, 0.42 + reactivity * (0.38 * levelEnvelope + 0.2 * highEnvelope))
        let bloom = intensity * min(1, reactivity * (0.6 * bassEnvelope + 0.45 * beatEnvelope))
        glow.setLevels(base: base, bloom: bloom)

        if config.haloColorMode == .spectrum {
            let total = levels.bass + levels.mid + levels.high
            if total > 0.01 {
                let centroid = (levels.mid * 0.5 + levels.high) / total
                balance += (centroid - balance) * 0.05
            }
            tickCount += 1
            if tickCount % 8 == 0 {
                applyColors(duration: 0.3)
            }
        }
    }

    /// Plus de musique : lueur fixe, respiration lente ou extinction, selon le réglage.
    private func enterRest() {
        guard let glow else { return }
        let config = settings.s
        let intensity = Float(config.haloIntensity)
        levelEnvelope = 0
        bassEnvelope = 0
        highEnvelope = 0
        beatEnvelope = 0
        glow.setDrift(false)
        glow.stopBreathing()

        switch config.haloRest {
        case .fixed:
            glow.setLevels(base: intensity * 0.5, bloom: 0, duration: 1.2)
        case .breathe:
            glow.setLevels(base: intensity * 0.3, bloom: 0, duration: 1.0)
            glow.startBreathing(low: intensity * 0.3, high: intensity * 0.62)
        case .off:
            glow.setLevels(base: 0, bloom: 0, duration: 1.5)
        }
    }
}
