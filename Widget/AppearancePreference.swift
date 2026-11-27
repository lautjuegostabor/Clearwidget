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

// No new signing capability: use extension-local preferences, and the existing
// narrow keychain bridge only when both targets actually have access.
struct AppearanceRecord: Codable, Equatable {
    let mode: Int
    let changedAt: Date
    var selection: WidgetAppearance? {
        guard changedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return WidgetAppearance(rawValue: mode)
    }
}

enum AppearancePreference {
    private static let key = "clearwidget.appearance.v1"
    static var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }
    private static func local() -> AppearanceRecord? {
        guard let bytes = UserDefaults.standard.data(forKey: key),
              let record = try? JSONDecoder().decode(AppearanceRecord.self, from: bytes),
              record.selection != nil else { return nil }
        return record
    }
    private static func shared() -> AppearanceRecord? {
        guard let record = try? ShortcutBridge.readAppearance(), record.selection != nil else { return nil }
        return record
    }
    static func latest(_ a: AppearanceRecord?, _ b: AppearanceRecord?) -> AppearanceRecord? {
        let valid = [a,b].compactMap { $0 }.filter { $0.selection != nil }
        return valid.max { $0.changedAt < $1.changedAt }
    }
    static func current() -> WidgetAppearance {
        latest(local(), shared())?.selection ?? .system
    }
    // Only report a confirmed selection to the app when the extension has
    // actually read and acknowledged the same record.
    static func confirmedInWidget() -> WidgetAppearance? {
        guard let requested = shared(), let ack = try? ShortcutBridge.readAppearanceReceipt(),
              requested == ack else { return nil }
        return ack.selection
    }
    static func acknowledgeIfPossible() {
        guard isExtension, let record = latest(local(),shared()) else { return }
        try? ShortcutBridge.writeAppearanceReceipt(record)
    }
    static func select(_ mode: WidgetAppearance) throws {
        let record = AppearanceRecord(mode: mode.rawValue, changedAt: Date())
        let data = try JSONEncoder().encode(record)
        if isExtension {
            UserDefaults.standard.set(data, forKey:key)
            guard local() == record else { throw AppearanceError.notSaved }
            try? ShortcutBridge.writeAppearance(record)
        } else {
            // Button(intent:) is system-dispatched; never claim a host-only
            // write succeeded when the signed bridge cannot be used.
            try ShortcutBridge.writeAppearance(record)
            guard shared() == record else { throw AppearanceError.notSaved }
            UserDefaults.standard.set(data, forKey:key)
        }
    }
}
private enum AppearanceError: LocalizedError {
    case notSaved
    var errorDescription: String? { "No se pudo confirmar la escritura de la apariencia." }
}

// C ABI called synchronously by the descriptor hook in the widget process.
// It reads the selected value at each fetch; no polling or timer.
@_cdecl("CWReadAppearance")
func CWReadAppearance() -> Int32 {
    let mode = AppearancePreference.current()
    AppearancePreference.acknowledgeIfPossible()
    return Int32(mode.rawValue)
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
