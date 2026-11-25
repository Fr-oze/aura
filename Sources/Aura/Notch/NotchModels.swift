import SwiftUI
import AppKit

enum AuraPalette {
    static let working = Color(red: 0.47, green: 0.67, blue: 1.0)
    static let attention = Color(red: 1.0, green: 0.6, blue: 0.12)
    static let done = Color(red: 0.26, green: 0.86, blue: 0.48)
    static let error = Color(red: 1.0, green: 0.33, blue: 0.33)
    static let notice = Color(red: 0.66, green: 0.55, blue: 1.0)
    static let echo = Color(red: 0.86, green: 0.88, blue: 0.95)

    static func color(for phase: AgentPhase) -> Color {
        switch phase {
        case .working: return working
        case .waiting: return attention
        case .done: return done
        case .error: return error
        }
    }
}

// MARK: - Modèles

/// Un écho : ce que les ailes de l'encoche affichent un instant (raccourci, volume, luminosité).
struct EchoEvent: Identifiable {
    var id = UUID()
    /// Type d'écho (« copy », « volume »…) : sert à mettre à jour sur place.
    var key: String
    var symbol: String
    var label: String
    var tint: Color
    /// Aperçu du texte copié (déjà tronqué).
    var preview = ""
    /// Miniature de l'image copiée.
    var thumbnail: NSImage?
    /// Niveau entre 0 et 1 (volume), ou nil.
    var level: Double?
    /// Valeur chiffrée affichée à droite (« 63 % »).
    var value = ""
    /// +1 ou -1 : barre animée sans valeur (luminosité illisible). 0 = aucune.
    var sweep = 0
    /// Flash blanc de capture d'écran.
    var flash = false
    /// Le survol de cet écho ouvre le panneau sur le presse-papiers.
    var opensClipboard = false
    /// Couleur du halo d'encoche pour cet écho ; nil = couleur des raccourcis.
    var glow: RGB?
    /// Valeur entre 0 et 1 que l'intensité du halo doit suivre (volume, luminosité), ou nil.
    var glowLevel: Double?

    /// Largeur de chaque aile pour ce contenu.
    var wing: CGFloat {
        if level != nil { return 96 }
        if !value.isEmpty { return 78 }
        if sweep != 0 { return 88 }
        var text = CGFloat(label.count) * 7.2
        if thumbnail != nil {
            text += 38
        } else if !preview.isEmpty {
            text += 8 + CGFloat(min(preview.count, EchoEvent.previewLimit)) * 6.4
        }
        return min(214, max(72, (text + 36).rounded()))
    }

    /// Longueur de l'aperçu du texte copié montré dans l'aile.
    static let previewLimit = 16
}

/// Une notification d'une autre app, telle qu'Aura l'a lue.
struct NoticeItem: Identifiable, Equatable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var title: String
    var subtitle: String
    var body: String
    var date: Date

    var headline: String {
        title.isEmpty ? appName : title
    }

    var detail: String {
        if subtitle.isEmpty { return body }
        if body.isEmpty { return subtitle }
        return subtitle + " · " + body
    }
}

/// Un texte gardé dans l'historique du presse-papiers.
struct ClipItem: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var preview: String

    init(text: String) {
        self.text = text
        self.preview = ClipItem.makePreview(text, limit: 90)
    }

    /// Une seule ligne, sans blancs en double, coupée à `limit` caractères.
    static func makePreview(_ text: String, limit: Int) -> String {
        let head = String(text.prefix(limit * 3))
        let words = head.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let line = words.joined(separator: " ")
        if line.count > limit {
            return String(line.prefix(limit)) + "…"
        }
        return line
    }
}

/// Nom, icône et couleur d'une app à partir de son identifiant de bundle (avec cache).
@MainActor
enum AppLookup {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]
    private static var tints: [String: RGB] = [:]
    private static var tintless: Set<String> = []

    static func url(for bundleID: String) -> URL? {
        guard !bundleID.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(for bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        var name = ""
        if let url = url(for: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") {
                name = String(name.dropLast(4))
            }
        }
        if name.isEmpty {
            name = bundleID.split(separator: ".").last.map { String($0).capitalized } ?? "App"
        }
        names[bundleID] = name
        return name
    }

    static func icon(for bundleID: String) -> NSImage {
        if let cached = icons[bundleID] { return cached }
        let image: NSImage
        if let url = url(for: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil) ?? NSImage()
        }
        icons[bundleID] = image
        return image
    }

    /// Couleur dominante de l'icône de l'app : c'est la couleur du halo d'une notification.
    static func tint(for bundleID: String) -> RGB? {
        if let cached = tints[bundleID] { return cached }
        if tintless.contains(bundleID) { return nil }
        guard url(for: bundleID) != nil else {
            tintless.insert(bundleID)
            return nil
        }
        var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        guard let image = icon(for: bundleID).cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let pair = ColorExtractor.dominantPair(from: image)
        else {
            tintless.insert(bundleID)
            return nil
        }
        tints[bundleID] = pair.0
        return pair.0
    }
}

// MARK: - État de l'encoche

/// Ce que l'encoche montre. Une seule scène à la fois, choisie par ordre de priorité.
enum NotchScene: Equatable {
    /// Rien à montrer : la forme se confond avec l'encoche physique.
    case rest
    /// Ailes : agent au travail, terminé, en erreur ou en attente.
    case agent
    /// Ailes : musique en cours.
    case music
    /// Ailes : volume, luminosité, raccourci.
    case echo
    /// Petit panneau : message d'Aura à cliquer (autorisation manquante).
    case hint
    /// Panneau : notification d'une autre app.
    case notice
    /// Panneau : validation d'une commande d'agent.
    case approval
    /// Panneau : question posée par un agent (choix, texte, fichier).
    case ask
    /// Panneau d'accueil ouvert au survol.
    case home

    var isExpanded: Bool {
        switch self {
        case .hint, .notice, .approval, .ask, .home: return true
        case .rest, .agent, .music, .echo: return false
        }
    }
}

enum HomeTab: String, CaseIterable, Identifiable {
    case home, agenda, timer, weather, clipboard, notices

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Accueil"
        case .agenda: return "Agenda"
        case .timer: return "Minuteur"
        case .weather: return "Météo"
        case .clipboard: return "Presse-papiers"
        case .notices: return "Notifications"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .agenda: return "calendar"
        case .timer: return "timer"
        case .weather: return "cloud.sun.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .notices: return "bell.fill"
        }
    }
}

/// Dimensions de la forme noire. Elle est toujours collée au bord haut de l'écran.
struct NotchLayout: Equatable {
    var width: CGFloat
    var height: CGFloat
    /// Rayon des coins concaves qui raccordent la forme au bord de l'écran.
    var topRadius: CGFloat
    /// Rayon des coins arrondis du bas.
    var bottomRadius: CGFloat
    /// Largeur de chaque aile (états compacts), 0 sinon.
    var wing: CGFloat = 0
}

/// Message court d'Aura affiché sous l'encoche ; un clic lance son action.
struct NotchHint: Equatable {
    var symbol: String
    var title: String
    var detail: String
}

enum MusicCommand {
    case toggle, next, previous
}

/// Ce que le contenu de l'encoche affiche. Rempli par `NotchEngine`.
@MainActor
final class NotchModel: ObservableObject {
    @Published var scene: NotchScene = .rest
    @Published var layout = NotchLayout(width: 184, height: 32, topRadius: 0, bottomRadius: 9)
    /// Hauteur réservée en haut des panneaux (sous l'encoche physique, rien n'est visible).
    @Published var headerHeight: CGFloat = 32
    @Published var tab: HomeTab = .home

    @Published var sessions: [AgentSession] = []
    @Published var approval: ApprovalRequest?
    @Published var pendingCount = 0
    @Published var ask: AskRequest?
    @Published var askCount = 0

    // Écho (éphémère). `echoTick` change à chaque nouvel écho : il rejoue l'entrée du contenu.
    @Published var echo: EchoEvent?
    @Published var echoTick = 0
    // Notification affichée, et liste des dernières reçues.
    @Published var notice: NoticeItem?
    @Published var noticeTick = 0
    @Published var notices: [NoticeItem] = []
    // Historique du presse-papiers.
    @Published var clips: [ClipItem] = []
    // Message d'Aura (autorisation manquante).
    @Published var hint: NotchHint?

    /// La souris est sur la forme. Tenu par le moteur, pas par SwiftUI.
    var hovered = false

    var onActivate: ((AgentSession) -> Void)?
    var onDecision: ((UUID, Verdict) -> Void)?
    var onAnswer: ((UUID, AskAnswer) -> Void)?
    var onOpenNotice: ((NoticeItem) -> Void)?
    var onClearNotices: (() -> Void)?
    var onRecopy: ((ClipItem) -> Void)?
    var onMusic: ((MusicCommand) -> Void)?
    var onHint: (() -> Void)?
}
