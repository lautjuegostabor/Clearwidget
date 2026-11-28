import Foundation
import AppIntents
import WidgetKit
import os

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

// Both routes are optional. A successful local write is not a widget receipt.
// Never ask for new entitlements or sign in as a side effect of changing a style.
private enum AppearanceTransport: String, CaseIterable {
    case keychain = "Keychain"
    case notify = "Darwin Notify"
    func request() throws -> AppearanceRecord? {
        switch self {
        case .keychain: return try ShortcutBridge.appearanceRequest()
        case .notify: return try AppearanceNotifyBus.shared().readRequest()
        }
    }
    func send(_ record: AppearanceRecord) throws {
        switch self {
        case .keychain: try ShortcutBridge.sendAppearance(record)
        case .notify: try AppearanceNotifyBus.shared().send(record)
        }
    }
    func timeline() throws -> AppearanceRecord? {
        switch self {
        case .keychain: return try ShortcutBridge.appearanceTimeline()
        case .notify: return try AppearanceNotifyBus.shared().readTimeline()
        }
    }
    func acknowledge(_ record: AppearanceRecord) throws {
        switch self {
        case .keychain: try ShortcutBridge.acknowledgeAppearance(record)
        case .notify: try AppearanceNotifyBus.shared().acknowledge(record)
        }
    }
    func descriptor() throws -> AppearanceDescriptorReceipt? {
        switch self {
        case .keychain: return try ShortcutBridge.appearanceDescriptor()
        case .notify: return try AppearanceNotifyBus.shared().readDescriptor()
        }
    }
    func report(_ receipt: AppearanceDescriptorReceipt) throws {
        switch self {
        case .keychain: try ShortcutBridge.reportAppearance(receipt)
        case .notify: try AppearanceNotifyBus.shared().report(receipt)
        }
    }
}
enum AppearancePreference {
    private static let key = "clearwidget.appearance.v1"
    private static let timelineKey = "clearwidget.appearance.local.timeline.v1"
    private static let lock = NSRecursiveLock()
    private static let log = Logger(subsystem:"com.clearwidget.app", category:"appearance")
    static var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }
    private static func readLocal(_ key: String) -> AppearanceRecord? {
        guard let bytes = UserDefaults.standard.data(forKey:key),
              let record = try? JSONDecoder().decode(AppearanceRecord.self,from:bytes),
              record.valid else { return nil }
        return record
    }
    static func local() -> AppearanceRecord? { readLocal(key) }
    private static func saveLocal(_ record: AppearanceRecord) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(record),forKey:key)
        guard local() == record else { throw AppearanceError.notSaved }
    }
    static func currentRecord() -> AppearanceRecord? {
        lock.lock(); defer { lock.unlock() }
        let stored = local()
        guard isExtension else { return stored }
        var newest = stored
        let limit = Date().addingTimeInterval(60)
        for route in AppearanceTransport.allCases {
            do {
                if let incoming = try route.request(), incoming.valid, incoming.changedAt <= limit,
                   incoming.revision > (newest?.revision ?? 0) { newest = incoming }
            } catch {
                log.debug("Appearance request \(route.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if let newest, newest != stored {
            do { try saveLocal(newest); return newest }
            catch { log.error("Appearance persistence: \(error.localizedDescription, privacy: .public)") }
        }
        return stored
    }
    static func current() -> WidgetAppearance { currentRecord()?.selection ?? .system }
    static func select(_ mode: WidgetAppearance) throws {
        lock.lock(); defer { lock.unlock() }
        let previous = currentRecord()?.revision ?? 0
        let now = UInt64((Date().timeIntervalSinceReferenceDate * 1000).rounded())
        let revision = max(now,previous+1)
        let record = AppearanceRecord(mode:mode.rawValue,changedAt:Date(timeIntervalSinceReferenceDate:Double(revision)/1000))
        try saveLocal(record)
        if !isExtension {
            var delivered = false
            var errors: [String] = []
            for route in AppearanceTransport.allCases {
                do { try route.send(record); delivered = true }
                catch { errors.append(route.rawValue + ": " + error.localizedDescription) }
            }
            if !delivered { throw AppearanceError.notSent(errors.joined(separator:" · ")) }
        }
    }
    @discardableResult static func restoreRequest() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isExtension, let record = local() else { return false }
        var available = false
        var restored = false
        var errors: [String] = []
        for route in AppearanceTransport.allCases {
            do {
                if try route.request() != record {
                    try route.send(record); restored = true
                }
                available = true
            } catch { errors.append(route.rawValue + ": " + error.localizedDescription) }
        }
        if !available { throw AppearanceError.notSent(errors.joined(separator:" · ")) }
        return restored
    }
    static func transportStatus() -> String {
        guard let record = local() else { return "Sin selección explícita." }
        return AppearanceTransport.allCases.map { route in
            do {
                let visible = try route.request() == record
                return route.rawValue + (visible ? ": selección legible en la app" : ": sin selección actual")
            } catch { return route.rawValue + ": " + error.localizedDescription }
        }.joined(separator:" · ")
    }
    static func delivery() throws -> AppearanceDelivery {
        guard let record = local() else { return .initial }
        var observations: [AppearanceObservation] = []
        for route in AppearanceTransport.allCases {
            do {
                let request = try route.request()
                guard request == record else { continue }
                var timeline: AppearanceRecord?
                var descriptor: AppearanceDescriptorReceipt?
                do { timeline = try route.timeline() } catch { log.error("Timeline receipt: \(error.localizedDescription, privacy: .public)") }
                do { descriptor = try route.descriptor() } catch { log.error("Descriptor receipt: \(error.localizedDescription, privacy: .public)") }
                observations.append(.init(request:request,timeline:timeline,descriptor:descriptor))
            } catch { log.debug("Appearance delivery: \(error.localizedDescription, privacy: .public)") }
        }
        return AppearanceDelivery.resolveAcross(request:record,observations:observations)
    }
    static func needsTimeline(_ record: AppearanceRecord?) -> Bool {
        guard isExtension, let record else { return false }
        return readLocal(timelineKey) != record
    }
    static func acknowledgeTimeline(_ renderedRecord: AppearanceRecord?) {
        lock.lock(); defer { lock.unlock() }
        guard isExtension, let record = renderedRecord, currentRecord() == record else { return }
        do { UserDefaults.standard.set(try JSONEncoder().encode(record),forKey:timelineKey) }
        catch { log.error("Local timeline receipt: \(error.localizedDescription, privacy: .public)") }
        for route in AppearanceTransport.allCases {
            do {
                guard try route.request() == record else { continue }
                try route.acknowledge(record)
            } catch { log.error("Timeline \(route.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }
    static func report(mode:Int32,revision:UInt64,outcome:Int32) {
        lock.lock(); defer { lock.unlock() }
        guard isExtension, let record = currentRecord(), record.mode == Int(mode), record.revision == revision,
              let result = AppearanceDescriptorOutcome(rawValue:Int(outcome)) else { return }
        let receipt = AppearanceDescriptorReceipt(record:record,outcome:result)
        for route in AppearanceTransport.allCases {
            do {
                guard try route.request() == record else { continue }
                try route.report(receipt)
            } catch { log.error("Descriptor \(route.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }
}
private enum AppearanceError: LocalizedError {
    case notSaved, notSent(String)
    var errorDescription: String? {
        switch self {
        case .notSaved: return "No se pudo confirmar la escritura de la apariencia."
        case .notSent(let errors): return "Ninguna vía de comunicación disponible. " + errors
        }
    }
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
