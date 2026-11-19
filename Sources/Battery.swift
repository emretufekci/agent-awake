import Foundation
import IOKit.ps

struct BatteryStatus {
    let percent: Int
    let onBattery: Bool
    let charging: Bool
}

enum Battery {
    /// nil on Macs without a battery.
    static func read() -> BatteryStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  d["Type"] as? String == "InternalBattery",
                  let cur = d["Current Capacity"] as? Int,
                  let max = d["Max Capacity"] as? Int, max > 0 else { continue }
            return BatteryStatus(percent: cur * 100 / max,
                                 onBattery: (d["Power Source State"] as? String) == "Battery Power",
                                 charging: d["Is Charging"] as? Bool ?? false)
        }
        return nil
    }
}
