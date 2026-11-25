import SwiftUI
import AppKit

/// Réglages de l'agenda (abonnements ICS) et du minuteur de concentration.
@MainActor
struct AgendaPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var calendar: CalendarService
    @State private var name = ""
    @State private var address = ""

    var body: some View {
        Form {
            Section("Ajouter un calendrier") {
                TextField("Nom", text: $name, prompt: Text("Perso, Pro…"))
                TextField("Adresse iCal", text: $address, prompt: Text("https://calendar.google.com/…/basic.ics"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Ajouter") { add() }
                        .buttonStyle(.borderedProminent)
                        .disabled(address.trimmed.isEmpty)
                    Text("Où trouver cette adresse : section « Brancher Google Agenda », plus bas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Agenda") {
                Toggle("Afficher mes rendez-vous dans l'encoche", isOn: $settings.s.calendarEnabled)
                Text("Aura s'abonne à l'adresse iCal d'un calendrier et la lit, c'est tout : aucun compte Google à connecter, aucune autorisation macOS, aucune écriture possible. Onglet Agenda du panneau de l'encoche.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Mes calendriers") {
                if settings.s.calendarFeeds.isEmpty {
                    Text("Aucun calendrier.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.s.calendarFeeds) { feed in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feed.name.isEmpty ? "Sans nom" : feed.name)
                            Text(AgendaPane.shortened(feed.url))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Button("Retirer") {
                            settings.s.calendarFeeds.removeAll { $0.id == feed.id }
                            calendar.refresh(force: true)
                        }
                    }
                }

                HStack {
                    Button("Rafraîchir maintenant") {
                        calendar.refresh(force: true)
                    }
                    Spacer()
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Brancher Google Agenda") {
                Text("""
                1. Ouvre Google Agenda dans un navigateur, sur ordinateur.
                2. Colonne de gauche, passe la souris sur le calendrier voulu > les trois points > Paramètres et partage.
                3. Descends jusqu'à « Intégrer l'agenda ».
                4. Copie l'« Adresse secrète au format iCal » (elle finit par .ics).
                5. Colle-la ci-dessus avec un nom, puis Ajouter.
                """)
                .font(.caption)
                Text("Cette adresse secrète donne accès au contenu du calendrier à qui l'a : ne la partage pas et ne la mets pas dans un dépôt. Si elle fuite, le bouton « Réinitialiser » de la même page Google en crée une nouvelle. Pour un agenda partagé avec ton équipe, prends plutôt l'adresse publique au format iCal, juste au-dessus (elle n'existe que si le calendrier est public).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Un autre fournisseur (iCloud, Outlook, un planning partagé) marche pareil : il suffit d'une adresse se terminant par .ics. Les adresses webcal:// sont acceptées.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Ouvrir Google Agenda") {
                    if let url = URL(string: "https://calendar.google.com/calendar/r/settings") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section("Boire de l'eau") {
                Toggle("Me rappeler de boire", isOn: $settings.s.waterEnabled)
                SliderRow(title: "Toutes les",
                          value: $settings.s.waterInterval,
                          range: 15...180,
                          display: { "\(Int($0)) min" })
                Text("Une pastille dans l'encoche, rien de plus. Rien ne sort quand tu n'es pas devant le Mac : après 5 minutes sans toucher au clavier ni à la souris, le compte à rebours repart à ton retour.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Tester") {
                    AppState.shared.testWater()
                }
            }

            Section("Minuteur") {
                Toggle("Onglet Minuteur dans le panneau de l'encoche", isOn: $settings.s.pomodoroEnabled)
                SliderRow(title: "Travail",
                          value: $settings.s.pomodoroWork,
                          range: 5...90,
                          display: { "\(Int($0)) min" })
                SliderRow(title: "Pause",
                          value: $settings.s.pomodoroRest,
                          range: 1...30,
                          display: { "\(Int($0)) min" })
                Text("À la fin de chaque phase, l'encoche affiche « Au travail » ou « Pause » et enchaîne. Le compte à rebours suit l'heure réelle : une mise en veille ne le décale pas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Batterie") {
                Toggle("Prévenir dans l'encoche", isOn: $settings.s.batteryEnabled)
                Text("Branchement, débranchement, charge terminée, et les seuils de 20 %, 10 % et 5 % sur batterie. Rien d'autre : pas de pourcentage affiché en permanence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Tester") {
                    AppState.shared.testBattery()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var status: String {
        switch calendar.state {
        case .idle: return ""
        case .loading: return "Chargement…"
        case .ready: return "\(calendar.upcoming.count) rendez-vous à venir"
        case .failed(let message): return message
        }
    }

    private func add() {
        let url = address.trimmed
        guard !url.isEmpty else { return }
        let label = name.trimmed.isEmpty ? "Agenda" : name.trimmed
        settings.s.calendarFeeds.append(CalendarFeed(name: label, url: url))
        name = ""
        address = ""
        settings.s.calendarEnabled = true
        calendar.refresh(force: true)
    }

    /// L'adresse secrète est longue : on n'en montre que les bords.
    private static func shortened(_ url: String) -> String {
        guard url.count > 56 else { return url }
        return url.prefix(34) + "…" + url.suffix(14)
    }
}
