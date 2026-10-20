#if os(macOS)
import Darwin
import Foundation

/// Who answers on a port of this Mac, so the welcome window hands the API key from Hermes's
/// `.env` only to Hermes itself (`docs/onboarding.md` §6). Anything can listen on a free port,
/// including a sandboxed app that can't read `~/.hermes`; Hermes records its own process in
/// `gateway.pid`, a file only this user's processes can write.
public enum LocalListener {
    /// The process Hermes recorded in its home: `gateway.pid` holds `{"pid": N, …}` (or, from an
    /// older Hermes, the bare number).
    public static func recordedPID(inHome home: URL) -> Int32? {
        guard let data = try? Data(contentsOf: home.appending(path: "gateway.pid")) else { return nil }
        if let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pid = record["pid"] as? Int {
            return Int32(exactly: pid)
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(text)
    }

    /// Whether the process has a TCP socket listening on the port. Only this user's processes can
    /// be looked into, so a true answer also means the process is ours.
    public static func listens(pid: Int32, port: Int) -> Bool {
        guard pid > 0 else { return false }
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let length = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, length) == length,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if tcp.tcpsi_state == TSI_S_LISTEN, local == port { return true }
        }
        return false
    }
}
#endif
