import Foundation
import OpenAPIRuntime
import Testing

@testable import StrideKit

struct SignInErrorTests {
    private struct Other: Error {}

    @Test("keeps a sign-in error as it is")
    func passThrough() {
        for error in [SignInError.cancelled, .network, .passcodeNotSet, .failed] {
            #expect(SignInError(classifying: error) == error)
        }
    }

    @Test("a cancelled task or request cancels")
    func cancelled() {
        #expect(SignInError(classifying: CancellationError()) == .cancelled)
        #expect(SignInError(classifying: URLError(.cancelled)) == .cancelled)
    }

    @Test("any other transport error is a network error")
    func network() {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .networkConnectionLost] {
            #expect(SignInError(classifying: URLError(code)) == .network)
        }
    }

    @Test("reads the error a client error wraps")
    func clientError() {
        let wrapped = ClientError(
            operationID: Operations.OauthToken.id,
            operationInput: "EXAMPLE",
            causeDescription: "EXAMPLE",
            underlyingError: URLError(.timedOut)
        )

        #expect(SignInError(classifying: wrapped) == .network)
    }

    @Test("anything else fails")
    func other() {
        #expect(SignInError(classifying: Other()) == .failed)
        #expect(SignInError(classifying: APIClientError.signedOut) == .failed)
    }
}
