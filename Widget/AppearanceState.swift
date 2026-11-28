import Foundation

struct AppearanceRecord: Codable, Equatable {
    let mode: Int
    let changedAt: Date
    var valid: Bool {
        let value = changedAt.timeIntervalSinceReferenceDate * 1000
        return (0...3).contains(mode) && value.isFinite && value >= 1 && value < 100_000_000_000_000
    }
    var revision: UInt64 { valid ? UInt64((changedAt.timeIntervalSinceReferenceDate * 1000).rounded()) : 0 }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mode == rhs.mode && lhs.revision == rhs.revision
    }
}
enum AppearanceDescriptorOutcome: Int, Codable {
    case system = 0, patched = 1, rejected = 2, hookUnavailable = 3
}
struct AppearanceDescriptorReceipt: Codable, Equatable {
    let record: AppearanceRecord
    let outcome: AppearanceDescriptorOutcome
}
struct AppearanceObservation {
    let request: AppearanceRecord?
    let timeline: AppearanceRecord?
    let descriptor: AppearanceDescriptorReceipt?
}
enum AppearanceDelivery: Equatable {
    case initial, pending, timelineReceived, system, patched, rejected, hookUnavailable
    // Observations are ordered by transport preference (authorized Keychain first).
    // A stale response on one transport cannot mask a current response on another.
    static func resolveAcross(request: AppearanceRecord?, observations: [AppearanceObservation]) -> Self {
        guard let request, request.valid else { return .initial }
        var timelineSeen = false
        for observation in observations where observation.request == request {
            let state = resolve(request: request, timeline: observation.timeline, descriptor: observation.descriptor)
            switch state {
            case .system, .patched, .rejected, .hookUnavailable: return state
            case .timelineReceived: timelineSeen = true
            case .initial, .pending: break
            }
        }
        return timelineSeen ? .timelineReceived : .pending
    }
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
