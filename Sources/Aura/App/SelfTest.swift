import Foundation

/// Autotest lancé par `./build.sh --test` (ou `Aura --selftest`).
/// Il couvre les deux endroits où une erreur silencieuse coûte cher : les règles qui décident
/// s'il faut te demander avant une commande, et la lecture des fichiers d'agenda.
/// `precondition` et pas `assert` : les `assert` disparaissent dans un build `-O`.
enum SelfTest {

    static func run() {
        rules()
        calendar()
        water()
        print("Autotest : tout passe.")
    }

    // MARK: Règles de validation

    private static let autoApprove = [
        "ls", "cat", "echo", "grep", "git status", "git diff", "npm test", "re:^npm run \\w+$"
    ]
    private static let alwaysAsk = ["rm", "sudo", "git push", "curl"]

    private static func verdict(_ command: String) -> RuleVerdict {
        ApprovalRules.evaluate(command, autoApprove: autoApprove, alwaysAsk: alwaysAsk)
    }

    private static func rules() {
        // Commandes routinières.
        precondition(verdict("ls") == .autoAllow, "ls doit passer tout seul")
        precondition(verdict("git status -s") == .autoAllow, "un préfixe doit reconnaître ses options")
        precondition(verdict("ls 2>/dev/null") == .autoAllow, "une redirection d'erreur est inoffensive")
        precondition(verdict("echo a | grep b") == .autoAllow, "chaque partie est routinière")

        // Ce qui doit toujours passer par l'encoche.
        precondition(verdict("rm -rf ./build") == .mustAsk, "rm doit toujours être soumis")
        precondition(verdict("ls && rm -rf /") == .mustAsk, "un rm caché dans une chaîne doit être vu")
        precondition(verdict("sudo ls") == .mustAsk, "sudo doit toujours être soumis")
        precondition(verdict("git push origin main") == .mustAsk, "git push doit toujours être soumis")

        // Ni l'un ni l'autre : Aura demande selon le réglage par défaut.
        precondition(verdict("git statuses") == .unlisted, "un préfixe ne doit pas déborder sur un autre mot")
        precondition(verdict("ls && inconnu") == .unlisted, "une partie inconnue empêche l'autorisation d'office")
        precondition(verdict("cat $(whoami)") == .unlisted, "une substitution empêche l'autorisation d'office")
        precondition(verdict("echo a > fichier.txt") == .unlisted, "une écriture de fichier n'est pas routinière")
        precondition(verdict("") == .unlisted, "une commande vide ne s'autorise pas")

        // Règle en expression régulière.
        precondition(verdict("npm run build") == .autoAllow, "la regex doit reconnaître npm run build")
        precondition(verdict("npm run build -- --watch") == .unlisted, "la regex est ancrée, elle ne doit pas déborder")
    }

    // MARK: Rappel de boire

    private static func water() {
        let now = Date()
        precondition(WaterReminder.isDue(last: now.addingTimeInterval(-3600), now: now, interval: 3600),
                     "une heure pile après le dernier rappel, il est dû")
        precondition(!WaterReminder.isDue(last: now.addingTimeInterval(-59), now: now, interval: 3600),
                     "une minute après, il ne l'est pas")
        precondition(WaterReminder.idleSeconds() >= 0, "le temps d_inactivite ne peut pas etre negatif")
    }

    // MARK: Agenda

    private static func calendar() {
        // Ligne coupée en deux : le dépliage doit recoller le titre.
        let folded = "SUMMARY:Réunion fondateurs\n  VK Studio"
        precondition(ICSParser.unfold(folded) == ["SUMMARY:Réunion fondateurs VK Studio"],
                     "les lignes coupées doivent être recollées")

        let property = ICSParser.property(from: "DTSTART;TZID=Europe/Paris:20261125T190000")
        precondition(property?.key == "DTSTART", "la clé doit être lue")
        precondition(property?.params["TZID"] == "Europe/Paris", "le fuseau doit être lu")
        precondition(property?.value == "20261125T190000", "la valeur doit être lue")

        precondition(ICSParser.seconds(fromDuration: "PT1H30M") == 5400, "une durée PT1H30M fait 5400 s")
        precondition(ICSParser.unescape("Chalet\\, Vaujany") == "Chalet, Vaujany", "les virgules sont échappées")

        // Un rendez-vous simple, demain, lu de bout en bout.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = .current
        let tomorrow = Date().addingTimeInterval(86400)
        let stamp = formatter.string(from: tomorrow)
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:test-1
        SUMMARY:Cold call garages
        DTSTART:\(stamp)
        DURATION:PT30M
        END:VEVENT
        END:VCALENDAR
        """
        let window = DateInterval(start: Date().addingTimeInterval(-3600),
                                  end: Date().addingTimeInterval(14 * 86400))
        let events = ICSParser.events(from: ics, calendar: "Test", window: window)
        precondition(events.count == 1, "un VEVENT doit donner un rendez-vous")
        precondition(events[0].title == "Cold call garages", "le titre doit être lu")
        precondition(Int(events[0].end.timeIntervalSince(events[0].start)) == 1800,
                     "la durée doit venir de DURATION")

        // Une répétition quotidienne doit donner plusieurs occurrences dans la fenêtre.
        let repeating = """
        BEGIN:VEVENT
        UID:test-2
        SUMMARY:Point quotidien
        DTSTART:\(stamp)
        DURATION:PT15M
        RRULE:FREQ=DAILY;COUNT=5
        END:VEVENT
        """
        let series = ICSParser.events(from: repeating, calendar: "Test", window: window)
        precondition(series.count == 5, "FREQ=DAILY;COUNT=5 doit donner 5 occurrences, pas \(series.count)")

        // Une occurrence retirée (EXDATE) ne doit plus apparaître.
        let excluded = repeating.replacingOccurrences(of: "RRULE:FREQ=DAILY;COUNT=5",
                                                      with: "RRULE:FREQ=DAILY;COUNT=5\nEXDATE:\(stamp)")
        let trimmed = ICSParser.events(from: excluded, calendar: "Test", window: window)
        precondition(trimmed.count == 4, "EXDATE doit retirer une occurrence, il en reste \(trimmed.count)")

        // Un rendez-vous annulé est ignoré.
        let cancelled = repeating.replacingOccurrences(of: "SUMMARY:Point quotidien",
                                                       with: "SUMMARY:Point quotidien\nSTATUS:CANCELLED")
        precondition(ICSParser.events(from: cancelled, calendar: "Test", window: window).isEmpty,
                     "un rendez-vous annulé ne doit pas s'afficher")

        // Un passé lointain ne doit pas remonter.
        let old = """
        BEGIN:VEVENT
        UID:test-3
        SUMMARY:Vieux rendez-vous
        DTSTART:20200101T100000
        DURATION:PT1H
        END:VEVENT
        """
        precondition(ICSParser.events(from: old, calendar: "Test", window: window).isEmpty,
                     "hors fenêtre, rien ne doit sortir")

        // webcal:// doit devenir https://
        let feed = CalendarFeed(name: "Google", url: "webcal://example.com/a.ics")
        precondition(feed.fetchURL?.scheme == "https", "webcal doit être traduit en https")
    }
}
