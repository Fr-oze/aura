import AppKit
import SwiftUI
import Combine
import CoreAudio
import ApplicationServices

/// Raccourcis reconnus par l'écho. Chacun se coupe individuellement dans les réglages.
enum EchoShortcut: String, CaseIterable, Identifiable {
    case copy, cut, paste, undo, redo, save, selectAll, find, screenshot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .copy: return "Copié"
        case .cut: return "Coupé"
        case .paste: return "Collé"
        case .undo: return "Annulé"
        case .redo: return "Rétabli"
        case .save: return "Enregistré"
        case .selectAll: return "Tout sélectionné"
        case .find: return "Recherche"
        case .screenshot: return "Capture"
        }
    }

    /// Touches affichées dans les réglages.
    var keys: String {
        switch self {
        case .copy: return "⌘C"
        case .cut: return "⌘X"
        case .paste: return "⌘V"
        case .undo: return "⌘Z"
        case .redo: return "⇧⌘Z"
        case .save: return "⌘S"
        case .selectAll: return "⌘A"
        case .find: return "⌘F"
        case .screenshot: return "⇧⌘3 / 4 / 5"
        }
    }

    var symbol: String {
        switch self {
        case .copy: return "doc.on.doc.fill"
        case .cut: return "scissors"
        case .paste: return "doc.on.clipboard.fill"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .save: return "square.and.arrow.down.fill"
        case .selectAll: return "square.dashed"
        case .find: return "magnifyingglass"
        case .screenshot: return "camera.viewfinder"
        }
    }

    var tint: Color {
        switch self {
        case .copy, .cut, .paste, .selectAll, .find: return AuraPalette.echo
        case .undo, .redo: return AuraPalette.working
        case .save: return AuraPalette.done
        case .screenshot: return .white
        }
    }
}

/// Codes des touches média (NX_KEYTYPE_* de IOKit/hidsystem/ev_keymap.h), redéfinis ici
/// parce que l'en-tête ne s'importe pas directement en Swift.
enum MediaKeyCode {
    static let soundUp: Int32 = 0
    static let soundDown: Int32 = 1
    static let brightnessUp: Int32 = 2
    static let brightnessDown: Int32 = 3
    static let mute: Int32 = 7
    /// Sous-type des événements système qui portent les touches média.
    static let subtype: Int16 = 8
}

/// Volume de la sortie audio par défaut, lu via CoreAudio.
enum SystemVolume {
    /// Sortie audio par défaut, ou nil.
    static func defaultDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else { return nil }
        return device
    }

    /// Adresses à surveiller pour être prévenu d'un changement de volume ou de sourdine.
    static func watchAddresses(for device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        var found: [AudioObjectPropertyAddress] = []
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(device, &address) {
                found.append(address)
            }
        }
        var mute = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &mute) {
            found.append(mute)
        }
        return found
    }

    static func read() -> (level: Double, muted: Bool)? {
        guard let device = defaultDevice() else { return nil }

        // Élément principal d'abord ; sinon moyenne des canaux gauche et droit.
        var level: Double?
        if let main = scalar(device, element: kAudioObjectPropertyElementMain) {
            level = Double(main)
        } else {
            var total = 0.0
            var found = 0.0
            for channel in [UInt32(1), UInt32(2)] {
                if let value = scalar(device, element: channel) {
                    total += Double(value)
                    found += 1
                }
            }
            if found > 0 {
                level = total / found
            }
        }
        guard let level else { return nil }

        var muted = false
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &muteAddress) {
            var flag = UInt32(0)
            var flagSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &flagSize, &flag) == noErr {
                muted = flag != 0
            }
        }
        return (min(max(level, 0), 1), muted)
    }

    private static func scalar(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

/// Luminosité de l'écran intégré. macOS n'a pas d'API publique pour la lire : on passe par
/// `DisplayServicesGetBrightness` (framework privé DisplayServices), chargé à l'exécution.
/// Si le symbole est absent ou échoue, `read()` renvoie nil et l'encoche montre juste l'animation.
enum DisplayBrightness {
    private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

    private static let getter: Getter? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness")
        else { return nil }
        return unsafeBitCast(symbol, to: Getter.self)
    }()

    static func read() -> Double? {
        guard let getter = DisplayBrightness.getter else { return nil }
        var value: Float = -1
        let status = getter(CGMainDisplayID(), &value)
        guard status == 0, value >= 0, value <= 1 else { return nil }
        return Double(value)
    }
}

/// Écoute les raccourcis clavier et les touches de volume / luminosité, et en fait des échos
/// pour l'encoche.
/// Tient aussi l'historique du presse-papiers.
@MainActor
final class ShortcutEcho: ObservableObject {
    /// Autorisation Accessibilité accordée.
    @Published private(set) var trusted = false
    /// Autorisation Surveillance de l'entrée accordée.
    @Published private(set) var listenAccess = false
    @Published private(set) var running = false
    @Published private(set) var clips: [ClipItem] = []

    /// Nouvel écho. Le booléen demande une mise à jour sur place (barre de volume).
    var onEcho: ((EchoEvent, Bool) -> Void)?
    /// Complément de l'écho en cours (aperçu du texte copié).
    var onUpdate: ((EchoEvent) -> Void)?
    /// Une copie a été vue sans que le clavier soit lisible : proposer d'autoriser Aura.
    var onNeedsAccess: (() -> Void)?
    /// L'autorisation vient d'être accordée et l'écoute du clavier est repartie.
    var onAccessGranted: (() -> Void)?

    static let historyLimit = 20
    private static let clipsKey = "aura.clips.v1"
    /// Contenus que les gestionnaires de mots de passe demandent de ne pas garder (nspasteboard.org).
    private static let secretTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword"
    ]

    private let settings: SettingsStore
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastChangeCount = 0
    private var clickSound: NSSound?
    private var volumeToken = 0
    private var brightnessToken = 0
    private var activeKeys = false
    private var activeMedia = false

    // Veille légère : presse-papiers (aucune autorisation) et autorisation Accessibilité.
    private var watchTimer: Timer?
    private var watchTicks = 0
    /// Écho du dernier ⌘C / ⌘X vu au clavier, en attente de son aperçu.
    private var pendingCopy: EchoEvent?
    private var pendingCopyAt: TimeInterval = 0
    private var accessHintOffered = false
    private static let accessHintKey = "aura.accessHint.count"

    // Surveillance du volume par CoreAudio (aucune autorisation, aucun sondage).
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private var volumeDevice = AudioDeviceID(0)
    private var volumeAddresses: [AudioObjectPropertyAddress] = []
    private var lastVolumeKey = ""

    init(settings: SettingsStore) {
        self.settings = settings
        lastChangeCount = NSPasteboard.general.changeCount
        if settings.s.clipPersist, let stored = UserDefaults.standard.stringArray(forKey: ShortcutEcho.clipsKey) {
            clips = stored.prefix(ShortcutEcho.historyLimit).map { ClipItem(text: $0) }
        }
    }

    var hasAccess: Bool { trusted || listenAccess }

    // MARK: Autorisations

    func refreshTrust() {
        let accessibility = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        if trusted != accessibility { trusted = accessibility }
        if listenAccess != listen { listenAccess = listen }
    }

    /// Affiche la demande d'autorisation Accessibilité de macOS (une fenêtre système).
    func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshTrust()
    }

    // MARK: Écoute

    /// Règle ce qui est écouté. `keys` : raccourcis clavier (Accessibilité) et presse-papiers.
    /// `media` : volume et luminosité.
    func apply(keys: Bool, media: Bool) {
        refreshTrust()
        guard keys != activeKeys || media != activeMedia else { return }
        removeMonitors()
        activeKeys = keys
        activeMedia = media
        if running != keys { running = keys }

        if media {
            startVolumeWatch()
        } else {
            stopVolumeWatch()
        }
        if keys {
            lastChangeCount = NSPasteboard.general.changeCount
            startWatch()
        } else {
            stopWatch()
        }
        installMonitors()
    }

    private func installMonitors() {
        guard activeKeys || activeMedia else { return }
        var mask: NSEvent.EventTypeMask = []
        if activeKeys { mask.insert(.keyDown) }
        if activeMedia { mask.insert(.systemDefined) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handle(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handle(event)
            }
            return event
        }
    }

    // MARK: Veille (presse-papiers, autorisation)

    /// Un minuteur lent (0,4 s) : il compare le compteur du presse-papiers, ce qui ne demande
    /// aucune autorisation, et revérifie de temps en temps l'autorisation Accessibilité.
    private func startWatch() {
        guard watchTimer == nil else { return }
        let created = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watchTick()
            }
        }
        created.tolerance = 0.12
        RunLoop.main.add(created, forMode: .common)
        watchTimer = created
    }

    private func stopWatch() {
        watchTimer?.invalidate()
        watchTimer = nil
        pendingCopy = nil
    }

    private func watchTick() {
        watchTicks += 1

        // Toutes les ~3 s tant que l'autorisation manque : dès qu'elle est accordée, on repose les
        // moniteurs clavier pour que l'écoute démarre sans relancer Aura.
        if watchTicks % 8 == 0 && !hasAccess {
            refreshTrust()
            if hasAccess {
                removeMonitors()
                installMonitors()
                onAccessGranted?()
            }
        }

        guard consumeClipboardChange() else { return }
        let now = Date().timeIntervalSinceReferenceDate

        // Le clavier a déjà signalé ce ⌘C / ⌘X : on complète son écho, sans en créer un second.
        if let pending = pendingCopy, now - pendingCopyAt < 1.5 {
            pendingCopy = nil
            onUpdate?(filled(pending))
            return
        }
        pendingCopy = nil

        // Copie vue seulement par le presse-papiers (clavier illisible, ou copie par un menu).
        var echo = EchoEvent(key: EchoShortcut.copy.rawValue, symbol: EchoShortcut.copy.symbol,
                             label: EchoShortcut.copy.label, tint: EchoShortcut.copy.tint)
        echo.opensClipboard = true
        let ready = filled(echo)
        let config = settings.s
        guard config.echoEnabled, !config.echoDisabled.contains(EchoShortcut.copy.rawValue) else { return }
        onEcho?(ready, false)

        if !hasAccess {
            offerAccessHint()
        }
    }

    /// Propose une fois par lancement (et trois fois au plus en tout) d'autoriser Aura.
    private func offerAccessHint() {
        guard !accessHintOffered else { return }
        accessHintOffered = true
        let shown = UserDefaults.standard.integer(forKey: ShortcutEcho.accessHintKey)
        guard shown < 3 else { return }
        UserDefaults.standard.set(shown + 1, forKey: ShortcutEcho.accessHintKey)
        onNeedsAccess?()
    }

    func stop() {
        apply(keys: false, media: false)
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            handleKey(event)
        case .systemDefined:
            handleSystem(event)
        default:
            break
        }
    }

    // MARK: Raccourcis

    /// Reconnaît le raccourci d'après la lettre produite (donc bon en AZERTY comme en QWERTY).
    /// Les captures passent par le code de touche : la rangée des chiffres ne bouge pas.
    private static func shortcut(for event: NSEvent) -> EchoShortcut? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.option) else { return nil }
        let shift = flags.contains(.shift)

        if shift {
            switch event.keyCode {
            case 20, 21, 23: // 3, 4, 5
                return .screenshot
            default:
                break
            }
        }
        guard !flags.contains(.control) else { return nil }

        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        switch (key, shift) {
        case ("c", false): return .copy
        case ("x", false): return .cut
        case ("v", false): return .paste
        case ("z", false): return .undo
        case ("z", true): return .redo
        case ("s", false): return .save
        case ("a", false): return .selectAll
        case ("f", false): return .find
        default: return nil // ⌘Tab et tout le reste : ignorés
        }
    }

    private func handleKey(_ event: NSEvent) {
        guard !event.isARepeat, let shortcut = ShortcutEcho.shortcut(for: event) else { return }
        let config = settings.s
        guard config.echoEnabled, !config.echoDisabled.contains(shortcut.rawValue) else { return }

        var echo = EchoEvent(key: shortcut.rawValue, symbol: shortcut.symbol,
                             label: shortcut.label, tint: shortcut.tint)
        echo.flash = shortcut == .screenshot
        echo.opensClipboard = shortcut == .copy || shortcut == .cut || shortcut == .paste
        onEcho?(echo, false)

        if shortcut == .copy || shortcut == .cut {
            pendingCopy = echo
            pendingCopyAt = Date().timeIntervalSinceReferenceDate
            captureClipboard(for: echo)
        }
    }

    /// Bouton « Tester » des réglages : un écho sans passer par le clavier.
    func test(_ shortcut: EchoShortcut) {
        var echo = EchoEvent(key: shortcut.rawValue, symbol: shortcut.symbol,
                             label: shortcut.label, tint: shortcut.tint)
        echo.flash = shortcut == .screenshot
        echo.opensClipboard = shortcut == .copy
        if shortcut == .copy {
            echo.preview = "Aura réagit à tes raccourcis"
        }
        onEcho?(echo, false)
    }

    // MARK: Volume et luminosité

    private func handleSystem(_ event: NSEvent) {
        guard event.subtype.rawValue == MediaKeyCode.subtype else { return }
        let config = settings.s

        let data = event.data1
        let code = Int32((data >> 16) & 0xFFFF)
        let flags = data & 0xFFFF
        let isDown = ((flags >> 8) & 0xFF) == 0x0A
        guard isDown else { return }

        switch code {
        case MediaKeyCode.soundUp, MediaKeyCode.soundDown, MediaKeyCode.mute:
            if config.notchVolume { volumeEcho() }
        case MediaKeyCode.brightnessUp:
            if config.notchBrightness { brightnessEcho(direction: 1) }
        case MediaKeyCode.brightnessDown:
            if config.notchBrightness { brightnessEcho(direction: -1) }
        default:
            break
        }
    }

    /// S'abonne aux changements de volume de la sortie audio par défaut.
    /// C'est la voie principale : elle marche sans autorisation et quelle que soit l'origine
    /// du changement (touches, Centre de contrôle, autre app).
    private func startVolumeWatch() {
        guard deviceBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.bindVolumeDevice()
            }
        }
        deviceBlock = block
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &address, DispatchQueue.main, block)
        bindVolumeDevice()
    }

    private func stopVolumeWatch() {
        unbindVolumeDevice()
        if let deviceBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                       &address, DispatchQueue.main, deviceBlock)
        }
        deviceBlock = nil
    }

    /// (Re)branche l'écoute sur la sortie par défaut du moment (casque branché, AirPods…).
    private func bindVolumeDevice() {
        unbindVolumeDevice()
        guard deviceBlock != nil, let device = SystemVolume.defaultDevice() else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.volumeChanged()
            }
        }
        let addresses = SystemVolume.watchAddresses(for: device)
        for var address in addresses {
            _ = AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
        }
        volumeDevice = device
        volumeBlock = block
        volumeAddresses = addresses
        lastVolumeKey = ShortcutEcho.volumeKey(SystemVolume.read())
    }

    private func unbindVolumeDevice() {
        if let volumeBlock {
            for var address in volumeAddresses {
                _ = AudioObjectRemovePropertyListenerBlock(volumeDevice, &address, DispatchQueue.main, volumeBlock)
            }
        }
        volumeBlock = nil
        volumeAddresses = []
        volumeDevice = AudioDeviceID(0)
    }

    private static func volumeKey(_ reading: (level: Double, muted: Bool)?) -> String {
        guard let reading else { return "?" }
        return "\(Int((reading.level * 100).rounded()))|\(reading.muted)"
    }

    /// CoreAudio signale un changement (une fois par canal) : on n'affiche que si la valeur a bougé.
    private func volumeChanged() {
        let reading = SystemVolume.read()
        let key = ShortcutEcho.volumeKey(reading)
        guard key != lastVolumeKey else { return }
        lastVolumeKey = key
        guard settings.s.notchVolume else { return }
        presentVolume(reading)
    }

    /// Touche de volume : on lit juste après, le temps que macOS l'applique. Sert surtout quand la
    /// valeur ne change pas (déjà au maximum), cas que CoreAudio ne signale pas.
    private func volumeEcho() {
        volumeToken += 1
        let token = volumeToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard let self, self.volumeToken == token else { return }
            let reading = SystemVolume.read()
            self.lastVolumeKey = ShortcutEcho.volumeKey(reading)
            self.presentVolume(reading)
        }
    }

    private func presentVolume(_ reading: (level: Double, muted: Bool)?) {
        let muted = reading?.muted ?? false
        let level = muted ? 0 : (reading?.level ?? 0)
        let symbol: String
        if muted || level <= 0.001 {
            symbol = "speaker.slash.fill"
        } else if level < 0.34 {
            symbol = "speaker.wave.1.fill"
        } else if level < 0.67 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }
        var echo = EchoEvent(key: "volume", symbol: symbol,
                             label: muted ? "Muet" : "Volume", tint: .white)
        echo.level = level
        echo.glowLevel = level
        echo.value = "\(Int((level * 100).rounded())) %"
        echo.glow = settings.s.notchColorVolume
        onEcho?(echo, true)
    }

    /// Touche de luminosité : on lit la valeur juste après, puis on l'affiche en pourcentage.
    private func brightnessEcho(direction: Int) {
        brightnessToken += 1
        let token = brightnessToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard let self, self.brightnessToken == token else { return }
            self.presentBrightness(direction: direction)
        }
    }

    private func presentBrightness(direction: Int) {
        let level = DisplayBrightness.read()
        let bright = (level ?? (direction > 0 ? 1 : 0)) >= 0.5
        var echo = EchoEvent(key: "brightness",
                             symbol: bright ? "sun.max.fill" : "sun.min.fill",
                             label: "Luminosité",
                             tint: .white)
        if let level {
            echo.value = "\(Int((level * 100).rounded())) %"
            echo.glowLevel = level
        } else {
            echo.sweep = direction
        }
        echo.glow = settings.s.notchColorBrightness
        onEcho?(echo, true)
    }

    /// Boutons « Tester » des réglages.
    func testVolume() {
        presentVolume(SystemVolume.read() ?? (level: 0.63, muted: false))
    }

    func testBrightness() {
        presentBrightness(direction: 1)
    }

    // MARK: Presse-papiers

    /// Après ⌘C / ⌘X : attend que l'app ait rempli le presse-papiers, puis complète l'écho.
    private func captureClipboard(for echo: EchoEvent) {
        Task { @MainActor [weak self] in
            for delay in [UInt64(110_000_000), UInt64(260_000_000)] {
                try? await Task.sleep(nanoseconds: delay)
                guard let self else { return }
                if self.readClipboard(into: echo) { return }
            }
        }
    }

    /// Vrai si le presse-papiers a changé depuis la dernière lecture (et note la nouvelle valeur).
    private func consumeClipboardChange() -> Bool {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return false }
        lastChangeCount = count
        return true
    }

    /// Renvoie vrai si le presse-papiers a changé : l'écho du raccourci est alors complété.
    private func readClipboard(into echo: EchoEvent) -> Bool {
        guard consumeClipboardChange() else { return false }
        pendingCopy = nil
        onUpdate?(filled(echo))
        return true
    }

    /// Complète un écho avec l'aperçu de ce qui vient d'être copié, et range le texte dans l'historique.
    private func filled(_ echo: EchoEvent) -> EchoEvent {
        let pasteboard = NSPasteboard.general
        var updated = echo
        let types = pasteboard.types ?? []

        // Mots de passe et contenus éphémères : ni aperçu, ni historique.
        if types.contains(where: { ShortcutEcho.secretTypes.contains($0.rawValue) }) {
            updated.symbol = "lock.fill"
            updated.preview = "contenu masqué"
            updated.opensClipboard = false
            return updated
        }

        if let text = pasteboard.string(forType: .string), !text.trimmed.isEmpty {
            updated.preview = ClipItem.makePreview(text, limit: 28)
            remember(text)
        } else if types.contains(.tiff) || types.contains(.png),
                  let image = NSImage(pasteboard: pasteboard) {
            updated.thumbnail = ShortcutEcho.thumbnail(of: image)
            if updated.thumbnail == nil {
                updated.preview = "image"
            }
        }
        return updated
    }

    /// Miniature 32 × 20 pt (rendue en 2x), pour ne pas garder l'image d'origine en mémoire.
    private static func thumbnail(of image: NSImage) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0
        else { return nil }
        let width = 64
        let height = 40
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = max(CGFloat(width) / CGFloat(source.width), CGFloat(height) / CGFloat(source.height))
        let drawn = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: (CGFloat(width) - drawn.width) / 2,
                                        y: (CGFloat(height) - drawn.height) / 2,
                                        width: drawn.width,
                                        height: drawn.height))
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: 32, height: 20))
    }

    private func remember(_ text: String) {
        let config = settings.s
        guard config.clipHistoryEnabled, text.utf16.count <= 100_000 else { return }
        var list = clips.filter { $0.text != text }
        list.insert(ClipItem(text: text), at: 0)
        if list.count > ShortcutEcho.historyLimit {
            list.removeLast(list.count - ShortcutEcho.historyLimit)
        }
        clips = list
        if config.clipPersist {
            saveClips()
        }
    }

    /// Remet un ancien texte dans le presse-papiers et le remonte en tête.
    func recopy(_ clip: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clip.text, forType: .string)
        lastChangeCount = pasteboard.changeCount

        var list = clips.filter { $0.id != clip.id }
        list.insert(clip, at: 0)
        clips = list
        if settings.s.clipPersist {
            saveClips()
        }

        var echo = EchoEvent(key: "recopy", symbol: "doc.on.doc.fill",
                             label: "Recopié", tint: AuraPalette.done)
        echo.preview = ClipItem.makePreview(clip.text, limit: 28)
        onEcho?(echo, false)
    }

    func clearClips() {
        if !clips.isEmpty { clips = [] }
        UserDefaults.standard.removeObject(forKey: ShortcutEcho.clipsKey)
    }

    /// Réglage « garder l'historique entre deux lancements » modifié.
    func setPersistence(_ enabled: Bool) {
        if enabled {
            saveClips()
        } else {
            UserDefaults.standard.removeObject(forKey: ShortcutEcho.clipsKey)
        }
    }

    private func saveClips() {
        UserDefaults.standard.set(clips.map(\.text), forKey: ShortcutEcho.clipsKey)
    }

    // MARK: Son

    /// Clic discret. Copie du son système pour ne pas toucher au volume des autres sons d'Aura.
    func click() {
        if clickSound == nil {
            let sound = NSSound(named: NSSound.Name("Tink"))?.copy() as? NSSound
            sound?.volume = 0.18
            clickSound = sound
        }
        guard let clickSound else { return }
        if clickSound.isPlaying {
            clickSound.stop()
        }
        clickSound.play()
    }
}
