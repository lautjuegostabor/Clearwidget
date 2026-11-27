import Foundation

struct AppearanceRecord: Codable, Equatable {
    let mode: Int
    let changedAt: Date
    var valid: Bool { (0...3).contains(mode) && changedAt.timeIntervalSinceReferenceDate.isFinite }
    var revision: UInt64 { changedAt.timeIntervalSinceReferenceDate.bitPattern }
}
enum AppearanceDescriptorOutcome: Int, Codable {
    case system = 0, patched = 1, rejected = 2, hookUnavailable = 3
}
struct AppearanceDescriptorReceipt: Codable, Equatable {
    let record: AppearanceRecord
    let outcome: AppearanceDescriptorOutcome
}
enum AppearanceDelivery: Equatable {
    case initial, pending, timelineReceived, system, patched, rejected, hookUnavailable
    static func resolve(request: AppearanceRecord?, timeline: AppearanceRecord?, descriptor: AppearanceDescriptorReceipt?) -> Self {
        guard let request, request.valid else { return .initial }
        if let descriptor, descriptor.record == request {
            switch descriptor.outcome {
            case .system: return request.mode == 0 ? .system : .rejected
            case .patched: return request.mode == 0 ? .rejected : .patched
            case .rejected: return .rejected
            case .hookUnavailable: return .hookUnavailable
            }
        }
        return timeline == request ? .timelineReceived : .pending
    }
}
