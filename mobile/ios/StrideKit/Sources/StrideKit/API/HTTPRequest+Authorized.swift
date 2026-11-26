import HTTPTypes

extension HTTPRequest {
    func authorized(by session: AuthSession) -> HTTPRequest {
        var request = self
        request.headerFields[.authorization] = "Bearer \(session.pair.accessToken)"
        return request
    }
}
