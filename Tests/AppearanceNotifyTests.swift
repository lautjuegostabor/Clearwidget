import Foundation

@main struct AppearanceNotifyTests {
    static func main() throws {
        let args = CommandLine.arguments
        let base = "com.clearwidget.app"
        precondition(AppearanceWire.namespace(bundleID:base+".ABC") == AppearanceWire.namespace(bundleID:base+".widget.ABC"))
        precondition(AppearanceWire.namespace(bundleID:base) == AppearanceWire.namespace(bundleID:base+".widget"))
        precondition(AppearanceWire.namespace(bundleID:"com.other") == nil)
        let record = AppearanceRecord(mode:3,changedAt:Date(timeIntervalSinceReferenceDate:123456789.123))
        for tag in UInt64(0)...7 {
            let raw = AppearanceWire.encode(record,tag:tag)!
            precondition(AppearanceWire.decode(raw,tag:tag) == record)
            precondition(AppearanceWire.decode(raw,tag:(tag+1)%8) == nil)
        }
        precondition(AppearanceWire.decode(0,tag:0) == nil)
        let bus = try AppearanceNotifyBus(namespace:args[2])
        if args[1] == "producer" {
            try bus.send(record)
            try Data().write(to:URL(fileURLWithPath:args[3]))
            for _ in 0..<200 {
                if try bus.readTimeline() == record,
                   try bus.readDescriptor() == AppearanceDescriptorReceipt(record:record,outcome:.patched) {
                    print("Independent process received request and returned both receipts")
                    return
                }
                Thread.sleep(forTimeInterval:0.025)
            }
            fatalError("Independent process did not acknowledge")
        } else {
            let received = try bus.readRequest()
            precondition(received == record)
            try bus.acknowledge(record)
            try bus.report(AppearanceDescriptorReceipt(record:record,outcome:.patched))
            Thread.sleep(forTimeInterval:0.3)
        }
    }
}
