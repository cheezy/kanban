import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// Makes the client that talks to the Stride server.
public enum StrideClient {
    /// The only server the client talks to.
    static let serverURL = URL(string: "https://www.stridelikeaboss.com")!

    static let configuration = Configuration(dateTranscoder: StrideDateTranscoder())

    /// Takes no base URL, so a caller cannot point the client anywhere else.
    public static func make(middlewares: [any ClientMiddleware] = []) -> some StrideAPI {
        make(transport: makeTransport(), middlewares: middlewares)
    }

    static func make(
        transport: any ClientTransport,
        middlewares: [any ClientMiddleware] = []
    ) -> some StrideAPI {
        Client(
            serverURL: serverURL,
            configuration: configuration,
            transport: StrideTransport(next: transport),
            middlewares: middlewares
        )
    }

    static func makeTransport() -> URLSessionTransport {
        URLSessionTransport(
            configuration: .init(session: makeSession(), httpBodyProcessingMode: .buffered)
        )
    }

    /// Keeps no cookies and no cached responses, and follows no redirects.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }
}
