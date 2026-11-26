import Foundation

@main struct InteractionTests {
    static func main() {
        let name = "clearwidget.tests.interaction." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let t = Date(timeIntervalSince1970: 1000)
        precondition(!WidgetInteraction.recent(at: t, defaults: d))
        WidgetInteraction.mark(at: t, defaults: d)
        precondition(WidgetInteraction.recent(at: t, defaults: d))
        precondition(WidgetInteraction.recent(at: t.addingTimeInterval(1), defaults: d))
        precondition(WidgetInteraction.recent(at: t.addingTimeInterval(6), defaults: d))
        precondition(!WidgetInteraction.recent(at: t.addingTimeInterval(6.01), defaults: d))
        precondition(!WidgetInteraction.recent(at: t.addingTimeInterval(-1), defaults: d))
        WidgetInteraction.mark(at: t.addingTimeInterval(5), defaults: d)
        precondition(WidgetInteraction.recent(at: t.addingTimeInterval(10), defaults: d))
        print("Interaction window tests passed")
    }
}
