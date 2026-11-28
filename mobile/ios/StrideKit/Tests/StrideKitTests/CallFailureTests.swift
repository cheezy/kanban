import Foundation
import OpenAPIRuntime
import Testing

@testable import StrideKit

/// Whether a failed call may have reached the server, which decides whether an
/// approval is sent a second time.
struct CallFailureTests {
    private struct Other: Error {}

    private static func wrapped(_ error: any Error) -> ClientError {
        ClientError(
            operationID: Operations.ApproveMyReview.id,
            operationInput: "EXAMPLE",
            causeDescription: "EXAMPLE",
            underlyingError: error
        )
    }

    @Test(
        "a transport failure, bare or wrapped by the client, is one",
        arguments: [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost]
    )
    func transport(code: URLError.Code) {
        #expect(CallFailure.isTransport(URLError(code)))
        #expect(CallFailure.isTransport(Self.wrapped(URLError(code))))
    }

    @Test(
        "an ended sign-in, a refused refresh, an unreadable answer or a cancel is not one",
        arguments: [
            APIClientError.signedOut as any Error,
            APIClientError.refreshUnavailable,
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "EXAMPLE")),
            CancellationError(),
            Other(),
        ]
    )
    func notTransport(error: any Error) {
        #expect(CallFailure.isTransport(error) == false)
        #expect(CallFailure.isTransport(Self.wrapped(error)) == false)
    }
}
