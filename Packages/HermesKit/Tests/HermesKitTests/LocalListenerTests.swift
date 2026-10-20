#if os(macOS)
import Darwin
import Foundation
@testable import HermesKit
import Testing

/// The Mac welcome sends the `.env` key only to the process Hermes recorded.
@Suite("Local listener")
struct LocalListenerTests {
    @Test func readsTheRecordedProcess() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "hermes-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(LocalListener.recordedPID(inHome: home) == nil)
        try Data(#"{"pid": 4242, "kind": "hermes-gateway", "argv": ["hermes"]}"#.utf8).write(to: home.appending(path: "gateway.pid"))
        #expect(LocalListener.recordedPID(inHome: home) == 4242)
        try Data("4243\n".utf8).write(to: home.appending(path: "gateway.pid"))
        #expect(LocalListener.recordedPID(inHome: home) == 4243)
    }

    @Test func seesOnlyTheProcessThatListens() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #expect(socket >= 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) } }
        #expect(bound == 0)
        #expect(listen(socket, 1) == 0)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        #expect(LocalListener.listens(pid: getpid(), port: port))
        #expect(!LocalListener.listens(pid: getpid(), port: port == 65535 ? 1 : port + 1))
        #expect(!LocalListener.listens(pid: 1, port: port)) // launchd: not ours to look into
        #expect(!LocalListener.listens(pid: 0, port: port))
    }
}
#endif
