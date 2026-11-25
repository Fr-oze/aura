import Foundation
import Combine

/// Une ville favorite pour la météo.
struct WeatherCity: Codable, Equatable, Identifiable, Sendable {
    var name: String
    /// Région ou pays, pour distinguer deux villes du même nom.
    var region: String
    var latitude: Double
    var longitude: Double

    var id: String { "\(name)|\(latitude)|\(longitude)" }
}

struct WeatherHour: Identifiable, Sendable {
    let id: String
    /// Heure affichée (« 14 h »).
    let label: String
    let temperature: Double
    let code: Int
    let isDay: Bool
}

struct WeatherDay: Identifiable, Sendable {
    let id: String
    /// « Auj. », « Demain », puis le jour de la semaine.
    let label: String
    let code: Int
    let low: Double
    let high: Double
}

struct WeatherReport: Sendable {
    let city: WeatherCity
    /// Heure locale de la ville au moment du relevé (« 11:28 »).
    let time: String
    let temperature: Double
    let feelsLike: Double
    let humidity: Double
    let wind: Double
    let code: Int
    let isDay: Bool
    let hours: [WeatherHour]
    let days: [WeatherDay]
    let fahrenheit: Bool
    let fetchedAt: Date

    var windUnit: String { fahrenheit ? "mph" : "km/h" }
}

struct WeatherError: Error, Sendable {
    let message: String
}

/// Codes météo de l'OMM (ceux que renvoie Open-Meteo) vers un symbole SF et un libellé.
enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 66: return "cloud.rain.fill"
        case 65, 67: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81: return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 82: return "cloud.heavyrain.fill"
        case 95, 96, 97, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func label(_ code: Int) -> String {
        switch code {
        case 0: return "Dégagé"
        case 1: return "Peu nuageux"
        case 2: return "Éclaircies"
        case 3: return "Couvert"
        case 45, 48: return "Brouillard"
        case 51, 53, 55: return "Bruine"
        case 56, 57: return "Bruine verglaçante"
        case 61: return "Pluie faible"
        case 63: return "Pluie"
        case 65: return "Forte pluie"
        case 66, 67: return "Pluie verglaçante"
        case 71: return "Neige faible"
        case 73: return "Neige"
        case 75: return "Forte neige"
        case 77: return "Grains de neige"
        case 80, 81: return "Averses"
        case 82: return "Fortes averses"
        case 85, 86: return "Averses de neige"
        case 95, 96, 97, 99: return "Orage"
        default: return "Variable"
        }
    }
}

/// Réponse de https://api.open-meteo.com/v1/forecast (paramètres vérifiés sur la doc le 2026-11-25).
private struct ForecastResponse: Decodable {
    struct Current: Decodable {
        let time: String
        let temperature_2m: Double?
        let apparent_temperature: Double?
        let relative_humidity_2m: Double?
        let weather_code: Double?
        let wind_speed_10m: Double?
        let is_day: Double?
    }

    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double?]
        let weather_code: [Double?]
        let is_day: [Double?]?
    }

    struct Daily: Decodable {
        let time: [String]
        let weather_code: [Double?]
        let temperature_2m_max: [Double?]
        let temperature_2m_min: [Double?]
    }

    let current: Current?
    let hourly: Hourly?
    let daily: Daily?
}

/// Réponse de https://geocoding-api.open-meteo.com/v1/search.
private struct GeocodingResponse: Decodable {
    struct Place: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
        let admin1: String?
    }

    let results: [Place]?
}

/// Météo Open-Meteo (sans clé). Aucune requête en tâche de fond : on ne charge que lorsque
/// l'onglet Météo est affiché, et au plus une fois par quart d'heure et par ville.
@MainActor
final class WeatherService: ObservableObject {
    @Published private(set) var report: WeatherReport?
    @Published private(set) var loading = false
    @Published private(set) var error = ""

    private static let cacheLife: TimeInterval = 15 * 60

    private let settings: SettingsStore
    private var cache: [String: WeatherReport] = [:]
    private var requestToken = 0

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var cities: [WeatherCity] { settings.s.weatherCities }

    var selectedIndex: Int {
        let count = settings.s.weatherCities.count
        guard count > 0 else { return 0 }
        return min(max(settings.s.weatherCity, 0), count - 1)
    }

    var selectedCity: WeatherCity? {
        let list = settings.s.weatherCities
        guard !list.isEmpty else { return nil }
        return list[selectedIndex]
    }

    func select(_ index: Int) {
        if settings.s.weatherCity != index {
            settings.s.weatherCity = index
        }
        refresh(force: false)
    }

    /// Charge la météo de la ville choisie. Sans `force`, un relevé de moins de 15 min est réutilisé.
    func refresh(force: Bool) {
        guard let city = selectedCity else {
            report = nil
            error = ""
            return
        }
        let fahrenheit = settings.s.weatherFahrenheit
        let key = "\(city.id)|\(fahrenheit)"

        if let cached = cache[key] {
            report = cached
            if !force && Date().timeIntervalSince(cached.fetchedAt) < WeatherService.cacheLife {
                error = ""
                return
            }
        } else {
            report = nil
        }

        requestToken += 1
        let token = requestToken
        loading = true
        error = ""
        Task { [weak self] in
            let result = await WeatherService.fetch(city: city, fahrenheit: fahrenheit)
            guard let self, self.requestToken == token else { return }
            self.loading = false
            switch result {
            case .success(let fresh):
                self.cache[key] = fresh
                self.report = fresh
            case .failure(let problem):
                self.error = problem.message
            }
        }
    }

    // MARK: Réseau

    nonisolated private static func fetch(city: WeatherCity, fahrenheit: Bool) async -> Result<WeatherReport, WeatherError> {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        var items = [
            URLQueryItem(name: "latitude", value: String(city.latitude)),
            URLQueryItem(name: "longitude", value: String(city.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "4"),
            URLQueryItem(name: "forecast_hours", value: "8")
        ]
        if fahrenheit {
            items.append(URLQueryItem(name: "temperature_unit", value: "fahrenheit"))
            items.append(URLQueryItem(name: "wind_speed_unit", value: "mph"))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            return .failure(WeatherError(message: "Adresse météo invalide"))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(WeatherError(message: "Open-Meteo ne répond pas"))
            }
            let decoded = try JSONDecoder().decode(ForecastResponse.self, from: data)
            guard let report = makeReport(decoded, city: city, fahrenheit: fahrenheit) else {
                return .failure(WeatherError(message: "Réponse météo incomplète"))
            }
            return .success(report)
        } catch {
            return .failure(WeatherError(message: "Météo indisponible (réseau ou format)"))
        }
    }

    nonisolated private static func makeReport(_ response: ForecastResponse, city: WeatherCity, fahrenheit: Bool) -> WeatherReport? {
        guard let current = response.current, let temperature = current.temperature_2m else { return nil }
        let isDay = (current.is_day ?? 1) >= 0.5

        // Heure par heure : les 7 prochaines heures à partir de l'heure en cours.
        var hours: [WeatherHour] = []
        if let hourly = response.hourly {
            let nowHour = String(current.time.prefix(13))
            for index in hourly.time.indices {
                guard hours.count < 7 else { break }
                let stamp = hourly.time[index]
                guard String(stamp.prefix(13)) >= nowHour,
                      index < hourly.temperature_2m.count,
                      let value = hourly.temperature_2m[index]
                else { continue }
                let code = index < hourly.weather_code.count ? Int(hourly.weather_code[index] ?? 3) : 3
                var day = true
                if let flags = hourly.is_day, index < flags.count, let flag = flags[index] {
                    day = flag >= 0.5
                }
                let hourText = String(stamp.dropFirst(11).prefix(2))
                hours.append(WeatherHour(id: stamp, label: "\(hourText) h", temperature: value, code: code, isDay: day))
            }
        }

        // 4 jours.
        var days: [WeatherDay] = []
        if let daily = response.daily {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(identifier: "UTC")
            parser.dateFormat = "yyyy-MM-dd"
            let weekday = DateFormatter()
            weekday.locale = Locale(identifier: "fr_FR")
            weekday.timeZone = TimeZone(identifier: "UTC")
            weekday.dateFormat = "EEE"

            for index in daily.time.indices {
                guard days.count < 4,
                      index < daily.temperature_2m_max.count,
                      index < daily.temperature_2m_min.count,
                      let high = daily.temperature_2m_max[index],
                      let low = daily.temperature_2m_min[index]
                else { continue }
                let stamp = daily.time[index]
                let label: String
                if days.isEmpty {
                    label = "Auj."
                } else if days.count == 1 {
                    label = "Demain"
                } else if let date = parser.date(from: stamp) {
                    label = weekday.string(from: date).replacingOccurrences(of: ".", with: "").capitalized
                } else {
                    label = stamp
                }
                let code = index < daily.weather_code.count ? Int(daily.weather_code[index] ?? 3) : 3
                days.append(WeatherDay(id: stamp, label: label, code: code, low: low, high: high))
            }
        }

        return WeatherReport(city: city,
                             time: String(current.time.suffix(5)),
                             temperature: temperature,
                             feelsLike: current.apparent_temperature ?? temperature,
                             humidity: current.relative_humidity_2m ?? 0,
                             wind: current.wind_speed_10m ?? 0,
                             code: Int(current.weather_code ?? 3),
                             isDay: isDay,
                             hours: hours,
                             days: days,
                             fahrenheit: fahrenheit,
                             fetchedAt: Date())
    }

    /// Géocodage Open-Meteo : cherche une ville par son nom (réglages).
    nonisolated static func search(_ query: String) async -> [WeatherCity] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return [] }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: text),
            URLQueryItem(name: "count", value: "6"),
            URLQueryItem(name: "language", value: "fr"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(GeocodingResponse.self, from: data)
        else { return [] }
        return (decoded.results ?? []).map { place in
            let parts = [place.admin1, place.country].compactMap { $0 }.filter { !$0.isEmpty }
            return WeatherCity(name: place.name,
                               region: parts.joined(separator: ", "),
                               latitude: place.latitude,
                               longitude: place.longitude)
        }
    }
}
