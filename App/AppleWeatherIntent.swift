import AppIntents
import WidgetKit
import Foundation

// Register the same actions in the host; writes are restricted to the widget.
private enum WidgetIntentError: LocalizedError {
    case wrongTarget
    var errorDescription: String? {
        "iOS no ejecutó la acción en la extensión ClearWidget. No se guardaron datos en el proceso equivocado."
    }
}
private func requireWidgetTarget() throws {
    guard Bundle.main.bundleURL.pathExtension == "appex" else { throw WidgetIntentError.wrongTarget }
}
private actor ShortcutWriter {
    static let shared = ShortcutWriter()
    func weather(_ json: String) throws {
        try requireWidgetTarget()
        let now = Date()
        let cache = try AppleWeatherInput.parse(json, at: now)
        guard let location = cache.location else { throw AppleWeatherError.invalid }
        try ForecastDisk.updateLocation(location)
        try ForecastDisk.save(cache, key: ForecastDisk.appleKey)
    }
    func activity(_ source: String, _ steps: Int, _ kcal: Double) throws {
        try requireWidgetTarget()
        try ActivityDisk.save(source: source, steps: steps, kcal: kcal)
    }
    func diagnostic() throws -> String {
        try requireWidgetTarget()
        let weather = ForecastDisk.cached?.source ?? "sin datos"
        return "Atajos ejecutado en la extensión ClearWidget. Clima: \(weather). " + WidgetInteraction.diagnostic()
    }
}
struct AppleWeatherUpdateIntent: AppIntent {
    static var title: LocalizedStringResource = "Guardar clima de Apple"
    static var description = IntentDescription("Guarda el pronóstico de Apple en la extensión ClearWidget.")
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    @Parameter(title: "Pronóstico JSON") var forecastJSON: String
    static var parameterSummary: some ParameterSummary { Summary("Guardar clima de Apple \(\.$forecastJSON)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try await ShortcutWriter.shared.weather(forecastJSON)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result(value: "Pronóstico guardado en la extensión. Recarga solicitada a iOS.")
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
        return .result(value: "Actividad guardada en la extensión. Recarga solicitada a iOS.")
    }
}
struct ClearWidgetStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Diagnóstico ClearWidget"
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ShortcutWriter.shared.diagnostic())
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
