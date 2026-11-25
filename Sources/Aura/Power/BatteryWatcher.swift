import Foundation
import IOKit.ps
import SwiftUI

/// État de la batterie interne, tel qu'affiché dans l'encoche.
struct BatteryState: Equatable {
    var percent: Int
    /// En charge (branché et pas encore plein).
    var charging: Bool
    /// Branché sur le secteur.
    var plugged: Bool

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Surveille la batterie et prévient quand l'état change vraiment : branchement, débranchement,
/// seuil bas franchi, charge terminée. Aucune autorisation, aucun sondage régulier : macOS
/// réveille Aura à chaque changement d'alimentation.
@MainActor
final class BatteryWatcher: ObservableObject {
    @Published private(set) var state: BatteryState?

    /// Écho à montrer dans les ailes de l'encoche.
    var onEcho: ((EchoEvent) -> Void)?

    private let settings: SettingsStore
    private var source: CFRunLoopSource?
    private var lastPlugged: Bool?
    private var lastBucket: Int?
    private var announcedFull = false

    /// Seuils bas annoncés une seule fois par descente.
    private static let lowSteps = [20, 10, 5]

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start() {
        state = BatteryWatcher.read()
        lastPlugged = state?.plugged
        lastBucket = state.map { BatteryWatcher.bucket(for: $0.percent) }
        announcedFull = state.map { $0.plugged && $0.percent >= 100 } ?? false
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource(BatteryWatcher.changed, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
        source = created
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        source = nil
        state = nil
        lastPlugged = nil
        lastBucket = nil
    }

    private static let changed: IOPowerSourceCallbackType = { context in
        guard let context else { return }
        let watcher = Unmanaged<BatteryWatcher>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in
            watcher.refresh()
        }
    }

    /// Lit l'état et n'annonce que les vrais changements.
    private func refresh() {
        guard let now = BatteryWatcher.read() else { return }
        let before = state
        state = now
        guard settings.s.batteryEnabled else { return }

        // Branchement ou débranchement.
        if let wasPlugged = lastPlugged, wasPlugged != now.plugged {
            announce(now,
                     label: now.plugged ? (now.charging ? "En charge" : "Branché") : "Sur batterie",
                     tint: now.plugged ? AuraPalette.done : AuraPalette.echo)
        }
        lastPlugged = now.plugged

        // Charge terminée : une seule fois par branchement.
        if now.plugged && now.percent >= 100 {
            if !announcedFull {
                announcedFull = true
                announce(now, label: "Batterie chargée", tint: AuraPalette.done)
            }
        } else if !now.plugged {
            announcedFull = false
        }

        // Seuil bas franchi vers le bas, sur batterie seulement.
        let bucket = BatteryWatcher.bucket(for: now.percent)
        if !now.plugged, let previous = lastBucket, bucket < previous,
           let step = BatteryWatcher.lowSteps.first(where: { now.percent <= $0 }) {
            announce(now, label: "Batterie \(step) %", tint: AuraPalette.error)
        }
        lastBucket = bucket
        _ = before
    }

    private func announce(_ battery: BatteryState, label: String, tint: Color) {
        var echo = EchoEvent(key: "battery", symbol: battery.symbol, label: label, tint: tint)
        echo.value = "\(battery.percent) %"
        echo.level = Double(battery.percent) / 100
        echo.glow = battery.percent <= 10 && !battery.plugged
            ? RGB(r: 1.0, g: 0.3, b: 0.3)
            : RGB(color: tint)
        onEcho?(echo)
    }

    /// Bouton « Tester » des réglages.
    func test() {
        let battery = state ?? BatteryState(percent: 42, charging: false, plugged: false)
        announce(battery, label: battery.plugged ? "Branché" : "Sur batterie", tint: AuraPalette.echo)
    }

    /// Paliers de 5 % : on ne compare pas des pourcentages bruts qui bougent sans arrêt.
    private static func bucket(for percent: Int) -> Int { percent / 5 }

    /// Lit la batterie interne. `nil` si la machine n'en a pas (Mac de bureau).
    static func read() -> BatteryState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for item in list {
            guard let description = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(1, description[kIOPSMaxCapacityKey] as? Int ?? 100)
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let percent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
            return BatteryState(percent: percent, charging: charging, plugged: plugged)
        }
        return nil
    }
}
