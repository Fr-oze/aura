import SwiftUI
import AppKit

/// Polices de l'encoche : SF Pro pour le texte, SF Mono pour les chiffres.
enum NotchFont {
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func digits(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Racine du contenu : tout est ancré en haut, au centre, dans le rectangle de la forme.
/// La forme noire et le découpage sont faits par les calques de `NotchSurfaceView`.
@MainActor
struct NotchRootView: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        ZStack(alignment: .top) {
            switch model.scene {
            case .rest:
                Color.clear
                    .frame(width: model.layout.width, height: model.layout.height)
            case .agent:
                AgentWings()
                    .transition(.opacity)
            case .music:
                MusicWings()
                    .transition(.opacity)
            case .echo:
                EchoWings()
                    .transition(.opacity)
            case .hint:
                HintPanel()
                    .transition(.opacity)
            case .notice:
                NoticePanel()
                    .transition(.opacity)
            case .approval:
                ApprovalPanel()
                    .transition(.opacity)
            case .ask:
                AskPanel()
                    .transition(.opacity)
            case .home:
                HomePanel()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

// MARK: - Ailes (états compacts)

/// Deux zones de part et d'autre de l'encoche physique : une à gauche, une à droite.
@MainActor
struct WingsLayout<Leading: View, Trailing: View>: View {
    @EnvironmentObject private var model: NotchModel
    private let leading: Leading
    private let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        let inner = max(0, model.layout.wing - 18)
        HStack(spacing: 0) {
            leading
                .frame(width: inner, alignment: .leading)
            Spacer(minLength: 0)
            trailing
                .frame(width: inner, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(width: model.layout.width, height: model.layout.height)
        .contentShape(Rectangle())
    }
}

/// Pastille ronde avec le pictogramme de la source.
@MainActor
struct SourceBadge: View {
    let source: AgentSource
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().fill(source.tint.opacity(0.22))
            Image(systemName: source.symbol)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(source.tint)
        }
        .frame(width: size, height: size)
    }
}

@MainActor
struct PhaseGlyph: View {
    let phase: AgentPhase

    var body: some View {
        switch phase {
        case .working:
            ActivityDots(color: AuraPalette.working)
                .frame(width: 21, height: 6)
                .allowsHitTesting(false)
        case .waiting:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AuraPalette.attention)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AuraPalette.done)
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AuraPalette.error)
        }
    }
}

/// Agent : logo de la source à gauche, état à droite (points, coche verte, erreur, attente).
@MainActor
struct AgentWings: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        if let session = model.sessions.first {
            WingsLayout {
                HStack(spacing: 5) {
                    SourceBadge(source: session.source, size: 20)
                    if model.sessions.count > 1 {
                        Text("+\(model.sessions.count - 1)")
                            .font(NotchFont.digits(10, .bold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            } trailing: {
                PhaseGlyph(phase: session.phase)
            }
            .onTapGesture {
                model.onActivate?(session)
            }
        } else {
            Color.clear
                .frame(width: model.layout.width, height: model.layout.height)
        }
    }
}

/// Musique en cours : pochette miniature à gauche, mini égaliseur à droite.
@MainActor
struct MusicWings: View {
    @EnvironmentObject private var music: MusicState

    var body: some View {
        WingsLayout {
            ArtworkView(image: music.artwork, side: 22, radius: 6)
        } trailing: {
            EqualizerBars(color: .white, active: music.isPlaying)
                .frame(width: 16, height: 13)
                .allowsHitTesting(false)
        }
    }
}

@MainActor
struct ArtworkView: View {
    let image: NSImage?
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.12)
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.45, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Volume, luminosité, raccourci : icône à gauche, valeur ou libellé à droite.
@MainActor
struct EchoWings: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        if let echo = model.echo {
            WingsLayout {
                Image(systemName: echo.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(echo.tint)
                    .frame(width: 20, alignment: .leading)
            } trailing: {
                EchoValue(echo: echo)
            }
            .id(model.echoTick)
            .overlay {
                if echo.flash {
                    ShutterFlash()
                }
            }
        } else {
            Color.clear
                .frame(width: model.layout.width, height: model.layout.height)
        }
    }
}

@MainActor
struct EchoValue: View {
    let echo: EchoEvent

    var body: some View {
        if let level = echo.level {
            HStack(spacing: 7) {
                LevelBar(level: level, tint: .white)
                    .frame(width: 30)
                Text(echo.value)
                    .font(NotchFont.digits(12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        } else if !echo.value.isEmpty {
            Text(echo.value)
                .font(NotchFont.digits(12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        } else if echo.sweep != 0 {
            SweepBar(direction: echo.sweep, tint: .white)
                .frame(width: 46)
        } else {
            HStack(spacing: 6) {
                if let thumbnail = echo.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(echo.label)
                    .font(NotchFont.text(12, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                if echo.thumbnail == nil && !echo.preview.isEmpty {
                    Text(echo.preview)
                        .font(NotchFont.text(11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

/// Barre de niveau (volume) : la largeur suit la valeur sur un ressort court.
@MainActor
struct LevelBar: View {
    let level: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geometry.size.width * CGFloat(min(max(level, 0), 1))))
            }
        }
        .frame(height: 4)
        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: level)
    }
}

/// Barre sans valeur (luminosité illisible) : un éclat traverse la piste dans le sens du réglage.
@MainActor
struct SweepBar: View {
    let direction: Int
    let tint: Color
    @State private var moved = false

    var body: some View {
        GeometryReader { geometry in
            let span = geometry.size.width
            let glint = span * 0.34
            let start = direction > 0 ? CGFloat(0) : span - glint
            let end = direction > 0 ? span - glint : CGFloat(0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: glint)
                    .offset(x: moved ? end : start)
                    .opacity(moved ? 0.35 : 1)
            }
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                moved = true
            }
        }
    }
}

/// Flash blanc bref, façon obturateur.
@MainActor
struct ShutterFlash: View {
    @State private var faded = false

    var body: some View {
        Color.white
            .opacity(faded ? 0 : 0.85)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.38)) {
                    faded = true
                }
            }
    }
}

// MARK: - Panneaux (états étendus)

/// Cadre commun des panneaux : la bande sous l'encoche physique reste vide, le contenu vient dessous.
@MainActor
struct PanelFrame<Content: View>: View {
    @EnvironmentObject private var model: NotchModel
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: model.headerHeight)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: model.layout.width, height: model.layout.height, alignment: .top)
    }
}

/// Message d'Aura (autorisation manquante) : une ligne à cliquer.
@MainActor
struct HintPanel: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        PanelFrame {
            if let hint = model.hint {
                HStack(spacing: 10) {
                    Image(systemName: hint.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AuraPalette.attention)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hint.title)
                            .font(NotchFont.text(12.5, .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(hint.detail)
                            .font(NotchFont.text(10.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.onHint?()
                }
            }
        }
    }
}

/// Notification d'une autre app : icône, nom, titre, extrait. Clic = ouvre l'app.
@MainActor
struct NoticePanel: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        PanelFrame {
            if let item = model.notice {
                HStack(spacing: 11) {
                    Image(nsImage: AppLookup.icon(for: item.bundleID))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.headline)
                                .font(NotchFont.text(13, .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(item.appName)
                                .font(NotchFont.text(10, .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        Text(item.detail.isEmpty ? "Nouvelle notification" : item.detail)
                            .font(NotchFont.text(11.5))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.notices.count > 1 {
                        Text("+\(model.notices.count - 1)")
                            .font(NotchFont.digits(10, .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.onOpenNotice?(item)
                }
                .id(model.noticeTick)
            }
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(text)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Validation requise : la commande et les deux boutons.
@MainActor
struct ApprovalPanel: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        PanelFrame {
            if let approval = model.approval {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        SourceBadge(source: approval.source, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(approval.project)
                                .font(NotchFont.text(14, .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("Validation requise · \(approval.source.label)")
                                .font(NotchFont.text(11, .medium))
                                .foregroundStyle(AuraPalette.attention)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if model.pendingCount > 1 {
                            Text("+\(model.pendingCount - 1) en attente")
                                .font(NotchFont.text(10, .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                        // Compte à rebours : un texte mis à jour par le système, pas d'animation continue.
                        Text(timerInterval: approval.createdAt...approval.deadline, countsDown: true)
                            .font(NotchFont.digits(11, .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize()
                    }

                    Text(approval.command)
                        .font(NotchFont.digits(12, .regular))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46, alignment: .topLeading)
                        .padding(9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.09))
                        )

                    HStack(spacing: 8) {
                        Button {
                            model.onDecision?(approval.id, .deny)
                        } label: {
                            Text("Refuser  esc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(fill: Color.white.opacity(0.13), text: .white))

                        Button {
                            model.onDecision?(approval.id, .allow)
                        } label: {
                            Text("Autoriser  ↩")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(fill: AuraPalette.attention, text: .black))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}
