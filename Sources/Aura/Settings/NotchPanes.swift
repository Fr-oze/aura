import SwiftUI
import AppKit

// MARK: - Encoche

@MainActor
struct NotchPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("Encoche") {
                Toggle("Transformer l'encoche", isOn: $settings.s.notchEnabled)
                Text("L'encoche elle-même s'étire en ailes (volume, luminosité, raccourcis, musique, agents) et descend en panneau (notifications, validations, accueil). Une seule surface, noire, collée au bord de l'écran. Boring Notch fait doublon : quitte-le, ou coupe au moins ses HUD de volume et de luminosité.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ce qui anime l'encoche") {
                Toggle("Volume", isOn: $settings.s.notchVolume)
                Toggle("Luminosité", isOn: $settings.s.notchBrightness)
                Toggle("Musique en cours (Spotify, Musique)", isOn: $settings.s.notchMusic)
                Toggle("Agent au travail", isOn: $settings.s.showWhileWorking)
                Toggle("Raccourcis clavier (⌘C, ⌘V…)", isOn: $settings.s.echoEnabled)
                Toggle("Notifications des autres apps", isOn: $settings.s.noticesEnabled)
                Text("Le volume est suivi sans aucune autorisation. La luminosité et les raccourcis passent par les touches : macOS peut demander Accessibilité ou Surveillance de l'entrée (voir Réglages > Raccourcis). Les notifications demandent l'Accès complet au disque (voir Réglages > Notifications).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Tester : volume") { AppState.shared.testVolume() }
                    Button("Tester : luminosité") { AppState.shared.testBrightness() }
                    Button("Tester : notification") { AppState.shared.testNotice() }
                    Spacer()
                }
                HStack {
                    Button("Tester : agent") { AppState.shared.runTest(.working) }
                    Button("Tester : terminé") { AppState.shared.runTest(.done) }
                    Button("Tester : validation") { AppState.shared.runTest(.approval) }
                    Spacer()
                }
            }

            Section("Survol") {
                Toggle("Ouvrir le panneau d'accueil au survol de l'encoche", isOn: $settings.s.notchHover)
                SliderRow(title: "Délai avant ouverture",
                          value: $settings.s.notchHoverDelay,
                          range: 0.1...1.5,
                          display: { NotchPane.seconds($0) })
                    .disabled(!settings.s.notchHover)
                Text("Onglets du panneau : Accueil (musique, agents), Météo, Presse-papiers, Notifications. Il se referme quand la souris sort.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Durées") {
                SliderRow(title: "Volume et luminosité",
                          value: $settings.s.notchHudDuration,
                          range: 0.8...4,
                          display: { NotchPane.seconds($0) })
                SliderRow(title: "Raccourcis",
                          value: $settings.s.echoDuration,
                          range: 0.5...2.5,
                          display: { NotchPane.seconds($0) })
                SliderRow(title: "Notifications",
                          value: $settings.s.noticeDuration,
                          range: 2...15,
                          display: { "\(Int($0.rounded())) s" })
                SliderRow(title: "Tâche terminée",
                          value: $settings.s.doneDisplaySeconds,
                          range: 2...15,
                          display: { "\(Int($0.rounded())) s" })
            }

            Section("Halo d'encoche") {
                Toggle("Lueur qui épouse le contour de l'encoche", isOn: $settings.s.notchGlow)
                Text("Elle se transforme avec la forme, respire tant qu'un état dure, pulse pour une validation ou une notification, lance une onde à chaque écho, et suit la valeur du volume et de la luminosité. Avec le halo musical allumé, elle reprend sa couleur au repos et brille sur les battements.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SliderRow(title: "Intensité",
                          value: $settings.s.notchGlowIntensity,
                          range: 0.2...1.4,
                          display: { "\(Int(($0 * 100).rounded())) %" })
                Toggle("Une onde à chaque action d'un agent", isOn: $settings.s.notchAgentPulse)
                Text("À chaque fois que Claude Code, Codex ou Cursor fait quelque chose (lire un fichier, lancer une commande, éditer), une onde part de l'encoche et longe la forme. Entre deux actions, rien ne bouge : une encoche immobile veut dire que l'agent attend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ColorPicker("Volume", selection: colorBinding(\.notchColorVolume), supportsOpacity: false)
                ColorPicker("Luminosité", selection: colorBinding(\.notchColorBrightness), supportsOpacity: false)
                ColorPicker("Validation agent, agent en attente", selection: colorBinding(\.notchColorApproval), supportsOpacity: false)
                ColorPicker("Tâche terminée", selection: colorBinding(\.notchColorDone), supportsOpacity: false)
                ColorPicker("Raccourcis", selection: colorBinding(\.notchColorEcho), supportsOpacity: false)
                Text("Notification : couleur de l'icône de l'app. Musique : couleur de la pochette. Erreur d'agent : rouge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostic") {
                Toggle("Afficher le contour", isOn: $settings.s.notchDiagnostics)
                Text("Trace en rouge, d'un trait de 1 px, le contour exact utilisé : le bord de l'écran (halo) et la forme de l'encoche. Le trait doit longer le bord réel de la dalle et le contour de l'encoche physique. S'il est décalé, envoie une photo de l'écran avec les chiffres ci-dessous.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(geometry)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var geometry: String {
        guard let screen = ScreenPicker.current(named: settings.s.screenName) else {
            return "Aucun écran détecté."
        }
        return ScreenPicker.describe(screen)
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value).replacingOccurrences(of: ".", with: ",")
    }

    private func colorBinding(_ keyPath: WritableKeyPath<AuraSettings, RGB>) -> Binding<Color> {
        Binding(
            get: { settings.s[keyPath: keyPath].color },
            set: { settings.s[keyPath: keyPath] = RGB(color: $0) }
        )
    }
}

// MARK: - Météo

@MainActor
struct WeatherPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var query = ""
    @State private var results: [WeatherCity] = []
    @State private var searching = false
    @State private var message = ""

    var body: some View {
        Form {
            Section("Météo") {
                Toggle("Onglet Météo dans le panneau de l'encoche", isOn: $settings.s.weatherEnabled)
                Picker("Unités", selection: $settings.s.weatherFahrenheit) {
                    Text("°C · km/h").tag(false)
                    Text("°F · mph").tag(true)
                }
                .pickerStyle(.segmented)
                Text("Données Open-Meteo, sans compte ni clé : temps actuel, 7 prochaines heures, 4 jours. Rien n'est chargé en tâche de fond : la météo se met à jour quand tu ouvres l'onglet, au plus une fois par quart d'heure et par ville.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Villes favorites") {
                if settings.s.weatherCities.isEmpty {
                    Text("Aucune ville. Cherches-en une ci-dessous.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(settings.s.weatherCities.enumerated()), id: \.offset) { index, city in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(city.name)
                            Text(WeatherPane.caption(for: city))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            move(index, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help("Monter")
                        Button {
                            remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Retirer cette ville")
                    }
                }
            }

            Section("Ajouter une ville") {
                HStack(spacing: 8) {
                    TextField("Nom de la ville", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            search()
                        }
                    Button(searching ? "Recherche…" : "Chercher") {
                        search()
                    }
                    .disabled(searching || query.trimmed.count < 2)
                }
                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(results) { city in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(city.name)
                            Text(WeatherPane.caption(for: city))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Ajouter") {
                            add(city)
                        }
                        .disabled(settings.s.weatherCities.contains(city))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func caption(for city: WeatherCity) -> String {
        let place = String(format: "%.2f, %.2f", city.latitude, city.longitude)
        return city.region.isEmpty ? place : "\(city.region) · \(place)"
    }

    /// Géocodage Open-Meteo.
    private func search() {
        let text = query.trimmed
        guard text.count >= 2, !searching else { return }
        searching = true
        message = ""
        Task {
            let found = await WeatherService.search(text)
            results = found
            searching = false
            message = found.isEmpty ? "Aucune ville trouvée (ou pas de réseau)." : ""
        }
    }

    private func add(_ city: WeatherCity) {
        guard !settings.s.weatherCities.contains(city) else { return }
        settings.s.weatherCities.append(city)
    }

    private func remove(at index: Int) {
        var updated = settings.s
        guard updated.weatherCities.indices.contains(index) else { return }
        updated.weatherCities.remove(at: index)
        if updated.weatherCity >= updated.weatherCities.count {
            updated.weatherCity = max(0, updated.weatherCities.count - 1)
        }
        settings.s = updated
    }

    private func move(_ index: Int, by offset: Int) {
        var updated = settings.s
        let target = index + offset
        guard updated.weatherCities.indices.contains(index),
              updated.weatherCities.indices.contains(target)
        else { return }
        updated.weatherCities.swapAt(index, target)
        if updated.weatherCity == index {
            updated.weatherCity = target
        } else if updated.weatherCity == target {
            updated.weatherCity = index
        }
        settings.s = updated
    }
}
