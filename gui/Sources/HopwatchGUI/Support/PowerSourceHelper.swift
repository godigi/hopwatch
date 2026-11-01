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
}
