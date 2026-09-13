import AdrafinilShared
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

@MainActor
final class LeaseDeviceMonitor {
    private let lid = LidStateMonitor()
    private let battery = BatteryMonitor()
    private let power = SystemPowerMonitor()
    private let smc = SMCReader()
    private var thermalObservation: NSObjectProtocol?
    var onChange: (() -> Void)?
    var onWake: (() -> Void)?

    init() {
        battery.enabled = false
        battery.onReading = { [weak self] _, _ in self?.onChange?() }
        lid.onChange = { [weak self] _ in self?.onChange?() }
        power.onWake = { [weak self] in
            self?.smc.close()
            self?.onWake?()
        }
        thermalObservation = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onChange?() }
        }
        battery.start()
    }

    func sample(includeTemperature: Bool) -> LeaseSafety {
        let reading = BatteryMonitor.read()
        let thermal: LeaseThermalState = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
        return LeaseSafety(lidClosed: lid.readCurrentState(), externalDisplayConnected: Self.externalDisplayConnected(), batteryPercent: reading?.percent, onBattery: reading?.onBattery, temperatureCelsius: includeTemperature ? smc.readCPUTemperature() : nil, thermalState: thermal)
    }

    static func externalDisplayConnected() -> Bool? {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success, count < 16 else { return nil }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    static func otherAssertionsPermitSleep() -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&unmanaged) == kIOReturnSuccess,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else { return false }
        return ["PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep"].allSatisfy { (dictionary[$0] as? NSNumber)?.intValue == 0 }
    }

    isolated deinit {
        if let thermalObservation { NotificationCenter.default.removeObserver(thermalObservation) }
    }
}
