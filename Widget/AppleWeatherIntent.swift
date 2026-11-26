import AppIntents
import WidgetKit
import Foundation

// Compiled into app and widget targets for discovery; actual write must run in widget.
struct AppleWeatherUpdateIntent: AppIntent {
    static var title: LocalizedStringResource = "Guardar clima de Apple"
    static var description = IntentDescription("Recibe el pronóstico de Clima de Apple desde un atajo y actualiza los widgets.")
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
