// Pure UI policy shared by the coordinator, views and regression tests.
struct SigningControls {
    let configured: Bool
    let automatic: Bool
    let running: Bool
    let setupActive: Bool
    let validExpiry: Bool
    var idle: Bool { !running && !setupActive }
    var canToggleAutomatic: Bool { !running && (automatic || (idle && configured && validExpiry)) }
    var canRenew: Bool { idle && configured && validExpiry }
    var canImport: Bool { idle }
    var canManageSession: Bool { idle && configured }
    var canBackup: Bool { canRenew }
    func canStartSetup(setupRunning: Bool) -> Bool { !running && !setupRunning }
    static func normalizedAutomatic(_ requested: Bool, sessionDefinitelyMissing: Bool) -> Bool {
        requested && !sessionDefinitelyMissing
    }
}
