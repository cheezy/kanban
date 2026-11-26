import HTTPTypes

@testable import StrideKit

/// What `FakeServer` answers a request with.
struct ServerAnswer {
    let status: HTTPResponse.Status
    let json: String?

    init(_ status: HTTPResponse.Status, _ json: String? = nil) {
        self.status = status
        self.json = json
    }

    var response: HTTPResponse {
        HTTPResponse(
            status: status,
            headerFields: [.contentType: "application/json", .cacheControl: "no-store"]
        )
    }

    /// The success answer to `listMyBoards`.
    static let boards = ServerAnswer(.ok, #"{"data": []}"#)

    /// The success answer to `updateCurrentDevice`.
    static let device = ServerAnswer(
        .ok,
        """
        {"data": {"id": 1, "name": "EXAMPLE", "platform": "ios", "device_class": "phone", "model": null,
         "os_version": null, "app_version": null, "last_seen_at": null, "signed_in_at": "2026-11-02T08:15:00Z",
         "current": true, "locale": "fr", "time_zone": null, "push_environment": null, "push_registered": false}}
        """
    )

    static let unauthorized = ServerAnswer(.unauthorized, #"{"error": "Invalid access token"}"#)

    static func tokens(_ pair: TokenPair) -> ServerAnswer {
        ServerAnswer(
            .ok,
            """
            {"access_token": "\(pair.accessToken)", "token_type": "Bearer", "expires_in": 3600,
             "refresh_token": "\(pair.refreshToken)"}
            """
        )
    }

    static func oauthError(_ error: String, status: HTTPResponse.Status = .badRequest) -> ServerAnswer {
        ServerAnswer(status, #"{"error": "\#(error)", "error_description": "EXAMPLE"}"#)
    }

    static func updateRequired(storeURL: String) -> ServerAnswer {
        ServerAnswer(.upgradeRequired, #"{"error": "app_update_required", "store_url": "\#(storeURL)"}"#)
    }
}
