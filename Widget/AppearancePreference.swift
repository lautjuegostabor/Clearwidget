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
        case .liquidGlass: return "Solicita la ruta experimental de cristal del compositor. Puede coincidir con Blur según iOS."
        }
    }
}

extension AppearanceRecord {
    var selection: WidgetAppearance? { valid ? WidgetAppearance(rawValue: mode) : nil }
}

enum AppearancePreference {
    private static let key = "clearwidget.appearance.v1"
    static var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }
    static func local() -> AppearanceRecord? {
        guard let bytes = UserDefaults.standard.data(forKey: key),
              let record = try? JSONDecoder().decode(AppearanceRecord.self, from: bytes),
              record.valid else { return nil }
        return record
    }
    private static func shared() -> AppearanceRecord? {
        guard let record = try? ShortcutBridge.readAppearance(), record.valid else { return nil }
        return record
    }
    private static func saveLocal(_ record: AppearanceRecord) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(record), forKey: key)
        guard local() == record else { throw AppearanceError.notSaved }
    }
    static func latest(_ a: AppearanceRecord?, _ b: AppearanceRecord?) -> AppearanceRecord? {
        [a,b].compactMap { $0 }.filter(\.valid).max { $0.changedAt < $1.changedAt }
    }
    static func currentRecord() -> AppearanceRecord? {
        let record = latest(local(), shared())
        if isExtension, let record, record != local() { try? saveLocal(record) }
        return record
    }
    static func current() -> WidgetAppearance { currentRecord()?.selection ?? .system }

    static func select(_ mode: WidgetAppearance) throws {
        let previous = currentRecord()?.changedAt ?? .distantPast
        let now = Date()
        let date = now > previous ? now : previous.addingTimeInterval(0.001)
        let record = AppearanceRecord(mode: mode.rawValue, changedAt: date)
        try saveLocal(record)
        if isExtension {
            try? ShortcutBridge.writeAppearance(record)
        } else {
            try ShortcutBridge.writeAppearance(record)
            guard shared() == record else { throw AppearanceError.notSaved }
        }
    }
    static func delivery() throws -> AppearanceDelivery {
        guard let request = latest(local(), shared()) else { return .initial }
        guard try ShortcutBridge.readAppearance() == request else { return .pending }
        return AppearanceDelivery.resolve(request: request, timeline: try ShortcutBridge.readAppearanceReceipt(),
            descriptor: try ShortcutBridge.readAppearanceDescriptorReceipt())
    }
    static func acknowledgeTimeline() {
        guard isExtension, let record = currentRecord() else { return }
        if (try? ShortcutBridge.readAppearanceReceipt()) != record {
            try? ShortcutBridge.writeAppearanceReceipt(record)
        }
    }
    static func report(mode: Int32, revision: UInt64, outcome: Int32) {
        guard isExtension, let record = currentRecord(),
              record.mode == Int(mode), record.revision == revision,
              let result = AppearanceDescriptorOutcome(rawValue: Int(outcome)) else { return }
        let receipt = AppearanceDescriptorReceipt(record: record, outcome: result)
        if (try? ShortcutBridge.readAppearanceDescriptorReceipt()) != receipt {
            try? ShortcutBridge.writeAppearanceDescriptorReceipt(receipt)
        }
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
