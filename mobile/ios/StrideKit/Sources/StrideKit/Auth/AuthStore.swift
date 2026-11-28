import Foundation
import Security

/// Keeps the device's token pair, and the approval key made at sign-in, in the
/// Keychain access group the app and its extensions share, and nowhere else.
///
/// The pair is one Keychain item, so a reader sees either the old pair or the new
/// one. Nothing is cached, so a process reads what another one last wrote.
///
/// Only the app writes, through one store: an extension calls nothing but `read`
/// and `signedIn`, and two writers could overwrite each other's pair. An extension
/// can run before the app does, and until the app has run once in this install
/// every read is nil.
public actor AuthStore {
    static let service = "StrideDeviceTokens"
    static let account = "token-pair"
    static let approvalKeyAccount = "approval-key"

    private let accessGroup: String
    private let service: String
    private let marker: InstallMarker
    private let keychain: any KeychainClient
    private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    /// Counts the sign-ins and sign-outs made through this store.
    private var signIn = 0

    /// Returns nil when the running target is not entitled to the app group.
    public init?(
        group: AppGroup,
        resolve: @Sendable (String) -> URL? = AppGroup.systemContainerURL
    ) {
        guard let container = group.containerURL(resolve: resolve) else { return nil }

        self.init(
            accessGroup: group.keychainAccessGroup,
            marker: InstallMarker(container: container),
            keychain: SystemKeychainClient()
        )
    }

    init(
        accessGroup: String,
        service: String = AuthStore.service,
        marker: InstallMarker,
        keychain: any KeychainClient
    ) {
        self.accessGroup = accessGroup
        self.service = service
        self.marker = marker
        self.keychain = keychain
    }

    deinit {
        for observer in observers.values {
            observer.finish()
        }
    }

    /// The stored pair, or nil when the device is signed out.
    public func read() throws(AuthStoreError) -> TokenPair? {
        guard marker.exists else { return nil }

        let (status, data) = keychain.copyData(matching: itemQuery)
        if status == errSecItemNotFound { return nil }
        try check(status)

        guard
            let data,
            let stored = try? JSONDecoder().decode(StoredTokenPair.self, from: data)
        else { throw .invalidPair }

        return stored.pair
    }

    /// The stored pair with its sign-in, or nil when the device is signed out.
    func session() throws(AuthStoreError) -> AuthSession? {
        guard let pair = try read() else { return nil }

        return AuthSession(signIn: signIn, pair: pair)
    }

    /// Stores the pair of a new sign-in, in place of any pair already there.
    public func save(_ pair: TokenPair) throws(AuthStoreError) {
        try clearItemsFromPreviousInstall()
        try write(try attributes(of: pair), to: itemQuery)

        signIn += 1
        publish(true)
    }

    /// Stores the pair and the approval key of a new sign-in, in place of any
    /// already there. The key is a second item of the same service, so every
    /// `clear` removes it with the pair.
    public func save(_ pair: TokenPair, approvalKey: ApprovalKey) throws(AuthStoreError) {
        guard let key = try? JSONEncoder().encode(approvalKey) else { throw .invalidPair }

        try clearItemsFromPreviousInstall()
        try write(
            [
                kSecValueData as String: key,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ],
            to: approvalKeyQuery
        )
        try write(try attributes(of: pair), to: itemQuery)

        signIn += 1
        publish(true)
    }

    /// The stored approval key, or nil when there is none. A key this version
    /// cannot read, such as one an earlier build kept as its bare handle, is
    /// none too, so the signer has a new one made.
    func approvalKey() throws(AuthStoreError) -> ApprovalKey? {
        guard marker.exists else { return nil }

        let (status, data) = keychain.copyData(matching: approvalKeyQuery)
        if status == errSecItemNotFound { return nil }
        try check(status)

        return data.flatMap { try? JSONDecoder().decode(ApprovalKey.self, from: $0) }
    }

    /// Replaces the pair that was refreshed with the pair the server answered.
    ///
    /// Throws `superseded`, and stores nothing, when `previous` is no longer the
    /// stored pair. That keeps a refresh that ends after a sign-out from signing
    /// the device back in.
    public func rotate(from previous: TokenPair, to next: TokenPair) throws(AuthStoreError) {
        guard try read() == previous else { throw .superseded }

        // An update, never an add, so it cannot bring back an item that was
        // cleared since the read.
        let status = keychain.update(itemQuery, to: try attributes(of: next))
        if status == errSecItemNotFound { throw .superseded }
        try check(status)
    }

    /// Removes every stored item, which signs the device out.
    public func clear() throws(AuthStoreError) {
        try deleteEveryItem()
        signIn += 1
        publish(false)
    }

    /// Signs the device out because the server refused `pair`. Throws `superseded`,
    /// and removes nothing, when that is no longer the stored pair, so that the
    /// refusal of an old pair cannot end a new sign-in.
    func clear(refused pair: TokenPair) throws(AuthStoreError) {
        guard try read() == pair else { throw .superseded }

        try clear()
    }

    /// Whether the device is signed in: the state now, then the state after each
    /// `save` and `clear` made through this store.
    public func signedIn() throws(AuthStoreError) -> AsyncStream<Bool> {
        let isSignedIn = try read() != nil
        let (stream, continuation) = AsyncStream.makeStream(
            of: Bool.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()

        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        observers[id] = continuation
        continuation.yield(isSignedIn)

        return stream
    }

    /// Removes what a previous install left in the Keychain. The app calls it at
    /// launch; it does nothing after the first time.
    ///
    /// The marker is written last, so a failure leaves it missing: reads stay nil
    /// and the next launch or sign-in tries again.
    public func clearItemsFromPreviousInstall() throws(AuthStoreError) {
        guard marker.exists == false else { return }

        try deleteEveryItem()
        do {
            try marker.create()
        } catch {
            throw .installNotMarked
        }
    }

    var observerCount: Int { observers.count }

    private var serviceQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }

    private var itemQuery: [String: Any] {
        serviceQuery.merging([kSecAttrAccount as String: Self.account]) { $1 }
    }

    private var approvalKeyQuery: [String: Any] {
        serviceQuery.merging([kSecAttrAccount as String: Self.approvalKeyAccount]) { $1 }
    }

    /// Adds the item `query` names, or replaces it.
    private func write(_ attributes: [String: Any], to query: [String: Any]) throws(AuthStoreError) {
        let status = keychain.add(query.merging(attributes) { $1 })
        if status == errSecDuplicateItem {
            try check(keychain.update(query, to: attributes))
        } else {
            try check(status)
        }
    }

    private func attributes(of pair: TokenPair) throws(AuthStoreError) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(StoredTokenPair(pair)) else {
            throw .invalidPair
        }

        return [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    private func deleteEveryItem() throws(AuthStoreError) {
        let status = keychain.delete(serviceQuery)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    private func check(_ status: OSStatus) throws(AuthStoreError) {
        guard status == errSecSuccess else { throw .keychain(status) }
    }

    private func publish(_ isSignedIn: Bool) {
        for observer in observers.values {
            observer.yield(isSignedIn)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
