import Foundation

@main struct AppearanceNotifyTests {
    static func main() throws {
        let args = CommandLine.arguments
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("ClearWidget.app")
        defer { try? FileManager.default.removeItem(at:folder.deletingLastPathComponent()) }
        let appex = folder.appendingPathComponent("PlugIns/ClearWidgetExtension.appex")
        try FileManager.default.createDirectory(at:appex,withIntermediateDirectories:true)
        for host in ["com.clearwidget.app", "com.clearwidget.app.ABC", "com.reused.identifier.ABC"] {
            let info = try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":host],format:.xml,options:0)
            try info.write(to:folder.appendingPathComponent("Info.plist"))
            let appID = AppearanceWire.hostBundleID(bundleURL:folder,bundleID:host)
            let extID = AppearanceWire.hostBundleID(bundleURL:appex,bundleID:host+".widget")
            precondition(appID == host && extID == host)
            precondition(AppearanceWire.namespace(hostBundleID:appID!) == AppearanceWire.namespace(hostBundleID:extID!))
            precondition(AppearanceWire.hostBundleID(bundleURL:appex,bundleID:"com.wrong.widget") == nil)
        }
        precondition(AppearanceWire.namespace(hostBundleID:"") == nil)
        precondition(AppearanceWire.namespace(hostBundleID:"a/b") == nil)
        let record = AppearanceRecord(mode:3,changedAt:Date(timeIntervalSinceReferenceDate:123456789.123))
        for mode in 0...3 {
            let r = AppearanceRecord(mode:mode,changedAt:record.changedAt)
            for tag in UInt64(0)...7 {
                let raw = AppearanceWire.encode(r,tag:tag)!
                precondition(AppearanceWire.decode(raw,tag:tag) == r)
                precondition(AppearanceWire.decode(raw,tag:(tag+1)%8) == nil)
            }
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
