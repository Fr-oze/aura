import SwiftUI
import AppKit

/// Panneau d'accueil ouvert au survol de l'encoche : onglets icônes, puis le contenu de l'onglet.
@MainActor
struct HomePanel: View {
    @EnvironmentObject private var model: NotchModel
    @EnvironmentObject private var settings: SettingsStore

    private var tabs: [HomeTab] {
        HomeTab.allCases.filter { tab in
            switch tab {
            case .home: return true
            case .agenda: return settings.s.calendarEnabled
            case .timer: return settings.s.pomodoroEnabled
            case .weather: return settings.s.weatherEnabled
            case .clipboard: return settings.s.clipHistoryEnabled
            case .notices: return true
            }
        }
    }

    private var shown: HomeTab {
        tabs.contains(model.tab) ? model.tab : .home
    }

    var body: some View {
        PanelFrame {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(shown.label)
                        .font(NotchFont.text(15, .bold))
                        .foregroundStyle(.white)
                        .frame(width: 128, alignment: .leading)
                    ForEach(tabs) { tab in
                        TabButton(tab: tab, selected: tab == shown, badge: badge(for: tab)) {
                            model.tab = tab
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 28)

                Group {
                    switch shown {
                    case .home: HomeTabView()
                    case .agenda: AgendaTabView()
                    case .timer: TimerTabView()
                    case .weather: WeatherTabView()
                    case .clipboard: ClipboardTabView()
                    case .notices: NoticesTabView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
    }

    private func badge(for tab: HomeTab) -> Int {
        switch tab {
        case .notices: return model.notices.count
        case .clipboard: return model.clips.count
        case .home, .weather, .agenda, .timer: return 0
        }
    }
}

@MainActor
struct TabButton: View {
    let tab: HomeTab
    let selected: Bool
    let badge: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(NotchFont.digits(10, .semibold))
                }
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.label)
    }
}

/// Carte sombre légèrement plus claire que le fond, comme sur les panneaux de référence.
@MainActor
struct PanelCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
    }
}

// MARK: - Accueil

@MainActor
struct HomeTabView: View {
    var body: some View {
        HStack(spacing: 10) {
            PanelCard {
                MusicCard()
            }
            PanelCard {
                AgentsCard()
            }
            .frame(width: 262)
        }
    }
}

/// Musique : pochette, titre, artiste, et les trois commandes.
@MainActor
struct MusicCard: View {
    @EnvironmentObject private var model: NotchModel
    @EnvironmentObject private var music: MusicState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        if music.hasTrack {
            HStack(alignment: .center, spacing: 14) {
                ArtworkView(image: music.artwork, side: 96, radius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.title.isEmpty ? "Morceau inconnu" : music.title)
                        .font(NotchFont.text(14, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(music.artist)
                        .font(NotchFont.text(12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 18) {
                        control("backward.fill", size: 14) { model.onMusic?(.previous) }
                        control(music.isPlaying ? "pause.fill" : "play.fill", size: 20) { model.onMusic?(.toggle) }
                        control("forward.fill", size: 14) { model.onMusic?(.next) }
                        Spacer(minLength: 0)
                        Text(music.source)
                            .font(NotchFont.text(10, .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Rien en lecture")
                    .font(NotchFont.text(13, .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(settings.s.notchMusic
                     ? "Lance un morceau dans Spotify ou Musique."
                     : "Le suivi de la musique est coupé dans Réglages > Encoche.")
                    .font(NotchFont.text(11))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Sessions d'agents en cours. Clic = passe au premier plan l'app qui héberge la session.
@MainActor
struct AgentsCard: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AGENTS")
                .font(NotchFont.digits(10, .semibold))
                .foregroundStyle(.white.opacity(0.45))
            if model.sessions.isEmpty {
                Text("Aucun agent actif")
                    .font(NotchFont.text(12))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(model.sessions.prefix(4)) { session in
                    HStack(spacing: 8) {
                        SourceBadge(source: session.source, size: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(session.project)
                                .font(NotchFont.text(12, .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(AgentsCard.status(of: session))
                                .font(NotchFont.text(10))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        PhaseGlyph(phase: session.phase)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.onActivate?(session)
                    }
                }
            }
        }
    }

    private static func status(of session: AgentSession) -> String {
        switch session.phase {
        case .working: return session.detail.isEmpty ? "au travail" : session.detail
        case .waiting: return session.detail.isEmpty ? "attend ta réponse" : session.detail
        case .done: return "terminé"
        case .error: return session.detail.isEmpty ? "erreur" : session.detail
        }
    }
}

// MARK: - Météo

@MainActor
struct WeatherTabView: View {
    @EnvironmentObject private var weather: WeatherService
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 8) {
            PanelCard {
                if let report = weather.report {
                    HStack(alignment: .top, spacing: 16) {
                        CurrentWeather(report: report)
                            .frame(width: 176, alignment: .leading)
                        HourlyWeather(report: report)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        DailyWeather(report: report)
                            .frame(width: 150, alignment: .leading)
                    }
                } else {
                    Text(placeholder)
                        .font(NotchFont.text(12))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            HStack(spacing: 6) {
                ForEach(Array(settings.s.weatherCities.enumerated()), id: \.offset) { index, city in
                    CityChip(name: city.name, selected: index == weather.selectedIndex) {
                        weather.select(index)
                    }
                }
                Spacer(minLength: 4)
                if !weather.error.isEmpty {
                    Text(weather.error)
                        .font(NotchFont.text(10))
                        .foregroundStyle(AuraPalette.attention)
                        .lineLimit(1)
                }
                Button {
                    weather.refresh(force: true)
                } label: {
                    Image(systemName: weather.loading ? "ellipsis" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 24, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Actualiser")
            }
            .frame(height: 22)
        }
    }

    private var placeholder: String {
        if settings.s.weatherCities.isEmpty {
            return "Ajoute une ville dans Réglages > Météo."
        }
        if weather.loading {
            return "Chargement de la météo…"
        }
        return weather.error.isEmpty ? "Météo pas encore chargée." : weather.error
    }
}

/// Pastille d'une ville favorite ; la ville affichée est en bleu.
@MainActor
struct CityChip: View {
    let name: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name.uppercased())
                .font(NotchFont.digits(10, .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(selected ? Color(red: 0.22, green: 0.5, blue: 1.0) : Color.white.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Température entière avec le signe degré (« 10° »).
private func degrees(_ value: Double) -> String {
    "\(Int(value.rounded()))°"
}

@MainActor
struct WeatherIcon: View {
    let code: Int
    let isDay: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: WeatherCode.symbol(code, isDay: isDay))
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size))
    }
}

@MainActor
struct CurrentWeather: View {
    let report: WeatherReport

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(report.city.name.uppercased()) · \(report.time)")
                .font(NotchFont.digits(10, .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            HStack(alignment: .center, spacing: 10) {
                WeatherIcon(code: report.code, isDay: report.isDay, size: 30)
                Text(degrees(report.temperature))
                    .font(NotchFont.digits(32, .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text("\(WeatherCode.label(report.code)) · ressenti \(degrees(report.feelsLike))")
                .font(NotchFont.text(11, .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Text("Humidité \(Int(report.humidity.rounded())) % · vent \(Int(report.wind.rounded())) \(report.windUnit)")
                .font(NotchFont.text(10))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
    }
}

@MainActor
struct HourlyWeather: View {
    let report: WeatherReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HEURE PAR HEURE")
                .font(NotchFont.digits(10, .semibold))
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 0) {
                ForEach(report.hours) { hour in
                    VStack(spacing: 7) {
                        Text(hour.label)
                            .font(NotchFont.digits(10, .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .fixedSize()
                        WeatherIcon(code: hour.code, isDay: hour.isDay, size: 15)
                            .frame(height: 18)
                        Text(degrees(hour.temperature))
                            .font(NotchFont.digits(12))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

@MainActor
struct DailyWeather: View {
    let report: WeatherReport

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PROCHAINS JOURS")
                .font(NotchFont.digits(10, .semibold))
                .foregroundStyle(.white.opacity(0.55))
            ForEach(report.days) { day in
                HStack(spacing: 6) {
                    Text(day.label.uppercased())
                        .font(NotchFont.digits(10, .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .frame(width: 52, alignment: .leading)
                    WeatherIcon(code: day.code, isDay: true, size: 12)
                        .frame(width: 20)
                    Spacer(minLength: 0)
                    Text(degrees(day.low))
                        .font(NotchFont.digits(11, .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize()
                    Text(degrees(day.high))
                        .font(NotchFont.digits(11))
                        .foregroundStyle(.white)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Presse-papiers et notifications

/// Ligne de liste avec surbrillance au survol.
@MainActor
struct HoverRow<Content: View>: View {
    private let content: Content
    @State private var inside = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(inside ? 0.11 : 0))
            )
            .contentShape(Rectangle())
            .onHover { inside = $0 }
    }
}

@MainActor
struct ClipboardTabView: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        if model.clips.isEmpty {
            Text("Aucun texte copié pour l'instant. Les ⌘C et ⌘X s'ajoutent ici quand l'écho des raccourcis est activé.")
                .font(NotchFont.text(12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    ForEach(model.clips) { clip in
                        HoverRow {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .frame(width: 14)
                                Text(clip.preview)
                                    .font(NotchFont.text(12))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(height: 28)
                        }
                        .onTapGesture {
                            model.onRecopy?(clip)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
struct NoticesTabView: View {
    @EnvironmentObject private var model: NotchModel

    var body: some View {
        if model.notices.isEmpty {
            Text("Aucune notification gardée.")
                .font(NotchFont.text(12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 4) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 1) {
                        ForEach(model.notices) { item in
                            HoverRow {
                                NoticeRow(item: item)
                            }
                            .onTapGesture {
                                model.onOpenNotice?(item)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        model.onClearNotices?()
                    } label: {
                        Text("Tout effacer")
                            .font(NotchFont.text(10, .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 9)
                            .frame(height: 20)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

@MainActor
struct NoticeRow: View {
    let item: NoticeItem

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: AppLookup.icon(for: item.bundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.headline)
                        .font(NotchFont.text(12, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.appName + " · " + item.date.formatted(date: .omitted, time: .shortened))
                        .font(NotchFont.text(10))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(item.detail.isEmpty ? "Nouvelle notification" : item.detail)
                    .font(NotchFont.text(11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(height: 42)
    }
}
