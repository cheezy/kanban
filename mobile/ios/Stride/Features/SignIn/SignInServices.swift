import StrideKit

/// What signing in needs. The app gives the real ones, and previews and tests
/// give stubs and the fixtures.
struct SignInServices {
    let store: any SignInStoring
    let api: any StrideAPI
    let keyMaker: any ApprovalKeyMaking
    let device: DeviceDetails
}
