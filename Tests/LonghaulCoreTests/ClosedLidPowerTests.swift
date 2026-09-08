import Testing
@testable import LonghaulCore

@Test func closedLidReserveAllowsConnectedDischarge() {
    #expect(PowerSnapshot(percent: 62, onAC: true, discharging: true).supportsClosedLidWork)
    #expect(PowerSnapshot(percent: 20, onAC: true, discharging: true).supportsClosedLidWork)
    #expect(PowerSnapshot(percent: 19.9, onAC: true, discharging: true).supportsClosedLidWork == false)
    #expect(PowerSnapshot(percent: nil, onAC: true).supportsClosedLidWork == false)
    #expect(PowerSnapshot(percent: .nan, onAC: true).supportsClosedLidWork == false)
    #expect(PowerSnapshot(percent: 101, onAC: true).supportsClosedLidWork == false)
    #expect(PowerSnapshot(percent: 62, warningLevel: 2).supportsClosedLidWork == false)
    #expect(PowerSnapshot(percent: 62, thermalLevel: 1).supportsClosedLidWork == false)
}

@Test func closedLidReserveSurvivesPowerSourceTransitions() {
    var power = PowerSnapshot(percent: 20, onAC: true)
    #expect(power.supportsClosedLidWork)
    power.onAC = false; power.discharging = true
    #expect(power.supportsClosedLidWork)
    power.onAC = true
    #expect(power.supportsClosedLidWork)
}

@Test func closedLidBatteryReserveAndWarnings() {
    #expect(PowerSnapshot(percent: 29.9, onAC: false, discharging: true).supportsClosedLidWork)
    #expect(PowerSnapshot(percent: 20, onAC: false, discharging: true).supportsClosedLidWork)
    for percent: Double? in [19.9, 0, nil, .nan, .infinity, 101] {
        #expect(!PowerSnapshot(percent: percent, onAC: false, discharging: true).supportsClosedLidWork)
    }
    #expect(!PowerSnapshot(percent: 62, onAC: false, discharging: true, warningLevel: 2).supportsClosedLidWork)
    #expect(!PowerSnapshot(percent: 62, onAC: false, discharging: true, thermalLevel: 1).supportsClosedLidWork)
}
