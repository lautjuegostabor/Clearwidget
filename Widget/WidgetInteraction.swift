import Foundation

// WidgetKit may request multiple timelines after a single intent. The marker
// is a short non-consuming window, not a durable pending update flag.
enum WidgetInteraction {
    private static let key = "clearwidget.interaction.timestamp.v1"
    static func mark(at now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: key)
    }
    static func recent(at now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        let age = now.timeIntervalSince1970 - defaults.double(forKey: key)
        return (0...4).contains(age) && defaults.object(forKey: key) != nil
    }
}
