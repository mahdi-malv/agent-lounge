import Foundation
import Network
import os

/// Answer to one request. The first `respond` wins; later calls are ignored.
/// A handler may keep it and answer later (approval requests, M8): the connection stays open.
final class HTTPResponder {
    private var send: ((HTTPResponse) -> Void)?
    private(set) var isDone = false
    /// Called when the client closes the connection before a held request got its answer.
    var onClientGone: (() -> Void)?

    init(send: @escaping (HTTPResponse) -> Void) {
        self.send = send
    }

    func respond(_ response: HTTPResponse) {
        guard !isDone else { return }
        isDone = true
        send?(response)
        send = nil
        onClientGone = nil
    }

    fileprivate func clientGone() {
        guard !isDone else { return }
        isDone = true
        send = nil
        let callback = onClientGone
        onClientGone = nil
        callback?()
    }
}

/// HTTP server on 127.0.0.1 only (PLAN §3). Runs on the main queue: requests are small and few.
final class EventServer {
    /// Keep in sync with `defaultPort` in `LoungeHook/main.swift`.
    static let defaultPort: UInt16 = 47821
    static let maxBodyBytes = 16 * 1024 * 1024

    enum Status: Equatable {
        case stopped
        case starting(UInt16)
        case listening(UInt16)
        case failed(String)
    }

    private(set) var status: Status = .stopped {
        didSet { onStatusChange?(status) }
    }
    var onStatusChange: ((Status) -> Void)?

    private let handler: (HTTPRequest, HTTPResponder) -> Void
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let logger = Logger(subsystem: "dev.agentlounge.AgentLounge", category: "EventServer")

    init(handler: @escaping (HTTPRequest, HTTPResponder) -> Void) {
        self.handler = handler
    }

    /// Port from env `AGENT_LOUNGE_PORT`, then user default `port`, then the default.
    static func configuredPort(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> UInt16 {
        if let value = environment["AGENT_LOUNGE_PORT"], let port = UInt16(value), port > 0 { return port }
        let stored = defaults.integer(forKey: "port")
        if stored > 0, stored <= Int(UInt16.max) { return UInt16(stored) }
        return defaultPort
    }

    func start(port: UInt16) {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            status = .failed(error.localizedDescription)
            logger.error("Cannot create listener: \(error.localizedDescription, privacy: .public)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerStateChanged(state, port: port) }
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
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        status = .stopped
    }

    private func listenerStateChanged(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            status = .listening(port)
            logger.info("Listening on 127.0.0.1:\(port)")
        case .failed(let error):
            status = .failed(error.localizedDescription)
            logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            listener = nil
        case .waiting(let error):
            // Usually "address in use". NWListener retries; report it.
            status = .failed(error.localizedDescription)
            logger.error("Listener waiting: \(error.localizedDescription, privacy: .public)")
        default:
            break
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = HTTPConnection(connection: nwConnection, maxBodyBytes: Self.maxBodyBytes, handler: handler)
        let key = ObjectIdentifier(connection)
        connection.onClose = { [weak self] in
            self?.connections[key] = nil
        }
        connections[key] = connection
        connection.start()
    }
}

/// One request, one response, then close. A held request (see `HTTPResponder`) may wait up to `holdLimit`.
private final class HTTPConnection {
    /// Longest wait for a held request. Above the approval hook timeout (`HookConfig`).
    static let holdLimit: Duration = .seconds(3_700)

    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let maxBodyBytes: Int
    private let handler: (HTTPRequest, HTTPResponder) -> Void
    private var buffer = Data()
    private var isClosed = false
    private var timeout: Task<Void, Never>?
    private var responder: HTTPResponder?

    init(connection: NWConnection, maxBodyBytes: Int, handler: @escaping (HTTPRequest, HTTPResponder) -> Void) {
        self.connection = connection
        self.maxBodyBytes = maxBodyBytes
        self.handler = handler
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
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.cancel() }
        }
        receive()
    }

    func cancel() {
        connection.cancel()
        finish()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                self?.handleReceive(data: data, isComplete: isComplete, failed: error != nil)
            }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, failed: Bool) {
        guard !isClosed else { return }
        if let data { buffer.append(data) }
        if responder != nil {
            // Held request: more data or EOF means the client is done or gone.
            if isComplete || failed { cancel() } else { receive() }
            return
        }
        switch HTTPRequestParser.parse(buffer, maxBodyBytes: maxBodyBytes) {
        case .complete(let request):
            let responder = HTTPResponder { [weak self] response in self?.respond(response) }
            self.responder = responder
            handler(request, responder)
            if !responder.isDone {
                // Held: longer timeout, and keep reading to notice when the client goes away.
                timeout?.cancel()
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: Self.holdLimit)
                    if !Task.isCancelled { self?.responder?.respond(.noContent) }
                }
                receive()
            }
        case .tooLarge:
            respond(.tooLarge)
        case .invalid:
            respond(.badRequest)
        case .incomplete:
            if isComplete || failed {
                cancel()
            } else {
                receive()
            }
        }
    }

    private func respond(_ response: HTTPResponse) {
        guard !isClosed else { return }
        connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        timeout?.cancel()
        responder?.clientGone()
        onClose?()
    }
}
