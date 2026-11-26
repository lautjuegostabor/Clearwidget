import SwiftUI
import WidgetKit
import AppIntents

struct GlassSmallConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Acción de Glass Small 7"
    static var description: IntentDescription = "Elegí un atajo o dejá el widget sin acción."
    @Parameter(title: "Acción al tocar") var action: SystemShortcut?
    init() {}
}

struct StayOnGlassSmall: AppIntent {
    static var title: LocalizedStringResource = "Permanecer en Glass Small 7"
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    func perform() async throws -> some IntentResult { .result() }
}

private struct GlassSmallEntry: TimelineEntry {
    let date: Date
    let forecast: GlassForecast
    let configuration: GlassSmallConfiguration
}

private struct GlassSmallProvider: AppIntentTimelineProvider {
    private func entry(_ date: Date, _ configuration: GlassSmallConfiguration) -> GlassSmallEntry {
        GlassSmallEntry(date: date, forecast: ForecastDisk.cached?.glassForecast(at: date) ?? .empty,
                        configuration: configuration)
    }
    func placeholder(in context: Context) -> GlassSmallEntry {
        GlassSmallEntry(date: Date(), forecast: .empty, configuration: GlassSmallConfiguration())
    }
    func snapshot(for configuration: GlassSmallConfiguration, in context: Context) async -> GlassSmallEntry {
        entry(Date(), configuration)
    }
    func timeline(for configuration: GlassSmallConfiguration, in context: Context) async -> Timeline<GlassSmallEntry> {
        if !context.isPreview { await WeatherService.shared.refreshIfDue(at: Date()) }
        let now = Date()
        let refresh = ForecastDisk.nextRefresh(at: now)
        let nextHour = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 3600) + 1) * 3600)
        return Timeline(entries: [entry(now, configuration)], policy: .after(min(refresh, nextHour)))
    }
}

private struct GlassSmallView: View {
    let entry: GlassSmallEntry
    private var currentText: String { GlassCondition.description(entry.forecast.current.code) }
    private var wrappedText: String {
        switch currentText {
        case "Parcialmente nublado": return "Parcialmente\nNublado"
        case "Mayormente despejado": return "Mayormente\nDespejado"
        default: return currentText
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let s = min(geometry.size.width, geometry.size.height) / 1600
            let shape = RoundedRectangle(cornerRadius: 320 * s)
            Group {
                if let shortcut = entry.configuration.action {
                    Button(intent: RunSystemShortcutIntent(shortcut: shortcut)) {
                        artwork(s: s).contentShape(.interaction, shape)
                    }
                } else {
                    Button(intent: StayOnGlassSmall()) {
                        artwork(s: s).contentShape(.interaction, shape)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHint(entry.configuration.action == nil ? "Sin acción configurada" : "Abrir atajo configurado")
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { Color.black.opacity(0.12) }
    }

    private func artwork(s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Text("Ahora")
                .font(.system(size: 136 * s, weight: .semibold))
                .foregroundStyle(.white.opacity(0.50))
                .frame(width: 900 * s, height: 182 * s, alignment: .leading)
                .position(x: 626 * s, y: 275 * s)
            Text(wrappedText)
                .font(.system(size: 138 * s, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.leading)
                .frame(width: 900 * s, height: 338 * s, alignment: .topLeading)
                .position(x: 626 * s, y: 551 * s)
            Text(WeatherReading.degrees(entry.forecast.current.current))
                .font(.system(size: 405 * s, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .contentTransition(.numericText())
                .frame(width: 850 * s, height: 498 * s, alignment: .leading)
                .position(x: 601 * s, y: 1251 * s)
            ForEach(0..<5) { i in
                let hour = i < entry.forecast.hours.count ? entry.forecast.hours[i] : nil
                let y = [274.0, 534.0, 800.0, 1064.0, 1328.0][i] * s
                Group {
                    if let asset = hour?.asset {
                        Image(asset).resizable()
                            .widgetAccentedRenderingMode(.fullColor)
                            .scaledToFit()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 260 * s, height: 208 * s)
                .position(x: 1158 * s, y: y)
                .accessibilityHidden(true)
                Text(hour?.label ?? "—")
                    .font(.system(size: 111 * s, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.72)
                    .contentTransition(.numericText())
                    .frame(width: 220 * s, height: 128 * s, alignment: .leading)
                    .position(x: 1350 * s, y: y)
                    .accessibilityLabel("En \(i + 1) horas: \(hour?.label ?? "sin datos") grados, \(GlassCondition.description(hour?.code))")
            }
        }
        .frame(width: 1600 * s, height: 1600 * s)
        .accessibilityElement(children: .combine)
    }
}

struct GlassSmall7Widget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "GlassSmall7", intent: GlassSmallConfiguration.self,
                               provider: GlassSmallProvider()) { entry in
            GlassSmallView(entry: entry)
        }
        .configurationDisplayName("Glass Small 7")
        .description("Temperatura actual y pronóstico de las próximas cinco horas.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
        .containerBackgroundRemovable(true)
    }
}
