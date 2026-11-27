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
        if json.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("CWAPPLE1") {
            return try AppleWeatherTextInput.parse(json, at: now)
        }
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
                                      weather_code: Self.code(x.current.condition), is_day: x.current.isDay ? 1 : 0)
        let h = ForecastPayload.Hourly(time: rows.map { Int($0.time) }, temperature_2m: rows.map { Optional($0.temperature) },
                                      weather_code: rows.map { Self.code($0.condition) }, is_day: rows.map { $0.isDay ? 1 : 0 })
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


// CWAPPLE1: plain-text transport from native Apple Weather Shortcuts.
// No JSON numbers, boolean coercions, parallel lists or localized date parsing
// in Shortcuts. Explicit Celsius conversion happens in the native action;
// the receiver still recognizes Fahrenheit if a unit is supplied.
enum AppleWeatherTextInput {
    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "Clima Apple: " + detail }
    }
    static func parse(_ text: String, at now: Date,
                      zone: TimeZone = .autoupdatingCurrent) throws -> ForecastCache {
        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func number(_ value: String, field: String) throws -> Double {
            let s = clean(value).replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: ",", with: ".")
            guard let v = Double(s), v.isFinite else { throw Failure(detail: "\(field): número ausente o inválido.") }
            return v
        }
        func temperature(_ value: String, field: String) throws -> Measurement<UnitTemperature> {
            let s = clean(value).uppercased().replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: ",", with: ".")
                .replacingOccurrences(of: "℃", with: "°C").replacingOccurrences(of: "℉", with: "°F")
            let compact = s.filter { !$0.isWhitespace }
            var magnitude = compact
            var unit = UnitTemperature.celsius
            if magnitude.hasSuffix("F") { unit = .fahrenheit; magnitude.removeLast() }
            else if magnitude.hasSuffix("C") { magnitude.removeLast() }
            if magnitude.hasSuffix("°") { magnitude.removeLast() }
            let result = Measurement(value: try number(magnitude, field: field), unit: unit)
            guard (-100...70).contains(result.converted(to: .celsius).value) else {
                throw Failure(detail: "\(field): temperatura fuera de rango.")
            }
            return result
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: String, field: String) throws -> Date {
            let s = clean(value)
            guard let d = formatter.date(from: s) ?? fractional.date(from: s) else {
                throw Failure(detail: "\(field): falta una fecha ISO 8601 válida.")
            }
            return d
        }
        let lines = text.components(separatedBy: .newlines).map(clean).filter { !$0.isEmpty }
        guard lines.first == "CWAPPLE1" else { throw Failure(detail: "cabecera incorrecta.") }
        var location: (Double, Double)?
        var current: (Date, Measurement<UnitTemperature>, String)?
        var hours: [(Date, Measurement<UnitTemperature>, String)] = []
        var days: [(Date, Measurement<UnitTemperature>, Measurement<UnitTemperature>)] = []
        for (i, line) in lines.dropFirst().enumerated() {
            let p = line.components(separatedBy: "|").map(clean)
            let label = "registro \(i + 1)"
            switch p.first {
            case "L":
                guard p.count == 3, location == nil else { throw Failure(detail: "ubicación: estructura inválida.") }
                location = (try number(p[1], field: "latitud"), try number(p[2], field: "longitud"))
            case "C", "H":
                guard p.count == 4, !p[3].isEmpty else { throw Failure(detail: "\(label): faltan fecha, temperatura o condición.") }
                let row = (try date(p[1], field: label), try temperature(p[2], field: label), p[3])
                if p[0] == "C" {
                    guard current == nil else { throw Failure(detail: "clima actual duplicado.") }
                    current = row
                } else { hours.append(row) }
            case "D":
                guard p.count == 4 else { throw Failure(detail: "\(label): pronóstico diario incompleto.") }
                days.append((try date(p[1], field: label), try temperature(p[2], field: label + " mínima"),
                             try temperature(p[3], field: label + " máxima")))
            default: throw Failure(detail: "\(label): formato de línea incorrecto.")
            }
        }
        guard let loc = location,
              WeatherLocation(latitude: loc.0, longitude: loc.1, observedAt: now).valid
        else { throw Failure(detail: "ubicación ausente o fuera de rango.") }
        guard let c = current else { throw Failure(detail: "faltan condiciones actuales.") }
        guard abs(now.timeIntervalSince(c.0)) <= 600 else { throw Failure(detail: "fecha de consulta fuera de los últimos 10 minutos.") }
        guard (5...168).contains(hours.count) else { throw Failure(detail: "se recibieron \(hours.count) registros horarios; se necesitan al menos cinco.") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: now),
              let today = days.first(where: { calendar.isDate($0.0, inSameDayAs: now) }),
              let tomorrow = days.first(where: { calendar.isDate($0.0, inSameDayAs: nextDay) })
        else { throw Failure(detail: "faltan los pronósticos diarios de hoy o mañana.") }
        let future = hours.filter { $0.0 > now && $0.0.timeIntervalSince(now) <= 72*3600 }.sorted { $0.0 < $1.0 }
        guard future.count >= 5 else { throw Failure(detail: "solo \(future.count) horas futuras válidas.") }
        guard future[0].0.timeIntervalSince(now) <= 3600 else { throw Failure(detail: "la primera hora futura está a más de 60 minutos.") }
        // Keep only the consecutive prefix, never manufacture missing forecast rows.
        var consecutive = [future[0]]
        for row in future.dropFirst() {
            guard row.0.timeIntervalSince(consecutive.last!.0) == 3600 else { break }
            consecutive.append(row)
        }
        guard consecutive.count >= 5 else { throw Failure(detail: "solo \(consecutive.count) horas consecutivas; faltan registros de Apple.") }
        return try NativeAppleWeatherInput.makeCache(latitude: loc.0, longitude: loc.1, timezone: zone,
            currentTemperature: c.1, currentCondition: c.2, hourlyDates: consecutive.map { $0.0 },
            hourlyTemperatures: consecutive.map { $0.1 }, hourlyConditions: consecutive.map { $0.2 },
            todayLow: today.1, tomorrowHigh: tomorrow.2, at: now)
    }
}
