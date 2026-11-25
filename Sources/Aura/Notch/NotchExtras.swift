import SwiftUI
import AppKit

// MARK: - Agenda

/// Prochains rendez-vous des calendriers auxquels Aura est abonnée.
/// Lecture en colonnes : l'heure à gauche, un filet de couleur par calendrier, le titre.
/// Ce qui est en cours est marqué, le prochain rendez-vous porte le temps qui reste.
@MainActor
struct AgendaTabView: View {
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var settings: SettingsStore

    private static let hour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayLong: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM"
        return formatter
    }()

    private static let dayShort: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d"
        return formatter
    }()

    var body: some View {
        Group {
            if settings.s.calendarFeeds.isEmpty {
                empty("Aucun calendrier. Réglages > Agenda : colle l'adresse iCal de ton agenda Google.")
            } else if case .failed(let message) = calendar.state {
                empty("Agenda illisible — \(message)")
            } else if calendar.upcoming.isEmpty {
                empty(calendar.state == .loading ? "Chargement…" : "Rien de prévu dans les 14 prochains jours.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(grouped(), id: \.label) { day in
                            header(day)
                            ForEach(day.events) { event in
                                row(event)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .onAppear { calendar.refresh(force: false) }
    }

    // MARK: Jour

    private func header(_ day: Day) -> some View {
        HStack(spacing: 8) {
            Text(day.label)
                .font(NotchFont.text(10, .bold))
                .foregroundStyle(day.isToday ? .white.opacity(0.9) : .white.opacity(0.45))
                .textCase(.uppercase)
                .tracking(0.6)
            if !day.detail.isEmpty {
                Text(day.detail)
                    .font(NotchFont.text(10))
                    .foregroundStyle(.white.opacity(0.3))
                    .textCase(.uppercase)
            }
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: Rendez-vous

    private func row(_ event: CalendarEvent) -> some View {
        let live = event.start <= Date() && event.end > Date()
        let isNext = event.id == calendar.next?.id
        return HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(event.allDay ? "journée" : AgendaTabView.hour.string(from: event.start))
                    .font(NotchFont.digits(12, .semibold))
                    .foregroundStyle(.white.opacity(live ? 1 : 0.75))
                if !event.allDay {
                    Text(AgendaTabView.hour.string(from: event.end))
                        .font(NotchFont.digits(9.5, .regular))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(width: 46, alignment: .trailing)

            // Filet de couleur : un calendrier, une couleur.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(AgendaTabView.tint(of: event.calendar).opacity(live ? 1 : 0.65))
                .frame(width: 3, height: event.location.isEmpty ? 22 : 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(NotchFont.text(13, live ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(live ? 1 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !event.location.isEmpty {
                    Text(event.location)
                        .font(NotchFont.text(10))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            if live {
                badge("en cours", color: AuraPalette.done)
            } else if isNext, let countdown = AgendaTabView.countdown(to: event.start) {
                badge(countdown, color: .white.opacity(0.5))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(live ? 0.09 : 0))
        )
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(NotchFont.text(10, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }

    // MARK: Données

    private struct Day {
        var label: String
        var detail: String
        var isToday: Bool
        var events: [CalendarEvent]
    }

    /// Regroupé par jour. Aujourd'hui et demain sont nommés, avec la date à côté.
    private func grouped() -> [Day] {
        let reference = Calendar.current
        var order: [String] = []
        var map: [String: Day] = [:]
        for event in calendar.upcoming {
            let key = AgendaTabView.dayLong.string(from: event.start)
            if map[key] == nil {
                let today = reference.isDateInToday(event.start)
                let tomorrow = reference.isDateInTomorrow(event.start)
                let label = today ? "Aujourd'hui" : (tomorrow ? "Demain" : key)
                let detail = (today || tomorrow) ? AgendaTabView.dayShort.string(from: event.start) : ""
                order.append(key)
                map[key] = Day(label: label, detail: detail, isToday: today, events: [])
            }
            map[key]?.events.append(event)
        }
        return order.compactMap { map[$0] }
    }

    /// « dans 25 min », « dans 3 h », « dans 2 j ».
    static func countdown(to date: Date) -> String? {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        if seconds < 3600 { return "dans \(max(1, Int(seconds / 60))) min" }
        if seconds < 86400 { return "dans \(Int(seconds / 3600)) h" }
        guard seconds < 7 * 86400 else { return nil }
        return "dans \(Int(seconds / 86400)) j"
    }

    /// Une couleur stable par calendrier, tirée de son nom.
    static func tint(of name: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.47, green: 0.67, blue: 1.0),
            Color(red: 0.26, green: 0.86, blue: 0.48),
            Color(red: 1.0, green: 0.6, blue: 0.12),
            Color(red: 0.86, green: 0.47, blue: 1.0),
            Color(red: 1.0, green: 0.45, blue: 0.5),
            Color(red: 0.35, green: 0.85, blue: 0.85)
        ]
        guard !name.isEmpty else { return palette[0] }
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(NotchFont.text(12))
            .foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Minuteur

/// Minuteur de concentration : cadran à gauche, commandes au centre, bilan du jour à droite.
@MainActor
struct TimerTabView: View {
    @EnvironmentObject private var pomodoro: Pomodoro
    @EnvironmentObject private var settings: SettingsStore

    /// Rythmes courants. Le dernier sert aux coups de collier courts.
    private static let presets: [(label: String, work: Double, rest: Double)] = [
        ("25 / 5", 25, 5), ("50 / 10", 50, 10), ("15 / 3", 15, 3)
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            dial
            controls
            Divider()
                .overlay(Color.white.opacity(0.1))
            today
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Cadran

    private var dial: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0.001, pomodoro.progress))
                .stroke(pomodoro.phase.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: pomodoro.progress)
            VStack(spacing: 1) {
                Text(pomodoro.isActive ? pomodoro.clock : Pomodoro.format(settings.s.pomodoroWork * 60))
                    .font(NotchFont.digits(20, .semibold))
                    .foregroundStyle(.white)
                Text(pomodoro.phase.label)
                    .font(NotchFont.text(9, .semibold))
                    .foregroundStyle(pomodoro.isActive ? pomodoro.phase.tint : .white.opacity(0.35))
                    .textCase(.uppercase)
            }
        }
        .frame(width: 106, height: 106)
    }

    // MARK: Commandes

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                button(pomodoro.running ? "Pause" : (pomodoro.isActive ? "Reprendre" : "Démarrer"),
                       filled: true) {
                    pomodoro.toggle()
                }
                if pomodoro.isActive {
                    button("Passer") { pomodoro.skip() }
                    button("Arrêter") { pomodoro.reset() }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Rythme")
                    .font(NotchFont.text(10, .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .textCase(.uppercase)
                HStack(spacing: 5) {
                    ForEach(TimerTabView.presets, id: \.label) { preset in
                        let active = Int(settings.s.pomodoroWork) == Int(preset.work)
                            && Int(settings.s.pomodoroRest) == Int(preset.rest)
                        Button {
                            settings.s.pomodoroWork = preset.work
                            settings.s.pomodoroRest = preset.rest
                        } label: {
                            Text(preset.label)
                                .font(NotchFont.digits(11, .semibold))
                                .foregroundStyle(.white.opacity(active ? 1 : 0.6))
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(Capsule().fill(Color.white.opacity(active ? 0.22 : 0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(pomodoro.isActive)
                        .opacity(pomodoro.isActive ? 0.45 : 1)
                    }
                }
                Text(pomodoro.isActive
                     ? "Arrête le minuteur pour changer de rythme."
                     : "\(Int(settings.s.pomodoroWork)) min de travail, \(Int(settings.s.pomodoroRest)) min de pause.")
                    .font(NotchFont.text(10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Bilan du jour

    private var today: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aujourd'hui")
                .font(NotchFont.text(10, .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(pomodoro.roundsToday)")
                    .font(NotchFont.digits(26, .semibold))
                    .foregroundStyle(.white)
                Text(pomodoro.roundsToday > 1 ? "séries" : "série")
                    .font(NotchFont.text(11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Une pastille par série, deux rangées de huit au maximum.
            if pomodoro.roundsToday > 0 {
                let shown = min(pomodoro.roundsToday, 16)
                let rows = stride(from: 0, to: shown, by: 8).map { Array($0..<min($0 + 8, shown)) }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 4) {
                            ForEach(row, id: \.self) { _ in
                                Circle()
                                    .fill(AuraPalette.working)
                                    .frame(width: 7, height: 7)
                            }
                        }
                    }
                }
            }

            Text(Pomodoro.formatLong(pomodoro.focusedToday) + " de travail")
                .font(NotchFont.text(11))
                .foregroundStyle(.white.opacity(0.55))

            Spacer(minLength: 0)
        }
        .frame(width: 168, alignment: .topLeading)
    }

    private func button(_ title: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(NotchFont.text(11, .semibold))
                .foregroundStyle(.white.opacity(filled ? 1 : 0.7))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Color.white.opacity(filled ? 0.2 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Question d'un agent

/// Un agent pose une question : l'encoche l'affiche et rend la réponse sans ouvrir l'app.
/// Boutons de choix, champ de texte, sélecteur de fichier — selon ce que la demande contient.
@MainActor
struct AskPanel: View {
    @EnvironmentObject private var model: NotchModel
    @State private var reply = ""
    @FocusState private var typing: Bool

    var body: some View {
        PanelFrame {
            if let ask = model.ask {
                VStack(alignment: .leading, spacing: 9) {
                    header(ask)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(ask.question)
                            .font(NotchFont.text(14, .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if !ask.detail.isEmpty {
                            Text(ask.detail)
                                .font(NotchFont.text(11))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !ask.choices.isEmpty {
                        choices(ask)
                    }

                    if ask.wantsText {
                        // Avec des choix au-dessus, le champ est la sortie « autre chose » :
                        // on le dit dans le texte d'invite plutôt que d'ajouter un intitulé.
                        HStack(spacing: 8) {
                            TextField("", text: $reply,
                                      prompt: Text(ask.choices.isEmpty ? "Ta réponse…" : "Autre réponse…")
                                        .foregroundStyle(.white.opacity(0.35)))
                                .textFieldStyle(.plain)
                                .font(NotchFont.text(12))
                                .foregroundStyle(.white)
                                .focused($typing)
                                .onSubmit { submit(ask) }
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.white.opacity(0.1))
                                )
                            Button("Envoyer  ↩") {
                                submit(ask)
                            }
                            .buttonStyle(PillButtonStyle(fill: reply.trimmed.isEmpty
                                                         ? Color.white.opacity(0.13) : AuraPalette.attention,
                                                         text: reply.trimmed.isEmpty ? .white.opacity(0.5) : .black))
                            .disabled(reply.trimmed.isEmpty)
                        }
                    }

                    footer(ask)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onAppear {
                    reply = ""
                    typing = ask.wantsText
                }
                .onChange(of: ask.id) { _, _ in
                    reply = ""
                    typing = ask.wantsText
                }
            }
        }
    }

    private func header(_ ask: AskRequest) -> some View {
        HStack(spacing: 10) {
            SourceBadge(source: ask.source, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(ask.project)
                    .font(NotchFont.text(14, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Question · \(ask.source.label)")
                    .font(NotchFont.text(11, .medium))
                    .foregroundStyle(AuraPalette.attention)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.askCount > 1 {
                Text("+\(model.askCount - 1) en attente")
                    .font(NotchFont.text(10, .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            Text(timerInterval: ask.createdAt...ask.deadline, countsDown: true)
                .font(NotchFont.digits(11, .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize()
        }
    }

    /// Réponses en pastilles à la taille de leur texte, alignées à gauche.
    /// La première est la réponse par défaut : elle porte la couleur et la touche ↩.
    private func choices(_ ask: AskRequest) -> some View {
        let rows: [[(offset: Int, element: String)]] = ask.choices.count > 3
            ? stride(from: 0, to: ask.choices.count, by: 3).map { start in
                Array(ask.choices.enumerated())[start..<min(start + 3, ask.choices.count)].map { ($0.offset, $0.element) }
            }
            : [Array(ask.choices.enumerated()).map { ($0.offset, $0.element) }]

        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    ForEach(row, id: \.offset) { item in
                        choiceButton(ask, choice: item.element, isDefault: item.offset == 0)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func choiceButton(_ ask: AskRequest, choice: String, isDefault: Bool) -> some View {
        Button {
            send(ask, .choice(choice))
        } label: {
            HStack(spacing: 6) {
                Text(choice)
                    .font(NotchFont.text(12.5, .semibold))
                if isDefault {
                    Text("↩")
                        .font(NotchFont.text(11, .semibold))
                        .opacity(0.55)
                }
            }
            .foregroundStyle(isDefault ? .black : .white.opacity(0.92))
            .padding(.horizontal, 15)
            .frame(height: 31)
            .background(
                Capsule().fill(isDefault ? AuraPalette.attention : Color.white.opacity(0.11))
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(isDefault ? 0 : 0.08), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Pied : le fichier à gauche s'il est demandé, puis les touches, puis Annuler en discret.
    /// Pas de gros bouton isolé : `esc` fait déjà le travail, le pied ne fait que le rappeler.
    private func footer(_ ask: AskRequest) -> some View {
        HStack(spacing: 10) {
            if ask.wantsFile {
                Button {
                    pickFile(ask)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Choisir un fichier…")
                            .font(NotchFont.text(12, .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 14)
                    .frame(height: 29)
                    .background(Capsule().fill(Color.white.opacity(0.11)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            if !ask.choices.isEmpty || ask.wantsText {
                Text(hint(ask))
                    .font(NotchFont.text(10.5))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
            }

            Button {
                send(ask, .cancelled)
            } label: {
                Text("Annuler  esc")
                    .font(NotchFont.text(11, .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 29)
    }

    /// `↩` dans le champ : envoie le texte, ou retombe sur la première réponse s'il est vide.
    private func submit(_ ask: AskRequest) {
        let value = reply.trimmed
        if value.isEmpty, let first = ask.choices.first {
            send(ask, .choice(first))
            return
        }
        send(ask, .text(value))
    }

    private func send(_ ask: AskRequest, _ answer: AskAnswer) {
        if case .text(let value) = answer, value.isEmpty { return }
        model.onAnswer?(ask.id, answer)
        reply = ""
    }

    /// Ce que fait la touche ↩ pour cette question.
    private func hint(_ ask: AskRequest) -> String {
        guard ask.wantsText else { return "↩ \(ask.choices.first ?? "")" }
        if reply.trimmed.isEmpty, let first = ask.choices.first {
            return "↩ \(first) · ou écris ta réponse"
        }
        return "↩ envoyer"
    }

    /// Sélecteur de fichier standard. Aura passe au premier plan le temps de la fenêtre.
    private func pickFile(_ ask: AskRequest) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Envoyer"
        panel.message = ask.question
        if panel.runModal() == .OK, let url = panel.url {
            send(ask, .file(url.path))
        }
    }
}
