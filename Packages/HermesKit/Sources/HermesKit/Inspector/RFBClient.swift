import Foundation

// The Bot Screen (`docs/inspector.md` §2): raw RFB (VNC, protocol 3.8) over the gateway's
// `/api/display/ws`, which splices the profile's Xvnc socket into binary WebSocket frames and lets
// input through only for the viewer holding the lease. This is the protocol half: bytes in, events
// and replies out. The ticket already authenticated the viewer, so security type None is used.

/// What the decoder found in the server's stream.
public enum RFBEvent: Sendable, Equatable {
    /// Bytes to send back (the handshake, pixel format, encodings, update requests).
    case send(Data)
    /// The desktop's size and name are known (and the framebuffer should be this size).
    case ready(width: Int, height: Int, name: String)
    case resized(width: Int, height: Int)
    /// A rectangle of BGRA pixels, row by row.
    case pixels(x: Int, y: Int, width: Int, height: Int, data: Data)
    /// Copy a rectangle already on screen from (sourceX, sourceY).
    case copy(x: Int, y: Int, width: Int, height: Int, sourceX: Int, sourceY: Int)
    /// An update finished: ask for the next one.
    case updateDone
    case bell
    case clipboard(String)
    /// The server refused or broke the protocol; the reason to show.
    case failed(String)
}

/// Turns the server's bytes into events. Feed it every binary frame in order.
public final class RFBDecoder: @unchecked Sendable {
    private enum Stage {
        case version, securityTypes, securityResult, serverInit, messages, failed
    }

    private var stage = Stage.version
    private var buffer = Data()
    public private(set) var width = 0
    public private(set) var height = 0

    public init() {}

    public func feed(_ data: Data) -> [RFBEvent] {
        buffer.append(data)
        var events: [RFBEvent] = []
        while true {
            guard let produced = step() else { break }
            events.append(contentsOf: produced)
            if stage == .failed { break }
        }
        return events
    }

    /// One unit of progress, or nil when more bytes are needed.
    private func step() -> [RFBEvent]? {
        switch stage {
        case .version:
            guard buffer.count >= 12 else { return nil }
            let version = String(decoding: take(12), as: UTF8.self)
            guard version.hasPrefix("RFB ") else { return fail("Not a VNC server.") }
            stage = .securityTypes
            return [.send(Data("RFB 003.008\n".utf8))]
        case .securityTypes:
            guard let count = peekUInt8(at: 0) else { return nil }
            if count == 0 {
                guard let length = peekUInt32(at: 1), buffer.count >= 5 + Int(length) else { return nil }
                _ = take(5)
                return fail(String(decoding: take(Int(length)), as: UTF8.self))
            }
            guard buffer.count >= 1 + Int(count) else { return nil }
            let types = Array(take(1 + Int(count)).dropFirst())
            guard types.contains(1) else { return fail("The screen asks for a password this app doesn't send.") }
            stage = .securityResult
            return [.send(Data([1]))]
        case .securityResult:
            guard let result = peekUInt32(at: 0) else { return nil }
            if result != 0 {
                guard let length = peekUInt32(at: 4), buffer.count >= 8 + Int(length) else { return nil }
                _ = take(8)
                return fail(String(decoding: take(Int(length)), as: UTF8.self))
            }
            _ = take(4)
            stage = .serverInit
            return [.send(Data([1]))] // ClientInit: share the desktop
        case .serverInit:
            guard buffer.count >= 24, let nameLength = peekUInt32(at: 20), buffer.count >= 24 + Int(nameLength) else { return nil }
            let header = take(24)
            width = Int(header.uint16(at: 0))
            height = Int(header.uint16(at: 2))
            let name = String(decoding: take(Int(nameLength)), as: UTF8.self)
            stage = .messages
            return [.ready(width: width, height: height, name: name), .send(RFBMessages.pixelFormat),
                    .send(RFBMessages.encodings), .send(RFBMessages.updateRequest(incremental: false, width: width, height: height))]
        case .messages:
            return message()
        case .failed:
            return nil
        }
    }

    private func message() -> [RFBEvent]? {
        guard let type = peekUInt8(at: 0) else { return nil }
        switch type {
        case 0: // FramebufferUpdate
            guard buffer.count >= 4 else { return nil }
            let count = Int(buffer.uint16(at: 2))
            var offset = 4
            var events: [RFBEvent] = []
            for _ in 0..<count {
                guard buffer.count >= offset + 12 else { return nil }
                let x = Int(buffer.uint16(at: offset)), y = Int(buffer.uint16(at: offset + 2))
                let w = Int(buffer.uint16(at: offset + 4)), h = Int(buffer.uint16(at: offset + 6))
                let encoding = Int32(bitPattern: buffer.uint32(at: offset + 8))
                offset += 12
                switch encoding {
                case 0:
                    let length = w * h * 4
                    guard buffer.count >= offset + length else { return nil }
                    let start = buffer.startIndex + offset
                    events.append(.pixels(x: x, y: y, width: w, height: h, data: buffer.subdata(in: start..<start + length)))
                    offset += length
                case 1:
                    guard buffer.count >= offset + 4 else { return nil }
                    events.append(.copy(x: x, y: y, width: w, height: h, sourceX: Int(buffer.uint16(at: offset)), sourceY: Int(buffer.uint16(at: offset + 2))))
                    offset += 4
                case -223: // DesktopSize
                    width = w
                    height = h
                    events.append(.resized(width: w, height: h))
                default:
                    return fail("The screen sent an encoding this app didn't ask for.")
                }
            }
            _ = take(offset)
            events.append(.updateDone)
            events.append(.send(RFBMessages.updateRequest(incremental: true, width: width, height: height)))
            return events
        case 1: // SetColourMapEntries (not used with true colour): skip it
            guard buffer.count >= 6 else { return nil }
            let count = Int(buffer.uint16(at: 4))
            guard buffer.count >= 6 + count * 6 else { return nil }
            _ = take(6 + count * 6)
            return []
        case 2:
            _ = take(1)
            return [.bell]
        case 3:
            guard let length = peekUInt32(at: 4), buffer.count >= 8 + Int(length) else { return nil }
            _ = take(8)
            let text = take(Int(length))
            return [.clipboard(String(data: text, encoding: .isoLatin1) ?? "")]
        default:
            return fail("The screen sent a message this app doesn't know.")
        }
    }

    private func fail(_ reason: String) -> [RFBEvent] {
        stage = .failed
        buffer.removeAll()
        return [.failed(reason.isEmpty ? "The screen closed the connection." : reason)]
    }

    private func take(_ count: Int) -> Data {
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }

    private func peekUInt8(at offset: Int) -> UInt8? {
        buffer.count > offset ? buffer[buffer.startIndex + offset] : nil
    }

    private func peekUInt32(at offset: Int) -> UInt32? {
        buffer.count >= offset + 4 ? buffer.uint32(at: offset) : nil
    }
}

/// What the client sends.
public enum RFBMessages {
    /// 32-bit little-endian BGRA true colour.
    static let pixelFormat: Data = {
        var data = Data([0, 0, 0, 0])
        data.append(contentsOf: [32, 24, 0, 1])
        data.append(contentsOf: [0, 255, 0, 255, 0, 255]) // red, green, blue max (big-endian u16)
        data.append(contentsOf: [16, 8, 0, 0, 0, 0])      // shifts, padding
        return data
    }()

    /// Raw, CopyRect and DesktopSize.
    static let encodings: Data = {
        var data = Data([2, 0])
        data.append(UInt16(3).bigEndianBytes)
        for encoding: Int32 in [1, 0, -223] { data.append(UInt32(bitPattern: encoding).bigEndianBytes) }
        return data
    }()

    public static func updateRequest(incremental: Bool, width: Int, height: Int) -> Data {
        var data = Data([3, incremental ? 1 : 0])
        for value in [0, 0, width, height] { data.append(UInt16(clamping: value).bigEndianBytes) }
        return data
    }

    /// A pointer position and the buttons held (bit 0 left, 1 middle, 2 right, 3/4 wheel).
    public static func pointer(x: Int, y: Int, buttons: UInt8) -> Data {
        var data = Data([5, buttons])
        data.append(UInt16(clamping: max(0, x)).bigEndianBytes)
        data.append(UInt16(clamping: max(0, y)).bigEndianBytes)
        return data
    }

    /// A key down or up, by X11 keysym.
    public static func key(_ keysym: UInt32, down: Bool) -> Data {
        var data = Data([4, down ? 1 : 0, 0, 0])
        data.append(keysym.bigEndianBytes)
        return data
    }

    /// The X11 keysym for a character or a named key ("Return", "BackSpace").
    public static func keysym(for character: Character) -> UInt32? {
        switch character {
        case "\r", "\n": return 0xFF0D
        case "\t": return 0xFF09
        case "\u{8}", "\u{7F}": return 0xFF08
        case "\u{1B}": return 0xFF1B
        default:
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
            if scalar.value < 0x100 { return scalar.value }
            return 0x0100_0000 | scalar.value
        }
    }
}

extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}

extension FixedWidthInteger {
    var bigEndianBytes: Data {
        withUnsafeBytes(of: bigEndian) { Data($0) }
    }
}

/// The screen as BGRA bytes, kept current from the decoder's events.
public struct RFBFramebuffer: Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var pixels: [UInt8]

    public init(width: Int = 0, height: Int = 0) {
        self.width = width
        self.height = height
        pixels = Array(repeating: 0, count: width * height * 4)
    }

    public mutating func resize(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = Array(repeating: 0, count: width * height * 4)
    }

    public mutating func apply(_ event: RFBEvent) {
        switch event {
        case .ready(let w, let h, _), .resized(let w, let h):
            resize(width: w, height: h)
        case .pixels(let x, let y, let w, let h, let data):
            data.withUnsafeBytes { source in
                for row in 0..<h where y + row < height {
                    let columns = min(w, width - x)
                    guard columns > 0 else { continue }
                    let to = ((y + row) * width + x) * 4
                    let from = row * w * 4
                    for i in 0..<(columns * 4) { pixels[to + i] = source[from + i] }
                    // Xvnc leaves alpha 0; draw it opaque.
                    for column in 0..<columns { pixels[to + column * 4 + 3] = 255 }
                }
            }
        case .copy(let x, let y, let w, let h, let sx, let sy):
            let copy = pixels
            let rows: [Int] = Array(0..<h)
            for row in rows where y + row < height && sy + row < height {
                let columns = min(w, width - x, width - sx)
                guard columns > 0 else { continue }
                let to = ((y + row) * width + x) * 4
                let from = ((sy + row) * width + sx) * 4
                for i in 0..<(columns * 4) { pixels[to + i] = copy[from + i] }
            }
        default:
            break
        }
    }
}
