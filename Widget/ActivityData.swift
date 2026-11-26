import Foundation
struct ActivityReading: Codable, Sendable {
    let source: String
    let steps: Int
    let activeKcal: Double
    let fetchedAt: Date
}
enum ActivityError: LocalizedError {
    case invalid
    var errorDescription: String? { "Datos de actividad inválidos." }
}
enum ActivityDisk {
    private static let key = "clearwidget.activity.bySource.v1"
    private static let lock = NSLock()
    static func normalize(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive,.diacriticInsensitive],locale: Locale(identifier: "es_AR"))
    }
    static func valid(_ item: ActivityReading, at now: Date) -> Bool {
        let age = now.timeIntervalSince(item.fetchedAt)
        return !normalize(item.source).isEmpty && item.source.count <= 100 && (0...200_000).contains(item.steps) &&
            item.activeKcal.isFinite && (0...20_000).contains(item.activeKcal) &&
            (-300...86400).contains(age) && Calendar.autoupdatingCurrent.isDate(item.fetchedAt,inSameDayAs: now)
    }
    private static func values() -> [String:ActivityReading] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String:ActivityReading].self,from: data)) ?? [:]
    }
    static func save(source: String,steps: Int,kcal: Double,at now: Date = Date()) throws {
        let item = ActivityReading(source: source,steps: steps,activeKcal: kcal,fetchedAt: now)
        guard valid(item,at: Date()) else { throw ActivityError.invalid }
        lock.lock(); defer { lock.unlock() }
        var v = values().filter { valid($0.value,at: now) }
        guard v.count < 30 || v[normalize(source)] != nil else { throw ActivityError.invalid }
        v[normalize(source)] = item
        UserDefaults.standard.set(try JSONEncoder().encode(v),forKey: key)
    }
    static func read(source: String,at now: Date = Date()) -> ActivityReading? {
        lock.lock(); defer { lock.unlock() }
        guard let item = values()[normalize(source)], valid(item,at: now) else { return nil }
        return item
    }
}
