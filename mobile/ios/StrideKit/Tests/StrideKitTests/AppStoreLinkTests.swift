import Foundation
import Testing

@testable import StrideKit

struct AppStoreLinkTests {
    @Test("takes the page the server names", arguments: [
        "https://apps.apple.com/app/stride",
        "https://apps.apple.com/ca/app/stride/id123?mt=8",
        "https://testflight.apple.com/join/EXAMPLE"
    ])
    func named(address: String) {
        #expect(AppStoreLink.url(in: answer(address)).absoluteString == address)
    }

    @Test("takes only a page of Apple's, over HTTPS", arguments: [
        "http://apps.apple.com/app/stride",
        "https://stride.example/app",
        "https://apps.apple.com.stride.example/app",
        "https://stride.example#apps.apple.com",
        "https://apps.apple.com@stride.example/app",
        "https://user:word@apps.apple.com/app",
        "https://apps.apple.com:8443/app",
        "itms-apps://apps.apple.com/app/stride",
        "javascript:alert(1)",
        "tel:911",
        "/app/stride",
        ""
    ])
    func refused(address: String) {
        #expect(AppStoreLink.url(in: answer(address)) == AppStoreLink.fallback)
    }

    @Test("has a page of its own for an answer it cannot read", arguments: [
        nil, Data(), Data("{}".utf8), Data("<html>".utf8)
    ])
    func unreadable(answer: Data?) {
        #expect(AppStoreLink.url(in: answer).absoluteString == "https://apps.apple.com/app/stride")
    }

    private func answer(_ address: String) -> Data {
        Data(#"{"error": "app_update_required", "store_url": "\#(address)"}"#.utf8)
    }
}
