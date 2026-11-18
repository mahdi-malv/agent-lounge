import CryptoKit
import Foundation
import Security

/// A phone that paired with this Mac. `secret` is the long-term key of protocol v2 (`PhoneCrypto`).
nonisolated struct PairedDevice: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var secret: Data
    var pairedAt: Date
    var lastSeenAt: Date?
}

/// Short code shown on the Mac. One use, expires, limited wrong attempts.
nonisolated struct PairingCode: Equatable, Sendable {
    var code: String
    var expiresAt: Date
    var attemptsLeft: Int
}

/// Pairing codes and paired phones (PLAN M8). Pure value, so it can be unit tested.
nonisolated struct PairingBook: Equatable, Sendable {
    static let codeLifetime: TimeInterval = 5 * 60
    static let maxAttempts = 5
    static let maxDeviceNameLength = 64

    enum PairResult: Equatable, Sendable {
        case paired(PairedDevice)
        case badCode
        case noPairing
    }

    var devices: [PairedDevice] = []
    private(set) var pending: PairingCode?

    init(devices: [PairedDevice] = []) {
        self.devices = devices
    }

    /// New 6-digit code. Replaces an open one.
    @discardableResult
    mutating func startPairing(now: Date, randomDigits: () -> UInt32 = Self.secureRandom) -> PairingCode {
        let code = String(format: "%06u", randomDigits() % 1_000_000)
        let pairing = PairingCode(code: code, expiresAt: now.addingTimeInterval(Self.codeLifetime), attemptsLeft: Self.maxAttempts)
        pending = pairing
        return pairing
    }

    mutating func cancelPairing() {
        pending = nil
    }

    /// Open code, or nil when there is none or it expired.
    func activePairing(now: Date) -> PairingCode? {
        guard let pending, now < pending.expiresAt, pending.attemptsLeft > 0 else { return nil }
        return pending
    }

    /// `isValid` checks the phone's proof against the open code (the code never travels).
    mutating func pair(
        isValid: (String) -> Bool,
        deviceName: String?,
        now: Date,
        makeSecret: () -> Data = { PhoneCrypto.randomBytes(PhoneCrypto.secretLength) },
        makeID: () -> String = { UUID().uuidString }
    ) -> PairResult {
        guard var open = activePairing(now: now) else {
            pending = nil
            return .noPairing
        }
        guard isValid(open.code) else {
            open.attemptsLeft -= 1
            pending = open.attemptsLeft > 0 ? open : nil
            return .badCode
        }
        pending = nil
        let device = PairedDevice(id: makeID(), name: Self.cleanName(deviceName), secret: makeSecret(), pairedAt: now, lastSeenAt: now)
        devices.append(device)
        return .paired(device)
    }

    func device(id: String) -> PairedDevice? {
        devices.first { $0.id == id }
    }

    mutating func markSeen(_ id: PairedDevice.ID, now: Date) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].lastSeenAt = now
    }

    mutating func remove(_ id: PairedDevice.ID) {
        devices.removeAll { $0.id == id }
    }

    static func cleanName(_ name: String?) -> String {
        let cleaned = (name ?? "")
            .filter { !$0.isNewline && !($0.unicodeScalars.first?.properties.generalCategory == .control) }
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Phone" : String(cleaned.prefix(maxDeviceNameLength))
    }

    static func secureRandom() -> UInt32 {
        var value: UInt32 = 0
        let status = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        precondition(status == errSecSuccess, "No secure random bytes")
        return value
    }
}

/// Plaintext of the `paired` box.
nonisolated struct PairedBox: Codable, Equatable, Sendable {
    var secret: String
    var deviceId: String
    var server: String
    var serverId: String
}

/// Clear-text part of a phone connection: `pair` or `hello` → reply. Pure, so it can be unit tested.
nonisolated enum RemoteHandshake {
    enum Outcome {
        /// Send and close (pairing result or refusal).
        case reply(ServerMessage, close: Bool)
        /// Send the challenge, then wait for the encrypted `auth` frame.
        case challenge(ServerMessage, deviceId: String, phoneToMac: SymmetricKey, macToPhone: SymmetricKey)
    }

    static func handle(
        _ data: Data,
        book: inout PairingBook,
        server: String,
        serverId: String,
        now: Date,
        macKey: P256.KeyAgreement.PrivateKey = .init(),
        macNonce: Data = PhoneCrypto.randomBytes(PhoneCrypto.nonceLength)
    ) -> Outcome {
        guard let message = try? RemoteCoding.decoder.decode(ClientMessage.self, from: data),
              message.v == RemoteProtocol.version else {
            return .reply(.failure(.badMessage), close: true)
        }
        switch message.type {
        case .pair:
            guard let pub = message.pub.flatMap({ Data(base64Encoded: $0) }),
                  let proof = message.proof.flatMap({ Data(base64Encoded: $0) }) else {
                return .reply(.failure(.badMessage), close: true)
            }
            var usedCode = ""
            let result = book.pair(
                isValid: { code in
                    usedCode = code
                    return PhoneCrypto.isValidProof(proof, code: code, publicKey: pub)
                },
                deviceName: message.device,
                now: now
            )
            switch result {
            case .paired(let device):
                guard let key = try? PhoneCrypto.pairKey(privateKey: macKey, peerPublicKey: pub, code: usedCode),
                      let plain = try? RemoteCoding.encoder.encode(PairedBox(
                          secret: device.secret.base64EncodedString(), deviceId: device.id, server: server, serverId: serverId
                      )),
                      let box = try? PhoneCrypto.sealBox(plain, key: key) else {
                    book.remove(device.id)
                    return .reply(.failure(.badMessage), close: true)
                }
                var reply = ServerMessage(type: .paired)
                reply.pub = macKey.publicKey.x963Representation.base64EncodedString()
                reply.box = box.base64EncodedString()
                return .reply(reply, close: true)
            case .badCode:
                return .reply(.failure(.badCode), close: true)
            case .noPairing:
                return .reply(.failure(.noPairing), close: true)
            }
        case .hello:
            guard let deviceId = message.deviceId, let device = book.device(id: deviceId),
                  let nonce = message.nonce.flatMap({ Data(base64Encoded: $0) }), nonce.count == PhoneCrypto.nonceLength else {
                return .reply(.failure(.badToken), close: true)
            }
            let keys = PhoneCrypto.sessionKeys(secret: device.secret, phoneNonce: nonce, macNonce: macNonce)
            var reply = ServerMessage(type: .challenge)
            reply.nonce = macNonce.base64EncodedString()
            return .challenge(reply, deviceId: device.id, phoneToMac: keys.phoneToMac, macToPhone: keys.macToPhone)
        case .auth, .decide, .prompt:
            return .reply(.failure(.badMessage), close: true)
        }
    }

    /// The phone's first encrypted frame must be `{"type":"auth"}`.
    static func isValidAuth(_ frame: Data, opener: inout FrameOpener) -> Bool {
        guard let plain = try? opener.open(frame),
              let message = try? RemoteCoding.decoder.decode(ClientMessage.self, from: plain) else { return false }
        return message.type == .auth
    }
}
