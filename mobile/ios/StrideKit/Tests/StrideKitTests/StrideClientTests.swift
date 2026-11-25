import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import StrideKit

struct StrideClientTests {
    @Test("sends every request to the Stride server over HTTPS")
    func serverURL() async throws {
        let transport = RecordingTransport()

        _ = try? await StrideClient.make(transport: transport).getMe()

        #expect(await transport.baseURLs == [URL(string: "https://www.stridelikeaboss.com")])
    }

    @Test(
        "refuses to send a request to another server",
        arguments: [
            "https://stride.example",
            "http://www.stridelikeaboss.com",
            "https://www.stridelikeaboss.com.example",
            "https://www.stridelikeaboss.com:8443",
            "https://user@www.stridelikeaboss.com",
            "https://www.stridelikeaboss.com/elsewhere",
            "http://localhost:4000",
            "/"
        ]
    )
    func otherServer(address: String) async throws {
        let transport = RecordingTransport()
        let url = try #require(URL(string: address))
        let api = StrideClient.make(transport: transport, middlewares: [BaseURLMiddleware(url: url)])

        await #expect { try await api.getMe() } throws: { error in
            (error as? ClientError)?.underlyingError is UnexpectedServerError
        }
        #expect(await transport.baseURLs.isEmpty)
    }

    @Test("follows no redirect")
    func redirect() async throws {
        let url = StrideClient.serverURL
        let session = StrideClient.makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? RedirectRefuser)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)
        )

        let next = await delegate.urlSession(
            session,
            task: session.dataTask(with: url),
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://stride.example")!)
        )

        #expect(next == nil)
    }

    @Test("the real transport keeps no cookies and no cached responses, and refuses redirects")
    func session() {
        let session = StrideClient.makeTransport().configuration.session
        defer { session.invalidateAndCancel() }

        #expect(session.delegate is RedirectRefuser)
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.httpCookieStorage == nil)
    }
}
