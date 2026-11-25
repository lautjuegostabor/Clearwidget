import SwiftUI
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

private enum Store {
    static let key = "clearwidget.activePage.v1"
    static var page: Page { Page(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .home }
    static func set(_ page: Page) {
        guard self.page != page else { return }
        UserDefaults.standard.set(page.rawValue, forKey: key)
    }
}

struct SelectPage: AppIntent {
    static var title: LocalizedStringResource = "Cambiar pantalla"
    static var openAppWhenRun = false
    @Parameter(title: "Pantalla") var page: Page
    init() {}
    init(_ page: Page) { self.page = page }
    func perform() async throws -> some IntentResult {
        ForecastDisk.markNavigation()
        Store.set(page)
        return .result()
    }
}

private struct Entry: TimelineEntry {
    let date: Date
    let page: Page
    let weather: WeatherReading
}
private struct Provider: TimelineProvider {
    private func entry(at now: Date, page: Page) -> Entry {
        Entry(date: now, page: page,
              weather: page == .weather ? ForecastDisk.cached?.reading(at: now) ?? .empty : .empty)
    }
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), page: .home, weather: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(entry(at: Date(), page: Store.page))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date()
        // A tap reloads the timeline but must never wait for a network fetch.
        if context.isPreview || ForecastDisk.navigationRecent(at: now) {
            complete(at: now, completion: completion)
            return
        }
        Task {
            await WeatherService.shared.refreshIfDue(at: now)
            complete(at: Date(), completion: completion)
        }
    }
    private func complete(at now: Date, completion: @escaping (Timeline<Entry>) -> Void) {
        let calendar = Calendar.autoupdatingCurrent
        let midnight = calendar.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(3600)
        let next = min(midnight, ForecastDisk.nextRefresh(at: now))
        completion(Timeline(entries: [entry(at: now, page: Store.page)], policy: .after(next)))
    }
}

private let spanish = Locale(identifier: "es_AR")

private struct ClearView: View {
    let entry: Entry
    @Environment(\.widgetRenderingMode) private var mode
    var body: some View {
        GeometryReader { geometry in
            let s = min(geometry.size.width / 1050, geometry.size.height / 490)
            HStack(spacing: 28 * s) {
                ZStack {
                    RoundedRectangle(cornerRadius: 74 * s)
                        .fill(mode == .fullColor ? Color.black.opacity(0.14) : Color.black.opacity(0.08))
                    RoundedRectangle(cornerRadius: 74 * s)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 2.5 * s)
                    switch entry.page {
                    case .home: HomePage(date: entry.date, s: s)
                    case .calendar:
                        Link(destination: URL(string: "clearwidget://calendar")!) {
                            CalendarPage(date: entry.date, s: s)
                        }
                    case .weather:
                        Link(destination: URL(string: "clearwidget://weather")!) {
                            WeatherPage(s: s, weather: entry.weather)
                        }
                    }
                }
                .frame(width: 824 * s, height: 460 * s)
                NavigationRail(active: entry.page, s: s)
                    .frame(width: 144 * s, height: 380 * s)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { Color.black.opacity(0.12) }
    }
}

// Original handwritten lettering recreated as one lightweight local vector.
// Normalized from the reference proportions; no downloaded artwork or wallpaper.
private struct HelloMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 250, sy = rect.height / 84
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var a = Path()
        a.move(to: p(3, 78))
        a.addQuadCurve(to: p(41, 46), control: p(24, 62))
        a.addCurve(to: p(42, 5), control1: p(63, 14), control2: p(48, -4))
        a.addCurve(to: p(27, 78), control1: p(30, 13), control2: p(30, 61))
        a.addCurve(to: p(61, 54), control1: p(38, 55), control2: p(53, 35))
        a.addCurve(to: p(75, 80), control1: p(76, 59), control2: p(55, 83))
        a.addCurve(to: p(103, 49), control1: p(91, 80), control2: p(111, 52))
        a.addCurve(to: p(83, 67), control1: p(92, 39), control2: p(76, 54))
        a.addCurve(to: p(126, 76), control1: p(88, 91), control2: p(111, 82))
        a.addCurve(to: p(139, 5), control1: p(148, 53), control2: p(156, 3))
        a.addCurve(to: p(123, 66), control1: p(128, 4), control2: p(117, 50))
        a.addCurve(to: p(163, 75), control1: p(123, 87), control2: p(144, 83))
        a.addCurve(to: p(181, 6), control1: p(189, 48), control2: p(196, 3))
        a.addCurve(to: p(163, 66), control1: p(171, 7), control2: p(155, 53))
        a.addCurve(to: p(198, 76), control1: p(167, 87), control2: p(184, 82))
        a.addCurve(to: p(214, 44), control1: p(190, 66), control2: p(199, 46))
        a.addCurve(to: p(226, 63), control1: p(228, 40), control2: p(232, 52))
        a.addCurve(to: p(198, 76), control1: p(223, 80), control2: p(208, 84))
        a.move(to: p(218, 44))
        a.addQuadCurve(to: p(247, 41), control: p(239, 54))
        return a
    }
}

private struct HomePage: View {
    let date: Date
    let s: CGFloat
    var body: some View {
        ZStack(alignment: .topLeading) {
            HelloMark()
                .stroke(Color.white.opacity(0.86), style: StrokeStyle(lineWidth: 5.5 * s, lineCap: .round, lineJoin: .round))
                .frame(width: 250 * s, height: 84 * s)
                .position(x: 220 * s, y: 230 * s)
                .accessibilityLabel("Hello")
            VStack(alignment: .trailing, spacing: 5 * s) {
                Text(date.formatted(.dateTime.weekday(.wide).locale(spanish)))
                Text(date.formatted(.dateTime.month(.wide).locale(spanish)))
            }
            .font(.system(size: 34 * s, weight: .regular, design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: 235 * s, alignment: .trailing)
            .position(x: 488 * s, y: 230 * s)
            ZStack {
                Image("HomeOrange").resizable().widgetAccentedRenderingMode(.fullColor)
                Text(String(Calendar.autoupdatingCurrent.component(.day, from: date)))
                    .font(.system(size: 44 * s, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .frame(width: 96 * s, height: 96 * s)
            .position(x: 685 * s, y: 230 * s)
        }
        .frame(width: 824 * s, height: 460 * s)
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
    let symbol: String
    let s: CGFloat
    var body: some View {
        if symbol == "cloud.sun" || symbol == "cloud.moon" {
            ZStack {
                Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 5 * s)
                    .frame(width: 160 * s, height: 160 * s)
                Image(systemName: "cloud.fill")
                    .font(.system(size: 96 * s, weight: .regular))
                    .foregroundStyle(Color(white: 0.21))
                    .overlay {
                        Image(systemName: "cloud")
                            .font(.system(size: 96 * s, weight: .ultraLight))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .offset(x: -22 * s, y: 51 * s)
            }.frame(width: 190 * s, height: 180 * s)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 136 * s, weight: .ultraLight))
                .frame(width: 190 * s, height: 180 * s)
        }
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
                WeatherGlyph(symbol: weather.symbol, s: s)
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(WeatherReading.degrees(weather.current)).font(.system(size: 50 * s, weight: .semibold, design: .rounded))
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
            Text(WeatherReading.degrees(temperature)).font(.system(size: 50 * s, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 55 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background { tile }
    }
}

private struct NavigationRail: View {
    let active: Page
    let s: CGFloat
    var body: some View {
        VStack(spacing: 3 * s) {
            key(.calendar, asset: "KeyCalendar", height: 128)
            key(.home, asset: "KeyHome", height: 110)
            key(.weather, asset: "KeyWeather", height: 128)
        }
        .frame(width: 126 * s, height: 372 * s)
        .frame(width: 144 * s, height: 380 * s)
        .background {
            Image("RailMetal").resizable().widgetAccentedRenderingMode(.fullColor)
        }
    }
    private func key(_ page: Page, asset: String, height: CGFloat) -> some View {
        Button(intent: SelectPage(page)) {
            Image(asset).resizable().widgetAccentedRenderingMode(.fullColor)
                .frame(width: 126 * s, height: height * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page.label)
        .accessibilityAddTraits(active == page ? .isSelected : [])
    }
}

@main
struct ClearWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClearWidget", provider: Provider()) { entry in
            ClearView(entry: entry)
        }
        .configurationDisplayName("ClearWidget")
        .description("Inicio, clima y calendario.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
        .containerBackgroundRemovable(true)
    }
}
