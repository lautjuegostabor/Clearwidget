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

private let red = Color(red: 1, green: 0.22, blue: 0.12)
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
                        .fill(mode == .fullColor ? Color.black.opacity(0.14) : Color.clear)
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

private struct HomePage: View {
    let date: Date
    let s: CGFloat
    var body: some View {
        HStack(spacing: 26 * s) {
            Text("hello")
                .font(.custom("SnellRoundhand", size: 106 * s))
                .minimumScaleFactor(0.7)
                .frame(width: 300 * s)
                .foregroundStyle(.white.opacity(0.87))
                .accessibilityLabel("Hello")
            VStack(alignment: .trailing, spacing: 5 * s) {
                Text(date.formatted(.dateTime.weekday(.wide).locale(spanish)))
                Text(date.formatted(.dateTime.month(.wide).locale(spanish)))
            }
            .font(.system(size: 34 * s, weight: .regular, design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.7)
            ZStack {
                Circle().fill(red)
                Text(String(Calendar.autoupdatingCurrent.component(.day, from: date)))
                    .font(.system(size: 44 * s, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }.frame(width: 96 * s, height: 96 * s)
        }.padding(.horizontal, 34 * s)
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
                                RoundedRectangle(cornerRadius: 13 * s)
                                    .fill(red).frame(width: 96 * s, height: 76 * s)
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

private struct WeatherPage: View {
    let s: CGFloat
    let weather: WeatherReading
    var body: some View {
        HStack(spacing: 22 * s) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Ahora").font(.system(size: 34 * s, design: .rounded)).foregroundStyle(.white.opacity(0.70))
                Spacer(minLength: 0)
                Image(systemName: weather.symbol)
                    .font(.system(size: 136 * s, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(WeatherReading.degrees(weather.current)).font(.system(size: 50 * s, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(40 * s).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { tile }
            VStack(spacing: 20 * s) {
                smallTile("Próxima hora", weather.nextHour)
                smallTile("Mañana", weather.tomorrowHigh)
                    .accessibilityLabel("Máxima de mañana")
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(26 * s).contentShape(Rectangle())
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
        .padding(.horizontal, 50 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background { tile }
    }
}

private struct NavigationRail: View {
    let active: Page
    let s: CGFloat
    var body: some View {
        VStack(spacing: 3 * s) {
            key(.calendar, top: true, bottom: false)
            key(.home, top: false, bottom: false)
            key(.weather, top: false, bottom: true)
        }
        .padding(9 * s)
        .background {
            Capsule().fill(LinearGradient(colors: [Color(white: 0.84), Color(white: 0.47), Color(white: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 2 * s) }
    }
    private func key(_ page: Page, top: Bool, bottom: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: (top ? 64 : 12) * s, bottomLeadingRadius: (bottom ? 64 : 12) * s, bottomTrailingRadius: (bottom ? 64 : 12) * s, topTrailingRadius: (top ? 64 : 12) * s)
        return Button(intent: SelectPage(page)) {
            ZStack {
                shape.fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.82)], startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.strokeBorder(Color.white.opacity(0.85), lineWidth: 2 * s)
                Capsule().fill(page.indicator)
                    .overlay { Capsule().strokeBorder(Color.black.opacity(0.16), lineWidth: s) }
                    .frame(width: 28 * s, height: 8 * s)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.buttonStyle(.plain)
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
