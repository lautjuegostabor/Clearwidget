import Foundation
@main struct AppearanceStateTests {
    static func main() {
        let a = AppearanceRecord(mode: 1, changedAt: Date(timeIntervalSinceReferenceDate: 10))
        let b = AppearanceRecord(mode: 2, changedAt: Date(timeIntervalSinceReferenceDate: 11))
        let system = AppearanceRecord(mode: 0, changedAt: Date(timeIntervalSinceReferenceDate: 12))
        let invalid = AppearanceRecord(mode: 9, changedAt: Date())
        func check(_ result: AppearanceDelivery, _ expected: AppearanceDelivery) { precondition(result == expected, "\(result) != \(expected)") }
        check(.resolve(request:nil,timeline:nil,descriptor:nil),.initial)
        check(.resolve(request:invalid,timeline:nil,descriptor:nil),.initial)
        check(.resolve(request:a,timeline:nil,descriptor:nil),.pending)
        check(.resolve(request:b,timeline:a,descriptor:.init(record:a,outcome:.patched)),.pending)
        check(.resolve(request:a,timeline:a,descriptor:nil),.timelineReceived)
        check(.resolve(request:a,timeline:a,descriptor:.init(record:a,outcome:.rejected)),.rejected)
        check(.resolve(request:a,timeline:a,descriptor:.init(record:a,outcome:.patched)),.patched)
        check(.resolve(request:a,timeline:a,descriptor:.init(record:a,outcome:.hookUnavailable)),.hookUnavailable)
        check(.resolve(request:system,timeline:nil,descriptor:.init(record:system,outcome:.system)),.system)
        check(.resolve(request:a,timeline:nil,descriptor:.init(record:a,outcome:.system)),.rejected)
        check(.resolve(request:system,timeline:nil,descriptor:.init(record:system,outcome:.patched)),.rejected)
        precondition(a.revision != b.revision)
        let decoded = try! JSONDecoder().decode(AppearanceRecord.self, from:JSONEncoder().encode(b))
        precondition(decoded == b && decoded.revision == b.revision)
        print("Appearance state and stale receipt tests passed")
    }
}
