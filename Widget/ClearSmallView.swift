import SwiftUI
import WidgetKit
import AppIntents

// Coordinates from the 1600-unit Widgy canvas and the supplied screenshot.
struct ClearSmallView: View {
    let date: Date
    let forecast: GlassForecast
    let shortcut: SystemShortcut?
    private var reading: WeatherReading { forecast.current }
    private var isDayArtwork: Bool {
        // Original Widgy visibility envelope: 06:00 through 18:00 local time.
        let c = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minute >= 360 && minute <= 1080
    }
    private var weekday: String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "es_AR")))
    }
    private var monthDay: String {
        let month = date.formatted(.dateTime.month(.wide).locale(Locale(identifier: "es_AR")))
        return "\(Calendar.autoupdatingCurrent.component(.day, from: date)) de \(month)"
    }
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height) / 1600
            let shape = RoundedRectangle(cornerRadius: 320 * s)
            Group {
                if let shortcut {
                    Button(intent: RunSystemShortcutIntent(shortcut: shortcut)) {
                        artwork(s).contentShape(.interaction, shape)
                    }
                } else {
                    Button(intent: StayOnGlassSmall()) {
                        artwork(s).contentShape(.interaction, shape)
                    }
                }
            }.buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { Color.clear }
    }
    private func artwork(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Source artwork includes dark upper section and colored rounded lower panel.
            // Preserve full-color artwork in the system glass rendering mode.
            Image(isDayArtwork ? "ClearSmallDay" : "ClearSmallNight")
                .resizable().widgetAccentedRenderingMode(.fullColor)
                .frame(width: 1600 * s, height: 1600 * s)
                .accessibilityHidden(true)
            (Text("Hoy es ").font(.system(size: 150 * s, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.40)) +
             Text(weekday + ",").font(.system(size: 150 * s, weight: .semibold, design: .rounded))
                .foregroundColor(.white))
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(width: 1240 * s, height: 200 * s, alignment: .leading)
                .position(x: 780 * s, y: 340 * s)
            Text(monthDay)
                .font(.system(size: 150 * s, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.68)
                .frame(width: 1240 * s, height: 200 * s, alignment: .leading)
                .position(x: 780 * s, y: 546 * s)
            Text(GlassCondition.description(reading.code))
                .font(.system(size: 76 * s, weight: .medium, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.72)
                .frame(width: 830 * s, height: 160 * s, alignment: .leading)
                .position(x: 615 * s, y: 1044 * s)
            Text(WeatherReading.degrees(reading.current))
                .font(.system(size: 220 * s, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .frame(width: 800 * s, height: 260 * s, alignment: .leading)
                .position(x: 600 * s, y: 1264 * s)
            if let asset = ClearCondition.asset(reading.code, day: reading.isDay) {
                Image(asset).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFit()
                    .frame(width: 400 * s, height: 400 * s)
                    .position(x: 1200 * s, y: 1164 * s)
                    .accessibilityHidden(true)
            }
        }.frame(width: 1600 * s, height: 1600 * s)
            .accessibilityElement(children: .combine)
    }
}
