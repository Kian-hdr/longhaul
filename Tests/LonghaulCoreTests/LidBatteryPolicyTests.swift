import Foundation
import Testing
import LonghaulCore

@Test func lidBatteryPolicyDefaultsAndRange() throws {
    #expect(LidBatteryPolicy() == .init(cutoffEnabled: true, cutoffPercent: 20))
    for cutoff in [1, 20, 100] {
        let policy = LidBatteryPolicy(cutoffPercent: cutoff)
        #expect(policy.isValid)
        #expect(try JSONDecoder().decode(LidBatteryPolicy.self, from: JSONEncoder().encode(policy)) == policy)
        #expect(PowerSnapshot(percent: Double(cutoff), onAC: false, discharging: true).supportsClosedLidWork(policy: policy))
        #expect(!PowerSnapshot(percent: Double(cutoff) - 0.01).supportsClosedLidWork(policy: policy))
    }
    for cutoff in [Int.min, 0, 101, Int.max] {
        for enabled in [false, true] {
            let policy = LidBatteryPolicy(cutoffEnabled: enabled, cutoffPercent: cutoff)
            #expect(!policy.isValid)
            #expect(!PowerSnapshot(percent: 100).supportsClosedLidWork(policy: policy))
        }
    }
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(LidBatteryPolicy.self, from: Data(#"{"cutoffEnabled":true,"cutoffPercent":20.5}"#.utf8))
    }
}

@Test func lidBatteryPolicyOffDisablesOnlyNumericReserve() {
    let off = LidBatteryPolicy(cutoffEnabled: false)
    for value in [0.0, 5, 19, 20, 100] {
        #expect(PowerSnapshot(percent: value, onAC: false, discharging: true).supportsClosedLidWork(policy: off))
    }
    for value: Double? in [nil, .nan, .infinity, -1, 101] {
        #expect(!PowerSnapshot(percent: value).supportsClosedLidWork(policy: off))
    }
    for warning in [0, 2, 3] {
        #expect(!PowerSnapshot(percent: 5, warningLevel: warning).supportsClosedLidWork(policy: off))
    }
    for thermal in [-1, 1, 2, 3] {
        #expect(!PowerSnapshot(percent: 5, thermalLevel: thermal).supportsClosedLidWork(policy: off))
    }
    #expect(PowerSnapshot(percent: 20).supportsClosedLidWork)
    #expect(!PowerSnapshot(percent: 19).supportsClosedLidWork)
}
