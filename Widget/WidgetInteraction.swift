import Foundation

enum WidgetInteraction {
    private static let key = "clearwidget.interaction.timestamp.v2"
    private static let metricsKey = "clearwidget.interaction.metrics.v1"
    struct Mark: Equatable { let date: Double; let uptime: Double }
    static func mark(at now: Date = Date(), defaults: UserDefaults = .standard,
                     uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        defaults.set(["date": now.timeIntervalSince1970, "uptime": uptime], forKey: key)
    }
    static func current(at now: Date = Date(), defaults: UserDefaults = .standard) -> Mark? {
        guard let data = defaults.dictionary(forKey: key),
              let date = data["date"] as? Double, let uptime = data["uptime"] as? Double,
              date.isFinite, uptime.isFinite, (0...6).contains(now.timeIntervalSince1970 - date) else { return nil }
        return Mark(date: date, uptime: uptime)
    }
    static func recent(at now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        current(at: now, defaults: defaults) != nil
    }
    static func finish(_ mark: Mark, started: TimeInterval, ended: TimeInterval,
                       at now: Date = Date(), defaults: UserDefaults = .standard) {
        guard current(at: now, defaults: defaults) == mark,
              (0...6).contains(started - mark.uptime), (0...6).contains(ended - started) else { return }
        defaults.set(["delay": (started - mark.uptime) * 1000,
                      "provider": (ended - started) * 1000,
                      "date": now.timeIntervalSince1970], forKey: metricsKey)
    }
    static func diagnostic(defaults: UserDefaults = .standard) -> String {
        guard let d = defaults.dictionary(forKey: metricsKey), let wait = d["delay"] as? Double,
              let provider = d["provider"] as? Double, let date = d["date"] as? Double,
              wait.isFinite, provider.isFinite, (0...6000).contains(wait), (0...6000).contains(provider) else {
            return "Sin medición de navegación disponible."
        }
        let time = Date(timeIntervalSince1970: date).formatted(.dateTime.hour().minute().second())
        return "Última navegación (\(time)): intent a timeline \(Int(wait.rounded())) ms; timeline \(Int(provider.rounded())) ms. No incluye el renderizado de iOS."
    }
}
