import CryptoKit
import Foundation

/// Phone protocol v2 crypto (PLAN §10). Same algorithms on Android (`PhoneCrypto.kt`):
///
/// Pairing
/// 1. Phone: P-256 key pair, sends its public key (X9.63, 65 bytes) and `proof = HMAC-SHA256(key: code, pub)`.
///    The code itself is never sent.
/// 2. Mac: checks the proof, makes its own key pair, `pairKey = HKDF-SHA256(ECDH, salt: code, info: "agentlounge v2 pair")`,
///    and sends its public key + `box = AES-GCM(pairKey, {secret, deviceId, server, serverId})`.
///    `secret` = 32 random bytes, the long-term device secret.
///
/// Connection
/// 3. Phone `hello` (deviceId, 16-byte nonce) → Mac `challenge` (16-byte nonce), both in clear.
/// 4. Keys = HKDF-SHA256(secret, salt: phoneNonce + macNonce, info: "agentlounge v2 session", 64 bytes):
///    bytes 0..<32 phone → Mac, 32..<64 Mac → phone.
/// 5. Every later frame is binary: AES-256-GCM, nonce = 4 zero bytes + 8-byte big-endian counter (from 0 per
///    direction), AAD "agentlounge v2", frame = nonce + ciphertext + tag. A frame with another counter is refused.
///    The phone's first frame is `{"type":"auth"}`; the Mac sends nothing secret before it.
///
/// Limit: a person on the same network who is active during the 5-minute pairing window can find the
/// 6-digit code from the proof and act in the middle. Passive listening never shows the secret.
nonisolated enum PhoneCrypto {
    static let pairInfo = Data("agentlounge v2 pair".utf8)
    static let sessionInfo = Data("agentlounge v2 session".utf8)
    static let frameAAD = Data("agentlounge v2".utf8)
    static let nonceLength = 16
    static let secretLength = 32

    enum Failure: Error {
        case badKey
        case badFrame
        case replay
    }

    static func proof(code: String, publicKey: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: publicKey, using: SymmetricKey(data: Data(code.utf8))))
    }

    static func isValidProof(_ proof: Data, code: String, publicKey: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: publicKey, using: SymmetricKey(data: Data(code.utf8)))
    }

    static func pairKey(privateKey: P256.KeyAgreement.PrivateKey, peerPublicKey: Data, code: String) throws -> SymmetricKey {
        guard let peer = try? P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey) else { throw Failure.badKey }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(code.utf8), sharedInfo: pairInfo, outputByteCount: 32)
    }

    /// AES-GCM with a random nonce; returns nonce + ciphertext + tag.
    static func sealBox(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.seal(plaintext, using: key).combined ?? Data()
    }

    static func openBox(_ box: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key)
    }

    static func sessionKeys(secret: Data, phoneNonce: Data, macNonce: Data) -> (phoneToMac: SymmetricKey, macToPhone: SymmetricKey) {
        let material = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: phoneNonce + macNonce,
            info: sessionInfo,
            outputByteCount: 64
        )
        let bytes = material.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func frameNonce(_ counter: UInt64) -> Data {
        Data(count: 4) + withUnsafeBytes(of: counter.bigEndian) { Data($0) }
    }
}

/// Encrypts frames of one direction. Not thread-safe; used on the main queue.
nonisolated struct FrameSealer: Sendable {
    let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: PhoneCrypto.frameNonce(counter))
        counter += 1
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: PhoneCrypto.frameAAD)
        return box.combined ?? Data()
    }
}

/// Decrypts frames of one direction and refuses replayed or reordered frames.
nonisolated struct FrameOpener: Sendable {
    let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= 12 + 16 else { throw PhoneCrypto.Failure.badFrame }
        guard frame.prefix(12) == PhoneCrypto.frameNonce(counter) else { throw PhoneCrypto.Failure.replay }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: frame), using: key, authenticating: PhoneCrypto.frameAAD)
        counter += 1
        return plaintext
    }
}
