@preconcurrency import AVFoundation
import Foundation
import HermesKit

/// The Bot's own voice (`docs/voice.md` §3, §4.2): its profile's speech provider on the gateway,
/// one sentence per `speak-stream` socket so each sentence's audio is known (the reply lights up
/// the one being heard). The PCM plays as it arrives; a provider that can't stream falls back to
/// `POST /api/audio/speak` for that sentence.
nonisolated final class GatewayVoice: SentenceVoice {
    private let backend: BackendClient
    private let profile: String?

    init(backend: BackendClient, profile: String?) {
        self.backend = backend
        self.profile = profile
    }

    func audio(for text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, any Error> {
        let backend = backend
        let profile = profile
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = try await backend.speakStream(text, profile: profile)
                    var format: AVAudioFormat?
                    events: for try await event in stream.events() {
                        switch event {
                        case .start(let rate):
                            format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: false)
                        case .pcm(let data):
                            if let format, let buffer = Self.buffer(data, format: format) { continuation.yield(buffer) }
                        case .end:
                            break events
                        case .fallback:
                            let (data, mimeType) = try await backend.speak(text, profile: profile)
                            for buffer in try Self.decode(data, mimeType: mimeType) { continuation.yield(buffer) }
                            break events
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Little-endian int16 samples as a buffer.
    static func buffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.int16ChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            for index in 0..<frames {
                channel[index] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// A whole audio file (MP3, WAV, Ogg, FLAC from `speak`) as buffers.
    static func decode(_ data: Data, mimeType: String) throws -> [AVAudioPCMBuffer] {
        let ext = switch mimeType {
        case "audio/wav", "audio/x-wav": "wav"
        case "audio/ogg": "ogg"
        case "audio/flac": "flac"
        default: "mp3"
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "speak-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        var buffers: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            buffers.append(buffer)
        }
        return buffers
    }
}
