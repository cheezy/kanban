import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import StrideKit

@Suite(.timeLimit(.minutes(1)))
struct ReadRetryTests {
    private let device: SignedInDevice

    init() async throws {
        device = try await SignedInDevice()
    }

    @Test("repeats a read once when the server is restarting", arguments: [
        HTTPResponse.Status.badGateway, .serviceUnavailable, .gatewayTimeout
    ])
    func status(_ status: HTTPResponse.Status) async throws {
        let first = FirstTime()
        let server = FakeServer { _ in await first.isNow() ? ServerAnswer(status) : .boards }

        _ = try await device.api(server).listMyBoards().ok

        #expect(await server.requests.count == 2)
        #expect(await server.requests.allSatisfy { $0.authorization == ["Bearer EXAMPLE-access-1"] })
        #expect(await server.requests.allSatisfy { $0.versions == ["ios/1.0.0 (42)"] })
    }

    @Test("repeats a read once when the connection is refused or lost", arguments: [
        URLError.Code.networkConnectionLost, .cannotConnectToHost
    ])
    func lostConnection(code: URLError.Code) async throws {
        let first = FirstTime()
        let server = FakeServer { _ in
            if await first.isNow() { throw URLError(code) }
            return .boards
        }

        _ = try await device.api(server).listMyBoards().ok

        #expect(await server.requests.count == 2)
    }

    @Test("gives up after the second failure")
    func secondFailure() async throws {
        let server = FakeServer { _ in ServerAnswer(.serviceUnavailable) }

        _ = try await device.api(server).listMyBoards()

        #expect(await server.requests.count == 2)
    }

    @Test("does not repeat a read that cannot succeed", arguments: [
        URLError.Code.notConnectedToInternet, .cancelled, .timedOut, .secureConnectionFailed
    ])
    func otherErrors(code: URLError.Code) async throws {
        let server = FakeServer { _ in throw URLError(code) }

        await #expect(throws: ClientError.self) { try await device.api(server).listMyBoards() }

        #expect(await server.requests.count == 1)
    }

    @Test("does not repeat other answers", arguments: [
        HTTPResponse.Status.internalServerError, .tooManyRequests, .notFound
    ])
    func otherStatuses(_ status: HTTPResponse.Status) async throws {
        let server = FakeServer { _ in ServerAnswer(status, #"{"error": "EXAMPLE"}"#) }

        _ = try? await device.api(server).listMyBoards()

        #expect(await server.requests.count == 1)
    }

    @Test("never repeats a write")
    func write() async throws {
        let failing = FakeServer { _ in ServerAnswer(.serviceUnavailable) }
        let lost = FakeServer { _ in throw URLError(.networkConnectionLost) }

        for server in [failing, lost] {
            _ = try? await device.api(server).updateCurrentDevice(body: .json(.init(locale: "fr")))

            #expect(await server.requests.count == 1)
        }
    }

    @Test("does not repeat a read that was cancelled during the pause")
    func cancelled() async throws {
        let answered = Gate()
        let server = FakeServer { _ in
            await answered.open()
            return ServerAnswer(.serviceUnavailable)
        }
        let api = device.api(server, readRetryDelay: .seconds(3600))

        let call = Task { try await api.listMyBoards() }
        await answered.wait()
        call.cancel()

        await #expect(throws: (any Error).self) { try await call.value }
        #expect(await server.requests.count == 1)
    }
}
