import Foundation
import SwiftUI

/// Phase du minuteur.
enum PomodoroPhase: String, Equatable {
    case idle, work, rest

    var label: String {
        switch self {
        case .idle: return "Minuteur"
        case .work: return "Au travail"
        case .rest: return "Pause"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "timer"
        case .work: return "timer"
        case .rest: return "cup.and.saucer.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return AuraPalette.echo
        case .work: return AuraPalette.working
        case .rest: return AuraPalette.done
        }
    }
}

/// Minuteur de concentration : des séries de travail séparées par des pauses.
/// Un seul minuteur à la fois, pas de reprise après un redémarrage d'Aura.
@MainActor
final class Pomodoro: ObservableObject {
    @Published private(set) var phase = PomodoroPhase.idle
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var running = false
    /// Nombre de séries de travail terminées depuis le dernier remise à zéro.
    @Published private(set) var rounds = 0
    /// Séries terminées aujourd'hui et temps de travail cumulé, gardés d'un lancement à l'autre.
    @Published private(set) var roundsToday = 0
    @Published private(set) var focusedToday: TimeInterval = 0

    /// Écho à montrer à chaque changement de phase.
    var onEcho: ((EchoEvent) -> Void)?

    private let settings: SettingsStore
    private var timer: Timer?
    private var endsAt: Date?

    private static let dayKey = "aura.pomodoro.day"
    private static let roundsKey = "aura.pomodoro.rounds"
    private static let focusKey = "aura.pomodoro.focus"

    init(settings: SettingsStore) {
        self.settings = settings
        loadToday()
    }

    /// Le compteur du jour repart à zéro au changement de date.
    private func loadToday() {
        let today = Pomodoro.today()
        guard UserDefaults.standard.string(forKey: Pomodoro.dayKey) == today else {
            UserDefaults.standard.set(today, forKey: Pomodoro.dayKey)
            UserDefaults.standard.set(0, forKey: Pomodoro.roundsKey)
            UserDefaults.standard.set(0.0, forKey: Pomodoro.focusKey)
            return
        }
        roundsToday = UserDefaults.standard.integer(forKey: Pomodoro.roundsKey)
        focusedToday = UserDefaults.standard.double(forKey: Pomodoro.focusKey)
    }

    private func saveToday() {
        UserDefaults.standard.set(Pomodoro.today(), forKey: Pomodoro.dayKey)
        UserDefaults.standard.set(roundsToday, forKey: Pomodoro.roundsKey)
        UserDefaults.standard.set(focusedToday, forKey: Pomodoro.focusKey)
    }

    private static func today() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    /// « 1 h 15 » ou « 25 min ».
    static func formatLong(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        guard minutes >= 60 else { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest)"
    }

    var isActive: Bool { phase != .idle }

    /// « 24:05 ».
    var clock: String { Pomodoro.format(remaining) }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Part de la phase déjà écoulée, entre 0 et 1.
    var progress: Double {
        let total = duration(of: phase)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    // MARK: Commandes

    func start() {
        if phase == .idle {
            enter(.work, announce: true)
        } else {
            resume()
        }
    }

    func pause() {
        guard running else { return }
        running = false
        endsAt = nil
        stopTimer()
    }

    func toggle() {
        running ? pause() : start()
    }

    func reset() {
        stopTimer()
        phase = .idle
        remaining = 0
        running = false
        rounds = 0
        endsAt = nil
    }

    /// Passe tout de suite à la phase suivante (travail → pause → travail).
    func skip() {
        guard phase != .idle else { return }
        finishPhase()
    }

    // MARK: Interne

    private func resume() {
        guard !running, remaining > 0 else { return }
        running = true
        endsAt = Date().addingTimeInterval(remaining)
        startTimer()
    }

    private func enter(_ next: PomodoroPhase, announce: Bool) {
        phase = next
        remaining = duration(of: next)
        running = true
        endsAt = Date().addingTimeInterval(remaining)
        startTimer()
        if announce {
            echo(label: next.label)
        }
    }

    private func finishPhase() {
        if phase == .work {
            rounds += 1
            loadToday()
            roundsToday += 1
            focusedToday += duration(of: .work)
            saveToday()
            enter(.rest, announce: true)
        } else {
            enter(.work, announce: true)
        }
    }

    private func duration(of phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .idle: return 0
        case .work: return max(1, settings.s.pomodoroWork) * 60
        case .rest: return max(1, settings.s.pomodoroRest) * 60
        }
    }

    private func startTimer() {
        stopTimer()
        let created = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        created.tolerance = 0.2
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// L'échéance est une date, pas un compteur : une mise en veille ne décale plus le minuteur.
    private func tick() {
        guard running, let endsAt else { return }
        let left = endsAt.timeIntervalSinceNow
        if left <= 0 {
            finishPhase()
        } else {
            remaining = left
        }
    }

    private func echo(label: String) {
        var event = EchoEvent(key: "pomodoro", symbol: phase.symbol, label: label, tint: phase.tint)
        event.value = clock
        event.glow = RGB(color: phase.tint)
        onEcho?(event)
    }
}
