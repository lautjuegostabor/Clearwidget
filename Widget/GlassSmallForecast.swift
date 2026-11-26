import Foundation

// WMO weather codes mapped to the original Lokki image set, verified visually.
enum GlassCondition {
    static func description(_ code: Int?) -> String {
        guard let code else { return "Sin datos" }
        switch code {
        case 0: return "Despejado"
        case 1: return "Mayormente despejado"
        case 2: return "Parcialmente nublado"
        case 3: return "Nublado"
        case 45, 48: return "Niebla"
        case 51...57: return "Llovizna"
        case 61...67: return "Lluvia"
        case 71...77, 85, 86: return "Nieve"
        case 80...82: return "Chaparrones"
        case 95...99: return "Tormenta"
        default: return "Sin datos"
        }
    }
    static func asset(_ code: Int?, day: Bool) -> String? {
        guard let code else { return nil }
        let index: Int
        switch code {
        case 0: index = day ? 0 : 8
        case 1: index = day ? 1 : 9
        case 2: index = day ? 2 : 9
        case 3, 45, 48: index = 7
        case 51...57, 61...67: index = 4
        case 71...77, 85, 86: index = 6
        case 80...82: index = day ? 3 : 10
        case 95...99: index = 5
        default: return nil
        }
        return "GlassWeather\(index)"
    }
}

struct GlassHour: Sendable {
    let date: Date
    let temperature: Double?
    let code: Int?
    let day: Bool
    var asset: String? { GlassCondition.asset(code, day: day) }
    var label: String {
        guard let t = temperature, t.isFinite, (-100...70).contains(t) else { return "—" }
        return String(Int(t.rounded()))
    }
}

struct GlassForecast: Sendable {
    let current: WeatherReading
    let hours: [GlassHour]
    static let empty = GlassForecast(current: .empty, hours: [])
}

extension ForecastCache {
    func glassForecast(at now: Date) -> GlassForecast {
        let current = reading(at: now)
        guard current.fetchedAt != nil else { return .empty }
        let h = payload.hourly
        let count = min(h.time.count, h.temperature_2m.count, h.weather_code.count, h.is_day.count)
        let seconds = now.timeIntervalSince1970
        // Five successive full forecast hours; don't skip missing data or invent values.
        let first = (0..<count).first { Double(h.time[$0]) > seconds }
        let rows = first.map { start in
            (start..<min(start + 5, count)).map { i in
                GlassHour(date: Date(timeIntervalSince1970: Double(h.time[i])),
                          temperature: h.temperature_2m[i], code: h.weather_code[i],
                          day: h.is_day[i] == 1)
            }
        } ?? []
        return GlassForecast(current: current, hours: rows)
    }
}
