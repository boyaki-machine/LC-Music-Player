import Testing
@testable import PlayerUI

@Suite @MainActor struct AlwaysOnDisplayTests {
    private final class Recorder {
        var monitoring: [Bool] = []
        var applied: [Bool] = []
    }
    private func display(_ power: PowerStatus) -> (AlwaysOnDisplay, Recorder) {
        let recorder = Recorder()
        let display = AlwaysOnDisplay(power: power, monitor: { recorder.monitoring.append($0) }, apply: { recorder.applied.append($0) })
        return (display, recorder)
    }

    @Test func keepsTheScreenOnUntilTheBatteryFallsToThirtyPercentUnlessCharging() {
        func keeps(_ level: Float?, charging: Bool = false) -> Bool {
            AlwaysOnDisplay.keepsAwake(requested: true, power: PowerStatus(level: level, charging: charging))
        }
        #expect(keeps(1) && keeps(0.35) && keeps(0.31))
        #expect(!keeps(0.3) && !keeps(0.05))
        #expect(keeps(0.2, charging: true) && keeps(0.05, charging: true))
        // An unknown level (the simulator) keeps the screen on.
        #expect(keeps(nil) && keeps(-1))
        #expect(!AlwaysOnDisplay.keepsAwake(requested: false, power: PowerStatus(level: 1, charging: true)))
    }

    @Test func togglingAppliesTheAutoLockOnceAndBatteryChangesReleaseAndRestoreIt() {
        let (display, recorder) = display(PowerStatus(level: 0.8, charging: false))
        #expect(!display.keepsAwake && recorder.applied.isEmpty)
        display.setRequested(true)
        #expect(display.keepsAwake && recorder.applied == [true] && recorder.monitoring == [true])
        display.powerChanged(PowerStatus(level: 0.6, charging: false))
        #expect(recorder.applied == [true])
        display.powerChanged(PowerStatus(level: 0.3, charging: false))
        #expect(!display.keepsAwake && display.isHeldBackByBattery && recorder.applied == [true, false])
        // Put on the charger: on again while it charges.
        display.powerChanged(PowerStatus(level: 0.3, charging: true))
        #expect(display.keepsAwake && !display.isHeldBackByBattery && recorder.applied == [true, false, true])
        display.setRequested(false)
        #expect(!display.keepsAwake && !display.isHeldBackByBattery && recorder.applied == [true, false, true, false])
        #expect(recorder.monitoring == [true, false])
    }

    @Test func turningItOnWithALowBatteryLeavesTheAutoLockAlone() {
        let (display, recorder) = display(PowerStatus(level: 0.2, charging: false))
        display.setRequested(true)
        #expect(display.isRequested && display.isHeldBackByBattery && recorder.applied.isEmpty)
        display.setRequested(false)
        #expect(recorder.applied.isEmpty)
    }
}
