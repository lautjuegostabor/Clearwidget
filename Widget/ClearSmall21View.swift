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
    private static let valueKey = "clearwidget.battery.cached.v1"
    private static let dateKey = "clearwidget.battery.cached.date.v1"
    static func cached(at now: Date) -> Int? {
        let d = UserDefaults.standard
        guard let value = d.object(forKey: valueKey) as? Int,
              let date = d.object(forKey: dateKey) as? Date,
              (0...3600).contains(now.timeIntervalSince(date)),
              (0...100).contains(value) else { return nil }
        return value
    }
    @MainActor static func level() -> Int? {
        let device = UIDevice.current
        let previous = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = previous }
        let value = device.batteryLevel
        guard value.isFinite, (0...1).contains(value) else { return nil }
        let result = Int((value * 100).rounded())
        UserDefaults.standard.set(result, forKey: valueKey)
        UserDefaults.standard.set(Date(), forKey: dateKey)
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
            ZStack(alignment: .topLeading) {
                ZStack { informationAction(s).id(page).transition(.blurReplace) }
                    .frame(width: 1600*s, height: 1600*s)
                    .invalidatableContent()
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: page)
                // Preserve the entire original PNG; draw the navigator once, inside its real button.
                Image("Small21Navigator").resizable().widgetAccentedRenderingMode(.fullColor)
                    .frame(width: 1600*s,height: 1600*s)
                    .mask {
                        Rectangle().fill(.white).overlay {
                            Circle().fill(.black)
                                .frame(width: 420*s,height: 420*s)
                                .position(x: 1280*s,y: 1280*s)
                                .blendMode(.destinationOut)
                        }.compositingGroup()
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                Button(intent: AdvanceSmall21()) {
                    Image("Small21Navigator").resizable().widgetAccentedRenderingMode(.fullColor)
                        .frame(width: 1600*s,height: 1600*s)
                        .offset(x: -480*s,y: -480*s)
                        .frame(width: 420*s,height: 420*s)
                        .clipShape(Circle())
                        .contentShape(.interaction, Circle())
                }.buttonStyle(.plain)
                    .position(x: 1280*s,y: 1280*s)
                    .accessibilityLabel("Siguiente pantalla")
            }.frame(width: 1600*s,height: 1600*s)
                .frame(maxWidth: .infinity,maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { Color.clear }
    }
    @ViewBuilder private func informationAction(_ s: CGFloat) -> some View {
        if let shortcut {
            Button(intent: RunSystemShortcutIntent(shortcut: shortcut)) {
                information(s).contentShape(.interaction, RoundedRectangle(cornerRadius: 320*s))
            }.buttonStyle(.plain)
                .accessibilityLabel("Abrir acción de \(subtitle)")
        } else {
            Button(intent: StayOnGlassSmall()) {
                information(s).contentShape(.interaction, RoundedRectangle(cornerRadius: 320*s))
            }.buttonStyle(.plain)
                .accessibilityLabel("Sin acción configurada")
        }
    }
    @ViewBuilder private func information(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Image(page.artwork).resizable().widgetAccentedRenderingMode(.fullColor)
                .frame(width: 1600*s,height: 1600*s)
                .allowsHitTesting(false).accessibilityHidden(true)
            ZStack(alignment: .topLeading) {
                text(subtitle,size: 135,weight: .medium,opacity: 0.60,width: 1200,height: 180,x: 220,y: 340,s: s)
                text(value,size: 310,weight: .bold,opacity: 1,width: 1200,height: 382,x: 220,y: 520,s: s)
                text(foot,size: 125,weight: .medium,opacity: 0.70,width: 710,height: 168,x: page == .activity ? 240 : 440,y: 1190,s: s)
            }.frame(width: 1600*s,height: 1600*s).allowsHitTesting(false)

        }
    }
    private func text(_ value: String,size: CGFloat,weight: Font.Weight,opacity: Double,
                      width: CGFloat,height: CGFloat,x: CGFloat,y: CGFloat,s: CGFloat) -> some View {
        Text(value).font(.system(size: size*s,weight: weight,design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.55).foregroundStyle(.white.opacity(opacity))
            .frame(width: width*s,height: height*s,alignment: .leading)
            .position(x: (x+width/2)*s,y: (y+height/2)*s)
    }
}
