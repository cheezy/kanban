import Foundation
import OpenAPIRuntime

extension ClientError {
    /// Why the server could not be reached, or nil when that is not the reason.
    var urlErrorCode: URLError.Code? {
        (underlyingError as? URLError)?.code
    }
}
