import Foundation
import Observation
import os
import SystemConfiguration

/// Phone access (PLAN M8, §10): owns the LAN listener, pairing, and the card stream.
/// Off by default. Phones get cards and alerts, answer permission requests (`ApprovalCenter`) and may
/// type prompts (`onPrompt`). All after the encrypted handshake (`PhoneCrypto`).
@Observable
final class RemoteHub {
    private enum Key {
        static let enabled = "remote.enabled"
        /// v1 device list (token hashes). Dropped: v2 needs a new pairing.
        static let legacyDevices = "remote.devices"
        static let serverId = "remote.serverId"
        static let approvals = "remote.approvals"
    }

    /// Snapshots are sent at most this often.
    static let snapshotGap: Duration = .milliseconds(250)

    private(set) var isEnabled: Bool
    /// Paired phones may answer Claude permission requests (default on).
    private(set) var approvalsEnabled: Bool
    private(set) var status: LANServer.Status = .stopped
    private(set) var book: PairingBook
    /// Paired devices with an open, authenticated connection.
    private(set) var connectedDeviceIDs: Set<PairedDevice.ID> = []
    let serverId: String
    let serviceName: String

    /// Set by the app before `start()`.
    @ObservationIgnored var approvals: ApprovalCenter? {
        didSet {
            approvals?.isEnabled = { [weak self] in
                guard let self else { return false }
                return isEnabled && approvalsEnabled && !book.devices.isEmpty
            }
        }
    }
    /// Types a phone prompt into the session (Ghostty). Returns nil on success, else the reason.
    /// Plan usage sent in snapshots. Set by the app before `start()`.
    @ObservationIgnored var usage: UsageMonitor?
    @ObservationIgnored var onPrompt: ((_ cardID: String, _ text: String) -> String?)?
    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let deviceFile: URL
    @ObservationIgnored private let server = LANServer()
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var authTimers: [ObjectIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastContent: SnapshotContent?
    @ObservationIgnored private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "Remote")

    init(store: SessionStore, defaults: UserDefaults = .standard, deviceFile: URL = RemoteHub.defaultDeviceFile) {
        self.store = store
        self.defaults = defaults
        self.deviceFile = deviceFile
        isEnabled = defaults.bool(forKey: Key.enabled)
        approvalsEnabled = defaults.object(forKey: Key.approvals) as? Bool ?? true
        defaults.removeObject(forKey: Key.legacyDevices)
        book = PairingBook(devices: Self.loadDevices(from: deviceFile))
        if let id = defaults.string(forKey: Key.serverId) {
            serverId = id
        } else {
            serverId = UUID().uuidString
            defaults.set(serverId, forKey: Key.serverId)
        }
        serviceName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"

        server.onStatusChange = { [weak self] status in self?.status = status }
        server.onOpen = { [weak self] connection in self?.opened(connection) }
        server.onMessage = { [weak self] connection, data, isBinary in self?.received(data, isBinary: isBinary, from: connection) }
        server.onClose = { [weak self] connection in self?.closed(connection) }
    }

    /// Call once at launch.
    func start() {
        if isEnabled { startServer() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        if enabled {
            startServer()
        } else {
            stopServer()
            book.cancelPairing()
            approvals?.releaseAll()
        }
    }

    func setApprovalsEnabled(_ enabled: Bool) {
        guard enabled != approvalsEnabled else { return }
        approvalsEnabled = enabled
        defaults.set(enabled, forKey: Key.approvals)
        if !enabled { approvals?.releaseAll() }
    }

    func stop() {
        stopServer()
    }

    // MARK: - Pairing

    @discardableResult
    func startPairing() -> PairingCode {
        book.startPairing(now: .now)
    }

    func cancelPairing() {
        book.cancelPairing()
    }

    func activePairing(now: Date = .now) -> PairingCode? {
        book.activePairing(now: now)
    }

    /// Forget a phone and close its connections.
    func removeDevice(_ id: PairedDevice.ID) {
        book.remove(id)
        saveDevices()
        for connection in server.connections.values where connection.deviceId == id {
            connection.send(.failure(.revoked), thenClose: true)
        }
    }

    var lanAddresses: [String] { LANAddress.currentIPv4() }

    // MARK: - Alerts

    /// Called by `AlertCenter` after its rules and repeat guard.
    func broadcastAlert(_ kind: AlertKind, session: AgentSession) {
        guard isEnabled else { return }
        let approval = approvals?.first(for: session.id)
        broadcast(ServerMessage(type: .alert, alert: RemoteAlert(kind, session: session, approval: approval)))
    }

    // MARK: - Server

    private func startServer() {
        server.start(port: LANServer.configuredPort(), serviceName: serviceName, serverId: serverId)
        let store = store
        let approvals = approvals
        let usage = usage
        snapshotTask = Task { [weak self] in
            for await content in Observations({ Self.content(store, approvals, usage) }) {
                guard let self else { return }
                contentChanged(content)
                try? await Task.sleep(for: Self.snapshotGap)
            }
        }
    }

    private func stopServer() {
        snapshotTask?.cancel()
        snapshotTask = nil
        authTimers.values.forEach { $0.cancel() }
        authTimers.removeAll()
        server.stop()
        connectedDeviceIDs = []
    }

    private struct SnapshotContent: Equatable {
        var cards: [RemoteCard]
        var usage: [AgentUsage]?
    }

    private func contentChanged(_ content: SnapshotContent) {
        guard content != lastContent else { return }
        lastContent = content
        broadcast(snapshot(content))
    }

    private static func content(_ store: SessionStore, _ approvals: ApprovalCenter?, _ usage: UsageMonitor?) -> SnapshotContent {
        // Same planets as the panel: sync with all sessions first, like the panel does.
        PlanetRegistry.sync(store.sessions)
        return SnapshotContent(
            cards: store.visibleSessions.map {
                RemoteCard($0, approval: approvals?.first(for: $0.id), planet: PlanetRegistry.planet(for: $0))
            },
            usage: usage?.usages
        )
    }

    private func snapshot(_ content: SnapshotContent) -> ServerMessage {
        ServerMessage(type: .snapshot, sessions: content.cards, usage: content.usage, sentAt: .now)
    }

    private func broadcast(_ message: ServerMessage) {
        let targets = server.connections.values.filter(\.isAuthenticated)
        guard !targets.isEmpty, let data = try? RemoteCoding.encoder.encode(message) else { return }
        targets.forEach { $0.send(json: data) }
    }

    private func opened(_ connection: RemoteConnection) {
        logger.info("Phone connection from \(connection.peer, privacy: .public)")
        let key = ObjectIdentifier(connection)
        authTimers[key] = Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(RemoteProtocol.authTimeout))
            guard !Task.isCancelled, let connection, !connection.isAuthenticated else { return }
            self?.logger.notice("Phone auth timeout: \(connection.peer, privacy: .public)")
            connection.send(.failure(.authTimeout))
            connection.close()
            self?.authTimers[key] = nil
        }
    }

    private func received(_ data: Data, isBinary: Bool, from connection: RemoteConnection) {
        if let deviceId = connection.deviceId {
            // Encrypted session: binary frames only. A bad frame ends the connection.
            guard isBinary, let plain = try? connection.opener?.open(data) else {
                connection.cancel()
                return
            }
            handleCommand(plain, from: deviceId, connection: connection)
            return
        }
        if let deviceId = connection.challengedDeviceId {
            guard isBinary, var opener = connection.opener, RemoteHandshake.isValidAuth(data, opener: &opener) else {
                logger.notice("Phone auth failed: \(connection.peer, privacy: .public)")
                connection.cancel()
                return
            }
            connection.opener = opener
            authenticated(connection, deviceId: deviceId)
            return
        }
        guard !isBinary else {
            connection.cancel()
            return
        }
        switch RemoteHandshake.handle(data, book: &book, server: serviceName, serverId: serverId, now: .now) {
        case .reply(let message, let close):
            if message.type == .paired {
                saveDevices()
                logger.info("Phone paired: \(self.book.devices.last?.name ?? "?", privacy: .public)")
            } else {
                logger.notice("Phone refused: \(message.error?.rawValue ?? "?", privacy: .public)")
            }
            connection.send(message, thenClose: close)
        case .challenge(let message, let deviceId, let phoneToMac, let macToPhone):
            connection.send(message) // clear text: no keys on the connection yet
            connection.challengedDeviceId = deviceId
            connection.opener = FrameOpener(key: phoneToMac)
            connection.sealer = FrameSealer(key: macToPhone)
        }
    }

    private func authenticated(_ connection: RemoteConnection, deviceId: String) {
        authTimers.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
        connection.challengedDeviceId = nil
        connection.deviceId = deviceId
        book.markSeen(deviceId, now: .now)
        saveDevices()
        connectedDeviceIDs.insert(deviceId)
        var welcome = ServerMessage(type: .welcome)
        welcome.deviceId = deviceId
        welcome.server = serviceName
        welcome.serverId = serverId
        connection.send(welcome)
        connection.send(snapshot(Self.content(store, approvals, usage)))
        logger.info("Phone \(deviceId, privacy: .public) authenticated")
    }

    /// Messages of an authenticated phone. Unknown ones are ignored.
    private func handleCommand(_ data: Data, from deviceId: String, connection: RemoteConnection) {
        guard let message = try? RemoteCoding.decoder.decode(ClientMessage.self, from: data) else { return }
        let name = book.device(id: deviceId)?.name ?? deviceId
        switch message.type {
        case .decide:
            guard approvalsEnabled, let id = message.requestId, let allow = message.allow else { return }
            if approvals?.decide(id, allow: allow, by: name) != true {
                logger.notice("Decision for unknown request \(id, privacy: .public)")
            }
        case .prompt:
            guard let cardId = message.cardId, let text = message.text else { return }
            let failure: String? = if let onPrompt { onPrompt(cardId, text) } else { "Prompts are not available" }
            logger.info("Prompt from \(name, privacy: .public) for \(cardId, privacy: .public): \(failure ?? "sent", privacy: .public)")
            var result = ServerMessage(type: .result)
            result.cardId = cardId
            result.ok = failure == nil
            result.reason = failure
            connection.send(result)
        case .pair, .hello, .auth:
            break
        }
    }

    private func closed(_ connection: RemoteConnection) {
        authTimers.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
        connectedDeviceIDs = Set(server.connections.values.compactMap(\.deviceId))
    }

    // MARK: - Device file

    /// `~/Library/Application Support/Agent Lounge/phones.json`, mode 0600. Holds the device secrets.
    static var defaultDeviceFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Agent Lounge", isDirectory: true).appendingPathComponent("phones.json")
    }

    private static func loadDevices(from file: URL) -> [PairedDevice] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    private func saveDevices() {
        do {
            let folder = deviceFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(book.devices)
            try data.write(to: deviceFile, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: deviceFile.path)
        } catch {
            logger.error("Cannot save phones: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Dev aid for `/debug/remote`.
    var debugStatus: [String: String] {
        [
            "enabled": "\(isEnabled)",
            "status": "\(status)",
            "devices": book.devices.map(\.name).joined(separator: ", "),
            "connected": "\(connectedDeviceIDs.count)",
            "connections": "\(server.connections.count)",
        ]
    }
}
