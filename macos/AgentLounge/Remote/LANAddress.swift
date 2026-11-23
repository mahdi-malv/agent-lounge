import Darwin
import Foundation
import Network

/// Address checks for the LAN listener (PLAN M8).
nonisolated enum LANAddress {
    /// True for loopback, private, link-local and Tailscale addresses. Other peers are refused.
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return isLocal(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address): return isLocal(ipv6: [UInt8](address.rawValue))
        default: return false
        }
    }

    static func isLocal(ipv4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return isTailscale(ipv4: b)
        }
    }

    /// 100.64.0.0/10: Tailscale node addresses (shared with carrier-grade NAT, which never
    /// reaches the Mac from outside). Tailscale IPv6 (fd7a:115c:a1e0::/48) is in fc00::/7.
    static func isTailscale(ipv4 b: [UInt8]) -> Bool {
        b.count == 4 && b[0] == 100 && b[1] & 0xc0 == 64
    }

    static func isLocal(ipv6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b == [UInt8](repeating: 0, count: 15) + [1] { return true }               // ::1
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return true }                         // fe80::/10 link-local
        if b[0] & 0xfe == 0xfc { return true }                                       // fc00::/7 unique local
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {         // ::ffff:a.b.c.d
            return isLocal(ipv4: Array(b[12..<16]))
        }
        return false
    }

    /// IPv4 addresses of the active non-loopback interfaces, Tailscale included (for manual entry
    /// on the phone and the `welcome` address list).
    static func currentIPv4() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let parts = text.split(separator: ".").compactMap { UInt8($0) }
            if isLocal(ipv4: parts), !text.hasPrefix("169.254.") { result.append(text) }
        }
        return result
    }
}
