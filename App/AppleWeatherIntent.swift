import AppIntents
import WidgetKit
import Foundation

// Host-only discovery and execution. Only widget data uses the shared group.
private actor ShortcutWriter {
    static let shared = ShortcutWriter()
    func weather(_ json: String) throws { try ShortcutBridge.storeWeather(json) }
    func activity(_ source: String, _ steps: Int, _ kcal: Double) throws { try ShortcutBridge.storeActivity(source: source, steps: steps, kcal: kcal) }
    func diagnostic() throws -> String { try ShortcutBridge.diagnostic() }
}
struct AppleWeatherUpdateIntent: AppIntent {
    static var title: LocalizedStringResource = "Guardar clima de Apple"
    static var description = IntentDescription("Guarda un pronóstico de Apple para ClearWidget.")
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Pronóstico JSON") var forecastJSON: String
    static var parameterSummary: some ParameterSummary { Summary("Guardar clima de Apple \(\.$forecastJSON)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await ShortcutWriter.shared.weather(forecastJSON)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result(value: "Pronóstico guardado en el puente local. Recarga solicitada; consultá el diagnóstico para confirmar la recepción.")
    }
}
struct ActivityUpdateIntent: AppIntent {
    static var title: LocalizedStringResource = "Guardar actividad ClearWidget"
    static var description = IntentDescription("Guarda totales de una sola fuente sin enviar datos fuera del dispositivo.")
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Fuente") var source: String
    @Parameter(title: "Pasos") var steps: Int
    @Parameter(title: "Calorías activas (kcal)") var kcal: Double
    static var parameterSummary: some ParameterSummary { Summary("Guardar \(\.$steps) pasos y \(\.$kcal) kcal de \(\.$source)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await ShortcutWriter.shared.activity(source, steps, kcal)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result(value: "Actividad guardada en el puente local. Recarga solicitada; consultá el diagnóstico para confirmar la recepción.")
    }
}
struct ClearWidgetStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Diagnóstico ClearWidget"
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await ShortcutWriter.shared.diagnostic()
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result(value: result)
    }
}
struct ClearWidgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AppleWeatherUpdateIntent(), phrases: ["Guardar clima en \(.applicationName)"], shortTitle: "Guardar clima de Apple", systemImageName: "cloud.sun")
        AppShortcut(intent: ActivityUpdateIntent(), phrases: ["Guardar actividad en \(.applicationName)"], shortTitle: "Guardar actividad", systemImageName: "figure.walk")
        AppShortcut(intent: ClearWidgetStatusIntent(), phrases: ["Diagnóstico de \(.applicationName)"], shortTitle: "Diagnóstico ClearWidget", systemImageName: "info.circle")
    }
}

