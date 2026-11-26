import StrideKit

/// What signing in needs. The app gives the real ones, and previews and tests
/// give stubs and the fixtures.
struct SignInServices {
    let store: any SignInStoring
    let api: any StrideAPI
    let keyMaker: any ApprovalKeyMaking
    let device: DeviceDetails
    /// Wiped whenever the device is signed out, so nothing of the person stays.
    var cache: (any CacheWiping)? = nil
}
