import Foundation
import Security

// A narrow shared access group; never use an unrestricted team-wide group.
// The actual signed entitlements must grant access to BOTH targets. Merely
// finding a wildcard in the provisioning profile does not establish access.
enum ShortcutBridgeError: LocalizedError {
    case missingProfile, denied(OSStatus), unverified, invalid
    var errorDescription: String? {
        switch self {
        case .missingProfile: return "No se encontró la identidad de la firma instalada."
        case .denied(let s): return "No hay acceso al puente local de ClearWidget (Keychain \(s))."
        case .unverified: return "El widget aún no confirmó el puente local. Ejecutá Diagnóstico ClearWidget con un widget añadido."
        case .invalid: return "Datos del puente local inválidos."
        }
    }
}

enum ShortcutBridge {
    private static let service = "com.clearwidget.shortcut.bridge.v1"
    private struct Probe: Codable { let id: UUID; let created: Date }
    private struct Ack: Codable { let id: UUID; let seen: Date }
    private struct WeatherPacket: Codable { let json: String; let date: Date }
    private static func group() throws -> String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let bytes = try? Data(contentsOf: url), bytes.count < 1_000_000,
              let a = bytes.range(of: Data("<plist".utf8)),
              let b = bytes.range(of: Data("</plist>".utf8), in: a.lowerBound..<bytes.endIndex),
              let p = try? PropertyListSerialization.propertyList(from: bytes.subdata(in: a.lowerBound..<b.upperBound), format: nil) as? [String: Any],
              let e = p["Entitlements"] as? [String: Any],
              let app = e["application-identifier"] as? String,
              let prefix = app.split(separator: ".").first,
              !prefix.isEmpty, prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw ShortcutBridgeError.missingProfile }
        return "\(prefix).com.clearwidget.bridge"
    }
    private static func query(_ account: String) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccessGroup as String: try group(),
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    private static func get<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        var q = try query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ShortcutBridgeError.denied(status) }
        guard let bytes = output as? Data, bytes.count <= 100_000 else { throw ShortcutBridgeError.invalid }
        return try JSONDecoder().decode(type, from: bytes)
    }
    private static func put<T: Encodable>(_ item: T, _ key: String) throws {
        let bytes = try JSONEncoder().encode(item)
        guard bytes.count <= 100_000 else { throw ShortcutBridgeError.invalid }
        let q = try query(key)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = bytes
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let inserted = SecItemAdd(add as CFDictionary, nil)
            if inserted == errSecDuplicateItem {
                let retried = SecItemUpdate(q as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
                guard retried == errSecSuccess else { throw ShortcutBridgeError.denied(retried) }
            } else if inserted != errSecSuccess { throw ShortcutBridgeError.denied(inserted) }
        } else if status != errSecSuccess { throw ShortcutBridgeError.denied(status) }
    }
    static func beginProbe() throws {
        try put(Probe(id: UUID(), created: Date()), "probe")
    }
    private static func verified() throws -> Bool {
        guard let p = try get(Probe.self, "probe"), let a = try get(Ack.self, "ack") else { return false }
        return p.id == a.id && a.seen >= p.created && (-60...7200).contains(Date().timeIntervalSince(a.seen))
    }
    static func diagnostic() throws -> String {
        if try verified() { return "Atajos responde. Puente local confirmado por la extensión." }
        if try get(Probe.self, "probe") == nil { try beginProbe() }
        return "Atajos responde. Esperando confirmación de la extensión; añadí un widget y volvé a consultar."
    }
    static func storeWeather(_ json: String) throws {
        let now = Date()
        _ = try AppleWeatherInput.parse(json, at: now)
        guard try verified() else { throw ShortcutBridgeError.unverified }
        try put(WeatherPacket(json: json, date: now), "weather")
    }
    static func storeActivity(source: String, steps: Int, kcal: Double) throws {
        let now = Date()
        let item = ActivityReading(source: source, steps: steps, activeKcal: kcal, fetchedAt: now)
        guard ActivityDisk.valid(item, at: now) else { throw ActivityError.invalid }
        guard try verified() else { throw ShortcutBridgeError.unverified }
        // Single writer (host), serialized by the AppIntent actor. Bound retention.
        var items = try get([String: ActivityReading].self, "activity") ?? [:]
        items = items.filter { ActivityDisk.valid($0.value, at: now) }
        let key = ActivityDisk.normalize(source)
        guard items.count < 30 || items[key] != nil else { throw ActivityError.invalid }
        items[key] = item
        try put(items, "activity")
    }
    // Called exclusively by the extension's timeline, not by the host. Local
    // caches preserve the existing weather selection and action/navigation logic.
    static func consumeInWidget(at now: Date) {
        if let p = try? get(Probe.self, "probe"), p.created <= now {
            let old = try? get(Ack.self, "ack")
            if old?.id != p.id || now.timeIntervalSince(old?.seen ?? .distantPast) > 1800 { try? put(Ack(id: p.id, seen: now), "ack") }
        }
        if let w = try? get(WeatherPacket.self, "weather"),
           (0..<ForecastDisk.appleFreshness).contains(now.timeIntervalSince(w.date)),
           let cache = try? AppleWeatherInput.parse(w.json, at: w.date), let position = cache.location,
           (ForecastDisk.apple?.fetchedAt ?? .distantPast) < w.date,
           ForecastDisk.location.map({ $0.observedAt <= w.date || $0.near(position) }) ?? true {
            do { try ForecastDisk.updateLocation(position); try ForecastDisk.save(cache, key: ForecastDisk.appleKey) } catch { }
        }
        if let items = try? get([String: ActivityReading].self, "activity") {
            for item in items.values where ActivityDisk.valid(item, at: now) {
                if (ActivityDisk.read(source: item.source, at: now)?.fetchedAt ?? .distantPast) < item.fetchedAt {
                    try? ActivityDisk.save(source: item.source, steps: item.steps, kcal: item.activeKcal, at: item.fetchedAt)
                }
            }
        }
    }
}
