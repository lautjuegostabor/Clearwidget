import SwiftUI
import WidgetKit
import AppIntents

struct StayOnGlassSmall: AppIntent {
    static var title: LocalizedStringResource = "Permanecer en Glass Small 7"
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    func perform() async throws -> some IntentResult { .result() }
}

struct GlassSmallView: View {
    let forecast: GlassForecast
    let shortcut: SystemShortcut?
    private var currentText: String { GlassCondition.description(forecast.current.code) }
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
                if let shortcut {
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
            .accessibilityHint(shortcut == nil ? "Sin acción configurada" : "Abrir atajo configurado")
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
            Text(WeatherReading.degrees(forecast.current.current))
                .font(.system(size: 405 * s, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .contentTransition(.numericText())
                .frame(width: 850 * s, height: 498 * s, alignment: .leading)
                .position(x: 601 * s, y: 1251 * s)
            ForEach(0..<5) { i in
                let hour = i < forecast.hours.count ? forecast.hours[i] : nil
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

