import Foundation
import IOKit.ps

enum BatteryReader {
    struct State: Sendable, Equatable {
        let percentage: Double  // 0...100
        let onBattery: Bool
    }

    /// Returns nil on desktops with no internal battery (Mac mini, iMac, Mac
    /// Studio, Mac Pro). Callers should treat nil as "no guard applies".
    static func current() -> State? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef] else { return nil }

        for source in list {
            guard let infoCF = IOPSGetPowerSourceDescription(blob, source) else { continue }
            guard let info = infoCF.takeUnretainedValue() as? [String: Any] else { continue }
            guard let type = info[kIOPSTypeKey as String] as? String,
                  type == kIOPSInternalBatteryType else { continue }

            let current = info[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let maxCap = info[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let psState = info[kIOPSPowerSourceStateKey as String] as? String ?? ""
            let onBattery = psState == kIOPSBatteryPowerValue

            let pct = maxCap > 0 ? Double(current) / Double(maxCap) * 100 : 0
            return State(percentage: pct, onBattery: onBattery)
        }
        return nil
    }
}
