import Foundation
import AppIntents
import WidgetKit

enum WidgetAppearance: Int, AppEnum, CaseIterable {
    case system = 0, clear = 1, blur = 2, liquidGlass = 3
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Apariencia"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .system: "Sistema", .clear: "Clear", .blur: "Blur", .liquidGlass: "Liquid Glass (experimental)"
    ]
    var label: String {
        switch self {
        case .system: return "Sistema"
        case .clear: return "Clear"
        case .blur: return "Blur"
        case .liquidGlass: return "Liquid Glass (experimental)"
        }
    }
    var explanation: String {
        switch self {
        case .system: return "Comportamiento original, según la apariencia de iOS."
        case .clear: return "Solicita transparencia sin material de fondo."
        case .blur: return "Solicita el fondo translúcido del sistema."
        case .liquidGlass: return "Prueba el cristal nativo de SwiftUI sobre un descriptor transparente. iOS puede omitir el efecto."
        }
    }
}

extension AppearanceRecord {
    var selection: WidgetAppearance? { valid ? WidgetAppearance(rawValue: mode) : nil }
}

enum AppearancePreference {
    private static let key = "clearwidget.appearance.v1"
    private static let lock = NSRecursiveLock()
    static var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }
    static func local() -> AppearanceRecord? {
        guard let bytes = UserDefaults.standard.data(forKey:key),
              let record = try? JSONDecoder().decode(AppearanceRecord.self,from:bytes),
              record.valid else { return nil }
        return record
    }
    private static func saveLocal(_ record: AppearanceRecord) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(record),forKey:key)
        guard local() == record else { throw AppearanceError.notSaved }
    }
    private static func bus() throws -> AppearanceNotifyBus { try AppearanceNotifyBus.shared() }
    static func currentRecord() -> AppearanceRecord? {
        lock.lock(); defer { lock.unlock() }
        let stored = local()
        guard isExtension else { return stored }
        // Reject malformed/future requests. A cosmetic preference only, never
        // trust this channel for anything requiring security or authentication.
        guard let incoming = try? bus().readRequest(), incoming.changedAt <= Date().addingTimeInterval(60),
              incoming.revision > (stored?.revision ?? 0) else { return stored }
        do { try saveLocal(incoming); return incoming } catch { return stored }
    }
    static func current() -> WidgetAppearance { currentRecord()?.selection ?? .system }
    static func select(_ mode: WidgetAppearance) throws {
        lock.lock(); defer { lock.unlock() }
        let previous = currentRecord()?.revision ?? 0
        let now = UInt64((Date().timeIntervalSinceReferenceDate * 1000).rounded())
        let revision = max(now,previous+1)
        let record = AppearanceRecord(mode:mode.rawValue,changedAt:Date(timeIntervalSinceReferenceDate:Double(revision)/1000))
        try saveLocal(record)
        if !isExtension { try bus().send(record) }
    }
    // Resend persisted host state if notifyd has lost its transient registration.
    // No new revision and no repeated reload when the existing request is intact.
    @discardableResult static func restoreRequest() throws -> Bool {
        guard !isExtension, let record = local() else { return false }
        let transport = try bus()
        if try transport.readRequest() != record {
            try transport.send(record); return true
        }
        return false
    }
    static func delivery() throws -> AppearanceDelivery {
        guard let record = local() else { return .initial }
        let transport = try bus()
        guard try transport.readRequest() == record else { return .pending }
        return AppearanceDelivery.resolve(request:record,timeline:try transport.readTimeline(),descriptor:try transport.readDescriptor())
    }
    static func acknowledgeTimeline() {
        lock.lock(); defer { lock.unlock() }
        guard isExtension, let record = currentRecord() else { return }
        try? bus().acknowledge(record)
    }
    static func report(mode:Int32,revision:UInt64,outcome:Int32) {
        lock.lock(); defer { lock.unlock() }
        guard isExtension, let record = currentRecord(), record.mode == Int(mode), record.revision == revision,
              let result = AppearanceDescriptorOutcome(rawValue:Int(outcome)) else { return }
        try? bus().report(AppearanceDescriptorReceipt(record:record,outcome:result))
    }
}
private enum AppearanceError: LocalizedError {
    case notSaved
    var errorDescription: String? { "No se pudo confirmar la escritura de la apariencia." }
}

@_cdecl("CWReadAppearance")
func CWReadAppearance(_ revision: UnsafeMutablePointer<UInt64>?) -> Int32 {
    let record = AppearancePreference.currentRecord()
    revision?.pointee = record?.revision ?? 0
    return Int32(record?.mode ?? 0)
}
@_cdecl("CWReportAppearance")
func CWReportAppearance(_ mode: Int32, _ revision: UInt64, _ outcome: Int32) {
    AppearancePreference.report(mode: mode, revision: revision, outcome: outcome)
}

struct SelectWidgetAppearance: AppIntent {
    static var title: LocalizedStringResource = "Cambiar apariencia ClearWidget"
    static var description = IntentDescription("Selecciona el fondo para todos los widgets ClearWidget.")
    static var openAppWhenRun = false
    static var isDiscoverable = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    @Parameter(title: "Apariencia") var mode: WidgetAppearance
    init() {}
    init(_ mode: WidgetAppearance) { self.mode = mode }
    func perform() async throws -> some IntentResult {
        try AppearancePreference.select(mode)
        WidgetCenter.shared.invalidateConfigurationRecommendations()
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result()
    }
}
