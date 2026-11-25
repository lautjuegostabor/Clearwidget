import Foundation

// Personal-use city forecast; no precise location or location permission.
struct WeatherReading: Sendable {
    let current: Double?
    let nextHour: Double?
    let tomorrowHigh: Double?
    let code: Int?
    let isDay: Bool
    let fetchedAt: Date?
    static let empty = WeatherReading(current: nil, nextHour: nil, tomorrowHigh: nil, code: nil, isDay: true, fetchedAt: nil)
    var symbol: String {
        guard let code else { return "cloud" }
        switch code {
        case 0: return isDay ? "sun.max" : "moon.stars"
        case 1, 2: return isDay ? "cloud.sun" : "cloud.moon"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...57: return "cloud.drizzle"
        case 61...67, 80...82: return "cloud.rain"
        case 71...77, 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }
    static func degrees(_ value: Double?) -> String {
        guard let value, value.isFinite, (-100...70).contains(value) else { return "—" }
        return "\(Int(value.rounded()))°"
    }
}
struct ForecastPayload: Codable, Sendable {
    struct Current: Codable, Sendable {
        let time: Int
        let temperature_2m: Double?
        let weather_code: Int?
        let is_day: Int?
    }
    struct Hourly: Codable, Sendable {
        let time: [Int]
        let temperature_2m: [Double?]
        let weather_code: [Int?]
        let is_day: [Int?]
    }
    let current: Current?
    let hourly: Hourly
}
struct ForecastCache: Codable, Sendable {
    let fetchedAt: Date
    let payload: ForecastPayload

    func reading(at now: Date) -> WeatherReading {
        let age = now.timeIntervalSince(fetchedAt)
        guard age >= -300, age <= 6 * 3600 else { return .empty }
        let h = payload.hourly
        let count = min(h.time.count, h.temperature_2m.count, h.weather_code.count, h.is_day.count)
        guard count > 0 else { return .empty }
        let seconds = now.timeIntervalSince1970
        let indices = 0..<count
        let lower = indices.last { Double(h.time[$0]) <= seconds }
        let upper = indices.first { Double(h.time[$0]) > seconds }
        var interpolated: Double?
        if let lo = lower, let hi = upper,
           let a = h.temperature_2m[lo], let b = h.temperature_2m[hi],
           h.time[hi] > h.time[lo], h.time[hi] - h.time[lo] <= 7200 {
            let ratio = (seconds - Double(h.time[lo])) / Double(h.time[hi] - h.time[lo])
            interpolated = a + (b - a) * ratio
        } else if let lo = lower, seconds - Double(h.time[lo]) < 3600 {
            interpolated = h.temperature_2m[lo]
        }
        let current = payload.current.flatMap { abs(seconds - Double($0.time)) <= 1800 ? $0 : nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Argentina/Cordoba") ?? .current
        let day = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let afterTomorrow = calendar.date(byAdding: .day, value: 2, to: day) ?? day
        let tomorrowValues = indices.compactMap { i -> Double? in
            let time = Date(timeIntervalSince1970: Double(h.time[i]))
            return time >= tomorrow && time < afterTomorrow ? h.temperature_2m[i] : nil
        }
        return WeatherReading(
            current: current?.temperature_2m ?? interpolated,
            nextHour: upper.flatMap { h.time[$0] <= Int(seconds) + 3600 ? h.temperature_2m[$0] : nil },
            tomorrowHigh: tomorrowValues.count >= 20 ? tomorrowValues.max() : nil,
            code: current?.weather_code ?? lower.flatMap { h.weather_code[$0] },
            isDay: (current?.is_day ?? lower.flatMap { h.is_day[$0] } ?? 1) == 1,
            fetchedAt: fetchedAt
        )
    }
}

enum ForecastDisk {
    static let cacheKey = "clearwidget.ecmwf.cache.v1"
    static let attemptKey = "clearwidget.ecmwf.attempt.v1"
    static let navigationKey = "clearwidget.navigation.v1"
    static let ttl: TimeInterval = 30 * 60
    static let retry: TimeInterval = 15 * 60
    static var cached: ForecastCache? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(ForecastCache.self, from: data)
    }
    static func markNavigation() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: navigationKey)
    }
    static func navigationRecent(at now: Date) -> Bool {
        let elapsed = now.timeIntervalSince1970 - UserDefaults.standard.double(forKey: navigationKey)
        return elapsed >= 0 && elapsed < 15
    }
    static func nextRefresh(at now: Date) -> Date {
        if let cache = cached, (0..<ttl).contains(now.timeIntervalSince(cache.fetchedAt)) {
            return max(now.addingTimeInterval(60), cache.fetchedAt.addingTimeInterval(ttl))
        }
        let last = UserDefaults.standard.double(forKey: attemptKey)
        let earliest = Date(timeIntervalSince1970: last + retry)
        return max(now.addingTimeInterval(retry), earliest)
    }
}

actor WeatherService {
    static let shared = WeatherService()
    private var inFlight = false
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // Only scheduled timeline generation may fetch. Navigation uses local cache.
    func refreshIfDue(at now: Date) async {
        guard !inFlight, !ForecastDisk.navigationRecent(at: now) else { return }
        if let cache = ForecastDisk.cached, (0..<ForecastDisk.ttl).contains(now.timeIntervalSince(cache.fetchedAt)) { return }
        let defaults = UserDefaults.standard
        let sinceAttempt = now.timeIntervalSince1970 - defaults.double(forKey: ForecastDisk.attemptKey)
        guard sinceAttempt >= ForecastDisk.retry || sinceAttempt < 0 else { return }
        guard let url = Self.endpoint else { return }
        inFlight = true
        defaults.set(now.timeIntervalSince1970, forKey: ForecastDisk.attemptKey)
        defer { inFlight = false }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 100_000 else { return }
            let decoded = try JSONDecoder().decode(ForecastPayload.self, from: data)
            guard decoded.hourly.time.count >= 48,
                  decoded.hourly.time.count == decoded.hourly.temperature_2m.count,
                  decoded.hourly.time.count == decoded.hourly.weather_code.count,
                  decoded.hourly.time.count == decoded.hourly.is_day.count,
                  decoded.hourly.temperature_2m.contains(where: { $0 != nil })
            else { return }
            let cache = ForecastCache(fetchedAt: Date(), payload: decoded)
            defaults.set(try JSONEncoder().encode(cache), forKey: ForecastDisk.cacheKey)
        } catch {
            // Retain last good forecast. No immediate retries or fabricated temperatures.
        }
    }
    static var endpoint: URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            .init(name: "latitude", value: "-31.4167"),
            .init(name: "longitude", value: "-64.1833"),
            .init(name: "models", value: "ecmwf_ifs"),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            .init(name: "forecast_days", value: "3"),
            .init(name: "temperature_unit", value: "celsius"),
            .init(name: "timezone", value: "America/Argentina/Cordoba"),
            .init(name: "timeformat", value: "unixtime")
        ]
        return components?.url
    }
}
