@main struct SigningControlsTests {
    static func main() {
        for configured in [false, true] {
            for automatic in [false, true] {
                for running in [false, true] {
                    for setup in [false, true] {
                        for valid in [false, true] {
                            let p = SigningControls(configured: configured, automatic: automatic,
                                running: running, setupActive: setup, validExpiry: valid)
                            precondition(p.canToggleAutomatic == (!running && (automatic || (configured && !setup && valid))))
                            precondition(p.canRenew == (configured && !running && !setup && valid))
                            precondition(p.canImport == (!running && !setup))
                            precondition(p.canManageSession == (configured && !running && !setup))
                            precondition(p.canBackup == p.canRenew)
                            precondition(p.canStartSetup(setupRunning: false) == !running)
                            precondition(!p.canStartSetup(setupRunning: true))
                        }
                    }
                }
            }
        }
        let stranded = SigningControls(configured: false, automatic: true, running: false, setupActive: false, validExpiry: true)
        precondition(stranded.canToggleAutomatic && stranded.canStartSetup(setupRunning: false))
        precondition(!stranded.canRenew)
        precondition(!SigningControls.normalizedAutomatic(true, sessionDefinitelyMissing: true))
        precondition(SigningControls.normalizedAutomatic(true, sessionDefinitelyMissing: false))
        print("Signing control matrix passed (32 states)")
    }
}
