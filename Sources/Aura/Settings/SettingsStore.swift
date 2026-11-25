import SwiftUI
import AppKit
import Combine

extension StringProtocol {
    /// Chaîne sans espaces ni retours à la ligne aux extrémités.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Couleur sRGB simple, stockable dans les réglages.
struct RGB: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? NSColor.white
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }

    init(color: Color) {
        self.init(nsColor: NSColor(color))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
    var cgColor: CGColor { CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }
}

/// Réponse possible à une demande de validation. `pass` = Aura ne se prononce pas.
enum Verdict: String, Codable, CaseIterable {
    case allow, deny, ask, pass
}

enum HaloColorMode: String, Codable, CaseIterable {
    case artwork, manual, spectrum

    var label: String {
        switch self {
        case .artwork: return "Pochette"
        case .manual: return "Manuel"
        case .spectrum: return "Spectre"
        }
    }
}

enum HaloRest: String, Codable, CaseIterable {
    case fixed, breathe, off

    var label: String {
        switch self {
        case .fixed: return "Lueur fixe"
        case .breathe: return "Respiration lente"
        case .off: return "Extinction"
        }
    }
}

/// Tous les réglages d'Aura. Chaque champ a une valeur par défaut : « Réinitialiser » = `AuraSettings()`.
struct AuraSettings: Codable, Equatable {
    // Général
    var soundEnabled = true
    var notificationsEnabled = false
    var screenName = ""

    // Agents
    var agentsEnabled = true
    var port = 47823
    var approvalTimeout = 60.0
    var defaultDecision = Verdict.ask
    var unlistedPassthrough = false
    var claudeEnabled = true
    var codexEnabled = true
    var cursorEnabled = true
    /// Codex ne signale que la fin d'un tour : Aura suit son journal de session pour voir
    /// aussi « au travail ».
    var codexWatch = true
    var showWhileWorking = true
    var doneDisplaySeconds = 4.0
    var claudeApp = ""
    var codexApp = ""
    var cursorApp = ""
    var autoApprove: [String] = [
        "ls", "pwd", "cd", "cat", "head", "tail", "wc", "which", "echo",
        "grep", "rg", "git status", "git diff", "git log", "git branch",
        "npm run build", "npm run lint", "npm test", "swift build"
    ]
    var alwaysAsk: [String] = [
        "rm", "sudo", "git push", "git reset", "git clean", "curl", "wget",
        "chmod", "chown", "dd", "kill", "ssh", "npm publish", "brew"
    ]

    // Halo
    var haloEnabled = false
    var haloColorMode = HaloColorMode.artwork
    var haloColor1 = RGB(r: 0.42, g: 0.36, b: 1.0)
    var haloColor2 = RGB(r: 1.0, g: 0.36, b: 0.62)
    var haloRatio = 0.5
    var haloThickness = 44.0
    var haloIntensity = 0.85
    /// Rayon intérieur de la lueur aux coins. Les coins physiques du haut d'un MacBook font environ 10 pt.
    /// Quelle que soit la valeur, la lueur remplit toujours le coin jusqu'au vrai bord de l'écran.
    var haloCorner = 10.0
    var haloAvoidNotch = true
    var haloDrift = true
    var haloReactivity = 1.0
    var haloAttack = 0.55
    var haloRelease = 0.12
    var haloRest = HaloRest.breathe
    var haloApprovalPulse = true
    var haloDoneFlash = true
    var haloHideFromCapture = false

    // Écho des raccourcis
    var echoEnabled = true
    var echoDuration = 0.9
    /// Raccourcis coupés (valeurs brutes de `EchoShortcut`).
    var echoDisabled: [String] = []
    var echoHaloFlash = false
    var echoSound = false
    var clipHistoryEnabled = true
    var clipPersist = false

    // Notifications dans l'encoche
    var noticesEnabled = false
    var noticeDuration = 5.0
    /// Identifiants de bundle des apps à ignorer / à mettre en avant.
    var noticeIgnored: [String] = []
    var noticePriority: [String] = []
    var noticeDND = false
    var noticeSound = false

    // Encoche (la surface unique d'Aura)
    var notchEnabled = true
    /// Le survol prolongé de l'encoche ouvre le panneau d'accueil.
    var notchHover = true
    var notchHoverDelay = 0.3
    var notchVolume = true
    var notchBrightness = true
    var notchMusic = true
    /// Durée d'affichage du volume et de la luminosité.
    var notchHudDuration = 1.6
    var notchGlow = true
    var notchGlowIntensity = 0.9
    /// Une onde part de l'encoche à chaque action d'un agent (fichier lu, commande, édition).
    var notchAgentPulse = true
    /// Branchement, débranchement, seuil bas, charge terminée.
    var batteryEnabled = true

    // Agenda (abonnement ICS, lecture seule)
    var calendarEnabled = false
    var calendarFeeds: [CalendarFeed] = []

    // Rappel de boire
    var waterEnabled = true
    /// Minutes entre deux rappels. Le compte repart si tu quittes le Mac.
    var waterInterval = 60.0

    // Minuteur de concentration (onglet Minuteur du panneau de l'encoche)
    var pomodoroEnabled = true
    /// Minutes de travail puis de pause.
    var pomodoroWork = 25.0
    var pomodoroRest = 5.0
    var notchColorVolume = RGB(r: 0.22, g: 0.55, b: 1.0)
    var notchColorBrightness = RGB(r: 1.0, g: 0.6, b: 0.12)
    var notchColorApproval = RGB(r: 1.0, g: 0.58, b: 0.1)
    var notchColorDone = RGB(r: 0.2, g: 0.9, b: 0.45)
    var notchColorEcho = RGB(r: 0.45, g: 0.7, b: 1.0)
    /// Trace en rouge le contour exact utilisé (bord d'écran et forme d'encoche).
    var notchDiagnostics = false

    // Météo (Open-Meteo, sans clé)
    var weatherEnabled = true
    var weatherCities: [WeatherCity] = [
        // Ville de départ sans signification : remplace-la par la tienne dans Réglages > Météo.
        WeatherCity(name: "Paris", region: "France", latitude: 48.8534, longitude: 2.3488)
    ]
    var weatherCity = 0
    var weatherFahrenheit = false
}

@MainActor
final class SettingsStore: ObservableObject {
    private static let defaultsKey = "aura.settings.v1"
    private static let cornerMigrationKey = "aura.migration.corner10"
    private static let cornerClampKey = "aura.migration.cornerClamp"
    private static let echoOnKey = "aura.migration.echoOn"
    /// Rayon maximal accepté pour les coins du halo.
    static let maxHaloCorner = 24.0

    @Published var s: AuraSettings {
        didSet {
            if s != oldValue { save() }
        }
    }

    init() {
        s = SettingsStore.load()
    }

    func reset() {
        s = AuraSettings()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: SettingsStore.defaultsKey)
    }

    /// Charge les réglages en les posant par-dessus les valeurs par défaut :
    /// un réglage ajouté dans une version future ne casse pas ceux déjà enregistrés.
    private static func load() -> AuraSettings {
        let fallback = AuraSettings()
        let migrateCorner = !UserDefaults.standard.bool(forKey: cornerMigrationKey)
        if migrateCorner {
            UserDefaults.standard.set(true, forKey: cornerMigrationKey)
        }
        // Notée dès le premier lancement : une installation neuve n'a rien à migrer.
        let migrateEcho = !UserDefaults.standard.bool(forKey: echoOnKey)
        if migrateEcho {
            UserDefaults.standard.set(true, forKey: echoOnKey)
        }
        guard let stored = UserDefaults.standard.data(forKey: defaultsKey),
              let storedObject = (try? JSONSerialization.jsonObject(with: stored)) as? [String: Any],
              let baseData = try? JSONEncoder().encode(fallback),
              var merged = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any]
        else { return fallback }

        for (key, value) in storedObject where merged[key] != nil {
            merged[key] = value
        }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              var decoded = try? JSONDecoder().decode(AuraSettings.self, from: mergedData)
        else { return fallback }

        // Migration unique : l'ancien rayon par défaut (18 pt) passe à 10 pt, celui des coins de l'écran.
        // Un rayon choisi à la main n'est pas touché.
        if migrateCorner && decoded.haloCorner == 18.0 {
            decoded.haloCorner = fallback.haloCorner
            if let migrated = try? JSONEncoder().encode(decoded) {
                UserDefaults.standard.set(migrated, forKey: defaultsKey)
            }
        }

        // Deuxième migration, unique elle aussi : la première ne touchait que la valeur exacte 18.
        // Un rayon resté plus grand que les coins réels (jusqu'à 60 pt avec l'ancien curseur)
        // faisait suivre à la lueur un grand arc, loin des coins de l'écran.
        if !UserDefaults.standard.bool(forKey: cornerClampKey) {
            UserDefaults.standard.set(true, forKey: cornerClampKey)
            if decoded.haloCorner > 14 {
                decoded.haloCorner = fallback.haloCorner
                if let migrated = try? JSONEncoder().encode(decoded) {
                    UserDefaults.standard.set(migrated, forKey: defaultsKey)
                }
            }
        }
        if decoded.haloCorner > maxHaloCorner {
            decoded.haloCorner = maxHaloCorner
        }

        // Migration unique : l'écho des raccourcis est maintenant activé par défaut. Un réglage
        // enregistré quand il était coupé d'origine le laissait coupé ; on l'allume une fois,
        // et le choix fait ensuite dans les réglages est respecté.
        if migrateEcho && !decoded.echoEnabled {
            decoded.echoEnabled = true
            if let migrated = try? JSONEncoder().encode(decoded) {
                UserDefaults.standard.set(migrated, forKey: defaultsKey)
            }
        }
        return decoded
    }
}

/// Mesures de l'encoche d'un écran, en points, dans le repère local de l'écran.
struct NotchMetrics: Equatable {
    /// Vrai si l'écran a une encoche physique ; sinon l'encoche est virtuelle.
    var hasNotch: Bool
    var width: CGFloat
    var height: CGFloat
    /// Abscisse du centre de l'encoche depuis le bord gauche de l'écran.
    var centerX: CGFloat
}

/// Choix de l'écran et géométrie de l'encoche.
@MainActor
enum ScreenPicker {
    /// Écran choisi dans les réglages ; sinon celui qui a une encoche ; sinon l'écran principal.
    static func current(named name: String) -> NSScreen? {
        let screens = NSScreen.screens
        if !name.isEmpty, let match = screens.first(where: { $0.localizedName == name }) {
            return match
        }
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return screens.first ?? NSScreen.main
    }

    /// Mesures de l'encoche. Les zones auxiliaires sont les deux bandes libres à gauche et à droite
    /// de l'encoche : la largeur de la bande gauche donne directement le bord gauche de l'encoche,
    /// sans supposer qu'elle est centrée.
    static func metrics(on screen: NSScreen) -> NotchMetrics {
        let top = screen.safeAreaInsets.top
        if top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            if width > 20 {
                return NotchMetrics(hasNotch: true,
                                    width: width,
                                    height: top,
                                    centerX: left.width + width / 2)
            }
        }
        // Pas d'encoche physique : encoche virtuelle de taille standard, centrée.
        return NotchMetrics(hasNotch: false, width: 184, height: 30, centerX: screen.frame.width / 2)
    }

    /// Rectangle de l'encoche physique en coordonnées locales à l'écran (origine en bas à gauche).
    static func notchRect(on screen: NSScreen) -> CGRect? {
        let metrics = ScreenPicker.metrics(on: screen)
        guard metrics.hasNotch else { return nil }
        return CGRect(x: metrics.centerX - metrics.width / 2,
                      y: screen.frame.height - metrics.height,
                      width: metrics.width,
                      height: metrics.height)
    }

    /// Résumé chiffré de la géométrie lue sur l'écran, pour le mode diagnostic.
    static func describe(_ screen: NSScreen) -> String {
        let metrics = ScreenPicker.metrics(on: screen)
        let frame = screen.frame
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let lines = [
            "Écran : \(screen.localizedName) · \(Int(frame.width)) × \(Int(frame.height)) pt · échelle \(screen.backingScaleFactor)",
            "Origine : x \(Int(frame.minX)), y \(Int(frame.minY)) · marge haute \(screen.safeAreaInsets.top) pt",
            "Bande gauche : \(left.width) × \(left.height) · bande droite : \(right.width) × \(right.height)",
            metrics.hasNotch
                ? "Encoche : \(metrics.width) × \(metrics.height) pt, centre à x = \(metrics.centerX)"
                : "Pas d'encoche physique : encoche virtuelle \(metrics.width) × \(metrics.height) pt"
        ]
        return lines.joined(separator: "\n")
    }
}
