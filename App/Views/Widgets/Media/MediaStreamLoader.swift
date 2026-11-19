import AVFoundation
import HermesKit
import OSLog
import Synchronization

/// Where a video's bytes come from (docs/widgets.md §9.3).
nonisolated enum MediaStreamSource: Sendable {
    /// A file on the gateway: `GET /api/files/stream` through the backend, with header auth and
    /// the chat's Bot profile.
    case gateway(client: BackendClient, path: String, profile: String?)
    /// An https video the card's tap to load let in: no key, no cache, redirects kept on its
    /// server (`RemoteMedia`).
    case web(URL)

    func range(_ range: ByteRange) async throws -> GatewayFileRange {
        switch self {
        case let .gateway(client, path, profile):
            try await client.fileStreamRange(path: path, profile: profile, range: range)
        case let .web(url):
            try await RemoteMedia.range(at: url, range: range)
        }
    }
}

/// Feeds AVPlayer a video a stretch at a time, held in memory only (docs/widgets.md §9.3).
///
/// The player is given a `hermes-media:` address that names neither the file nor the gateway,
/// so it can't fetch, cache or write anything itself: every byte comes through this delegate,
/// which asks the gateway (or the https server) for Range reads through the app's own sessions.
/// The key stays in request headers and never reaches a URL.
nonisolated final class MediaStreamLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    static let scheme = "hermes-media"
    /// One Range read; the player asks for more as it plays, so only a little is held at once.
    private static let chunk: Int64 = 1 << 20

    let source: MediaStreamSource
    /// The address the player is given: `hermes-media://video/<uuid>.mp4`.
    let url: URL
    let queue = DispatchQueue(label: "co.caffeinatedcode.hermes.media-stream")

    private let fallbackType: String
    private let failed: @Sendable (any Error) -> Void
    private let state = Mutex(State())

    private struct State {
        var total: Int64?
        var uniformType: String?
        var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    }

    /// The player's request, handed to the task that answers it, and that task. AVFoundation lets
    /// a loading request be answered from any thread once the delegate has kept it; this one only
    /// ever touches it on `queue`.
    private final class Request: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
        let task = Mutex<Task<Void, Never>?>(nil)

        init(request: AVAssetResourceLoadingRequest) {
            self.request = request
        }

        /// Whether the task that reads for it was cancelled. `Task.isCancelled` means nothing on
        /// `queue`, which runs outside any task, so the answer asks the task's handle.
        var isCancelled: Bool { task.withLock { $0?.isCancelled ?? false } }
    }

    private struct StreamEnded: Error {}

    init(source: MediaStreamSource, type: MediaFileType?, failed: @escaping @Sendable (any Error) -> Void) {
        self.source = source
        let suffix = type?.mimeType == "video/quicktime" ? "mov" : "mp4"
        url = URL(string: "\(Self.scheme)://video/\(UUID().uuidString).\(suffix)")!
        fallbackType = type?.uniformType ?? "public.mpeg-4"
        self.failed = failed
    }

    /// An asset that reads only through this loader.
    func asset() -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// The video's size in bytes, once the first read has answered.
    var total: Int64? { state.withLock { $0.total } }

    func cancelAll() {
        let tasks = state.withLock { state in
            defer { state.tasks.removeAll() }
            return Array(state.tasks.values)
        }
        tasks.forEach { $0.cancel() }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        let key = ObjectIdentifier(loadingRequest)
        let request = Request(request: loadingRequest)
        let task = Task { [weak self] in
            await self?.serve(request)
            _ = self?.state.withLock { $0.tasks.removeValue(forKey: key) }
        }
        request.task.withLock { $0 = task }
        state.withLock { $0.tasks[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let task = state.withLock { $0.tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }
        task?.cancel()
    }

    private func serve(_ request: Request) async {
        do {
            let (total, uniformType) = try await information()
            try Task.checkCancellation()
            answer(request) { loading in
                guard let info = loading.contentInformationRequest else { return }
                info.contentType = uniformType
                info.contentLength = total
                info.isByteRangeAccessSupported = true
            }
            if let dataRequest = request.request.dataRequest {
                let offset = dataRequest.requestedOffset
                let wanted = dataRequest.requestsAllDataToEndOfResource ? total - offset : Int64(dataRequest.requestedLength)
                let end = min(offset + max(wanted, 0), total)
                var next = offset
                while next < end {
                    try Task.checkCancellation()
                    guard let range = ByteRange(offset: next, length: min(Self.chunk, end - next)) else { break }
                    let part = try await source.range(range)
                    // A stretch that starts elsewhere, or nothing at all, is the stream cut short.
                    guard part.start == next, !part.data.isEmpty else { throw StreamEnded() }
                    let data = part.data.prefix(Int(end - next))
                    answer(request) { $0.dataRequest?.respond(with: data) }
                    next += Int64(data.count)
                }
            }
            answer(request) { $0.finishLoading() }
        } catch {
            // The player let go of this request (it seeked, or closed): nothing to report. On
            // the https route that arrives as a cancelled URL load rather than a CancellationError.
            if Task.isCancelled || RemoteMedia.isCancellation(error) { return }
            answer(request) { $0.finishLoading(with: error) }
            failed(error)
        }
    }

    /// Hands the player its answer on the delegate's queue, in order, without holding up the
    /// task that read it, and only while the player still wants the request and its task wasn't
    /// cancelled (a seek or a close) meanwhile.
    private func answer(_ request: Request, _ body: @escaping @Sendable (AVAssetResourceLoadingRequest) -> Void) {
        queue.async {
            let loading = request.request
            guard !request.isCancelled, !loading.isCancelled, !loading.isFinished else { return }
            body(loading)
        }
    }

    /// The video's size and type, from its first two bytes. A video has no size cap: it's never
    /// held whole (docs/widgets.md §9.3).
    private func information() async throws -> (Int64, String) {
        if let known = state.withLock({ state in state.total.map { ($0, state.uniformType ?? fallbackType) } }) {
            return known
        }
        let first = try await source.range(ByteRange(offset: 0, length: 2)!)
        guard let total = first.total, total > 0 else { throw StreamEnded() }
        let uniformType = first.contentType.flatMap { MediaFileType(mimeType: $0) }?.uniformType ?? fallbackType
        state.withLock { state in
            state.total = total
            state.uniformType = uniformType
        }
        return (total, uniformType)
    }
}

/// One video's player, from the tap to playing or a state (docs/widgets.md §9.3).
@Observable
final class VideoPlayback {
    enum Phase: Equatable {
        /// Nothing asked yet: the poster with its play button.
        case idle
        /// Asked: the poster stays, with a Spinner after 0.5 s.
        case loading
        /// The system player has it.
        case ready
        case failed(MediaProblem)
    }

    private(set) var phase = Phase.idle
    private(set) var player: AVPlayer?
    /// What the File tab's footer says about it, once it's ready.
    private(set) var bytes: Int64?
    private(set) var duration: Double?
    private(set) var size: CGSize?

    private let source: MediaStreamSource?
    private let type: MediaFileType?
    private let problem: MediaProblem?
    private var loader: MediaStreamLoader?
    private var observation: NSKeyValueObservation?
    /// A start that a newer one replaced gives up when it wakes.
    private var generation = 0
    /// Where it stopped, so Try Again carries on from there.
    private var resumeAt: CMTime = .zero
    /// Whether the start that's loading plays once it's ready.
    private var playsWhenReady = false

    private static let log = Logger(subsystem: "co.caffeinatedcode.hermes", category: "widgets")

    /// A video that can't be streamed (Bot Mode off, an address that names no file) starts in
    /// its state.
    init(source: MediaStreamSource?, type: MediaFileType?, problem: MediaProblem? = nil) {
        self.source = source
        self.type = type
        self.problem = problem
    }

    /// Starts streaming. `plays` starts it once it's ready (the tap that opened it); otherwise it
    /// waits in the system player for a tap there (the File tab).
    func start(plays: Bool) {
        if let problem {
            phase = .failed(problem)
            return
        }
        guard let source else { return }
        stop(keepingPlace: true)
        generation += 1
        let generation = generation
        phase = .loading
        let loader = MediaStreamLoader(source: source, type: type) { [weak self] error in
            Task { @MainActor in self?.fail(error, generation: generation) }
        }
        self.loader = loader
        let item = AVPlayerItem(asset: loader.asset())
        let player = AVPlayer(playerItem: item)
        self.player = player
        playsWhenReady = plays
        // The item's status is read where the change lands, on the main actor. An async sequence
        // of KVO changes drops one that arrives between two reads, and a short video read from
        // memory turns ready in exactly that gap.
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.statusChanged(generation: generation) }
        }
    }

    private func statusChanged(generation: Int) {
        guard self.generation == generation, phase == .loading,
              let player, let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            if resumeAt > .zero { player.seek(to: resumeAt) }
            bytes = loader?.total
            let seconds = item.duration.seconds
            duration = seconds.isFinite ? seconds : nil
            size = item.presentationSize == .zero ? nil : item.presentationSize
            phase = .ready
            if playsWhenReady { player.play() }
        case .failed:
            fail(item.error ?? URLError(.networkConnectionLost), generation: generation)
        default:
            break
        }
    }

    /// Lets go of the player and every read it had in flight; nothing of the video stays.
    func stop(keepingPlace: Bool = false) {
        if !keepingPlace {
            resumeAt = .zero
        } else if let time = player?.currentTime(), time.isNumeric {
            resumeAt = time
        }
        generation += 1
        observation?.invalidate()
        observation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        loader?.cancelAll()
        loader = nil
        if !keepingPlace { phase = .idle }
    }

    private func fail(_ error: any Error, generation: Int) {
        guard self.generation == generation, phase != .idle else { return }
        let failure = MediaProblem.of(error, video: true)
        if let error = error as? URLError {
            Self.log.error("video stream failed: \(error.code.rawValue, privacy: .public)")
        } else {
            Self.log.error("video stream failed: \(String(describing: Swift.type(of: error)), privacy: .public)")
        }
        stop(keepingPlace: true)
        phase = .failed(failure)
    }
}
