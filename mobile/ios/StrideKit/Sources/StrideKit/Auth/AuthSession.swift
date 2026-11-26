/// The stored pair, and which sign-in it belongs to. A refresh keeps the sign-in
/// and changes the pair.
struct AuthSession: Equatable, Sendable {
    let signIn: Int
    let pair: TokenPair
}
