import AppIntents
import WidgetKit
import Foundation

// App-only discovery/execution; never claim a local host write reached a widget.
private actor ShortcutWriter {
    static let shared = ShortcutWriter()
    func weather(_ json: String) throws { try ShortcutBridge.storeWeather(json) }
    func activity(_ source: String, _ steps: Int, _ kcal: Double) throws {
        try ShortcutBridge.storeActivity(source: source, steps: steps, kcal: kcal)
    }
}
struct AppleWeatherUpdateIntent: AppIntent {
    static var title: LocalizedStringResource = "Guardar clima de Apple"
    static var description = IntentDescription("Entrega un pronóstico de Apple a la extensión mediante el puente local verificado.")
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Pronóstico JSON") var forecastJSON: String
    static var parameterSummary: some ParameterSummary { Summary("Guardar clima de Apple \(\.$forecastJSON)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await ShortcutWriter.shared.weather(forecastJSON)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result(value: "Pronóstico enviado al puente verificado; recarga solicitada a iOS.")
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
        return .result(value: "Actividad enviada al puente verificado; recarga solicitada a iOS.")
    }
}
struct ClearWidgetStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Diagnóstico ClearWidget"
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let status: String
        do { status = try ShortcutBridge.diagnostic() } catch { status = "Atajos responde. " + error.localizedDescription }
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result(value: status)
    }
}
struct ClearWidgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AppleWeatherUpdateIntent(), phrases: ["Guardar clima en \(.applicationName)"], shortTitle: "Guardar clima de Apple", systemImageName: "cloud.sun")
        AppShortcut(intent: ActivityUpdateIntent(), phrases: ["Guardar actividad en \(.applicationName)"], shortTitle: "Guardar actividad", systemImageName: "figure.walk")
        AppShortcut(intent: ClearWidgetStatusIntent(), phrases: ["Diagnóstico de \(.applicationName)"], shortTitle: "Diagnóstico ClearWidget", systemImageName: "info.circle")
    }
}
