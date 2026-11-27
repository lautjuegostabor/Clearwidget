import Foundation

// One latest receipt per kind. Only a timeline containing the exact new
// payload can acknowledge a data write; a generic refresh cannot.
enum ShortcutReceipt {
    enum Kind: String, CaseIterable, Codable {
        case diagnostic, weather, activity
        var label: String {
            switch self {
            case .diagnostic: return "diagnóstico"
            case .weather: return "clima"
            case .activity: return "actividad"
            }
        }
    }
    private struct Probe: Codable {
        let id: UUID
        let created: Date
        let source: String?
        let steps: Int?
        let kcal: Double?
    }
    private struct Ack: Codable { let id: UUID; let time: Date }
    private struct Record: Codable { let probe: Probe; var ack: Ack? }
    private static let lock = NSLock()
    private static func key(_ kind: Kind) -> String { "clearwidget.shortcut.local.receipt.v2." + kind.rawValue }
    private static func read(_ kind: Kind, _ defaults: UserDefaults) -> Record? {
        defaults.data(forKey: key(kind)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }
    private static func write(_ record: Record, _ kind: Kind, _ defaults: UserDefaults) {
        if let bytes = try? JSONEncoder().encode(record) { defaults.set(bytes, forKey: key(kind)) }
    }
    private static func current(_ record: Record, at now: Date) -> Bool {
        (0...86400).contains(now.timeIntervalSince(record.probe.created))
    }
    private static func replace(_ kind: Kind, at now: Date, source: String? = nil,
                                steps: Int? = nil, kcal: Double? = nil, defaults: UserDefaults) {
        write(Record(probe: Probe(id: UUID(), created: now, source: source, steps: steps, kcal: kcal), ack: nil), kind, defaults)
    }
    static func startWeather(at now: Date, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        replace(.weather, at: now, defaults: defaults)
    }
    static func startActivity(_ activity: ActivityReading, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        replace(.activity, at: activity.fetchedAt, source: ActivityDisk.normalize(activity.source),
                steps: activity.steps, kcal: activity.activeKcal, defaults: defaults)
    }
    static func ensureDiagnostic(at now: Date = Date(), defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        if let record = read(.diagnostic, defaults), current(record, at: now) { return }
        replace(.diagnostic, at: now, defaults: defaults)
    }
    static func confirmTimeline(at now: Date, weatherSource: String?, weatherFetchedAt: Date?,
                                activity: ActivityReading?, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        for kind in Kind.allCases {
            guard var record = read(kind, defaults), current(record, at: now), record.ack == nil else { continue }
            let p = record.probe
            let matches: Bool
            switch kind {
            case .diagnostic:
                matches = true
            case .weather:
                matches = weatherSource == "apple" && weatherFetchedAt == p.created
            case .activity:
                if let activity {
                    matches = ActivityDisk.normalize(activity.source) == p.source &&
                        activity.fetchedAt == p.created && activity.steps == p.steps && activity.activeKcal == p.kcal
                } else { matches = false }
            }
            guard matches else { continue }
            record.ack = Ack(id: p.id, time: now)
            write(record, kind, defaults)
        }
    }
    static func status(at now: Date = Date(), defaults: UserDefaults = .standard) -> String? {
        lock.lock(); defer { lock.unlock() }
        let messages = Kind.allCases.compactMap { kind -> String? in
            guard let r = read(kind, defaults), current(r, at: now) else { return nil }
            let label = kind.label
            guard let ack = r.ack, ack.id == r.probe.id, ack.time >= r.probe.created else {
                return "\(label): guardado, timeline pendiente."
            }
            return "\(label): timeline confirmado."
        }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }
}
