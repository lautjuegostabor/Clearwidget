import Foundation
import Darwin
import CWNotify

// Public Darwin Notify 64-bit state. ONLY a cosmetic selection travels here.
// Namespace is device-global and not an authenticated or confidential IPC channel.
// Never use this mechanism for signing, identifiers beyond the scope, health, etc.
enum AppearanceWire {
    static func encode(_ record: AppearanceRecord, tag: UInt64) -> UInt64? {
        guard record.valid, tag <= 7, record.revision > 0 else { return nil }
        return (record.revision << 5) | (UInt64(record.mode) << 3) | tag
    }
    static func decode(_ raw: UInt64, tag: UInt64) -> AppearanceRecord? {
        guard raw != 0, raw & 7 == tag else { return nil }
        let record = AppearanceRecord(mode: Int((raw >> 3) & 3),
            changedAt: Date(timeIntervalSinceReferenceDate: Double(raw >> 5) / 1000))
        return record.valid && record.revision == raw >> 5 ? record : nil
    }
    static func namespace(bundleID: String) -> String? {
        let host = "com.clearwidget.app"
        let extensionID = host + ".widget"
        let canonical: String
        if bundleID == extensionID || bundleID.hasPrefix(extensionID + ".") {
            canonical = host + String(bundleID.dropFirst(extensionID.count))
        } else if bundleID == host || bundleID.hasPrefix(host + ".") {
            canonical = bundleID
        } else { return nil }
        guard canonical.utf8.count <= 150,
              canonical.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 })
        else { return nil }
        return canonical + ".appearance.notify.v1"
    }
}
enum AppearanceNotifyError: LocalizedError {
    case invalidNamespace, invalidValue, operation(String, UInt32), readback
    var errorDescription: String? {
        switch self {
        case .invalidNamespace: return "Identidad de ClearWidget no reconocida."
        case .invalidValue: return "Valor de apariencia inválido."
        case .operation(let name, let status): return "Darwin Notify \(name): \(status)."
        case .readback: return "El sistema no conservó el valor enviado."
        }
    }
}
final class AppearanceNotifyChannel {
    private let token: Int32
    init(_ name: String) throws {
        var t: Int32 = -1
        let status = name.withCString { CWNotifyRegister($0, &t) }
        guard status == 0 else { throw AppearanceNotifyError.operation("registro",status) }
        token = t
    }
    deinit { CWNotifyCancel(token) }
    func read() throws -> UInt64 {
        var value: UInt64 = 0
        let status = CWNotifyGetState(token,&value)
        guard status == 0 else { throw AppearanceNotifyError.operation("lectura",status) }
        return value
    }
    func write(_ value: UInt64) throws {
        let status = CWNotifySetState(token,value)
        guard status == 0 else { throw AppearanceNotifyError.operation("escritura",status) }
        guard try read() == value else { throw AppearanceNotifyError.readback }
    }
}
final class AppearanceNotifyBus {
    let request: AppearanceNotifyChannel
    let timeline: AppearanceNotifyChannel
    let descriptor: AppearanceNotifyChannel
    init(namespace: String) throws {
        request = try AppearanceNotifyChannel(namespace + ".request")
        timeline = try AppearanceNotifyChannel(namespace + ".timeline")
        descriptor = try AppearanceNotifyChannel(namespace + ".descriptor")
    }
    // Retain registration tokens for the lifetime of each cooperating process.
    // The state is transient; the actual preference is saved locally in each process.
    static let instance: Result<AppearanceNotifyBus, Error> = Result {
        guard let name = AppearanceWire.namespace(bundleID: Bundle.main.bundleIdentifier ?? "") else {
            throw AppearanceNotifyError.invalidNamespace
        }
        return try AppearanceNotifyBus(namespace: name)
    }
    func readRequest() throws -> AppearanceRecord? {
        AppearanceWire.decode(try request.read(),tag:7)
    }
    func send(_ record: AppearanceRecord) throws {
        guard let raw = AppearanceWire.encode(record,tag:7) else { throw AppearanceNotifyError.invalidValue }
        try request.write(raw)
    }
    func readTimeline() throws -> AppearanceRecord? {
        AppearanceWire.decode(try timeline.read(),tag:4)
    }
    func acknowledge(_ record: AppearanceRecord) throws {
        guard let raw = AppearanceWire.encode(record,tag:4) else { throw AppearanceNotifyError.invalidValue }
        if try timeline.read() != raw { try timeline.write(raw) }
    }
    func readDescriptor() throws -> AppearanceDescriptorReceipt? {
        let raw = try descriptor.read()
        guard let outcome = AppearanceDescriptorOutcome(rawValue:Int(raw & 7)),
              let record = AppearanceWire.decode(raw,tag:UInt64(outcome.rawValue)) else { return nil }
        return AppearanceDescriptorReceipt(record:record,outcome:outcome)
    }
    func report(_ receipt: AppearanceDescriptorReceipt) throws {
        guard let raw = AppearanceWire.encode(receipt.record,tag:UInt64(receipt.outcome.rawValue)) else {
            throw AppearanceNotifyError.invalidValue
        }
        if try descriptor.read() != raw { try descriptor.write(raw) }
    }
}
