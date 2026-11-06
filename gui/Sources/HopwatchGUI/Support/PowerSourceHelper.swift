import Foundation
#if os(macOS)
import IOKit.ps
#endif

/// Provides zero-cost, synchronous power source and battery state awareness.
enum PowerSourceHelper {
    /// True when running on battery power (unplugged from AC).
    static var isOnBattery: Bool {
        #if os(macOS)
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = (IOPSGetProvidingPowerSourceType(snapshot).takeRetainedValue() as CFString) as String
        return type == kIOPMBatteryPowerKey || type == "Battery Power"
        #else
        return false
        #endif
    }

    /// True when macOS Low Power Mode is actively enabled in System Settings.
    static var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Current battery charge percentage (0-100) when running on battery power, or nil on AC / desktop Mac.
    static var batteryPercentage: Int? {
        #if os(macOS)
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = (IOPSGetProvidingPowerSourceType(snapshot).takeRetainedValue() as CFString) as String
        guard type == kIOPMBatteryPowerKey || type == "Battery Power" else { return nil }
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as NSArray
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
               let cur = desc[kIOPSCurrentCapacityKey as String] as? Int,
               let max = desc[kIOPSMaxCapacityKey as String] as? Int, max > 0 {
                return Int(round(Double(cur) / Double(max) * 100.0))
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// True when running unplugged on battery power below 20% charge (or in Low Power Mode while on battery).
    static var isLowBattery: Bool {
        guard isOnBattery else { return false }
        if let pct = batteryPercentage {
            return pct < 20
        }
        return isLowPowerMode
    }
}
