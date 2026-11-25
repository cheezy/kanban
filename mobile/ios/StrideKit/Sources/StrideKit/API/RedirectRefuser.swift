import Foundation

/// Keeps a request on the server it was made for. The API never redirects, and
/// following one would send the request's tokens to the host it names.
final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
