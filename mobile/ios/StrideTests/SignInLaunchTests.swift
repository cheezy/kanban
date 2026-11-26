import Foundation
import StrideKit
import Testing

@testable import Stride

@MainActor
struct SignInLaunchTests {
    @Test(
        "reads the stub sign-in from the launch arguments",
        arguments: [
            (["-StrideStubSignIn", "allow"], StubSignIn.allow),
            (["-StrideStubSignIn", "cancel"], .cancel),
            (["-AppleLanguages", "(de)", "-StrideStubSignIn", "locked"], .locked),
            (["-StrideStubSignIn", "offline"], .offline)
        ]
    )
    func stub(arguments: [String], expected: StubSignIn) {
        #expect(StubSignIn(arguments: arguments) == expected)
    }

    @Test(
        "no stub without the argument or its value",
        arguments: [[], ["-StrideStubSignIn"], ["-StrideStubSignIn", "other"], ["allow"]]
    )
    func noStub(arguments: [String]) {
        #expect(StubSignIn(arguments: arguments) == nil)
    }

    @Test("an app without its app group shows the Sign in screen, where every attempt fails")
    func noStore() async {
        let model = SignInModel.atLaunch(arguments: [], store: nil, api: nil)

        await model.observeSignIn()
        #expect(model.phase == .signedOut(nil))

        await model.signIn(using: StubWebAuthenticator(outcome: .allow))
        #expect(model.phase == .signedOut(.failed))
    }

    @Test(
        "each stub starts on the Sign in screen",
        arguments: [StubSignIn.allow, .cancel, .locked, .offline]
    )
    func stubStartsSignedOut(stub: StubSignIn) async {
        let model = SignInModel.atLaunch(arguments: ["-StrideStubSignIn", stub.rawValue], store: nil, api: nil)
        let task = Task { await model.observeSignIn() }
        defer { task.cancel() }

        for _ in 0..<2_000 where model.phase == .starting {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(model.phase == .signedOut(nil))
    }
}
