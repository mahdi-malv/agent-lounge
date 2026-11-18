import Foundation
import Network
import os

/// WebSocket listener on all interfaces for the phone app (PLAN M8). Advertised with Bonjour.
/// Accepts only local-network peers (`LANAddress.isLocal`). Messages are passed to `onMessage`;
/// auth and content are the hub's job. Runs on the main queue.
final class LANServer {
    static let defaultPort: UInt16 = 47822

    enum Status: Equatable {
        case stopped
        case starting(UInt16)
        case listening(UInt16)
        case failed(String)
    }

    private(set) var status: Status = .stopped {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    var onStatusChange: ((Status) -> Void)?
    var onOpen: ((RemoteConnection) -> Void)?
    var onMessage: ((RemoteConnection, Data, _ isBinary: Bool) -> Void)?
    var onClose: ((RemoteConnection) -> Void)?

    private var listener: NWListener?
    private(set) var connections: [ObjectIdentifier: RemoteConnection] = [:]
    private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "LANServer")

    /// Port from env `AGENT_LOUNGE_LAN_PORT`, then user default `lanPort`, then the default.
    static func configuredPort(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> UInt16 {
        if let value = environment["AGENT_LOUNGE_LAN_PORT"], let port = UInt16(value), port > 0 { return port }
        let stored = defaults.integer(forKey: "lanPort")
        if stored > 0, stored <= Int(UInt16.max) { return UInt16(stored) }
        return defaultPort
    }

    func start(port: UInt16, serviceName: String, serverId: String) {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        let tcp = NWProtocolTCP.Options()
        // Phones leave Wi-Fi without closing the socket. Find dead peers in about a minute.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = RemoteProtocol.maxMessageBytes
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            status = .failed(error.localizedDescription)
            logger.error("Cannot create LAN listener: \(error.localizedDescription, privacy: .public)")
            return
        }
        listener.service = NWListener.Service(
            name: serviceName,
            type: RemoteProtocol.serviceType,
            domain: nil,
            txtRecord: NWTXTRecord(["v": "\(RemoteProtocol.version)", "id": serverId])
        )
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerStateChanged(state, port: port) }
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            MainActor.assumeIsolated {
                if case .add(let endpoint) = change {
                    self?.logger.info("Bonjour: \(String(describing: endpoint), privacy: .public)")
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        status = .starting(port)
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.close() }
        connections.removeAll()
        status = .stopped
    }

    private func listenerStateChanged(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            status = .listening(port)
            logger.info("LAN listener on port \(port)")
        case .failed(let error):
            status = .failed(error.localizedDescription)
            logger.error("LAN listener failed: \(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            listener = nil
        case .waiting(let error):
            status = .failed(error.localizedDescription)
            logger.error("LAN listener waiting: \(error.localizedDescription, privacy: .public)")
        default:
            break
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        guard LANAddress.isLocal(nwConnection.endpoint) else {
            logger.notice("Refused non-local peer \(String(describing: nwConnection.endpoint), privacy: .public)")
            nwConnection.cancel()
            return
        }
        let connection = RemoteConnection(connection: nwConnection)
        let key = ObjectIdentifier(connection)
        connection.onMessage = { [weak self, weak connection] data, isBinary in
            guard let self, let connection else { return }
            onMessage?(connection, data, isBinary)
        }
        connection.onClose = { [weak self, weak connection] in
            guard let self else { return }
            connections[key] = nil
            if let connection { onClose?(connection) }
        }
        connections[key] = connection
        connection.start()
        onOpen?(connection)
    }
}

/// One phone WebSocket. Clear text frames until the handshake; then encrypted binary frames (`PhoneCrypto`).
final class RemoteConnection {
    /// Set by the hub after a valid `auth` frame.
    var deviceId: String?
    var isAuthenticated: Bool { deviceId != nil }
    /// After `challenge`: the device that must prove its key.
    var challengedDeviceId: String?
    var sealer: FrameSealer?
    var opener: FrameOpener?
    let peer: String

    var onMessage: ((Data, _ isBinary: Bool) -> Void)?
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private var isClosed = false

    init(connection: NWConnection) {
        self.connection = connection
        peer = String(describing: connection.endpoint)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func send(_ message: ServerMessage, thenClose: Bool = false) {
        guard !isClosed, let data = try? RemoteCoding.encoder.encode(message) else { return }
        send(json: data, thenClose: thenClose)
    }

    /// JSON message: encrypted once the session keys exist, else clear text.
    func send(json data: Data, thenClose: Bool = false) {
        guard !isClosed else { return }
        if sealer != nil {
            guard let frame = try? sealer?.seal(data) else {
                cancel()
                return
            }
            write(frame, opcode: .binary, thenClose: thenClose)
        } else {
            write(data, opcode: .text, thenClose: thenClose)
        }
    }

    private func write(_ data: Data, opcode: NWProtocolWebSocket.Opcode, thenClose: Bool) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                if error != nil || thenClose { self?.close() }
            }
        })
    }

    /// Sends a close frame, then cancels. Cancels after 1 s anyway: a peer that never finished
    /// the WebSocket handshake never completes the send.
    func close() {
        guard !isClosed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.cancel()
        }
    }

    /// Drops the connection at once.
    func cancel() {
        connection.cancel()
        finish()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            let opcode = metadata?.opcode
            let failed = error != nil
            MainActor.assumeIsolated {
                self?.handleReceive(data: data, opcode: opcode, failed: failed)
            }
        }
    }

    private func handleReceive(data: Data?, opcode: NWProtocolWebSocket.Opcode?, failed: Bool) {
        guard !isClosed else { return }
        if failed || opcode == .close {
            connection.cancel()
            finish()
            return
        }
        // Ping, pong: ignored.
        if opcode == .text || opcode == .binary, let data { onMessage?(data, opcode == .binary) }
        receive()
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        onClose?()
    }
}
