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
        let payload = ForecastPayload(current: current, hourly: hourly)
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
        let query = URLComponents(url: WeatherService.endpoint!, resolvingAgainstBaseURL: false)!.queryItems!
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
        print("Weather and both Clear icon mapping tests passed")
    }
}
