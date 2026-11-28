import Foundation
import OpenAPIRuntime

extension ClientError {
    /// Why the server could not be reached, or nil when that is not the reason.
    var urlErrorCode: URLError.Code? {
        (underlyingError as? URLError)?.code
    }
}

/// Reads why a call failed without the app naming OpenAPIRuntime.
public enum CallFailure {
    /// Whether `error`, thrown by a call, is a transport failure, after which
    /// the request may or may not have reached the server. An ended sign-in, a
    /// refused refresh or an answer that could not be read is not one.
    public static func isTransport(_ error: any Error) -> Bool {
        ((error as? ClientError)?.underlyingError ?? error) is URLError
    }
}
