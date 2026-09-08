import AppKit
import IOKit.pwr_mgt
import IOKit.ps
import LonghaulCore
import OSLog

@MainActor
final class PowerService {
    private(set) var assertion: IOPMAssertionID = 0
    private let assertionLease: CFTimeInterval = 30
    private let logger = Logger(subsystem: "space.exlumina.longhaul", category: "Power")
    private var source: CFRunLoopSource?
    var onChange: (() -> Void)?
    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<PowerService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in service.onChange?() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
    func snapshot() -> PowerSnapshot {
        var percent: Double?
        var onAC = true
        var discharging = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for item in sources {
                guard let d = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                let capacity = (d[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
                let maximum = (d[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
                if let capacity, let maximum, maximum > 0 { percent = min(100, max(0, capacity / maximum * 100)) }
                onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                discharging = !onAC
            }
        }
        // A weak charger may report AC while the battery is still supplying current.
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if battery != 0 {
            if let value = IORegistryEntryCreateCFProperty(battery, "InstantAmperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                discharging = discharging || value.int64Value < 0
            }
            IOObjectRelease(battery)
        }
        let estimate = IOPSGetTimeRemainingEstimate()
        return PowerSnapshot(percent: percent, onAC: onAC, discharging: discharging,
                             secondsRemaining: estimate >= 0 ? estimate : nil,
                             warningLevel: Int(IOPSGetBatteryWarningLevel().rawValue),
                             thermalLevel: ProcessInfo.processInfo.thermalState.rawValue)
    }
    func setHold(_ enabled: Bool) -> String? {
        if enabled && assertion != 0 {
            // Renewal follows a completed policy evaluation. A hung UI or blocked
            // mailbox cannot keep this process-scoped assertion alive on its own.
            let result = IOPMAssertionSetProperty(assertion, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: assertionLease))
            if result == kIOReturnNotFound { assertion = 0 }
            else if result != kIOReturnSuccess { return "Could not renew sleep protection (\(result))." }
        }
        if enabled && assertion == 0 {
            let result = IOPMAssertionCreateWithDescription(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                "Longhaul is protecting active work" as CFString,
                "Protection expires if Longhaul stops evaluating active work." as CFString,
                nil, nil, assertionLease, kIOPMAssertionTimeoutActionTurnOff as CFString, &assertion)
            if result != kIOReturnSuccess { assertion = 0; return "macOS refused sleep protection (\(result))." }
            logger.info("Acquired idle-sleep assertion")
        } else if !enabled && assertion != 0 {
            let result = IOPMAssertionRelease(assertion)
            if result != kIOReturnSuccess && result != kIOReturnNotFound { return "Could not release sleep protection (\(result))." }
            assertion = 0; logger.info("Released idle-sleep assertion")
        }
        return nil
    }
    var isHolding: Bool {
        guard assertion != 0, let properties = IOPMAssertionCopyProperties(assertion)?.takeRetainedValue() as? [String: Any] else { return false }
        return (properties[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn)
    }
    func otherAppsHoldSleep() -> Bool {
        var result: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess,
              let dictionary = result?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return true }
        for (pid, assertions) in dictionary where pid.int32Value != getpid() {
            for item in assertions {
                guard (item[kIOPMAssertionLevelKey] as? NSNumber)?.intValue != 0 else { continue }
                if let type = item[kIOPMAssertionTypeKey] as? String,
                   ["PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep", "NetworkClientActive"].contains(type) { return true }
            }
        }
        return false
    }
    var userIdle: TimeInterval {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        return idle.isFinite && idle >= 0 ? idle : 0
    }
    func requestSleep() -> String? {
        if let error = setHold(false) { return error }
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != 0 else { return "Could not connect to macOS power management." }
        defer { IOServiceClose(connection) }
        let result = IOPMSleepSystem(connection)
        return result == kIOReturnSuccess ? nil : "macOS did not accept sleep (\(result))."
    }
    func shutdown() {
        _ = setHold(false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }
}
