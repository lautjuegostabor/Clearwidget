import Foundation

@main
struct WeatherTests {
    static func main() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Argentina/Cordoba")!
        let start = cal.date(from: DateComponents(year: 2026, month: 11, day: 25))!
        let now = start.addingTimeInterval(10.5 * 3600)
        let times = (0..<72).map { Int(start.timeIntervalSince1970) + $0 * 3600 }
        let temps = (0..<72).map { Optional(Double($0)) }
        let hourly = ForecastPayload.Hourly(time: times, temperature_2m: temps,
                                             weather_code: Array(repeating: 2, count: 72),
                                             is_day: Array(repeating: 1, count: 72))
        let current = ForecastPayload.Current(time: Int(now.timeIntervalSince1970), temperature_2m: 22.5, weather_code: 0, is_day: 1)
        let payload = ForecastPayload(current: current, hourly: hourly, timezone: "America/Argentina/Cordoba")
        let cache = ForecastCache(fetchedAt: now, payload: payload)
        let reading = cache.reading(at: now)
        precondition(reading.current == 22.5)
        precondition(reading.nextHour == 11)
        precondition(reading.tomorrowHigh == 47)
        precondition(reading.symbol == "sun.max")
        precondition(WeatherReading.degrees(reading.current) == "23°")
        precondition(cache.reading(at: now.addingTimeInterval(7 * 3600)).current == nil)
        let later = cache.reading(at: now.addingTimeInterval(3600))
        precondition(later.current == 11.5)
        precondition(later.nextHour == 12)
        precondition(later.symbol == "cloud.sun")
        let encoded = try JSONEncoder().encode(cache)
        let roundTrip = try JSONDecoder().decode(ForecastCache.self, from: encoded)
        precondition(roundTrip.reading(at: now).tomorrowHigh == 47)
        let query = URLComponents(url: WeatherService.endpoint(latitude: -31.4167, longitude: -64.1833)!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.contains { $0.name == "models" && $0.value == "ecmwf_ifs" })
        precondition(query.contains { $0.name == "timeformat" && $0.value == "unixtime" })
        let glass = cache.glassForecast(at: now)
        precondition(glass.hours.count == 5)
        precondition(glass.hours.map(\.label) == ["11", "12", "13", "14", "15"])
        precondition(glass.hours.allSatisfy { $0.asset == "GlassWeather2" })
        precondition(GlassCondition.asset(2, day: false) == "GlassWeather9")
        precondition(GlassCondition.asset(80, day: false) == "GlassWeather10")
        precondition(GlassCondition.asset(95, day: true) == "GlassWeather5")
        precondition(GlassCondition.description(2) == "Parcialmente nublado")
        precondition(GlassCondition.description(nil) == "Sin datos")
        precondition(cache.glassForecast(at: now.addingTimeInterval(7 * 3600)).hours.isEmpty)
        let midnight = start.addingTimeInterval(23.5 * 3600)
        let crossing = ForecastCache(fetchedAt: midnight, payload: payload).glassForecast(at: midnight)
        precondition(crossing.hours.map(\.label) == ["24", "25", "26", "27", "28"])
        precondition(cache.glassForecast(at: start.addingTimeInterval(11 * 3600)).hours.first?.label == "12")
        precondition(ClearCondition.asset(2, day: false) == "ClearWeather10")
        precondition(ClearCondition.asset(0, day: true) == "ClearWeather0")
        precondition(ClearCondition.asset(95, day: true) == "ClearWeather5")
        precondition(query.contains { $0.name == "timezone" && $0.value == "auto" })
        let timestamp = now.timeIntervalSince1970
        let appleRows: [[String: Any]] = (0..<5).map { i in
            ["time": Double(times[11 + i]), "temperature": Double(i + 20), "condition": "Parcialmente nublado", "isDay": true]
        }
        let input: [String: Any] = ["latitude": -31.4, "longitude": -64.2,
            "current": ["time": timestamp, "temperature": 25.0, "condition": "Despejado", "isDay": true],
            "hourly": appleRows, "tomorrowHigh": 29.0, "timezone": "America/Argentina/Cordoba"]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let apple = try AppleWeatherInput.parse(json, at: now)
        precondition(apple.source == "apple" && apple.reading(at: now).current == 25)
        precondition(apple.reading(at: now).tomorrowHigh == 29)
        precondition(apple.glassForecast(at: now).hours.map(\.label) == ["20","21","22","23","24"])
        precondition(AppleWeatherInput.code("Partly Cloudy") == 2)
        precondition(AppleWeatherInput.code("Tormenta") == 95)
        precondition(AppleWeatherInput.code("inconocido") == nil)
        let location = apple.location!
        let fallback = ForecastCache(fetchedAt: now, payload: payload, source: "openmeteo", location: location)
        precondition(ForecastDisk.select(apple: apple, fallback: fallback, location: location, at: now)?.source == "apple")
        precondition(ForecastDisk.select(apple: apple, fallback: fallback, location: location, at: now.addingTimeInterval(80*60))?.source == "openmeteo")
        let moved = WeatherLocation(latitude: -34.6, longitude: -58.4, observedAt: now)
        precondition(ForecastDisk.select(apple: apple, fallback: fallback, location: moved, at: now) == nil)
        print("Weather, Apple ingestion, source selection, travel invalidation and icon tests passed")
    }
}
