import SwiftUI
import Foundation
import WidgetKit
import AppIntents

enum Page: String, AppEnum {
    case calendar, home, weather
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Pantalla"
    static var caseDisplayRepresentations: [Page: DisplayRepresentation] = [
        .calendar: "Calendario", .home: "Inicio", .weather: "Clima"
    ]
    var indicator: Color {
        switch self {
        case .calendar: return Color(red: 0.32, green: 0.95, blue: 0.10)
        case .home: return Color(white: 0.56)
        case .weather: return Color(red: 1, green: 0.28, blue: 0.13)
        }
    }
    var label: String {
        switch self {
        case .calendar: return "Calendario"
        case .home: return "Inicio"
        case .weather: return "Clima"
        }
    }
}

// Preserve the original medium kind and navigation state for installed widgets.
private enum Store {
    private static let key = "clearwidget.navigation.state.v2"
    private static let lock = NSLock()
    static var page: Page {
        let raw = UserDefaults.standard.string(forKey: key)?.split(separator: "|").first.map(String.init)
        return raw.flatMap(Page.init(rawValue:)) ??
            Page(rawValue: UserDefaults.standard.string(forKey: "clearwidget.activePage.v1") ?? "") ?? .home
    }
    static func select(_ page: Page) {
        lock.lock(); defer { lock.unlock() }
        // A single write carries both the selected page and the reload reason.
        UserDefaults.standard.set(page.rawValue + "|tap", forKey: key)
    }
    static func consumeTap() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let raw = UserDefaults.standard.string(forKey: key), raw.hasSuffix("|tap") else { return false }
        UserDefaults.standard.set(String(raw.dropLast(4)), forKey: key)
        return true
    }
}

struct SelectPage: AppIntent {
    static var title: LocalizedStringResource = "Cambiar pantalla"
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    @Parameter(title: "Pantalla") var page: Page
    init() {}
    init(_ page: Page) { self.page = page }
    func perform() async throws -> some IntentResult {
        Store.select(page)
        return .result()
    }
}

// Consume taps on the informational home panel without launching the host.
struct StayOnWidget: AppIntent {
    static var title: LocalizedStringResource = "Permanecer en ClearWidget"
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    func perform() async throws -> some IntentResult {
        Store.select(Store.page) // cache-only reload; no page change
        return .result()
    }
}

enum SmallDesign: String, AppEnum {
    case glass, clear
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Diseño"
    static var caseDisplayRepresentations: [SmallDesign: DisplayRepresentation] = [
        .glass: "Glass Small 7", .clear: "Clear Small"
    ]
}

struct ClearConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Acciones de ClearWidget"
    static var description: IntentDescription = "Elegí las aplicaciones que abrirá cada pantalla."
    @Parameter(title: "Acción principal") var home: SystemShortcut?
    @Parameter(title: "Abrir Clima") var weather: SystemShortcut?
    @Parameter(title: "Abrir Calendario") var calendar: SystemShortcut?
    @Parameter(title: "Diseño", default: .glass) var design: SmallDesign
    static var parameterSummary: some ParameterSummary {
        When(widgetFamily: .equalTo, .systemSmall) {
            Summary {
                \.$design
                \.$home
            }
        } otherwise: {
            Summary {
                \.$home
                \.$weather
                \.$calendar
            }
        }
    }
    init() {}
}

private struct Entry: TimelineEntry {
    let date: Date
    let page: Page
    let weather: WeatherReading
    let glass: GlassForecast
    let configuration: ClearConfiguration
}

private struct Provider: AppIntentTimelineProvider {
    private func entry(at now: Date, configuration: ClearConfiguration, family: WidgetFamily) -> Entry {
        let page = Store.page
        let cache = ForecastDisk.cached
        return Entry(date: now, page: page,
            weather: family == .systemMedium && page == .weather ? cache?.reading(at: now) ?? .empty : .empty,
            glass: family == .systemSmall ? cache?.glassForecast(at: now) ?? .empty : .empty,
            configuration: configuration)
    }
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), page: .home, weather: .empty, glass: .empty, configuration: ClearConfiguration())
    }
    func snapshot(for configuration: ClearConfiguration, in context: Context) async -> Entry {
        entry(at: Date(), configuration: configuration, family: context.family)
    }
    func timeline(for configuration: ClearConfiguration, in context: Context) async -> Timeline<Entry> {
        let now = Date()
        let tap = context.family == .systemMedium && !context.isPreview && Store.consumeTap()
        if !context.isPreview && !tap {
            await WeatherService.shared.refreshIfDue(at: now)
        }
        // Read the latest state after any scheduled network request, never restore an old page.
        let date = Date()
        let midnight = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: date)?.end ?? date.addingTimeInterval(3600)
        let refresh = tap && ForecastDisk.cached == nil ? date.addingTimeInterval(60) : ForecastDisk.nextRefresh(at: date)
        let nextHour = Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / 3600) + 1) * 3600)
        let next = context.family == .systemSmall ? min(refresh, nextHour) : min(midnight, refresh)
        return Timeline(entries: [entry(at: date, configuration: configuration, family: context.family)], policy: .after(next))
    }
}

private let spanish = Locale(identifier: "es_AR")

// Artwork dimensions and positions are based on the original 1480 × 708 PNGs.
private struct OriginalImage: View {
    let name: String
    var body: some View {
        Image(name).resizable().widgetAccentedRenderingMode(.fullColor)
            .accessibilityHidden(true)
    }
}

private struct ClearView: View {
    let entry: Entry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let s = min(geometry.size.width / 1480, geometry.size.height / 708)
            ZStack(alignment: .topLeading) {
                // This asset retains the original 20% alpha tint and border. iOS owns the outer glass.
                OriginalImage(name: "OriginalFrame")
                    .frame(width: 1480 * s, height: 708 * s)
                    .transition(.identity)
                ZStack {
                    panel(s: s)
                        .id(entry.page)
                        .transition(.blurReplace)
                }
                .frame(width: 1164 * s, height: 652 * s)
                .clipped()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: entry.page)
                .position(x: 610 * s, y: 354 * s)
                NavigationRail(active: entry.page, s: s)
                    .frame(width: 173 * s, height: 506 * s)
                    .position(x: 1334.5 * s, y: 352 * s)
                    .transition(.identity)
            }
            .frame(width: 1480 * s, height: 708 * s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { Color.black.opacity(0.12) }
    }

    @ViewBuilder private func panel(s: CGFloat) -> some View {
        let unit = s * 1164 / 824
        switch entry.page {
        case .home:
            if let shortcut = entry.configuration.home {
                Button(intent: RunSystemShortcutIntent(shortcut: shortcut)) {
                    HomePage(date: entry.date, s: s)
                        .contentShape(.interaction, RoundedRectangle(cornerRadius: 100 * s))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Inicio, fecha actual")
            } else {
                Button(intent: StayOnWidget()) {
                    HomePage(date: entry.date, s: s)
                        .contentShape(.interaction, RoundedRectangle(cornerRadius: 100 * s))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Inicio, fecha actual")
            }
        case .calendar:
            action(entry.configuration.calendar, page: .calendar) {
                CalendarPage(date: entry.date, s: unit)
                    .frame(width: 824 * unit, height: 460 * unit)
            }
        case .weather:
            action(entry.configuration.weather, page: .weather) {
                WeatherPage(s: unit, weather: entry.weather)
                    .frame(width: 824 * unit, height: 460 * unit)
            }
        }
    }

    // Apple's iOS 27 API opens the configured application directly, not ClearWidget.
    // An unconfigured control stays in the widget; there is no old URL relay.
    @ViewBuilder private func action<V: View>(_ shortcut: SystemShortcut?, page: Page, @ViewBuilder content: () -> V) -> some View {
        if let shortcut {
            Button(intent: RunSystemShortcutIntent(shortcut: shortcut)) { content().contentShape(.interaction, RoundedRectangle(cornerRadius: 70)) }
                .buttonStyle(.plain)
                .accessibilityHint("Abrir aplicación configurada")
        } else {
            Button(intent: StayOnWidget()) { content().contentShape(.interaction, RoundedRectangle(cornerRadius: 70)) }
                .buttonStyle(.plain)
                .accessibilityHint("Elegí la aplicación en Editar widget")
        }
    }
}

private struct HomePage: View {
    let date: Date
    let s: CGFloat
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Original combined hello / orange disc, cropped without resampling.
            OriginalImage(name: "OriginalHome")
                .frame(width: 910 * s, height: 153 * s)
                .position(x: 577 * s, y: 336.5 * s)
            VStack(alignment: .trailing, spacing: 6 * s) {
                Text(date.formatted(.dateTime.weekday(.wide).locale(spanish)))
                Text(date.formatted(.dateTime.month(.wide).locale(spanish)))
            }
            .font(.system(size: 48 * s, weight: .regular, design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.75)
            .frame(width: 340 * s, alignment: .trailing)
            .position(x: 703 * s, y: 326 * s)
            Text(String(Calendar.autoupdatingCurrent.component(.day, from: date)))
                .font(.system(size: 62 * s, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 136 * s, height: 136 * s)
                .position(x: 964 * s, y: 328 * s)
        }
        .frame(width: 1164 * s, height: 652 * s)
        .accessibilityElement(children: .combine)
    }
}

private struct CalendarPage: View {
    let date: Date
    let s: CGFloat
    private var calendar: Calendar {
        var cal = Calendar.autoupdatingCurrent
        cal.firstWeekday = 2
        return cal
    }
    private var firstDay: Date {
        let start = calendar.startOfDay(for: date)
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        return calendar.date(byAdding: .day, value: -offset - 7, to: start) ?? start
    }
    var body: some View {
        let cal = calendar
        let start = firstDay
        let currentMonth = cal.component(.month, from: date)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(["L","M","X","J","V","S","D"].enumerated()), id: \.offset) { _, letter in
                    Text(letter).foregroundStyle(.white.opacity(0.50))
                        .frame(maxWidth: .infinity)
                }
            }.frame(height: 90 * s)
            ForEach(0..<3) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7) { column in
                        let day = cal.date(byAdding: .day, value: row * 7 + column, to: start) ?? start
                        let today = cal.isDate(day, inSameDayAs: date)
                        let sameMonth = cal.component(.month, from: day) == currentMonth
                        ZStack {
                            if today {
                                Image("TodayRed").resizable().widgetAccentedRenderingMode(.fullColor)
                                    .frame(width: 96 * s, height: 76 * s)
                            }
                            Text(String(cal.component(.day, from: day)))
                                .foregroundStyle(.white.opacity(today || sameMonth ? 1 : 0.48))
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(day.formatted(.dateTime.day().month(.wide).locale(spanish)))
                        .accessibilityAddTraits(today ? .isSelected : [])
                    }
                }
                .frame(height: 104 * s)
                .background {
                    if row == 1 { RoundedRectangle(cornerRadius: 16 * s).fill(Color.white.opacity(0.10)) }
                }
            }
        }
        .font(.system(size: 42 * s, weight: .medium, design: .rounded))
        .padding(.horizontal, 30 * s)
        .contentShape(Rectangle())
    }
}

private struct WeatherGlyph: View {
    let weather: WeatherReading
    let s: CGFloat
    var body: some View {
        Group {
            if let asset = ClearCondition.asset(weather.code, day: weather.isDay) {
                Image(asset).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFit()
            } else {
                Color.clear
            }
        }.frame(width: 190 * s, height: 180 * s)
    }
}

private struct WeatherPage: View {
    let s: CGFloat
    let weather: WeatherReading
    var body: some View {
        HStack(spacing: 23 * s) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Ahora").font(.system(size: 34 * s, design: .rounded)).foregroundStyle(.white.opacity(0.70))
                Spacer(minLength: 0)
                WeatherGlyph(weather: weather, s: s)
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(WeatherReading.degrees(weather.current)).contentTransition(.numericText()).font(.system(size: 50 * s, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(40 * s).frame(width: 373 * s).frame(maxHeight: .infinity)
                .background { tile }
            VStack(spacing: 21 * s) {
                smallTile("Próxima hora", weather.nextHour)
                smallTile("Mañana", weather.tomorrowHigh)
                    .accessibilityLabel("Máxima de mañana: \(WeatherReading.degrees(weather.tomorrowHigh))")
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(.horizontal, 26 * s).padding(.vertical, 24 * s).contentShape(Rectangle())
        .accessibilityHint(weather.fetchedAt.map { "Pronóstico ECMWF actualizado \($0.formatted(date: .omitted, time: .shortened))" } ?? "Datos meteorológicos no disponibles")
    }
    private var tile: some View {
        RoundedRectangle(cornerRadius: 45 * s)
            .fill(Color.white.opacity(0.12))
            .overlay { RoundedRectangle(cornerRadius: 45 * s).strokeBorder(Color.white.opacity(0.15), lineWidth: 1.5 * s) }
    }
    private func smallTile(_ label: String, _ temperature: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6 * s) {
            Text(label).font(.system(size: 34 * s, design: .rounded))
                .foregroundStyle(.white.opacity(0.70)).lineLimit(1).minimumScaleFactor(0.72)
            Text(WeatherReading.degrees(temperature)).contentTransition(.numericText()).font(.system(size: 50 * s, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 55 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background { tile }
    }
}

// Momentary keys, not switches. Keep the original images and selected asset.
private struct NavigationRail: View {
    let active: Page
    let s: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            key(.calendar, asset: "OriginalKeyCalendar", height: 176)
            key(.home, asset: "OriginalKeyHome", height: 156)
            key(.weather, asset: "OriginalKeyWeather", height: 174)
        }
    }
    private func key(_ page: Page, asset: String, height: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: (page == .calendar ? 86 : 14) * s,
            bottomLeadingRadius: (page == .weather ? 86 : 14) * s,
            bottomTrailingRadius: (page == .weather ? 86 : 14) * s,
            topTrailingRadius: (page == .calendar ? 86 : 14) * s
        )
        return Button(intent: SelectPage(page)) {
            OriginalImage(name: active == page && page != .home ? asset + "On" : asset)
                .frame(width: 173 * s, height: height * s)
                .contentShape(.interaction, shape)
                .contentShape(.hoverEffect, shape)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: active == page)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page.label)
        .accessibilityAddTraits(active == page ? .isSelected : [])
    }
}

// A single registered kind exposes both sizes, with independent rendering.
private struct FamilyRoot: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var body: some View {
        if family == .systemSmall {
            switch entry.configuration.design {
            case .glass:
                GlassSmallView(forecast: entry.glass, shortcut: entry.configuration.home)
            case .clear:
                ClearSmallView(date: entry.date, forecast: entry.glass, shortcut: entry.configuration.home)
            }
        } else {
            ClearView(entry: entry)
        }
    }
}

@main
struct ClearWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ClearWidget", intent: ClearConfiguration.self, provider: Provider()) { entry in
            FamilyRoot(entry: entry)
        }
        .configurationDisplayName("ClearWidget")
        .description("Dos diseños pequeños configurables y Clear Medium.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
        .containerBackgroundRemovable(true)
    }
}
