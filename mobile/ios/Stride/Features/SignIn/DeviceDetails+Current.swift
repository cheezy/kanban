import Foundation
import StrideKit
import UIKit

extension DeviceDetails {
    /// This device, as the server records it at sign-in.
    @MainActor
    static func current(bundle: Bundle = .main) -> DeviceDetails {
        let device = UIDevice.current

        return DeviceDetails(
            name: device.name,
            deviceClass: device.userInterfaceIdiom == .pad ? .tablet : .phone,
            model: modelIdentifier(),
            osVersion: device.systemVersion,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            // The app's own language, so the server writes to the person in it.
            locale: bundle.preferredLocalizations.first,
            timeZone: TimeZone.current.identifier
        )
    }

    /// Such as `iPhone17,1`: the hardware, where `UIDevice.model` says only
    /// "iPhone".
    private static func modelIdentifier() -> String? {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return model }
        #endif
        var system = utsname()
        guard uname(&system) == 0 else { return nil }

        let machine = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? nil : machine
    }
}
