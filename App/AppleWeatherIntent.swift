import AppIntents
import WidgetKit
import Foundation

// The host registers the actions; only the widget extension may perform them.
// Both targets contain the same intent types and metadata.
private enum ShortcutTargetError: LocalizedError {
    case wrongTarget, readbackFailed
    var errorDescription: String? {
        switch self {
        case .wrongTarget: return "iOS no ejecutó la acción en la extensión WidgetKit. No se guardaron datos."
        case .readbackFailed: return "No se pudo verificar la escritura en la extensión."
        }
    }
}
private actor ShortcutWriter {
    static let shared = ShortcutWriter()
    private func checkTarget() throws {
        guard Bundle.main.bundleURL.pathExtension == "appex" else { throw ShortcutTargetError.wrongTarget }
    }
    func weather(_ json: String) async throws {
        try checkTarget()
        // Use the same actor as the fallback forecast to serialize cache writes.
        try await WeatherService.shared.acceptShortcutApple(json)
    }
    func activity(_ source: String, _ steps: Int, _ kcal: Double) throws {
        try checkTarget()
        let now = Date()
        try ActivityDisk.save(source: source, steps: steps, kcal: kcal, at: now)
        guard let stored = ActivityDisk.read(source: source, at: now),
              stored.steps == steps, stored.activeKcal == kcal, stored.fetchedAt == now
        else { throw ShortcutTargetError.readbackFailed }
        ShortcutReceipt.startActivity(stored)
    }
    func diagnostic() throws -> String {
        try checkTarget()
        ShortcutReceipt.ensureDiagnostic()
        let data = ShortcutReceipt.status() ?? "No hay comprobante de ejecución guardado."
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "desconocido"
        return "Atajos: ejecución directa en WidgetKit · build \(build). " + data + " " + WidgetInteraction.diagnostic()
    }
}
struct AppleWeatherUpdateIntent: AppIntent {
    static var title: LocalizedStringResource = "Guardar clima de Apple"
    static var description = IntentDescription("Guarda un pronóstico de Apple para ClearWidget.")
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    @Parameter(title: "Pronóstico JSON") var forecastJSON: String
    static var parameterSummary: some ParameterSummary { Summary("Guardar clima de Apple \(\.$forecastJSON)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await ShortcutWriter.shared.weather(forecastJSON)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result(value: "Pronóstico guardado y releído dentro de WidgetKit. Recarga solicitada; Diagnóstico ClearWidget permite comprobar el timeline.")
    }
}
struct ActivityUpdateIntent: AppIntent {
    static var title: LocalizedStringResource = "Guardar actividad ClearWidget"
    static var description = IntentDescription("Guarda totales de una sola fuente sin enviar datos fuera del dispositivo.")
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    @Parameter(title: "Fuente") var source: String
    @Parameter(title: "Pasos") var steps: Int
    @Parameter(title: "Calorías activas (kcal)") var kcal: Double
    static var parameterSummary: some ParameterSummary { Summary("Guardar \(\.$steps) pasos y \(\.$kcal) kcal de \(\.$source)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await ShortcutWriter.shared.activity(source, steps, kcal)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result(value: "Actividad guardada y releída dentro de WidgetKit. Recarga solicitada; Diagnóstico ClearWidget permite comprobar el timeline.")
    }
}
struct ClearWidgetStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Diagnóstico ClearWidget"
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await ShortcutWriter.shared.diagnostic()
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result(value: result)
    }
}
#if CLEARWIDGET_HOST
struct ClearWidgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AppleWeatherUpdateIntent(), phrases: ["Guardar clima en \(.applicationName)"], shortTitle: "Guardar clima de Apple", systemImageName: "cloud.sun")
        AppShortcut(intent: ActivityUpdateIntent(), phrases: ["Guardar actividad en \(.applicationName)"], shortTitle: "Guardar actividad", systemImageName: "figure.walk")
        AppShortcut(intent: ClearWidgetStatusIntent(), phrases: ["Diagnóstico de \(.applicationName)"], shortTitle: "Diagnóstico ClearWidget", systemImageName: "info.circle")
    }
}
#endif
