import Foundation

// Common forecast format for Apple Shortcuts and Open-Meteo.
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
    var timezone: String? = nil
}
struct ForecastCache: Codable, Sendable {
    let fetchedAt: Date
    let payload: ForecastPayload
    var source: String? = nil
    var location: WeatherLocation? = nil
    var tomorrowMaximum: Double? = nil
    var todayLow: Double? = nil

    func todayMinimum(at now: Date) -> Double? {
        guard (0...21600).contains(now.timeIntervalSince(fetchedAt)) else { return nil }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = payload.timezone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        if source == "apple" { return c.isDate(fetchedAt,inSameDayAs: now) ? todayLow : nil }
        let start = c.startOfDay(for: now)
        guard let end = c.date(byAdding: .day,value: 1,to: start) else { return nil }
        let values = zip(payload.hourly.time,payload.hourly.temperature_2m).compactMap { time,temp -> Double? in
            let d = Date(timeIntervalSince1970: Double(time))
            return d >= start && d < end ? temp : nil
        }
        return values.count >= 20 ? values.min() : nil
    }

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
        let currentWindow: Double = source == "apple" ? 75 * 60 : 1800
        let current = payload.current.flatMap { abs(seconds - Double($0.time)) <= currentWindow ? $0 : nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = payload.timezone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
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
            tomorrowHigh: (calendar.isDate(fetchedAt, inSameDayAs: now) ? tomorrowMaximum : nil) ?? (tomorrowValues.count >= 20 ? tomorrowValues.max() : nil),
            code: current?.weather_code ?? lower.flatMap { h.weather_code[$0] },
            isDay: (current?.is_day ?? lower.flatMap { h.is_day[$0] } ?? 1) == 1,
            fetchedAt: fetchedAt
        )
    }
}

struct WeatherLocation: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let observedAt: Date
    var valid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    func near(_ other: WeatherLocation) -> Bool {
        let r = Double.pi / 180
        let dLat = (latitude - other.latitude) * r
        let dLon = (longitude - other.longitude) * r
        let a = pow(sin(dLat / 2), 2) + cos(latitude * r) * cos(other.latitude * r) * pow(sin(dLon / 2), 2)
        return 6371 * 2 * asin(sqrt(min(1, max(0, a)))) <= 20
    }
}

enum ForecastDisk {
    static let cacheKey = "clearwidget.openmeteo.cache.v2"
    static let appleKey = "clearwidget.apple.cache.v1"
    static let locationKey = "clearwidget.forecast.location.v1"
    static let attemptKey = "clearwidget.openmeteo.attempt.v2"
    static let ttl: TimeInterval = 60 * 60
    static let appleFreshness: TimeInterval = 75 * 60
    static let retry: TimeInterval = 5 * 60
    private static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static var location: WeatherLocation? { read(WeatherLocation.self, key: locationKey) }
    static var apple: ForecastCache? { read(ForecastCache.self, key: appleKey) }
    static var fallback: ForecastCache? { read(ForecastCache.self, key: cacheKey) }
    static func fresh(_ cache: ForecastCache?, at now: Date, maxAge: TimeInterval) -> Bool {
        guard let cache, let position = cache.location, let latest = location, position.near(latest) else { return false }
        return (0..<maxAge).contains(now.timeIntervalSince(cache.fetchedAt))
    }
    static func select(apple: ForecastCache?, fallback: ForecastCache?, location: WeatherLocation?, at now: Date) -> ForecastCache? {
        guard let location, (0..<6 * 3600).contains(now.timeIntervalSince(location.observedAt)) else { return nil }
        func valid(_ c: ForecastCache?, age: TimeInterval) -> Bool {
            guard let c, let p = c.location, p.near(location) else { return false }
            return (0..<age).contains(now.timeIntervalSince(c.fetchedAt))
        }
        if valid(apple, age: appleFreshness) { return apple }
        if valid(fallback, age: 6 * 3600) { return fallback }
        if valid(apple, age: 6 * 3600) { return apple }
        return nil
    }
    static func cached(at now: Date) -> ForecastCache? {
        select(apple: apple, fallback: fallback, location: location, at: now)
    }
    static var cached: ForecastCache? { cached(at: Date()) }
    static func updateLocation(_ new: WeatherLocation) throws {
        guard new.valid else { return }
        if let old = location {
            guard new.observedAt >= old.observedAt else { return }
            if !old.near(new) {
                UserDefaults.standard.removeObject(forKey: appleKey)
                UserDefaults.standard.removeObject(forKey: cacheKey)
                UserDefaults.standard.removeObject(forKey: attemptKey)
            }
        }
        UserDefaults.standard.set(try JSONEncoder().encode(new), forKey: locationKey)
    }
    static func save(_ cache: ForecastCache, key: String) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(cache), forKey: key)
    }
    static func nextRefresh(at now: Date) -> Date { nextRefresh(at: now, cache: cached(at: now)) }
    static func nextRefresh(at now: Date, cache: ForecastCache?) -> Date {
        if let cache, (0..<ttl).contains(now.timeIntervalSince(cache.fetchedAt)) {
            return max(now.addingTimeInterval(60), cache.fetchedAt.addingTimeInterval(ttl))
        }
        let last = UserDefaults.standard.double(forKey: attemptKey)
        return max(now.addingTimeInterval(5 * 60), Date(timeIntervalSince1970: last + retry))
    }
}

actor WeatherService {
    static let shared = WeatherService()
    private var inFlight = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
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

    // Scheduled fallback; navigation remains cache-only. Apple ingestion is independent.
    func refreshIfDue(at now: Date) async {
        if let position = ForecastDisk.location,
           (0..<300).contains(now.timeIntervalSince(position.observedAt)),
           ForecastDisk.fresh(ForecastDisk.apple, at: now, maxAge: ForecastDisk.appleFreshness) ||
           ForecastDisk.fresh(ForecastDisk.fallback, at: now, maxAge: ForecastDisk.ttl) { return }
        if inFlight {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        inFlight = true
        defer {
            inFlight = false
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
        do {
            if let position = await WidgetLocation.current() {
                try ForecastDisk.updateLocation(position)
            }
            guard let position = ForecastDisk.location,
                  (0..<2 * 3600).contains(Date().timeIntervalSince(position.observedAt)) else { return }
            let date = Date()
            if ForecastDisk.fresh(ForecastDisk.apple, at: date, maxAge: ForecastDisk.appleFreshness) ||
                ForecastDisk.fresh(ForecastDisk.fallback, at: date, maxAge: ForecastDisk.ttl) { return }
            let defaults = UserDefaults.standard
            let sinceAttempt = date.timeIntervalSince1970 - defaults.double(forKey: ForecastDisk.attemptKey)
            guard sinceAttempt >= ForecastDisk.retry || sinceAttempt < 0 else { return }
            guard let url = Self.endpoint(latitude: position.latitude, longitude: position.longitude) else { return }
            defaults.set(date.timeIntervalSince1970, forKey: ForecastDisk.attemptKey)
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 100_000 else { return }
            let decoded = try JSONDecoder().decode(ForecastPayload.self, from: data)
            guard decoded.hourly.time.count >= 48,
                  decoded.hourly.time.count == decoded.hourly.temperature_2m.count,
                  decoded.hourly.time.count == decoded.hourly.weather_code.count,
                  decoded.hourly.time.count == decoded.hourly.is_day.count,
                  decoded.hourly.temperature_2m.contains(where: { $0 != nil })
            else { return }
            guard let latest = ForecastDisk.location, latest.near(position) else { return }
            let cache = ForecastCache(fetchedAt: Date(), payload: decoded, source: "openmeteo", location: position)
            try ForecastDisk.save(cache, key: ForecastDisk.cacheKey)
        } catch {
            // Retain last good forecast. No immediate retries or fabricated temperatures.
        }
    }
    // Explicit shortcut input is not rate-limited. Verify its own persisted
    // cache before reporting success and associate the exact payload timestamp.
    func acceptShortcutApple(_ json: String, at now: Date = Date()) throws {
        let cache = try AppleWeatherInput.parse(json, at: now)
        try acceptShortcutCache(cache, at: now)
    }

    func acceptShortcutCache(_ cache: ForecastCache, at now: Date) throws {
        guard cache.source == "apple", cache.fetchedAt == now,
              let position = cache.location,
              ForecastDisk.location.map({ $0.observedAt <= now }) ?? true
        else { throw AppleWeatherTextInput.Failure(detail: "el registro de ubicación es más reciente que el pronóstico o el origen no es válido.") }
        try ForecastDisk.updateLocation(position)
        try ForecastDisk.save(cache, key: ForecastDisk.appleKey)
        guard let stored = ForecastDisk.apple, stored.fetchedAt == now,
              ForecastDisk.cached(at: now)?.source == "apple"
        else { throw AppleWeatherTextInput.Failure(detail: "no se pudo verificar el pronóstico guardado en WidgetKit.") }
        ShortcutReceipt.startWeather(at: stored.fetchedAt)
    }

    func acceptApple(_ json: String, at now: Date = Date()) throws {
        let cache = try AppleWeatherInput.parse(json, at: now)
        guard let position = cache.location else { throw AppleWeatherError.invalid }
        if let previous = ForecastDisk.apple, let prior = previous.location, prior.near(position),
           (0..<ForecastDisk.retry).contains(now.timeIntervalSince(previous.fetchedAt)) {
            return
        }
        try ForecastDisk.updateLocation(position)
        try ForecastDisk.save(cache, key: ForecastDisk.appleKey)
    }

    static func endpoint(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "models", value: "ecmwf_ifs"),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            .init(name: "forecast_days", value: "3"),
            .init(name: "temperature_unit", value: "celsius"),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime")
        ]
        return components?.url
    }
}
