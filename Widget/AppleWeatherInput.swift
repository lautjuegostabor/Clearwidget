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
    let todayLow: Double?
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
        return try x.cache(at: now)
    }

    func cache(at now: Date) throws -> ForecastCache {
        let x = self
        let position = WeatherLocation(latitude: x.latitude, longitude: x.longitude, observedAt: now)
        let t = now.timeIntervalSince1970
        func tempOK(_ d: Double) -> Bool { d.isFinite && (-100...70).contains(d) }
        guard position.valid, x.current.time.isFinite, abs(x.current.time - t) <= 600,
              tempOK(x.current.temperature), tempOK(x.tomorrowHigh), x.todayLow.map(tempOK) ?? true, x.hourly.count <= 72 else { throw AppleWeatherError.invalid }
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
                             source: "apple", location: position, tomorrowMaximum: x.tomorrowHigh, todayLow: x.todayLow)
    }
}

// Native Shortcuts values: convert units and dates in Swift, not in the shortcut.
// Sunrise/sunset display classification uses the NOAA approximate solar position
// equations (solar zenith 90.833 degrees). No network request or fixed local time.
enum NativeWeatherInputError: LocalizedError {
    case location, listLengths, temperature, hourlyCoverage, missingCondition
    var errorDescription: String? {
        switch self {
        case .location: return "No se recibió una ubicación válida."
        case .listLengths: return "Las listas de fechas, temperaturas y condiciones por hora deben tener igual cantidad de elementos."
        case .temperature: return "La temperatura recibida no es válida."
        case .hourlyCoverage: return "El pronóstico debe contener al menos cinco horas futuras consecutivas."
        case .missingCondition: return "Falta una condición meteorológica."
        }
    }
}

enum NativeAppleWeatherInput {
    static func isDay(at date: Date, latitude: Double, longitude: Double) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hours = Double(components.hour ?? 0) + Double(components.minute ?? 0)/60 + Double(components.second ?? 0)/3600
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let days = Double(calendar.range(of: .day, in: .year, for: date)?.count ?? 365)
        let gamma = 2 * Double.pi / days * (day - 1 + (hours - 12)/24)
        let eqtime = 229.18 * (0.000075 + 0.001868*cos(gamma) - 0.032077*sin(gamma)
            - 0.014615*cos(2*gamma) - 0.040849*sin(2*gamma))
        let decl = 0.006918 - 0.399912*cos(gamma) + 0.070257*sin(gamma)
            - 0.006758*cos(2*gamma) + 0.000907*sin(2*gamma)
            - 0.002697*cos(3*gamma) + 0.00148*sin(3*gamma)
        let solarMinutes = (hours*60 + eqtime + 4*longitude).truncatingRemainder(dividingBy: 1440)
        let normalized = solarMinutes < 0 ? solarMinutes + 1440 : solarMinutes
        let hourAngle = (normalized/4 - 180) * Double.pi/180
        let lat = latitude * Double.pi/180
        let cosine = sin(lat)*sin(decl) + cos(lat)*cos(decl)*cos(hourAngle)
        return cosine >= cos(90.833 * Double.pi/180)
    }

    static func makeCache(latitude: Double, longitude: Double, timezone: TimeZone,
                          currentTemperature: Measurement<UnitTemperature>, currentCondition: String,
                          hourlyDates: [Date], hourlyTemperatures: [Measurement<UnitTemperature>],
                          hourlyConditions: [String], todayLow: Measurement<UnitTemperature>,
                          tomorrowHigh: Measurement<UnitTemperature>, at now: Date = Date()) throws -> ForecastCache {
        let location = WeatherLocation(latitude: latitude, longitude: longitude, observedAt: now)
        guard location.valid else { throw NativeWeatherInputError.location }
        guard hourlyDates.count == hourlyTemperatures.count, hourlyDates.count == hourlyConditions.count,
              (5...168).contains(hourlyDates.count)
        else { throw NativeWeatherInputError.listLengths }
        func celsius(_ temperature: Measurement<UnitTemperature>) throws -> Double {
            let v = temperature.converted(to: .celsius).value
            guard v.isFinite, (-100...70).contains(v) else { throw NativeWeatherInputError.temperature }
            return v
        }
        func row(_ date: Date, _ temp: Measurement<UnitTemperature>, _ condition: String) throws -> AppleWeatherInput.Hour {
            guard !condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw NativeWeatherInputError.missingCondition }
            return .init(time: date.timeIntervalSince1970, temperature: try celsius(temp),
                         condition: condition, isDay: isDay(at: date, latitude: latitude, longitude: longitude))
        }
        // Shortcuts may include the current hour; preserve alignment and select
        // only future rows. The source dates, not their list index, set times.
        let indices = hourlyDates.indices.filter {
            let t = hourlyDates[$0].timeIntervalSince(now)
            return t.isFinite && t > 0 && t <= 72*3600
        }.sorted { hourlyDates[$0] < hourlyDates[$1] }
        guard indices.count >= 5, hourlyDates[indices[0]].timeIntervalSince(now) <= 3600,
              zip(indices, indices.dropFirst()).allSatisfy({ hourlyDates[$1].timeIntervalSince(hourlyDates[$0]) == 3600 })
        else { throw NativeWeatherInputError.hourlyCoverage }
        let hours = try indices.prefix(72).map { try row(hourlyDates[$0], hourlyTemperatures[$0], hourlyConditions[$0]) }
        let input = AppleWeatherInput(latitude: latitude, longitude: longitude,
            current: try row(now, currentTemperature, currentCondition), hourly: hours,
            tomorrowHigh: try celsius(tomorrowHigh), todayLow: try celsius(todayLow), timezone: timezone.identifier)
        return try input.cache(at: now)
    }
}
