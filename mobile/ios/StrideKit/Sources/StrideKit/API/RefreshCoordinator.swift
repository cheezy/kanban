import Foundation
import OpenAPIRuntime

/// Gives requests the pair to send, and replaces one the server refused.
///
/// The server revokes the device when a refresh token is used twice. So however
/// many requests ask at once, a refused token is refreshed once, the refresh is not
/// retried, and a new pair the Keychain does not take is kept to be stored later.
/// When the answer to a refresh is lost, the sign-in ends at the next one.
actor RefreshCoordinator {
    private let store: AuthStore
    private let api: any StrideAPI
    private let now: @Sendable () -> Date

    /// The refreshes that are under way, by the access token they replace.
    private var refreshes: [String: Task<AuthSession, any Error>] = [:]

    /// A new pair that is not stored yet, and the pair it replaces.
    private var unsaved: (replaced: TokenPair, pair: TokenPair)?

    /// `api` must not use this coordinator itself.
    init(store: AuthStore, api: any StrideAPI, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.api = api
        self.now = now
    }

    /// The session to send a request with.
    func session() async throws -> AuthSession {
        guard let session = try await store.session() else { throw APIClientError.signedOut }

        return session
    }

    /// The session to repeat a request with, after the server refused the access
    /// token of `refused`. Throws `signedOut` when the server refuses to refresh it,
    /// or when that sign-in has ended, even if there is another one since. Without
    /// an answer to use it throws `refreshUnavailable` or a `URLError`.
    func session(replacing refused: AuthSession) async throws -> AuthSession {
        let token = refused.pair.accessToken
        // Nothing is awaited between this and storing the new task, so a token
        // never gets two.
        if let refresh = refreshes[token] { return try await refresh.value }

        // Not a child task, so cancelling the request that started it does not
        // cancel it: the others wait for it, and its answer must be stored.
        let refresh = Task {
            defer { refreshes[token] = nil }
            return try await replace(refused)
        }
        refreshes[token] = refresh

        return try await refresh.value
    }

    private func replace(_ refused: AuthSession) async throws -> AuthSession {
        let current = try await session(ofSameSignInAs: refused)
        guard current.pair == refused.pair else { return current }

        do {
            guard let pair = try await newPair(for: current.pair) else {
                try await store.clear(refused: current.pair)
                throw APIClientError.signedOut
            }
            try await store.rotate(from: current.pair, to: pair)
        } catch AuthStoreError.superseded {
            // A sign-out or a sign-in came first.
        }
        if unsaved?.replaced == current.pair { unsaved = nil }

        return try await session(ofSameSignInAs: refused)
    }

    private func session(ofSameSignInAs other: AuthSession) async throws -> AuthSession {
        let session = try await session()
        guard session.signIn == other.signIn else { throw APIClientError.signedOut }

        return session
    }

    /// The pair to store in place of `pair`, or nil when the server refuses to give
    /// one.
    private func newPair(for pair: TokenPair) async throws -> TokenPair? {
        if let unsaved, unsaved.replaced == pair { return unsaved.pair }
        guard let newPair = try await refresh(pair) else { return nil }

        unsaved = (pair, newPair)
        return newPair
    }

    /// The new pair, or nil when the server refuses to give one.
    ///
    /// Its errors hold no part of the request or the answer, which have tokens.
    private func refresh(_ pair: TokenPair) async throws -> TokenPair? {
        switch try await send(pair.refreshToken) {
        case .ok(let response):
            guard let tokens = try? response.body.json else { throw APIClientError.refreshUnavailable }

            return TokenPair(
                accessToken: tokens.accessToken,
                accessTokenExpiresAt: now().addingTimeInterval(TimeInterval(tokens.expiresIn)),
                refreshToken: tokens.refreshToken
            )
        case .badRequest(let response) where (try? response.body.json.error.value1) == .invalidGrant:
            return nil
        case .badRequest, .notAcceptable, .tooManyRequests, .undocumented:
            throw APIClientError.refreshUnavailable
        }
    }

    private func send(_ refreshToken: String) async throws -> Operations.OauthToken.Output {
        do {
            return try await api.oauthToken(
                body: .json(.init(grantType: .refreshToken, clientId: .strideIos, refreshToken: refreshToken))
            )
        } catch {
            guard let code = (error as? ClientError)?.urlErrorCode else {
                throw APIClientError.refreshUnavailable
            }
            throw URLError(code)
        }
    }
}
