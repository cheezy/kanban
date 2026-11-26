#if DEBUG
import StrideKit

/// A sign-in kept in memory, which says true or false as `AuthStore` does.
actor MemorySignInStore: SignInStoring {
    private var isSignedIn: Bool
    private let refusal: AuthStoreError?
    private var observers: [AsyncStream<Bool>.Continuation] = []
    private(set) var saved: [TokenPair] = []
    private(set) var savedKeys: [ApprovalKey] = []

    /// With a `refusal`, every call throws it, as the Keychain does before the
    /// first unlock.
    init(signedIn: Bool = false, refusal: AuthStoreError? = nil) {
        self.isSignedIn = signedIn
        self.refusal = refusal
    }

    func signedIn() throws(AuthStoreError) -> AsyncStream<Bool> {
        if let refusal { throw refusal }

        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(isSignedIn)
        observers.append(continuation)
        return stream
    }

    func save(_ pair: TokenPair, approvalKey: ApprovalKey) throws(AuthStoreError) {
        if let refusal { throw refusal }

        saved.append(pair)
        savedKeys.append(approvalKey)
        publish(true)
    }

    func clear() {
        publish(false)
    }

    private func publish(_ value: Bool) {
        isSignedIn = value
        for observer in observers {
            observer.yield(value)
        }
    }
}
#endif
