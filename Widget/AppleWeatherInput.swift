import Foundation

enum AppleWeatherError: LocalizedError {
    case invalid
    var errorDescription: String? { "Pronóstico de Apple inválido. Revisá los datos, las unidades y las fechas del atajo." }
}

// Stable local interface for a user-created Shortcut; no private Weather API.
struct AppleWeatherInput: Decodable {
    struct Hour: Decodable {
        let time: Double
        let temperature: Double
        let condition: String
        let isDay: Bool
    }
    let latitude: Double
    let longitude: Double
    let current: Hour
    let hourly: [Hour]
    let tomorrowHigh: Double
    let timezone: String?

    static func code(_ condition: String) -> Int? {
        let s = condition.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_AR")).lowercased()
        if s.contains("torment") || s.contains("thunder") { return 95 }
        if s.contains("nieve") || s.contains("snow") || s.contains("sleet") || s.contains("aguanieve") { return 71 }
        if s.contains("granizo") || s.contains("hail") { return 96 }
        if s.contains("niebla") || s.contains("fog") || s.contains("mist") || s.contains("bruma") || s.contains("haze") || s.contains("smok") || s.contains("humo") { return 45 }
        if s.contains("llovizna") || s.contains("drizzle") { return 51 }
        if s.contains("chubasc") || s.contains("chaparr") || s.contains("shower") { return 80 }
        if s.contains("lluv") || s.contains("rain") { return 61 }
        if s.contains("parcial") || s.contains("partly") || s.contains("partially") { return 2 }
        if s.contains("mayormente despejado") || s.contains("mayormente soleado") || s.contains("mostly clear") || s.contains("mostly sunny") { return 1 }
        if s.contains("nublad") || s.contains("nubos") || s.contains("cloudy") || s.contains("overcast") { return 3 }
        if s.contains("despejad") || s.contains("solead") || s.contains("clear") || s.contains("sunny") { return 0 }
        return nil
    }
    static func parse(_ json: String, at now: Date) throws -> ForecastCache {
        guard let data = json.data(using: .utf8), data.count <= 64_000 else { throw AppleWeatherError.invalid }
        let x = try JSONDecoder().decode(Self.self, from: data)
        let position = WeatherLocation(latitude: x.latitude, longitude: x.longitude, observedAt: now)
        let t = now.timeIntervalSince1970
        func tempOK(_ d: Double) -> Bool { d.isFinite && (-100...70).contains(d) }
        guard position.valid, x.current.time.isFinite, abs(x.current.time - t) <= 600,
              tempOK(x.current.temperature), tempOK(x.tomorrowHigh), x.hourly.count <= 72 else { throw AppleWeatherError.invalid }
        let hours = x.hourly.filter { $0.time.isFinite && $0.time > t && $0.time <= t + 72 * 3600 }.sorted { $0.time < $1.time }
        guard hours.count >= 5, hours[0].time - t <= 3600,
              hours.allSatisfy({ tempOK($0.temperature) }),
              zip(hours, hours.dropFirst()).allSatisfy({ $1.time - $0.time == 3600 }) else { throw AppleWeatherError.invalid }
        let rows = [x.current] + hours
        let c = ForecastPayload.Current(time: Int(x.current.time), temperature_2m: x.current.temperature,
                                      weather_code: code(x.current.condition), is_day: x.current.isDay ? 1 : 0)
        let h = ForecastPayload.Hourly(time: rows.map { Int($0.time) }, temperature_2m: rows.map { Optional($0.temperature) },
                                      weather_code: rows.map { code($0.condition) }, is_day: rows.map { $0.isDay ? 1 : 0 })
        let zone = x.timezone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        return ForecastCache(fetchedAt: now, payload: ForecastPayload(current: c, hourly: h, timezone: zone.identifier),
                             source: "apple", location: position, tomorrowMaximum: x.tomorrowHigh)
    }
}
