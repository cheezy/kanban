import Foundation
import Testing

@testable import StrideKit

struct StrideWebTests {
    @Test("a page on the Stride server over https is a Stride page")
    func stridePage() throws {
        let page = try #require(URL(string: "https://www.stridelikeaboss.com/boards/12/tasks/4812"))

        #expect(StrideWeb.isStridePage(page))
        #expect(StrideWeb.isStridePage(StrideWeb.pricing))
    }

    @Test("the web review selects the task on the Stride server")
    func review() throws {
        let url = StrideWeb.review(taskID: 4812)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(StrideWeb.isStridePage(url))
        #expect(components.path == "/review")
        #expect(components.queryItems == [URLQueryItem(name: "task", value: "4812")])
    }

    @Test(
        "any other address is not",
        arguments: [
            "http://www.stridelikeaboss.com/boards/12",
            "https://stride.example/boards/12",
            "https://www.stridelikeaboss.com.evil.example/boards/12",
            "https://evil.example/?u=https://www.stridelikeaboss.com",
            "https://user:secret@www.stridelikeaboss.com/boards/12",
            "https://www.stridelikeaboss.com:8443/boards/12",
            "javascript:alert(1)",
            "https://",
        ]
    )
    func otherAddresses(address: String) throws {
        let url = try #require(URL(string: address))

        #expect(StrideWeb.isStridePage(url) == false)
    }
}
