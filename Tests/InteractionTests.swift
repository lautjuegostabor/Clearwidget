import Foundation
@main struct InteractionTests {
    static func main() {
        let name = "clearwidget.tests.interaction." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let t = Date(timeIntervalSince1970: 1000)
        precondition(!WidgetInteraction.recent(at: t, defaults: d))
        WidgetInteraction.mark(at: t, defaults: d, uptime: 100)
        let mark = WidgetInteraction.current(at: t, defaults: d)!
        precondition(WidgetInteraction.recent(at: t.addingTimeInterval(1), defaults: d))
        precondition(WidgetInteraction.recent(at: t.addingTimeInterval(6), defaults: d))
        precondition(!WidgetInteraction.recent(at: t.addingTimeInterval(6.01), defaults: d))
        precondition(!WidgetInteraction.recent(at: t.addingTimeInterval(-1), defaults: d))
        WidgetInteraction.finish(mark, started: 100.2, ended: 100.23, at: t.addingTimeInterval(0.3), defaults: d)
        let measured = WidgetInteraction.diagnostic(defaults: d)
        precondition(measured.contains("200 ms") && measured.contains("30 ms"), measured)
        WidgetInteraction.mark(at: t.addingTimeInterval(1), defaults: d, uptime: 101)
        WidgetInteraction.finish(mark, started: 100.5, ended: 100.6, at: t.addingTimeInterval(1), defaults: d)
        precondition(WidgetInteraction.diagnostic(defaults: d) == measured, "stale reload overwrote measurements")
        precondition(WidgetInteraction.recent(at: t.addingTimeInterval(7), defaults: d))
        print("Interaction timing, expiration and overlapping reload tests passed")
    }
}
