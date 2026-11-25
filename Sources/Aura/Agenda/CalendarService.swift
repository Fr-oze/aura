import Foundation

/// Un calendrier auquel Aura est abonnée (adresse iCal / ICS).
struct CalendarFeed: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var url: String

    /// `webcal://` est un `https://` déguisé.
    var fetchURL: URL? {
        var text = url.trimmed
        if text.lowercased().hasPrefix("webcal://") {
            text = "https://" + text.dropFirst("webcal://".count)
        }
        return URL(string: text)
    }
}

struct CalendarEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String
    var calendar: String

    var isOver: Bool { end < Date() }

    /// « 14:30 » ou « journée ».
    func timeLabel(_ formatter: DateFormatter) -> String {
        allDay ? "journée" : formatter.string(from: start)
    }
}

enum CalendarState: Equatable {
    case idle, loading, ready
    case failed(String)
}

/// Agenda par abonnement : Aura télécharge les fichiers ICS réglés et affiche les prochains
/// rendez-vous. Lecture seule, aucun compte, aucune autorisation macOS — l'adresse iCal
/// suffit (voir le README pour Google Agenda).
@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var state = CalendarState.idle

    /// Nombre de jours affichés et limite de rendez-vous gardés.
    static let windowDays = 14
    static let keep = 40

    private let settings: SettingsStore
    private var lastLoad: Date?
    private var loading = false

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Rafraîchit au plus une fois par quart d'heure, sauf `force`.
    func refresh(force: Bool) {
        let config = settings.s
        guard config.calendarEnabled else { return }
        let feeds = config.calendarFeeds.filter { $0.fetchURL != nil }
        guard !feeds.isEmpty else {
            events = []
            state = .idle
            return
        }
        if !force, let lastLoad, Date().timeIntervalSince(lastLoad) < 900 { return }
        guard !loading else { return }

        loading = true
        state = .loading
        let window = DateInterval(start: Date().addingTimeInterval(-3600),
                                  end: Date().addingTimeInterval(Double(CalendarService.windowDays) * 86400))

        Task { [weak self] in
            var collected: [CalendarEvent] = []
            var failures: [String] = []
            for feed in feeds {
                guard let url = feed.fetchURL else { continue }
                do {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 20
                    request.setValue("text/calendar", forHTTPHeaderField: "Accept")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        failures.append("\(feed.name) : HTTP \(http.statusCode)")
                        continue
                    }
                    let text = String(decoding: data, as: UTF8.self)
                    collected += ICSParser.events(from: text, calendar: feed.name, window: window)
                } catch {
                    failures.append("\(feed.name) : \(error.localizedDescription)")
                }
            }

            let sorted = collected
                .filter { !$0.isOver }
                .sorted { $0.start < $1.start }
                .prefix(CalendarService.keep)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading = false
                self.events = Array(sorted)
                self.lastLoad = Date()
                if collected.isEmpty, let first = failures.first {
                    self.state = .failed(first)
                } else {
                    self.state = .ready
                }
            }
        }
    }

    /// Les rendez-vous du jour, puis des jours suivants.
    var upcoming: [CalendarEvent] { events }

    var next: CalendarEvent? { events.first }
}

/// Lecture d'un fichier ICS : déplie les lignes, lit les VEVENT, déroule les répétitions
/// simples dans la fenêtre demandée.
///
/// ponytail : RRULE limité à FREQ DAILY / WEEKLY / MONTHLY / YEARLY avec INTERVAL, COUNT,
/// UNTIL et BYDAY (hebdomadaire). Pas de BYMONTHDAY ni BYSETPOS : si un agenda en a besoin,
/// l'occurrence de base reste affichée, pas ses variantes.
enum ICSParser {

    static func events(from text: String, calendar name: String, window: DateInterval) -> [CalendarEvent] {
        var result: [CalendarEvent] = []
        // Occurrences explicitement retirées (EXDATE) ou remplacées (RECURRENCE-ID), par UID.
        var excluded: [String: Set<Date>] = [:]
        var blocks: [[(key: String, params: [String: String], value: String)]] = []
        var current: [(key: String, params: [String: String], value: String)]?

        for line in unfold(text) {
            if line == "BEGIN:VEVENT" {
                current = []
                continue
            }
            if line == "END:VEVENT" {
                if let current { blocks.append(current) }
                current = nil
                continue
            }
            guard current != nil, let property = property(from: line) else { continue }
            current?.append(property)
        }

        // Premier passage : les occurrences remplacées, pour ne pas les afficher deux fois.
        for block in blocks {
            guard let uid = value(of: "UID", in: block),
                  let recurrence = entry(of: "RECURRENCE-ID", in: block),
                  let date = date(from: recurrence.value, params: recurrence.params)
            else { continue }
            excluded[uid, default: []].insert(date.date)
        }
        for block in blocks {
            guard let uid = value(of: "UID", in: block) else { continue }
            for entry in entries(of: "EXDATE", in: block) {
                for piece in entry.value.split(separator: ",") {
                    guard let date = date(from: String(piece), params: entry.params) else { continue }
                    excluded[uid, default: []].insert(date.date)
                }
            }
        }

        for block in blocks {
            guard let startEntry = entry(of: "DTSTART", in: block),
                  let start = date(from: startEntry.value, params: startEntry.params)
            else { continue }

            let uid = value(of: "UID", in: block) ?? UUID().uuidString
            let title = unescape(value(of: "SUMMARY", in: block) ?? "(sans titre)")
            let location = unescape(value(of: "LOCATION", in: block) ?? "")
            let status = value(of: "STATUS", in: block) ?? ""
            guard status != "CANCELLED" else { continue }

            var length: TimeInterval = start.allDay ? 86400 : 3600
            if let endEntry = entry(of: "DTEND", in: block),
               let end = date(from: endEntry.value, params: endEntry.params) {
                length = max(60, end.date.timeIntervalSince(start.date))
            } else if let duration = value(of: "DURATION", in: block),
                      let parsed = seconds(fromDuration: duration) {
                length = parsed
            }

            let isOverride = entry(of: "RECURRENCE-ID", in: block) != nil
            let starts: [Date]
            if let rule = value(of: "RRULE", in: block), !isOverride {
                starts = expand(rule: rule, from: start, window: window)
            } else {
                starts = [start.date]
            }

            let skip = excluded[uid] ?? []
            for occurrence in starts {
                if !isOverride && skip.contains(occurrence) { continue }
                let end = occurrence.addingTimeInterval(length)
                guard end >= window.start, occurrence <= window.end else { continue }
                result.append(CalendarEvent(id: "\(uid)-\(Int(occurrence.timeIntervalSince1970))",
                                            title: title,
                                            start: occurrence,
                                            end: end,
                                            allDay: start.allDay,
                                            location: location,
                                            calendar: name))
            }
        }
        return result
    }

    // MARK: Lignes

    /// Les lignes ICS peuvent être coupées : une suite commence par une espace ou une tabulation.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix(" ") || raw.hasPrefix("\t") {
                let continuation = raw.dropFirst()
                if lines.isEmpty {
                    lines.append(String(continuation))
                } else {
                    lines[lines.count - 1] += continuation
                }
            } else if !raw.isEmpty {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// `DTSTART;TZID=Europe/Paris:20261125T190000` → clé, paramètres, valeur.
    static func property(from line: String) -> (key: String, params: [String: String], value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = String(line[line.startIndex..<colon])
        let value = String(line[line.index(after: colon)...])
        let pieces = head.split(separator: ";").map(String.init)
        guard let key = pieces.first?.uppercased() else { return nil }
        var params: [String: String] = [:]
        for piece in pieces.dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            params[pair[0].uppercased()] = pair[1]
        }
        return (key, params, value)
    }

    private static func entry(of key: String,
                              in block: [(key: String, params: [String: String], value: String)])
    -> (key: String, params: [String: String], value: String)? {
        block.first { $0.key == key }
    }

    private static func entries(of key: String,
                                in block: [(key: String, params: [String: String], value: String)])
    -> [(key: String, params: [String: String], value: String)] {
        block.filter { $0.key == key }
    }

    private static func value(of key: String,
                              in block: [(key: String, params: [String: String], value: String)]) -> String? {
        entry(of: key, in: block)?.value
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .trimmed
    }

    // MARK: Dates

    /// `20261125T190000Z`, `20261125T190000` (avec TZID) ou `20261125` (journée entière).
    static func date(from text: String, params: [String: String]) -> (date: Date, allDay: Bool)? {
        let raw = text.trimmed
        var components = DateComponents()
        let zone: TimeZone

        if raw.hasSuffix("Z") {
            zone = TimeZone(identifier: "UTC") ?? .current
        } else if let identifier = params["TZID"], let found = TimeZone(identifier: identifier) {
            zone = found
        } else {
            zone = .current
        }

        let digits = raw.filter { $0.isNumber }
        guard digits.count == 8 || digits.count == 14 else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            let begin = digits.index(digits.startIndex, offsetBy: start)
            let end = digits.index(begin, offsetBy: length)
            return Int(digits[begin..<end])
        }
        components.year = number(0, 4)
        components.month = number(4, 2)
        components.day = number(6, 2)
        let allDay = digits.count == 8 || params["VALUE"]?.uppercased() == "DATE"
        if digits.count == 14 {
            components.hour = number(8, 2)
            components.minute = number(10, 2)
            components.second = number(12, 2)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = allDay ? .current : zone
        guard let date = calendar.date(from: components) else { return nil }
        return (date, allDay)
    }

    /// `PT1H30M`, `P1D`.
    static func seconds(fromDuration text: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var seen = false
        for character in text.uppercased() where character != "P" {
            if character.isNumber {
                number.append(character)
                continue
            }
            guard let amount = Double(number) else {
                number = ""
                continue
            }
            switch character {
            case "W": total += amount * 604800; seen = true
            case "D": total += amount * 86400; seen = true
            case "H": total += amount * 3600; seen = true
            case "M": total += amount * 60; seen = true
            case "S": total += amount; seen = true
            default: break
            }
            number = ""
        }
        return seen ? total : nil
    }

    // MARK: Répétitions

    private static let weekdays: [String: Int] = [
        "SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7
    ]

    /// Déroule une RRULE entre le début de la fenêtre et sa fin.
    static func expand(rule: String, from start: (date: Date, allDay: Bool), window: DateInterval) -> [Date] {
        var parts: [String: String] = [:]
        for piece in rule.split(separator: ";") {
            let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            parts[pair[0].uppercased()] = pair[1]
        }
        guard let frequency = parts["FREQ"]?.uppercased() else { return [start.date] }
        let interval = max(1, Int(parts["INTERVAL"] ?? "1") ?? 1)
        let count = Int(parts["COUNT"] ?? "")
        let until = parts["UNTIL"].flatMap { date(from: $0, params: [:])?.date }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let component: Calendar.Component
        switch frequency {
        case "DAILY": component = .day
        case "WEEKLY": component = .weekOfYear
        case "MONTHLY": component = .month
        case "YEARLY": component = .year
        default: return [start.date]
        }

        // Jours de la semaine demandés (hebdomadaire seulement).
        let byDay: [Int] = (parts["BYDAY"] ?? "")
            .split(separator: ",")
            .compactMap { piece in
                let code = String(piece.suffix(2)).uppercased()
                return weekdays[code]
            }

        var result: [Date] = []
        var cursor = start.date
        var emitted = 0
        // Garde-fou : un agenda peut contenir une règle sans fin.
        for _ in 0..<5000 {
            if let until, cursor > until { break }
            if let count, emitted >= count { break }
            if cursor > window.end { break }

            var occurrences = [cursor]
            if component == .weekOfYear, !byDay.isEmpty {
                // Semaine du curseur, puis chaque jour demandé de cette semaine.
                occurrences = byDay.compactMap { weekday in
                    calendar.nextDate(after: calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor,
                                      matching: DateComponents(hour: calendar.component(.hour, from: start.date),
                                                               minute: calendar.component(.minute, from: start.date),
                                                               weekday: weekday),
                                      matchingPolicy: .nextTime,
                                      direction: .forward)
                }
            }

            for occurrence in occurrences.sorted() {
                if let until, occurrence > until { continue }
                if let count, emitted >= count { break }
                emitted += 1
                if occurrence >= window.start && occurrence <= window.end {
                    result.append(occurrence)
                }
            }

            guard let next = calendar.date(byAdding: component, value: interval, to: cursor) else { break }
            cursor = next
        }
        return result
    }
}
