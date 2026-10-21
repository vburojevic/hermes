import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// An IP address, as its bytes in network order: 4 for IPv4, 16 for IPv6.
public enum IPAddress: Hashable, Sendable {
    case v4([UInt8])
    case v6([UInt8])
}

/// Addresses for the checks that decide what the app reaches without asking. An address literal
/// counts only when the whole host is one (`10.0.0.1.example.com` is a name, not 10.0.0.1), and a
/// name is looked up when it matters, since a public name can point into this device's network.
public enum HostAddresses {
    /// The host as an IP address literal; nil for a name. IPv4 only in its strict four-part form
    /// (no `127.1`, no leading zeros, which the resolver may read as octal); IPv6 in any form,
    /// with or without brackets and a zone (`%en0`).
    public static func literal(_ host: String) -> IPAddress? {
        var host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") {
            if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
            return .v6(withUnsafeBytes(of: &address) { Array($0) })
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return nil }
        var octets: [UInt8] = []
        for label in labels {
            guard (1...3).contains(label.count), label.allSatisfy({ $0.isASCII && $0.isNumber }),
                  label.count == 1 || label.first != "0", let value = UInt8(label) else { return nil }
            octets.append(value)
        }
        return .v4(octets)
    }

    /// On this device's network or the machine itself: loopback, private, link-local, Tailscale's
    /// CGNAT range, "this host" (`0.0.0.0`, `::`) and IPv4 addresses written as IPv6 (mapped, or
    /// behind NAT64).
    public static func isLocal(_ address: IPAddress) -> Bool {
        switch address {
        case .v4(let octets):
            return isLocalV4(octets)
        case .v6(let bytes):
            guard bytes.count == 16 else { return false }
            // ::ffff:a.b.c.d, and ::a.b.c.d (which covers :: and ::1 as 0.0.0.0 and 0.0.0.1).
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == bytes[11], bytes[10] == 0 || bytes[10] == 0xff {
                return isLocalV4(Array(bytes[12...]))
            }
            // 64:ff9b::a.b.c.d, NAT64's well-known prefix: an IPv4 address reached through IPv6.
            if bytes[0..<12] == [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] {
                return isLocalV4(Array(bytes[12...]))
            }
            return (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) // fe80::/10, link-local
                || bytes[0] & 0xfe == 0xfc // fc00::/7, unique local
        }
    }

    private static func isLocalV4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true // CGNAT, used by Tailscale
        default: return false
        }
    }

    /// Whether any address a name resolves to is local (`isLocal`). An address literal is judged
    /// as it stands; a name that doesn't resolve isn't local.
    public static func resolvesLocal(_ host: String) async -> Bool {
        if let address = literal(host) { return isLocal(address) }
        return await resolve(host).contains(where: isLocal)
    }

    /// The addresses a name resolves to (`getaddrinfo`), looked up off the caller's thread.
    public static func resolve(_ host: String) async -> [IPAddress] {
        await Task.detached(priority: .userInitiated) { lookUp(host) }.value
    }

    private static func lookUp(_ host: String) -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0, let first else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [IPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            if let socket = info.ai_addr {
                switch Int32(socket.pointee.sa_family) {
                case AF_INET:
                    var address = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    addresses.append(.v4(withUnsafeBytes(of: &address) { Array($0) }))
                case AF_INET6:
                    var address = socket.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    addresses.append(.v6(withUnsafeBytes(of: &address) { Array($0) }))
                default:
                    break
                }
            }
            cursor = info.ai_next
        }
        return addresses
    }
}
