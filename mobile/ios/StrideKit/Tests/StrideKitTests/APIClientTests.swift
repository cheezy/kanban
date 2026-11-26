import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import StrideKit

@Suite(.timeLimit(.minutes(1)))
struct APIClientTests {
    private let device: SignedInDevice

    init() async throws {
        device = try await SignedInDevice()
    }

    // MARK: The version header

    @Test("adds the version and platform headers")
    func versionHeader() async throws {
        let server = FakeServer { _ in ServerAnswer(.internalServerError) }
        let api = device.api(server, version: "1.2.3", build: "42")

        for call in FixtureOperations.calls.values {
            _ = try? await call(api)
        }

        let operations = await Set(server.operations)
        #expect(operations == Set(FixtureOperations.calls.keys))
        for request in await server.requests {
            #expect(request.versions == ["ios/1.2.3 (42)"], "\(request.operationID)")
        }
    }

    @Test("sends one version header when the caller passed another")
    func versionHeaderPassed() async throws {
        let server = FakeServer { _ in .boards }

        _ = try await device.api(server).listMyBoards(headers: .init(xStrideApp: "ios/9.9.9"))

        #expect(await server.requests.map(\.versions) == [["ios/1.0.0 (42)"]])
    }

    // MARK: Refreshing

    @Test("refreshes once on 401 and retries")
    func refresh() async throws {
        let server = FakeServer { $0.answer(accepting: .example(2)) }

        let response = try await device.api(server).listMyBoards()

        #expect(try response.ok.body.json.data.isEmpty)
        #expect(await server.operations == [
            Operations.ListMyBoards.id, Operations.OauthToken.id, Operations.ListMyBoards.id
        ])
        #expect(await server.requests.map(\.authorization) == [
            ["Bearer EXAMPLE-access-1"], [], ["Bearer EXAMPLE-access-2"]
        ])
        #expect(try await device.store.read() == TokenPair(
            accessToken: "EXAMPLE-access-2",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_800_003_600),
            refreshToken: "EXAMPLE-refresh-2"
        ))
    }

    @Test("sends the refresh token in the body of the refresh and nowhere else")
    func refreshToken() async throws {
        let server = FakeServer { $0.answer(accepting: .example(2)) }

        _ = try await device.api(server).listMyBoards()

        for request in await server.requests {
            #expect(request.head.contains("EXAMPLE-refresh") == false)
            #expect(request.request.path?.contains("EXAMPLE") == false)
        }
        let refresh = try #require(await server.requests.dropFirst().first)
        #expect(refresh.request.method == .post)
        #expect(refresh.request.path == "/oauth/token")
        #expect(refresh.versions == ["ios/1.0.0 (42)"])
        #expect(try JSONDecoder().decode([String: String].self, from: refresh.body) == [
            "grant_type": "refresh_token", "client_id": "stride-ios", "refresh_token": "EXAMPLE-refresh-1"
        ])
        for request in await server.requests where request.operationID != Operations.OauthToken.id {
            #expect(request.body.isEmpty)
        }
    }

    @Test("repeats a write with the same body after the refresh")
    func refreshWrite() async throws {
        let server = FakeServer { request in
            request.authorization == ["Bearer EXAMPLE-access-2"] ? .device : request.answer(accepting: .example(2))
        }

        _ = try await device.api(server).updateCurrentDevice(body: .json(.init(locale: "fr"))).ok

        let writes = await server.requests.filter { $0.operationID == Operations.UpdateCurrentDevice.id }
        #expect(writes.count == 2)
        #expect(writes.first?.body.isEmpty == false)
        #expect(writes.first?.body == writes.last?.body)
    }

    @Test("a 401 after the refresh goes to the caller")
    func secondUnauthorized() async throws {
        let server = FakeServer { request in
            request.isRefresh ? .tokens(.example(2)) : .unauthorized
        }

        let response = try await device.api(server).listMyBoards()

        guard case .unauthorized = response else {
            Issue.record("the answer is not a 401")
            return
        }
        #expect(await server.operations == [
            Operations.ListMyBoards.id, Operations.OauthToken.id, Operations.ListMyBoards.id
        ])
        #expect(try await device.store.read()?.accessToken == "EXAMPLE-access-2")
    }

    @Test("uses the stored pair when it was refreshed while the request was under way")
    func refreshedMeanwhile() async throws {
        let store = device.store
        let server = FakeServer { request in
            if request.authorization == ["Bearer EXAMPLE-access-2"] { return .boards }
            try await store.rotate(from: .example(1), to: .example(2))
            return .unauthorized
        }

        _ = try await device.api(server).listMyBoards().ok

        #expect(await server.operations == [Operations.ListMyBoards.id, Operations.ListMyBoards.id])
    }

    @Test("parallel 401s share one refresh")
    func parallelRefresh() async throws {
        let refused = Barrier(count: 5)
        let server = FakeServer { request in
            if request.isRefresh {
                // Lets the other requests ask for a token before this answer.
                for _ in 0..<200 { await Task.yield() }
                return .tokens(.example(2))
            }
            if request.authorization == ["Bearer EXAMPLE-access-2"] { return .boards }
            await refused.arrive()
            return .unauthorized
        }
        let api = device.api(server)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await api.listMyBoards().ok }
            }
            try await group.waitForAll()
        }

        #expect(await server.operations.count { $0 == Operations.OauthToken.id } == 1)
        #expect(await server.operations.count { $0 == Operations.ListMyBoards.id } == 10)
    }

    @Test("cancelling the request that started a refresh does not lose the new pair")
    func cancelledRefresh() async throws {
        let started = Gate()
        let cancelled = Gate()
        let server = FakeServer { request in
            guard request.isRefresh else { return request.answer(accepting: .example(2)) }
            await started.open()
            await cancelled.wait()
            try Task.checkCancellation()
            return .tokens(.example(2))
        }
        let api = device.api(server)

        let call = Task { try await api.listMyBoards() }
        await started.wait()
        call.cancel()
        await cancelled.open()
        _ = await call.result

        #expect(try await device.store.read()?.accessToken == "EXAMPLE-access-2")
    }

    @Test("gets no token for the operations that take none", arguments: [
        Operations.OauthToken.id, Operations.OauthRevoke.id
    ])
    func withoutToken(operation: String) async throws {
        let server = FakeServer { _ in .unauthorized }
        let call = try #require(FixtureOperations.calls[operation])

        _ = try? await call(device.api(server))

        #expect(await server.operations == [operation])
        #expect(await server.requests.map(\.authorization) == [[]])
    }

    // MARK: Signing out

    @Test("a failed refresh signs the app out")
    func refusedRefresh() async throws {
        let server = FakeServer { $0.isRefresh ? .oauthError("invalid_grant") : .unauthorized }
        var signedIn = try await device.store.signedIn().makeAsyncIterator()
        #expect(await signedIn.next() == true)

        await #expect(throws: APIClientError.signedOut) {
            try await reason { try await device.api(server).listMyBoards() }
        }

        #expect(await signedIn.next() == false)
        #expect(device.keychain.items.isEmpty)
        #expect(await server.operations == [Operations.ListMyBoards.id, Operations.OauthToken.id])
    }

    @Test("a refresh token that was used before signs the app out")
    func reusedRefreshToken() async throws {
        let lost = URLError(.networkConnectionLost)
        let server = FakeServer { request in
            guard request.isRefresh else { return request.answer(accepting: .example(2)) }
            throw lost
        }
        // The server rotated the pair, and its answer never arrived.
        _ = try? await device.api(server).listMyBoards()

        let next = FakeServer { $0.isRefresh ? .oauthError("invalid_grant") : .unauthorized }
        await #expect(throws: APIClientError.signedOut) {
            try await reason { try await device.api(next).listMyBoards() }
        }

        #expect(device.keychain.items.isEmpty)
    }

    @Test("sends nothing while signed out")
    func signedOut() async throws {
        let server = FakeServer { _ in .boards }
        try await device.store.clear()

        await #expect(throws: APIClientError.signedOut) {
            try await reason { try await device.api(server).listMyBoards() }
        }

        #expect(await server.requests.isEmpty)
    }

    @Test("a sign-out during the refresh stays signed out")
    func signOutDuringRefresh() async throws {
        let store = device.store
        let server = FakeServer { request in
            guard request.isRefresh else { return .unauthorized }
            try await store.clear()
            return .tokens(.example(2))
        }

        await #expect(throws: APIClientError.signedOut) {
            try await reason { try await device.api(server).listMyBoards() }
        }

        #expect(device.keychain.items.isEmpty)
    }

    @Test("a new sign-in during the refresh is kept, and does not send the request", arguments: [
        ServerAnswer.tokens(.example(2)), .oauthError("invalid_grant")
    ])
    func signInDuringRefresh(answer: ServerAnswer) async throws {
        let store = device.store
        let server = FakeServer { request in
            guard request.isRefresh else { return request.answer(accepting: .example(3)) }
            try await store.save(.example(3))
            return answer
        }

        await #expect(throws: APIClientError.signedOut) {
            try await reason { try await device.api(server).listMyBoards() }
        }

        #expect(try await store.read() == .example(3))
        #expect(await server.operations == [Operations.ListMyBoards.id, Operations.OauthToken.id])
    }

    @Test("a request is not repeated for the next person who signs in")
    func signInDuringRequest() async throws {
        let store = device.store
        let server = FakeServer { request in
            if request.authorization == ["Bearer EXAMPLE-access-3"] { return .boards }
            try await store.clear()
            try await store.save(.example(3))
            return .unauthorized
        }

        await #expect(throws: APIClientError.signedOut) {
            try await reason { try await device.api(server).listMyBoards() }
        }

        #expect(await server.operations == [Operations.ListMyBoards.id])
        #expect(try await store.read() == .example(3))
    }

    @Test("a pair the Keychain does not delete is reported, not called signed out")
    func refusedRefreshNotCleared() async throws {
        let server = FakeServer { $0.isRefresh ? .oauthError("invalid_grant") : .unauthorized }
        device.keychain.fail(.delete, with: errSecInteractionNotAllowed)

        await #expect(throws: AuthStoreError.keychain(errSecInteractionNotAllowed)) {
            try await reason { try await device.api(server).listMyBoards() }
        }
    }

    @Test("a new pair the Keychain does not take is stored later, without another refresh")
    func newPairNotStored() async throws {
        let server = FakeServer { $0.answer(accepting: .example(2)) }
        let api = device.api(server)
        device.keychain.fail(.update, with: errSecInteractionNotAllowed)

        for _ in 0..<2 {
            await #expect(throws: AuthStoreError.keychain(errSecInteractionNotAllowed)) {
                try await reason { try await api.listMyBoards() }
            }
        }
        device.keychain.recover()
        _ = try await api.listMyBoards().ok

        #expect(try await device.store.read()?.accessToken == "EXAMPLE-access-2")
        #expect(await server.operations.count { $0 == Operations.OauthToken.id } == 1)
    }

    @Test("a pair that was not stored is not used for the next sign-in")
    func newPairNotStoredThenSignIn() async throws {
        let server = FakeServer { request in
            if request.authorization == ["Bearer EXAMPLE-access-4"] { return .boards }
            guard request.isRefresh else { return .unauthorized }
            let isNext = String(decoding: request.body, as: UTF8.self).contains("EXAMPLE-refresh-3")
            return .tokens(.example(isNext ? 4 : 2))
        }
        let api = device.api(server)
        device.keychain.fail(.update, with: errSecInteractionNotAllowed)
        _ = try? await api.listMyBoards()
        device.keychain.recover()

        try await device.store.save(.example(3))
        _ = try await api.listMyBoards().ok

        #expect(try await device.store.read()?.accessToken == "EXAMPLE-access-4")
    }

    @Test("a locked Keychain is not called signed out, and sends nothing")
    func lockedKeychain() async throws {
        let server = FakeServer { _ in .boards }
        device.keychain.fail(.copyData, with: errSecInteractionNotAllowed)

        await #expect(throws: AuthStoreError.keychain(errSecInteractionNotAllowed)) {
            try await reason { try await device.api(server).listMyBoards() }
        }

        #expect(await server.requests.isEmpty)
    }

    // MARK: A refresh without an answer

    @Test("an answer that is no refusal keeps the app signed in", arguments: [
        ServerAnswer.oauthError("invalid_request"),
        .oauthError("invalid_client"),
        .oauthError("unsupported_grant_type"),
        .oauthError("a_new_error"),
        .oauthError("rate_limited", status: .tooManyRequests),
        .oauthError("invalid_grant", status: .unauthorized),
        ServerAnswer(.badRequest, "not JSON"),
        ServerAnswer(.notAcceptable),
        ServerAnswer(.internalServerError),
        ServerAnswer(.serviceUnavailable),
        ServerAnswer(.ok, #"{"access_token": "EXAMPLE-access-2"}"#)
    ])
    func temporaryFailure(answer: ServerAnswer) async throws {
        let server = FakeServer { $0.isRefresh ? answer : .unauthorized }

        await #expect(throws: APIClientError.refreshUnavailable) {
            try await reason { try await device.api(server).listMyBoards() }
        }

        #expect(try await device.store.read() == .example(1))
        #expect(await server.operations == [Operations.ListMyBoards.id, Operations.OauthToken.id])
    }

    @Test("a refresh that cannot reach the server is sent once and keeps the app signed in", arguments: [
        URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost
    ])
    func offlineRefresh(code: URLError.Code) async throws {
        let server = FakeServer { request in
            if request.isRefresh { throw URLError(code) }
            return .unauthorized
        }

        await #expect(throws: URLError(code)) {
            try await reason { try await device.api(server).listMyBoards() }
        }

        #expect(try await device.store.read() == .example(1))
        #expect(await server.operations == [Operations.ListMyBoards.id, Operations.OauthToken.id])
    }

    @Test("refreshes again for the next request after a failure")
    func refreshAfterFailure() async throws {
        let offline = URLError(.notConnectedToInternet)
        let failing = Gate()
        let server = FakeServer { request in
            if request.isRefresh, await failing.isOpen == false { throw offline }
            return request.answer(accepting: .example(2))
        }
        let api = device.api(server)

        _ = try? await api.listMyBoards()
        await failing.open()
        _ = try await api.listMyBoards().ok

        #expect(await server.operations.count { $0 == Operations.OauthToken.id } == 2)
    }

    @Test("no error holds a token", arguments: [
        ServerAnswer.oauthError("invalid_grant"),
        ServerAnswer(.internalServerError),
        ServerAnswer(.ok, #"{"access_token": "EXAMPLE-access-2"}"#),
        nil
    ])
    func redactedErrors(answer: ServerAnswer?) async throws {
        let server = FakeServer { request in
            guard request.isRefresh else { return .unauthorized }
            guard let answer else {
                throw URLError(.timedOut, userInfo: ["EXAMPLE": "EXAMPLE-refresh-1"])
            }
            return answer
        }

        do {
            _ = try await device.api(server).listMyBoards()
            Issue.record("the call did not fail")
        } catch {
            var dumped = ""
            dump(error, to: &dumped)
            #expect("\(error)\(dumped)".contains("EXAMPLE") == false)
        }
    }

    // MARK: Other answers

    @Test("an answer that does not refuse the token is not refreshed", arguments: [
        HTTPResponse.Status.forbidden, .notFound, .tooManyRequests, .internalServerError
    ])
    func otherAnswers(status: HTTPResponse.Status) async throws {
        let server = FakeServer { _ in ServerAnswer(status, #"{"error": "EXAMPLE"}"#) }

        _ = try? await device.api(server).listMyBoards()

        #expect(await server.operations == [Operations.ListMyBoards.id])
        #expect(try await device.store.read() == .example(1))
    }

    // MARK: An outdated app

    @Test("426 switches to update required")
    func updateRequired() async throws {
        let server = FakeServer { _ in .updateRequired(storeURL: "https://apps.apple.com/app/id1") }
        #expect(await device.update.storeURL == nil)

        let response = try await device.api(server).listMyBoards()

        #expect(try response.upgradeRequired.body.json.storeUrl == "https://apps.apple.com/app/id1")
        #expect(await device.update.storeURL?.absoluteString == "https://apps.apple.com/app/id1")
        #expect(await server.operations == [Operations.ListMyBoards.id])
        #expect(try await device.store.read() == .example(1))
    }

    @Test("426 after a refresh switches to update required")
    func updateRequiredAfterRefresh() async throws {
        let server = FakeServer { request in
            if request.isRefresh { return .tokens(.example(2)) }
            if request.authorization == ["Bearer EXAMPLE-access-1"] { return .unauthorized }
            return .updateRequired(storeURL: "https://apps.apple.com/app/id1")
        }

        _ = try await device.api(server).listMyBoards().upgradeRequired

        #expect(await device.update.storeURL?.absoluteString == "https://apps.apple.com/app/id1")
    }

    @Test("426 to the refresh switches to update required and keeps the app signed in")
    func updateRequiredByRefresh() async throws {
        let server = FakeServer { request in
            request.isRefresh ? .updateRequired(storeURL: "https://apps.apple.com/app/id1") : .unauthorized
        }

        await #expect(throws: APIClientError.refreshUnavailable) {
            try await reason { try await device.api(server).listMyBoards() }
        }

        #expect(await device.update.storeURL?.absoluteString == "https://apps.apple.com/app/id1")
        #expect(try await device.store.read() == .example(1))
    }

    @Test("a 426 without a page Apple serves offers the app's own page", arguments: [
        ServerAnswer.updateRequired(storeURL: "https://stride.example/app"),
        ServerAnswer(.upgradeRequired, "not JSON"),
        .updateRequired(storeURL: "https://apps.apple.com/app/id1?" + String(repeating: "a", count: 16 * 1024)),
        ServerAnswer(.upgradeRequired)
    ])
    func updateRequiredElsewhere(answer: ServerAnswer) async throws {
        let server = FakeServer { _ in answer }

        _ = try? await device.api(server).listMyBoards()

        #expect(await device.update.storeURL == AppStoreLink.fallback)
    }

    @Test("other answers leave the app in use", arguments: [
        ServerAnswer.boards, .unauthorized, ServerAnswer(.serviceUnavailable)
    ])
    func noUpdateRequired(answer: ServerAnswer) async throws {
        let server = FakeServer { _ in answer }

        _ = try? await device.api(server).listMyBoards()

        #expect(await device.update.storeURL == nil)
    }

    /// The error under the `ClientError` a call throws.
    private func reason<Output>(_ call: () async throws -> Output) async throws {
        do {
            _ = try await call()
        } catch let error as ClientError {
            throw error.underlyingError
        }
    }
}
