import Foundation

// Widget-local evidence, not a shared container or entitlement.
// A receipt is distinct from actual rendering on the Home Screen.
enum ShortcutReceipt {
    private struct Probe: Codable { let id: UUID; let kind: String; let created: Date }
    private struct Ack: Codable { let id: UUID; let time: Date; let weather: String?; let activity: String? }
    private static let probeKey = "clearwidget.shortcut.local.probe.v1"
    private static let ackKey = "clearwidget.shortcut.local.ack.v1"
    private static let lock = NSLock()
    private static func read<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    private static func write<T: Encodable>(_ value: T, _ key: String, _ defaults: UserDefaults) {
        if let bytes = try? JSONEncoder().encode(value) { defaults.set(bytes, forKey: key) }
    }
    static func start(kind: String, at now: Date, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        write(Probe(id: UUID(), kind: kind, created: now), probeKey, defaults)
        defaults.removeObject(forKey: ackKey)
    }
    static func confirmTimeline(at now: Date, weather: String?, activity: String?, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        guard let p = read(Probe.self, probeKey, defaults), now >= p.created,
              now.timeIntervalSince(p.created) <= 86400 else { return }
        let prior = read(Ack.self, ackKey, defaults)
        if let prior, prior.id == p.id {
            // Do not erase prior evidence when a different widget/page refreshes.
            let w = weather == "apple" ? weather : prior.weather ?? weather
            let a = activity ?? prior.activity
            if prior.weather == w && prior.activity == a { return }
            write(Ack(id: p.id, time: now, weather: w, activity: a), ackKey, defaults)
        } else {
            write(Ack(id: p.id, time: now, weather: weather, activity: activity), ackKey, defaults)
        }
    }
    static func status(at now: Date = Date(), defaults: UserDefaults = .standard) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let p = read(Probe.self, probeKey, defaults), now >= p.created,
              now.timeIntervalSince(p.created) <= 86400 else { return nil }
        guard let a = read(Ack.self, ackKey, defaults), a.id == p.id, a.time >= p.created else {
            return "Prueba de \(p.kind) guardada; timeline pendiente."
        }
        return "Timeline confirmado (\(p.kind)). Clima seleccionado: \(a.weather ?? "sin datos"). Actividad en entrada: \(a.activity ?? "sin datos o página no activa")."
    }
}
