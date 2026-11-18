// lounge-hook — bridge from agent hooks to Agent Lounge.
//
// Hook command:  lounge-hook <source>        source = claude | codex
//
// Reads the hook JSON from stdin, adds host info (env + process chain + tty), and POSTs
// one envelope to http://127.0.0.1:<port>/events (PLAN §3).
//
// Rules: never block the agent. Short socket timeouts, nothing on stdout (some hook
// events add stdout to the model context), always exit 0.
//
// One exception (PLAN §12): Claude `PermissionRequest`. Claude shows its dialog while the hook runs, so
// the hook may wait for an answer from the phone. The app answers 200 with the decision JSON (printed
// to stdout), or 204 when it does not hold the request or the dialog was answered on the Mac.

import Darwin
import Foundation

let version = "0.3.0"
let defaultPort: UInt16 = 47821
let socketTimeoutMicroseconds: Int32 = 250_000
/// Wait for a phone answer. The hook timeout in the Claude settings (3600 s) ends it earlier.
let approvalWaitSeconds = 3_700
/// Tools whose dialog needs more than allow / deny (Claude docs); never wait for them.
let approvalSkippedTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

/// Env vars copied into `host` (key in envelope → env var name).
let hostEnvironmentKeys: [(String, String)] = [
    ("termProgram", "TERM_PROGRAM"),
    ("termProgramVersion", "TERM_PROGRAM_VERSION"),
    ("bundleId", "__CFBundleIdentifier"),
    ("entrypoint", "CLAUDE_CODE_ENTRYPOINT"),
    ("cmuxSurfaceId", "CMUX_SURFACE_ID"),
    ("cmuxWorkspaceId", "CMUX_WORKSPACE_ID"),
    ("cmuxSocketPath", "CMUX_SOCKET_PATH"),
    ("cmuxClaudePid", "CMUX_CLAUDE_PID"),
    ("zedTerm", "ZED_TERM"),
    ("termSessionId", "TERM_SESSION_ID"),
    ("itermSessionId", "ITERM_SESSION_ID"),
]

// MARK: - Envelope

func makeEnvelope(source: String, input: Data) -> [String: Any] {
    let payload: Any = (try? JSONSerialization.jsonObject(with: input))
        ?? ["_raw": String(decoding: input, as: UTF8.self)]

    let environment = ProcessInfo.processInfo.environment
    var host: [String: Any] = [:]
    for (key, name) in hostEnvironmentKeys {
        if let value = environment[name], !value.isEmpty {
            host[key] = value
        }
    }
    let chain = processChain()
    host["processes"] = chain
    if let tty = controllingTTY(chain: chain) {
        host["tty"] = tty
    }

    return [
        "v": 1,
        "source": source,
        "sentAt": Date().timeIntervalSince1970,
        "host": host,
        "payload": payload,
    ]
}

func resolvePort() -> UInt16 {
    if let value = ProcessInfo.processInfo.environment["AGENT_LOUNGE_PORT"], let port = UInt16(value) {
        return port
    }
    return defaultPort
}

// MARK: - Processes

struct KernelProcessInfo {
    let parentPID: pid_t
    let name: String
    let terminalDevice: dev_t
}

func kernelProcessInfo(pid: pid_t) -> KernelProcessInfo? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
        String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return KernelProcessInfo(parentPID: info.kp_eproc.e_ppid, name: name, terminalDevice: info.kp_eproc.e_tdev)
}

func executablePath(pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
}

/// Ancestors of this hook: shell → agent → shell → … → terminal app → launchd.
func processChain() -> [[String: Any]] {
    var chain: [[String: Any]] = []
    var pid = getppid()
    for _ in 0..<16 {
        guard pid > 0, let info = kernelProcessInfo(pid: pid) else { break }
        var entry: [String: Any] = ["pid": pid, "ppid": info.parentPID, "name": info.name]
        if let path = executablePath(pid: pid) {
            entry["path"] = path
        }
        if let tty = ttyName(info.terminalDevice) {
            entry["tty"] = tty
        }
        chain.append(entry)
        if pid == 1 { break }
        pid = info.parentPID
    }
    return chain
}

/// Terminal of the agent, e.g. "ttys012": the first tty of this hook or its nearest ancestor.
/// Stdin is a pipe, so `ttyname` does not work, and hooks can run without a controlling tty.
func controllingTTY(chain: [[String: Any]]) -> String? {
    if let own = kernelProcessInfo(pid: getpid()).flatMap({ ttyName($0.terminalDevice) }) {
        return own
    }
    return chain.lazy.compactMap { $0["tty"] as? String }.first
}

func ttyName(_ device: dev_t) -> String? {
    guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
    let tty = String(cString: name)
    return tty == "??" ? nil : tty
}

// MARK: - HTTP

/// True for a Claude permission dialog that a phone may answer.
func wantsApproval(source: String, input: Data) -> Bool {
    guard source == "claude",
          let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          payload["hook_event_name"] as? String == "PermissionRequest" else { return false }
    return !approvalSkippedTools.contains(payload["tool_name"] as? String ?? "")
}

/// Minimal blocking HTTP POST with short timeouts. Errors are ignored on purpose.
/// With `waitForApproval`, it waits long for the answer and returns the body of a 200 response.
func post(_ body: Data, port: UInt16, waitForApproval: Bool = false) -> Data? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 0, tv_usec: socketTimeoutMicroseconds)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var receiveTimeout = waitForApproval ? timeval(tv_sec: approvalWaitSeconds, tv_usec: 0) : timeout
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return nil } // App not running.

    let head = "POST /events HTTP/1.1\r\n"
        + "Host: 127.0.0.1:\(port)\r\n"
        + "Content-Type: application/json\r\n"
        + (waitForApproval ? "X-Lounge-Wait: approval\r\n" : "")
        + "Content-Length: \(body.count)\r\n"
        + "Connection: close\r\n\r\n"
    var request = Data(head.utf8)
    request.append(body)
    guard sendAll(fd, request) else { return nil }

    guard waitForApproval else {
        // Wait briefly for the status line so the app has read the whole request.
        var response = [UInt8](repeating: 0, count: 256)
        _ = recv(fd, &response, response.count, 0)
        return nil
    }
    // Read the whole response (the app closes after it).
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while response.count < 64 * 1024 {
        let count = recv(fd, &chunk, chunk.count, 0)
        if count <= 0 { break }
        response.append(contentsOf: chunk.prefix(count))
    }
    return approvalBody(response)
}

/// Body of an HTTP 200 response, else nil.
func approvalBody(_ response: Data) -> Data? {
    guard let split = response.firstRange(of: Data("\r\n\r\n".utf8)),
          let head = String(data: response[..<split.lowerBound], encoding: .utf8),
          head.hasPrefix("HTTP/1.1 200") || head.hasPrefix("HTTP/1.0 200") else { return nil }
    let body = response[split.upperBound...]
    return body.isEmpty ? nil : Data(body)
}

func sendAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
            let sent = send(fd, base + offset, raw.count - offset, 0)
            if sent <= 0 { return false }
            offset += sent
        }
        return true
    }
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--version") {
    print("lounge-hook \(version)")
    exit(0)
}
let source = arguments.first ?? "claude"

let input = FileHandle.standardInput.readDataToEndOfFile()
if let body = try? JSONSerialization.data(withJSONObject: makeEnvelope(source: source, input: input)) {
    let wait = wantsApproval(source: source, input: input)
    if let decision = post(body, port: resolvePort(), waitForApproval: wait) {
        FileHandle.standardOutput.write(decision)
    }
}
exit(0)
