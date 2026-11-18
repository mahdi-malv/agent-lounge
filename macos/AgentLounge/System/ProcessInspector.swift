import Darwin
import Foundation

/// Reads facts about other processes of the same user (no special permission needed).
nonisolated enum ProcessInspector {
    struct Info: Sendable {
        let pid: pid_t
        let parentPID: pid_t
        /// Kernel short name (`p_comm`).
        let name: String
        /// Start time, Unix seconds.
        let startTime: Double
        let terminalDevice: dev_t
        let isZombie: Bool
    }

    static func info(_ pid: pid_t) -> Info? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let start = info.kp_proc.p_un.__p_starttime
        return Info(
            pid: pid,
            parentPID: info.kp_eproc.e_ppid,
            name: name,
            startTime: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000,
            terminalDevice: info.kp_eproc.e_tdev,
            isZombie: info.kp_proc.p_stat == SZOMB
        )
    }

    /// True when `pid` runs and, if given, started at `startTime` (guards against PID reuse).
    static func isAlive(_ pid: pid_t, startTime: Double? = nil) -> Bool {
        guard let info = info(pid), !info.isZombie else { return false }
        guard let startTime else { return true }
        return abs(info.startTime - startTime) < 1
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    static func ttyName(_ device: dev_t) -> String? {
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty == "??" ? nil : tty
    }

    /// `pid` and its ancestors up to launchd, nearest first.
    static func ancestry(from pid: pid_t, limit: Int = 16) -> [ProcessEntry] {
        var chain: [ProcessEntry] = []
        var current = pid
        while chain.count < limit, let info = info(current) {
            chain.append(ProcessEntry(
                pid: current,
                ppid: info.parentPID,
                name: info.name,
                path: executablePath(current),
                tty: ttyName(info.terminalDevice)
            ))
            if current <= 1 { break }
            current = info.parentPID
        }
        return chain
    }

    /// Environment at exec time (`KERN_PROCARGS2`). Works for processes of the same user.
    static func environment(_ pid: pid_t) -> [String: String]? {
        procArgs(pid)?.environment
    }

    /// Arguments at exec time, `argv[0]` first.
    static func arguments(_ pid: pid_t) -> [String]? {
        procArgs(pid)?.arguments
    }

    static func procArgs(_ pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// All process IDs on the system.
    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    /// Current working directory of a process of the same user.
    static func currentDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// Layout: argc (Int32), exec path, NUL padding, argv[argc], env strings, empty string.
    static func parseProcArgs(_ bytes: [UInt8]) -> (arguments: [String], environment: [String: String])? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 } // exec path
        while index < bytes.count, bytes[index] == 0 { index += 1 } // padding

        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return value
        }

        var arguments: [String] = []
        while arguments.count < argc, let argument = nextString() {
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (arguments, environment)
    }
}
