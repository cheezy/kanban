import CryptoKit
import Foundation
import Testing

@testable import StrideKit

struct ApprovalKeyTests {
    @Test("the public key is the uncompressed P-256 point in 87 characters of base64url")
    func publicKey() throws {
        let key = try ApprovalKey.make()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

        #expect(key.publicKey.count == 87)
        #expect(key.publicKey.unicodeScalars.allSatisfy(allowed.contains))

        let bytes = try #require(Data(base64URLEncoded: key.publicKey))
        #expect(bytes.count == 65)
        #expect(bytes.first == 0x04)
        #expect(throws: Never.self) { try P256.Signing.PublicKey(x963Representation: bytes) }
    }

    @Test("each sign-in makes a new key")
    func newKey() throws {
        #expect(try ApprovalKey.make() != ApprovalKey.make())
    }

    @Test("the Secure Enclave key maker gives a key with its public half and a handle")
    func keyMaker() async throws {
        let key = try await SecureEnclaveKeyMaker().makeKey()

        #expect(key.publicKey.count == 87)
        #expect(key.handle.isEmpty == false)
    }

    @Test("prints, dumps and reflects as redacted")
    func redacted() {
        let key = ApprovalKey.example()
        var dumped = ""
        dump(key, to: &dumped)

        #expect(String(describing: key) == "ApprovalKey(redacted)")
        #expect(String(reflecting: key) == "ApprovalKey(redacted)")
        #expect(dumped.contains(key.publicKey) == false)
        #expect(Mirror(reflecting: key).children.isEmpty)
    }
}

private extension Data {
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
