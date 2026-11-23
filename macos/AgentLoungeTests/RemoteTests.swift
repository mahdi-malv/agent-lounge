import CryptoKit
import Foundation
import Network
import Testing
@testable import AgentLounge

struct PairingBookTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func codeHasSixDigitsAndExpires() {
        var book = PairingBook()
        let pairing = book.startPairing(now: now, randomDigits: { 42 })
        #expect(pairing.code == "000042")
        #expect(book.activePairing(now: now.addingTimeInterval(299)) != nil)
        #expect(book.activePairing(now: now.addingTimeInterval(300)) == nil)
        #expect(book.pair(isValid: { $0 == "000042" }, deviceName: "Pixel", now: now.addingTimeInterval(301)) == .noPairing)
        #expect(book.devices.isEmpty)
    }

    @Test func pairIsOneUseAndMakesASecret() {
        var book = PairingBook()
        book.startPairing(now: now, randomDigits: { 123_456 })
        let result = book.pair(isValid: { $0 == "123456" }, deviceName: "Pixel 9", now: now,
                               makeSecret: { Data([1, 2, 3]) }, makeID: { "dev-1" })
        #expect(result == .paired(PairedDevice(id: "dev-1", name: "Pixel 9", secret: Data([1, 2, 3]), pairedAt: now, lastSeenAt: now)))
        #expect(book.device(id: "dev-1")?.secret == Data([1, 2, 3]))
        #expect(book.pair(isValid: { _ in true }, deviceName: "Other", now: now) == .noPairing)
        #expect(book.devices.count == 1)
    }

    @Test func wrongCodesUseUpTheAttempts() {
        var book = PairingBook()
        book.startPairing(now: now, randomDigits: { 111_111 })
        for _ in 1..<PairingBook.maxAttempts {
            #expect(book.pair(isValid: { _ in false }, deviceName: nil, now: now) == .badCode)
        }
        #expect(book.activePairing(now: now) != nil)
        #expect(book.pair(isValid: { _ in false }, deviceName: nil, now: now) == .badCode)
        #expect(book.pair(isValid: { _ in true }, deviceName: nil, now: now) == .noPairing)
    }

    @Test func removeAndNames() {
        var book = PairingBook()
        book.startPairing(now: now, randomDigits: { 1 })
        _ = book.pair(isValid: { _ in true }, deviceName: nil, now: now, makeID: { "d" })
        #expect(book.devices.first?.name == "Phone")
        #expect(book.devices.first?.secret.count == PhoneCrypto.secretLength)
        book.remove("d")
        #expect(book.device(id: "d") == nil)
        #expect(PairingBook.cleanName("  My\nPhone  ") == "MyPhone")
        #expect(PairingBook.cleanName(String(repeating: "x", count: 100)).count == PairingBook.maxDeviceNameLength)
    }
}

/// Values computed once with CryptoKit; the Android tests check the same values (`PhoneCryptoTest.kt`).
struct PhoneCryptoVectorTests {
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func bytes(_ start: UInt8, _ count: Int) -> Data { Data((0..<count).map { start &+ UInt8($0) }) }

    @Test func sessionKeysAndFirstFrame() throws {
        let keys = PhoneCrypto.sessionKeys(secret: Self.bytes(1, 32), phoneNonce: Self.bytes(0xA0, 16), macNonce: Self.bytes(0xB0, 16))
        #expect(keys.phoneToMac.withUnsafeBytes { Self.hex(Data($0)) } == "f24bf037517780f16c1d30f84bbe5ac11b92fb2e59ab11280c250b6d8bda477b")
        #expect(keys.macToPhone.withUnsafeBytes { Self.hex(Data($0)) } == "e90deab804f097bb67a29ed2df85714de2b8934c4fae3b8ce0120d6c942d1fc6")
        var sealer = FrameSealer(key: keys.phoneToMac)
        let frame = try sealer.seal(Data(#"{"type":"auth"}"#.utf8))
        #expect(Self.hex(frame) == "0000000000000000000000004902c8c4c9dcfdab729c425fc02ba115f26e1bf70ff262a1ad9a723374da38")
    }

    @Test func proofAndPairKey() throws {
        let pub = Data([4]) + Data(repeating: 0x11, count: 64)
        #expect(Self.hex(PhoneCrypto.proof(code: "123456", publicKey: pub)) == "3ac454726bb5e2851d2d7ad32bf408a7b19755651b4061e5b64ec3d1d631b658")
        #expect(PhoneCrypto.isValidProof(PhoneCrypto.proof(code: "123456", publicKey: pub), code: "123456", publicKey: pub))
        #expect(!PhoneCrypto.isValidProof(PhoneCrypto.proof(code: "123457", publicKey: pub), code: "123456", publicKey: pub))
        let mac = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        let phone = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))
        let key = try PhoneCrypto.pairKey(privateKey: mac, peerPublicKey: phone.publicKey.x963Representation, code: "123456")
        #expect(key.withUnsafeBytes { Self.hex(Data($0)) } == "5e0cd2a8f8228a46c5be79338158d7c5daa5380e1cfa975181ead3f6b725b1ef")
    }

    @Test func openerRefusesReplayAndTampering() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = FrameSealer(key: key)
        var opener = FrameOpener(key: key)
        let first = try sealer.seal(Data("a".utf8))
        let second = try sealer.seal(Data("b".utf8))
        #expect(throws: PhoneCrypto.Failure.self) { try opener.open(second) } // out of order
        #expect(try opener.open(first) == Data("a".utf8))
        #expect(throws: PhoneCrypto.Failure.self) { try opener.open(first) } // replay
        var tampered = second
        tampered[tampered.count - 1] ^= 1
        #expect(throws: (any Error).self) { try opener.open(tampered) }
        #expect(try opener.open(second) == Data("b".utf8))
    }
}

/// The Mac side of the handshake against a phone simulated with CryptoKit.
struct RemoteHandshakeTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func message(_ json: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func pairThenHelloThenAuth() throws {
        var book = PairingBook()
        book.startPairing(now: now, randomDigits: { 654_321 })
        let phone = P256.KeyAgreement.PrivateKey()
        let pub = phone.publicKey.x963Representation
        let pair = message(["type": "pair", "v": 2, "device": "Pixel",
                            "pub": pub.base64EncodedString(),
                            "proof": PhoneCrypto.proof(code: "654321", publicKey: pub).base64EncodedString()])
        guard case .reply(let paired, let close) = RemoteHandshake.handle(pair, book: &book, server: "Mac", serverId: "srv", now: now) else {
            Issue.record("expected a reply")
            return
        }
        #expect(paired.type == .paired && close)
        // Phone side: open the box.
        let macPub = try #require(paired.pub.flatMap { Data(base64Encoded: $0) })
        let key = try PhoneCrypto.pairKey(privateKey: phone, peerPublicKey: macPub, code: "654321")
        let plain = try PhoneCrypto.openBox(try #require(paired.box.flatMap { Data(base64Encoded: $0) }), key: key)
        let box = try RemoteCoding.decoder.decode(PairedBox.self, from: plain)
        #expect(box.server == "Mac" && box.serverId == "srv")
        let secret = try #require(Data(base64Encoded: box.secret))
        #expect(book.device(id: box.deviceId)?.secret == secret)

        // hello → challenge → auth
        let phoneNonce = PhoneCrypto.randomBytes(16)
        let hello = message(["type": "hello", "v": 2, "deviceId": box.deviceId, "nonce": phoneNonce.base64EncodedString()])
        guard case .challenge(let challenge, let deviceId, let phoneToMac, _) =
                RemoteHandshake.handle(hello, book: &book, server: "Mac", serverId: "srv", now: now) else {
            Issue.record("expected a challenge")
            return
        }
        #expect(deviceId == box.deviceId)
        let macNonce = try #require(challenge.nonce.flatMap { Data(base64Encoded: $0) })
        let phoneKeys = PhoneCrypto.sessionKeys(secret: secret, phoneNonce: phoneNonce, macNonce: macNonce)
        var phoneSealer = FrameSealer(key: phoneKeys.phoneToMac)
        var opener = FrameOpener(key: phoneToMac)
        #expect(RemoteHandshake.isValidAuth(try phoneSealer.seal(Data(#"{"type":"auth"}"#.utf8)), opener: &opener))

        // A wrong secret fails the auth.
        let wrong = PhoneCrypto.sessionKeys(secret: Data(count: 32), phoneNonce: phoneNonce, macNonce: macNonce)
        var wrongSealer = FrameSealer(key: wrong.phoneToMac)
        var freshOpener = FrameOpener(key: phoneToMac)
        #expect(!RemoteHandshake.isValidAuth(try wrongSealer.seal(Data(#"{"type":"auth"}"#.utf8)), opener: &freshOpener))
    }

    @Test func refusals() {
        var book = PairingBook()
        func reply(_ data: Data) -> ServerMessage.ErrorCode? {
            if case .reply(let message, _) = RemoteHandshake.handle(data, book: &book, server: "M", serverId: "s", now: now) {
                return message.error
            }
            return nil
        }
        #expect(reply(Data("not json".utf8)) == .badMessage)
        #expect(reply(message(["type": "hello", "v": 1, "deviceId": "x"])) == .badMessage) // v1
        #expect(reply(message(["type": "pair", "v": 2, "pub": "AA==", "proof": "AA=="])) == .noPairing)
        #expect(reply(message(["type": "hello", "v": 2, "deviceId": "x", "nonce": PhoneCrypto.randomBytes(16).base64EncodedString()])) == .badToken)
        #expect(reply(message(["type": "decide", "v": 2, "requestId": "r", "allow": true])) == .badMessage)
        book.startPairing(now: now, randomDigits: { 5 })
        let pub = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let wrong = message(["type": "pair", "v": 2, "pub": pub.base64EncodedString(),
                             "proof": PhoneCrypto.proof(code: "000006", publicKey: pub).base64EncodedString()])
        #expect(reply(wrong) == .badCode)
    }
}

struct RemoteCardTests {
    @Test func cardFromSession() throws {
        var session = AgentSession(
            id: "claude:s1", agent: .claude, host: .terminal("Ghostty"), state: .running, cwd: "/Users/u/code/app",
            startedAt: Date(timeIntervalSince1970: 100), lastEventAt: Date(timeIntervalSince1970: 200)
        )
        session.activity = "Editing Foo.swift"
        session.pid = 42
        session.lastAssistantMessage = String(repeating: "a", count: RemoteProtocol.maxMessageLength + 10)
        session.tasks = [
            AgentTask(id: "1", subject: "Write", activeForm: "Writing", status: .completed),
            AgentTask(id: "2", subject: "Test", activeForm: "Testing", status: .inProgress),
        ]
        let card = RemoteCard(session)
        #expect(card.title == "app")
        #expect(card.subtitle == "Editing Foo.swift")
        #expect(card.host == "Ghostty")
        #expect(card.progress == RemoteCard.Progress(done: 1, total: 2, label: "Testing"))
        #expect(card.lastMessage?.count == RemoteProtocol.maxMessageLength + 1)

        let message = ServerMessage(type: .snapshot, sessions: [card], sentAt: Date(timeIntervalSince1970: 300))
        let data = try RemoteCoding.encoder.encode(message)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""type":"snapshot""#))
        #expect(text.contains(#""startedAt":"1970-01-01T00:01:40Z""#))
        #expect(!text.contains("pid"))
        #expect(try RemoteCoding.decoder.decode(ServerMessage.self, from: data) == message)
    }
}

struct LANAddressTests {
    @Test func ipv4() {
        #expect(LANAddress.isLocal(ipv4: [192, 168, 1, 20]))
        #expect(LANAddress.isLocal(ipv4: [10, 0, 0, 1]))
        #expect(LANAddress.isLocal(ipv4: [172, 16, 0, 1]))
        #expect(LANAddress.isLocal(ipv4: [172, 31, 255, 1]))
        #expect(LANAddress.isLocal(ipv4: [127, 0, 0, 1]))
        #expect(LANAddress.isLocal(ipv4: [169, 254, 3, 4]))
        #expect(!LANAddress.isLocal(ipv4: [172, 32, 0, 1]))
        #expect(!LANAddress.isLocal(ipv4: [8, 8, 8, 8]))
        #expect(LANAddress.isLocal(ipv4: [100, 64, 0, 1]))
        #expect(LANAddress.isLocal(ipv4: [100, 127, 255, 254]))
        #expect(!LANAddress.isLocal(ipv4: [100, 63, 255, 255]))
        #expect(!LANAddress.isLocal(ipv4: [100, 128, 0, 1]))
    }

    @Test func tailscale() {
        #expect(LANAddress.isTailscale(ipv4: [100, 69, 105, 56]))
        #expect(!LANAddress.isTailscale(ipv4: [192, 168, 1, 2]))
        #expect(!LANAddress.isTailscale(ipv4: [100, 64, 0]))
    }

    @Test func ipv6() {
        func v6(_ text: String) -> [UInt8] { [UInt8](IPv6Address(text)!.rawValue) }
        #expect(LANAddress.isLocal(ipv6: v6("::1")))
        #expect(LANAddress.isLocal(ipv6: v6("fe80::1")))
        #expect(LANAddress.isLocal(ipv6: v6("fd12:3456::1")))
        #expect(LANAddress.isLocal(ipv6: v6("fd7a:115c:a1e0::22f:6939")))   // Tailscale
        #expect(LANAddress.isLocal(ipv6: v6("::ffff:192.168.0.5")))
        #expect(!LANAddress.isLocal(ipv6: v6("::ffff:8.8.8.8")))
        #expect(!LANAddress.isLocal(ipv6: v6("2001:4860::8888")))
    }

    @Test func endpoint() {
        #expect(LANAddress.isLocal(.hostPort(host: "192.168.0.9", port: 1)))
        #expect(!LANAddress.isLocal(.hostPort(host: "1.2.3.4", port: 1)))
        #expect(!LANAddress.isLocal(.hostPort(host: .name("example.com", nil), port: 1)))
    }
}
