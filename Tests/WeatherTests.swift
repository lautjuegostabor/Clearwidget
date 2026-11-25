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
        print("Weather tests passed")
    }
}
