import AuthenticationServices
import Foundation
import Observation
import StrideKit
import SwiftUI

/// Signs the device in through the web, and follows whether it is signed in and
/// whether the person's plan includes the app.
@MainActor
@Observable
final class SignInModel {
    private(set) var phase: SignInPhase

    /// What the person will approve with, which the first point names.
    let unlock: ApprovalUnlock

    @ObservationIgnored private let services: SignInServices?
    @ObservationIgnored private let authenticatorOverride: (any WebAuthenticating)?
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var signedOutDuringSignIn = false

    /// With no services, as when the app lacks its app group, the screen shows
    /// and every attempt fails.
    init(
        services: SignInServices?,
        unlock: ApprovalUnlock = .current(),
        phase: SignInPhase = .starting,
        authenticator: (any WebAuthenticating)? = nil,
        retryDelay: Duration = .seconds(2)
    ) {
        self.services = services
        self.unlock = unlock
        self.phase = phase
        self.authenticatorOverride = authenticator
        self.retryDelay = retryDelay
    }

    // MARK: What the screen shows

    var isSigningIn: Bool { phase == .signingIn }

    var reviewPoint: LocalizedStringResource {
        switch unlock {
        case .faceID: .signInPointReviewFaceId
        case .touchID: .signInPointReviewTouchId
        case .passcode: .signInPointReviewPasscode
        }
    }

    var problem: LocalizedStringResource? {
        guard case .signedOut(let error?) = phase else { return nil }

        switch error {
        case .network: return .signInNetworkError
        case .passcodeNotSet: return .signInPasscodeRequired
        case .failed, .cancelled: return .signInFailed
        }
    }

    // MARK: What the screen does

    /// Follows the stored sign-in for as long as the calling task runs. Before
    /// the first unlock after a restart the Keychain refuses, so it asks again.
    func observeSignIn() async {
        guard let store = services?.store else {
            if phase == .starting { phase = .signedOut(nil) }
            return
        }

        var changes: AsyncStream<Bool>?
        while changes == nil, Task.isCancelled == false {
            do {
                changes = try await store.signedIn()
            } catch {
                try? await Task.sleep(for: retryDelay)
            }
        }
        guard let changes else { return }

        for await isSignedIn in changes {
            // A sign-out, a revoked device, or a launch that starts signed out
            // after one. A failed wipe is tried again at the next of these.
            if isSignedIn == false { try? await services?.cache?.wipe() }
            await show(signedIn: isSignedIn)
        }
    }

    /// Signs in through the system's browser window, or through the debug stub.
    func signIn(through session: WebAuthenticationSession) async {
        await signIn(using: authenticatorOverride ?? SystemWebAuthenticator(session: session))
    }

    func signIn(using web: any WebAuthenticating) async {
        guard case .signedOut = phase else { return }

        phase = .signingIn
        signedOutDuringSignIn = false
        do throws(SignInError) {
            guard let services else { throw .failed }

            try await OAuthSignIn.run(services, web: web)
        } catch {
            phase = .signedOut(error == .cancelled ? nil : error)
            return
        }

        // Signed in from here on, whatever the server says about the plan.
        guard let api = services?.api else { return }

        let access = await AppAccess.load(using: api)
        phase = signedOutDuringSignIn ? .signedOut(nil) : Self.phase(for: access)
    }

    /// Asks again whether the plan includes the app, when the last answer was
    /// no or none, so a person who joins an Organization on the web gets in.
    func recheckAccess() async {
        guard phase == .locked || phase == .signedIn(.unknown) else { return }

        await loadAccess(replacing: phase)
    }

    // MARK: Private

    private func show(signedIn isSignedIn: Bool) async {
        if phase == .signingIn {
            // The attempt's own save says true; only a sign-out matters.
            if isSignedIn == false { signedOutDuringSignIn = true }
            return
        }

        guard isSignedIn else {
            if case .signedOut = phase { return }
            phase = .signedOut(nil)
            return
        }

        switch phase {
        case .signedIn, .locked:
            return
        case .starting, .signedOut, .signingIn:
            phase = .signedIn(.checking)
            await loadAccess(replacing: .signedIn(.checking))
        }
    }

    /// Applies the answer only if nothing else changed the phase meanwhile, so a
    /// slow answer cannot sign the person back in after they signed out.
    private func loadAccess(replacing before: SignInPhase) async {
        guard let api = services?.api else { return }

        let access = await AppAccess.load(using: api)
        guard phase == before else { return }

        phase = Self.phase(for: access)
    }

    private static func phase(for access: AppAccess) -> SignInPhase {
        access == .locked ? .locked : .signedIn(access)
    }
}
