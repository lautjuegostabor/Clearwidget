import SwiftUI
import AppIntents
import WidgetKit
import UIKit

enum Small21Page: Int, CaseIterable {
    case calendar, weather, activity
    var next: Self { Self(rawValue: (rawValue + 1) % 3) ?? .calendar }
    var artwork: String {
        switch self {
        case .calendar: return "Small21Calendar"
        case .weather: return "Small21Weather"
        case .activity: return "Small21Activity"
        }
    }
}
// Independent of medium navigation; instances of this design share the page.
enum Small21Navigation {
    private static let key = "clearwidget.small21.page.v1"
    private static let tapKey = "clearwidget.small21.tap.v1"
    private static let lock = NSLock()
    static var page: Small21Page { Small21Page(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .calendar }
    static func advance() {
        lock.lock(); defer { lock.unlock() }
        WidgetInteraction.mark()
        UserDefaults.standard.set(page.next.rawValue, forKey: key)
        UserDefaults.standard.set(true, forKey: tapKey)
    }
    static func consumeTap() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let tap = UserDefaults.standard.bool(forKey: tapKey)
        UserDefaults.standard.removeObject(forKey: tapKey)
        return tap
    }
}
struct AdvanceSmall21: AppIntent {
    static var title: LocalizedStringResource = "Siguiente pantalla de Clear Small"
    static var isDiscoverable = false
    static var openAppWhenRun = false
    static var allowedExecutionTargets: IntentExecutionTargets { .widgetKitExtension }
    func perform() async throws -> some IntentResult { Small21Navigation.advance(); return .result() }
}
enum BatteryReader {
    private static let key = "clearwidget.battery.cache.v2"
    private struct Reading: Codable { let value: Int; let at: Date }
    static func cached(at now: Date) -> Int? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let reading = try? JSONDecoder().decode(Reading.self, from: data),
              (0...3600).contains(now.timeIntervalSince(reading.at)),
              (0...100).contains(reading.value) else { return nil }
        return reading.value
    }
    @MainActor static func level() -> Int? {
        let device = UIDevice.current
        let previous = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = previous }
        let value = device.batteryLevel
        guard value.isFinite, (0...1).contains(value) else { return nil }
        let result = Int((value * 100).rounded())
        if let data = try? JSONEncoder().encode(Reading(value: result, at: Date())) {
            UserDefaults.standard.set(data, forKey: key)
        }
        return result
    }
}
enum ActivityProvider: String, AppEnum {
    case miFitness, iphone, appleWatch, appleHealth, custom
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Fuente de actividad"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .miFitness: "Mi Fitness", .iphone: "iPhone", .appleWatch: "Apple Watch",
        .appleHealth: "Salud (total consolidado)", .custom: "Otra fuente"
    ]
    func key(custom: String?) -> String {
        switch self {
        case .miFitness: return "Mi Fitness"
        case .iphone: return "iPhone"
        case .appleWatch: return "Apple Watch"
        case .appleHealth: return "Salud"
        case .custom: return custom ?? ""
        }
    }
}
struct ClearSmall21View: View {
    let date: Date
    let page: Small21Page
    let weather: WeatherReading
    let todayLow: Double?
    let battery: Int?
    let activity: ActivityReading?
    let configuration: ClearConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var shortcut: SystemShortcut? {
        switch page {
        case .calendar: return configuration.calendar
        case .weather: return configuration.weather
        case .activity: return configuration.activityAction
        }
    }
    private var subtitle: String {
        switch page {
        case .calendar: return date.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "es_AR")))
        case .weather: return GlassCondition.description(weather.code)
        case .activity: return "Pasos"
        }
    }
    private var value: String {
        switch page {
        case .calendar: return date.formatted(.dateTime.day(.twoDigits).locale(Locale(identifier: "es_AR")))
        case .weather: return WeatherReading.degrees(weather.current)
        case .activity: return activity?.steps.formatted(.number.locale(Locale(identifier: "es_AR"))) ?? "—"
        }
    }
    private var foot: String {
        switch page {
        case .calendar: return battery.map { "\($0)%" } ?? "—%"
        case .weather: return WeatherReading.degrees(todayLow)
        case .activity: return activity.map { "\(Int($0.activeKcal.rounded())) kcal" } ?? "— kcal"
        }
    }
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height) / 1600
            // Original Widgy Gesture layer: full width, y=1000, height=600.
            VStack(spacing: 0) {
                Group {
                    if let shortcut {
                        Button(intent: RunSystemShortcutIntent(shortcut: shortcut)) {
                            band(s, lower: false).contentShape(.interaction, Rectangle())
                        }.accessibilityLabel("Abrir acción de \(subtitle)")
                    } else {
                        Button(intent: StayOnGlassSmall()) {
                            band(s, lower: false).contentShape(.interaction, Rectangle())
                        }.accessibilityLabel("Sin acción configurada")
                    }
                }.buttonStyle(.plain)
                Button(intent: AdvanceSmall21()) {
                    band(s, lower: true).contentShape(.interaction, Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Siguiente pantalla")
            }
            .frame(width: 1600*s,height: 1600*s)
            .frame(maxWidth: .infinity,maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { Color.clear }
    }
    private func band(_ s: CGFloat, lower: Bool) -> some View {
        let suffix = lower ? "Lower" : "Upper"
        let origin = lower ? Small21BandGeometry.upperHeight : 0
        let height = lower ? 1600 - Small21BandGeometry.upperHeight : Small21BandGeometry.upperHeight
        return ZStack(alignment: .topLeading) {
            ZStack {
                ZStack(alignment: .topLeading) {
                    Image(page.artwork + suffix).resizable().widgetAccentedRenderingMode(.fullColor)
                        .frame(width: 1600*s,height: height*s).accessibilityHidden(true)
                    if lower {
                        text(foot,size: 125,weight: .medium,opacity: 0.70,width: 710,height: 168,x: page == .activity ? 240 : 440,y: 1190-origin,s: s)
                    } else {
                        text(subtitle,size: 135,weight: .medium,opacity: 0.60,width: 1200,height: 180,x: 220,y: 340,s: s)
                        text(value,size: 310,weight: .bold,opacity: 1,width: 1200,height: 382,x: 220,y: 520,s: s)
                    }
                }
                .frame(width: 1600*s,height: height*s)
                .id(page).transition(.blurReplace)
            }
            .frame(width: 1600*s,height: height*s)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: page)
            Image("Small21Navigator" + suffix).resizable().widgetAccentedRenderingMode(.fullColor)
                .frame(width: 1600*s,height: height*s).accessibilityHidden(true)
        }.frame(width: 1600*s,height: height*s)
    }
    private func text(_ value: String,size: CGFloat,weight: Font.Weight,opacity: Double,
                      width: CGFloat,height: CGFloat,x: CGFloat,y: CGFloat,s: CGFloat) -> some View {
        Text(value).font(.system(size: size*s,weight: weight,design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.55).foregroundStyle(.white.opacity(opacity))
            .frame(width: width*s,height: height*s,alignment: .leading)
            .position(x: (x+width/2)*s,y: (y+height/2)*s)
    }
}
