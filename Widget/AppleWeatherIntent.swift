import AppIntents
import WidgetKit
import Foundation

// Compiled into app and widget targets for discovery; actual write must run in widget.
struct AppleWeatherUpdateIntent: AppIntent {
    static var title: LocalizedStringResource = "Guardar clima de Apple"
    static var description = IntentDescription("Recibe el pronóstico de Clima de Apple desde un atajo y actualiza los widgets.")
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    @Parameter(title: "Pronóstico JSON") var forecastJSON: String
    static var parameterSummary: some ParameterSummary {
        Summary("Guardar clima de Apple \(\.$forecastJSON)")
    }
    func perform() async throws -> some IntentResult {
        try await WeatherService.shared.acceptApple(forecastJSON)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result()
    }
}

struct ActivityUpdateIntent: AppIntent {
    static var title: LocalizedStringResource = "Guardar actividad ClearWidget"
    static var description = IntentDescription("Guarda pasos y calorías activas de hoy de una sola fuente.")
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    @Parameter(title: "Fuente") var source: String
    @Parameter(title: "Pasos") var steps: Int
    @Parameter(title: "Calorías activas (kcal)") var kcal: Double
    static var parameterSummary: some ParameterSummary {
        Summary("Guardar \(\.$steps) pasos y \(\.$kcal) kcal de \(\.$source)")
    }
    func perform() async throws -> some IntentResult {
        try ActivityDisk.save(source: source,steps: steps,kcal: kcal)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClearWidget")
        return .result()
    }
}
struct ClearWidgetStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Diagnóstico ClearWidget"
    static var isDiscoverable = true
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let f = ForecastDisk.cached
        let status = f.map { "\($0.source == "apple" ? "Apple Weather" : "Open-Meteo") · \($0.fetchedAt.formatted(date: .abbreviated,time: .shortened))" } ?? "Sin clima vigente"
        let health = ActivityDisk.read(source: "Mi Fitness").map { "Mi Fitness actualizado \($0.fetchedAt.formatted(date: .abbreviated,time: .shortened))" } ?? "Mi Fitness sin datos de hoy"
        return .result(value: status + "\n" + health)
    }
}
struct ClearWidgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AppleWeatherUpdateIntent(), phrases: ["Guardar clima en \(.applicationName)"], shortTitle: "Guardar clima de Apple", systemImageName: "cloud.sun")
        AppShortcut(intent: ActivityUpdateIntent(), phrases: ["Guardar actividad en \(.applicationName)"], shortTitle: "Guardar actividad", systemImageName: "figure.walk")
        AppShortcut(intent: ClearWidgetStatusIntent(), phrases: ["Diagnóstico de \(.applicationName)"], shortTitle: "Diagnóstico ClearWidget", systemImageName: "info.circle")
    }
}
