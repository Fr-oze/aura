import Foundation
import AppKit
import SwiftUI
import CoreGraphics

/// Rappel de boire. Une pastille dans l'encoche toutes les N minutes, mais seulement quand le Mac
/// est vraiment utilisé : inutile de rappeler de boire à quelqu'un qui n'est pas là.
///
/// Aucune autorisation : le temps d'inactivité vient de `CGEventSource`, pas d'un espion clavier.
@MainActor
final class WaterReminder: ObservableObject {
    /// Verres comptés aujourd'hui (un par rappel affiché).
    @Published private(set) var glassesToday = 0

    var onEcho: ((EchoEvent) -> Void)?

    private let settings: SettingsStore
    private var timer: Timer?
    private var lastReminder = Date()

    /// Au-delà, l'utilisateur est considéré absent : le compte à rebours repart à son retour.
    static let awayAfter: TimeInterval = 300

    private static let dayKey = "aura.water.day"
    private static let countKey = "aura.water.count"

    init(settings: SettingsStore) {
        self.settings = settings
        loadToday()
    }

    func start() {
        guard timer == nil else { return }
        lastReminder = Date()
        let created = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        created.tolerance = 10
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Prochain rappel, en secondes. `nil` si le module est coupé.
    var nextIn: TimeInterval? {
        guard settings.s.waterEnabled else { return nil }
        let interval = max(5, settings.s.waterInterval) * 60
        return max(0, interval - Date().timeIntervalSince(lastReminder))
    }

    private func tick() {
        let config = settings.s
        guard config.waterEnabled else { return }
        let idle = WaterReminder.idleSeconds()

        // Absent : on ne rappelle rien, et le compte à rebours repart de son retour.
        guard idle < WaterReminder.awayAfter else {
            lastReminder = Date()
            return
        }

        guard WaterReminder.isDue(last: lastReminder,
                                  now: Date(),
                                  interval: max(5, config.waterInterval) * 60)
        else { return }
        remind()
    }

    private func remind() {
        lastReminder = Date()
        loadToday()
        glassesToday += 1
        saveToday()

        var echo = EchoEvent(key: "water", symbol: "drop.fill", label: "Bois un coup",
                             tint: Color(red: 0.42, green: 0.78, blue: 1.0))
        echo.value = glassesToday > 1 ? "\(glassesToday)ᵉ verre" : "1ᵉʳ verre"
        echo.glow = RGB(r: 0.42, g: 0.78, b: 1.0)
        onEcho?(echo)
    }

    /// Bouton « Tester » des réglages.
    func test() {
        var echo = EchoEvent(key: "water", symbol: "drop.fill", label: "Bois un coup",
                             tint: Color(red: 0.42, green: 0.78, blue: 1.0))
        echo.value = "test"
        echo.glow = RGB(r: 0.42, g: 0.78, b: 1.0)
        onEcho?(echo)
    }

    /// Le rappel est dû. Isolé pour être vérifiable par l'autotest.
    nonisolated static func isDue(last: Date, now: Date, interval: TimeInterval) -> Bool {
        now.timeIntervalSince(last) >= interval
    }

    /// Secondes depuis la dernière action de l'utilisateur (clavier, souris, trackpad).
    nonisolated static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
    }

    // MARK: Compte du jour

    private func loadToday() {
        let today = WaterReminder.today()
        guard UserDefaults.standard.string(forKey: WaterReminder.dayKey) == today else {
            UserDefaults.standard.set(today, forKey: WaterReminder.dayKey)
            UserDefaults.standard.set(0, forKey: WaterReminder.countKey)
            glassesToday = 0
            return
        }
        glassesToday = UserDefaults.standard.integer(forKey: WaterReminder.countKey)
    }

    private func saveToday() {
        UserDefaults.standard.set(WaterReminder.today(), forKey: WaterReminder.dayKey)
        UserDefaults.standard.set(glassesToday, forKey: WaterReminder.countKey)
    }

    private static func today() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
