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
        // Same real values as the original JSON fixture, now as typed parameters.
        // Fahrenheit deliberately tests that the shortcut need not convert units.
        let native = try NativeAppleWeatherInput.makeCache(latitude: -31.4, longitude: -64.2,
            timezone: TimeZone(identifier: "America/Argentina/Cordoba")!,
            currentTemperature: .init(value: 77, unit: .fahrenheit), currentCondition: "Despejado",
            hourlyDates: [now.addingTimeInterval(-1800)] + (11...15).map { Date(timeIntervalSince1970: Double(times[$0])) },
            hourlyTemperatures: [99.0,20,21,22,23,24].map { .init(value: $0, unit: .celsius) },
            hourlyConditions: Array(repeating: "Parcialmente nublado", count: 6),
            todayLow: .init(value: 15, unit: .celsius), tomorrowHigh: .init(value: 84.2, unit: .fahrenheit), at: now)
        precondition(abs((native.reading(at: now).current ?? 0) - 25) < 0.001)
        precondition(abs((native.reading(at: now).tomorrowHigh ?? 0) - 29) < 0.001)
        precondition(native.todayMinimum(at: now) == 15)
        precondition(native.payload.hourly.time.count == 6 && native.payload.hourly.time[1] == times[11])
        precondition(native.payload.current?.is_day == 1)
        precondition(!NativeAppleWeatherInput.isDay(at: midnight, latitude: -31.4, longitude: -64.2))
        precondition(NativeAppleWeatherInput.isDay(at: now, latitude: -31.4, longitude: -64.2))
        func invalidNative(_ ds: [Date], _ ts: [Measurement<UnitTemperature>], _ cs: [String]) -> Bool {
            do {
                _ = try NativeAppleWeatherInput.makeCache(latitude: -31.4, longitude: -64.2,
                    timezone: cal.timeZone, currentTemperature: .init(value: 23, unit: .celsius),
                    currentCondition: "Despejado", hourlyDates: ds, hourlyTemperatures: ts,
                    hourlyConditions: cs, todayLow: .init(value: 15, unit: .celsius),
                    tomorrowHigh: .init(value: 30, unit: .celsius), at: now)
                return false
            } catch { return true }
        }
        let d = (11...15).map { Date(timeIntervalSince1970: Double(times[$0])) }
        let v = Array(repeating: Measurement(value: 23.0, unit: UnitTemperature.celsius), count: 5)
        let c = Array(repeating: "Despejado", count: 5)
        precondition(invalidNative(d, Array(v.dropLast()), c))
        precondition(invalidNative([d[0],d[0],d[2],d[3],d[4]], v, c))
        precondition(invalidNative([d[0],d[1],d[2],d[3],d[4].addingTimeInterval(3600)], v, c))
        precondition(invalidNative(d, v, ["","Despejado","Despejado","Despejado","Despejado"]))
        let iso = ISO8601DateFormatter()
        var packet = ["CWAPPLE1", "L|-31,4|-64,2", "C|\(iso.string(from: now))|25,5 °C|Despejado"]
        for i in 10...16 {
            packet.append("H|\(iso.string(from: Date(timeIntervalSince1970: Double(times[i]))))|23 °C|Parcialmente nublado")
        }
        packet.append("D|\(iso.string(from: start))|15 °C|29 °C")
        packet.append("D|\(iso.string(from: start.addingTimeInterval(86400)))|17 °C|86 °F")
        let rawText = packet.joined(separator: "\n")
        let received = try AppleWeatherTextInput.parse(rawText, at: now, zone: cal.timeZone)
        precondition(received.source == "apple")
        precondition(received.reading(at: now).current == 25.5)
        precondition(abs((received.reading(at: now).tomorrowHigh ?? 0) - 30) < 0.001)
        precondition(received.todayMinimum(at: now) == 15)
        precondition(received.payload.hourly.time.count == 7)
        let invalidPackets = [
            rawText.replacingOccurrences(of: "25,5 °C", with: ""),
            rawText.replacingOccurrences(of: "L|-31,4|-64,2", with: "L||-64,2"),
            rawText.replacingOccurrences(of: "CWAPPLE1", with: "CWAPPLE2"),
            packet.filter { !$0.hasPrefix("H|") }.joined(separator: "\n"),
            packet.filter { !$0.hasPrefix("D|") }.joined(separator: "\n")
        ]
        for bad in invalidPackets {
            do {
                _ = try AppleWeatherTextInput.parse(bad, at: now, zone: cal.timeZone)
                preconditionFailure("Invalid Apple Weather text accepted")
            } catch { precondition(error.localizedDescription.hasPrefix("Clima Apple:")) }
        }
        let location = apple.location!
        let fallback = ForecastCache(fetchedAt: now, payload: payload, source: "openmeteo", location: location)
        precondition(ForecastDisk.select(apple: apple, fallback: fallback, location: location, at: now)?.source == "apple")
        precondition(ForecastDisk.select(apple: apple, fallback: fallback, location: location, at: now.addingTimeInterval(80*60))?.source == "openmeteo")
        let moved = WeatherLocation(latitude: -34.6, longitude: -58.4, observedAt: now)
        precondition(ForecastDisk.select(apple: apple, fallback: fallback, location: moved, at: now) == nil)
        precondition(cache.todayMinimum(at: now) == 0)
        precondition(apple.todayMinimum(at: now) == nil)
        let item = ActivityReading(source: "Mi Fitness", steps: 1234, activeKcal: 120, fetchedAt: Date())
        precondition(ActivityDisk.valid(item,at: item.fetchedAt))
        precondition(!ActivityDisk.valid(item,at: item.fetchedAt.addingTimeInterval(86401)))
        precondition(ActivityDisk.normalize("  MI Fitness ") == ActivityDisk.normalize("Mi Fitness"))
        precondition(!ActivityDisk.valid(ActivityReading(source: "",steps: 1,activeKcal: 0,fetchedAt: item.fetchedAt),at: item.fetchedAt))
        let suite = "ClearWidget.ShortcutReceipt.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(ShortcutReceipt.status(at: now, defaults: defaults) == nil)
        ShortcutReceipt.ensureDiagnostic(at: now, defaults: defaults)
        ShortcutReceipt.startWeather(at: now, defaults: defaults)
        let freshActivity = ActivityReading(source: "Mi Fitness", steps: 567, activeKcal: 42, fetchedAt: now)
        ShortcutReceipt.startActivity(freshActivity, defaults: defaults)
        func status(_ date: Date) -> String { ShortcutReceipt.status(at: date, defaults: defaults) ?? "" }
        let after = now.addingTimeInterval(1)
        ShortcutReceipt.confirmTimeline(at: now.addingTimeInterval(-1), weatherSource: "apple", weatherFetchedAt: now, activity: freshActivity, defaults: defaults)
        precondition(!status(now).contains("confirmado"))
        ShortcutReceipt.confirmTimeline(at: after, weatherSource: "apple", weatherFetchedAt: now.addingTimeInterval(-1), activity: nil, defaults: defaults)
        precondition(status(after).contains("diagnóstico: timeline confirmado"))
        precondition(status(after).contains("clima: guardado, timeline pendiente"))
        precondition(status(after).contains("actividad: guardado, timeline pendiente"))
        // Same source but stale or different values must not confirm a new packet.
        let wrong = ActivityReading(source: "Mi Fitness", steps: 1, activeKcal: 42, fetchedAt: now)
        ShortcutReceipt.confirmTimeline(at: after, weatherSource: "openmeteo", weatherFetchedAt: now, activity: wrong, defaults: defaults)
        precondition(status(after).contains("clima: guardado, timeline pendiente"))
        precondition(status(after).contains("actividad: guardado, timeline pendiente"))
        ShortcutReceipt.confirmTimeline(at: after, weatherSource: "apple", weatherFetchedAt: now, activity: freshActivity, defaults: defaults)
        precondition(status(after).contains("clima: timeline confirmado"))
        precondition(status(after).contains("actividad: timeline confirmado"))
        // New writes reset only their own receipt, never other confirmed kinds.
        ShortcutReceipt.startWeather(at: after, defaults: defaults)
        precondition(status(after).contains("clima: guardado, timeline pendiente"))
        precondition(status(after).contains("actividad: timeline confirmado"))
        ShortcutReceipt.confirmTimeline(at: after, weatherSource: "apple", weatherFetchedAt: nil, activity: nil, defaults: defaults)
        precondition(status(after).contains("clima: guardado, timeline pendiente"))
        ShortcutReceipt.confirmTimeline(at: after, weatherSource: "apple", weatherFetchedAt: after, activity: nil, defaults: defaults)
        precondition(status(after).contains("clima: timeline confirmado"))
        precondition(ShortcutReceipt.status(at: now.addingTimeInterval(86402), defaults: defaults) == nil)
        print("Weather, activity and widget-local receipt tests passed")
    }
}
