import Foundation

enum WidgetInteraction {
    private static let key = "clearwidget.interaction.timestamp.v1"
    static func mark(at now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: key)
    }
    static func recent(at now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return false }
        return (0...6).contains(now.timeIntervalSince1970 - defaults.double(forKey: key))
    }
}
