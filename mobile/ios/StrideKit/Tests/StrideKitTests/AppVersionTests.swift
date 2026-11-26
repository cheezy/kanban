import Testing

@testable import StrideKit

struct AppVersionTests {
    @Test("formats the header the server reads", arguments: [
        ("1.0.0", "42", "ios/1.0.0 (42)"),
        ("0.0.0", "0", "ios/0.0.0 (0)"),
        ("9999.9999.9999", "999999999", "ios/9999.9999.9999 (999999999)")
    ])
    func header(version: String, build: String, header: String) {
        #expect(AppVersion(version: version, build: build)?.headerValue == header)
    }

    @Test("refuses a version or build the server could not read", arguments: [
        ("1.0", "42"), ("1", "42"), ("1.0.0.0", "42"), ("10000.0.0", "42"), ("1.0.0-beta", "42"),
        ("١.0.0", "42"), ("", "42"), ("1.0.0\r\nX-Other: 1", "42"),
        ("1.0.0", ""), ("1.0.0", "1.2"), ("1.0.0", "1234567890"), ("1.0.0", "42) x"), ("1.0.0", "٤٢")
    ])
    func refused(version: String, build: String) {
        #expect(AppVersion(version: version, build: build) == nil)
    }
}
