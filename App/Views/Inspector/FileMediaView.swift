import AVFoundation
import HermesKit
import OSLog
import SwiftUI

/// A picture or video file in the File tab (`inspectorPicture`, `inspectorVideo`): the path, the
/// picture fitted and zoomable, or the video's first frame with a play button and its length,
/// and a footer that says what it is (docs/inspector.md §2.8). Nothing of it is written to
/// disk, and it's let go when the tab closes.
struct FileMediaView: View {
    let inspector: InspectorModel
    let path: String
    let type: MediaFileType

    @State private var model: FileMediaModel

    /// The design rounds the picture and the video's frame alike.
    static let cornerRadius: CGFloat = 10

    init(inspector: InspectorModel, path: String, type: MediaFileType) {
        self.inspector = inspector
        self.path = path
        self.type = type
        _model = State(initialValue: FileMediaModel(path: path, type: type, backend: inspector.backend, profile: inspector.profile))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
            if let footer = model.footer {
                Divider().overlay(Theme.hairline)
                Text(footer)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 28)
            }
        }
        .task { model.load() }
        .onDisappear { model.tearDown() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(relativePath)
                .font(Theme.Typography.code)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            GatewayFileKeepButton(path: path, profile: inspector.profile, client: inspector.backend)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .loading:
            MediaLoadingView()
        case .picture(let image):
            FilePicture(image: image, name: model.name)
        case .video(let video):
            switch video.phase {
            case .failed(let problem):
                state(problem) { video.start(plays: false) }
            case .ready:
                if let player = video.player {
                    FileVideo(video: video, player: player, name: model.name)
                }
            case .idle, .loading:
                MediaLoadingView()
            }
        case .failed(let problem):
            state(problem) { model.start() }
        }
    }

    private func state(_ problem: MediaProblem, retry: @escaping () -> Void) -> some View {
        MediaStateView(problem: problem, fileName: model.name, video: type.kind == .video,
                       references: ReferenceContext(workspace: inspector.workspace), retry: retry)
            .padding(16)
    }

    private var relativePath: String {
        if let root = inspector.workingFolder, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }
}

/// The picture, fitted with rounded corners; a pinch or a double tap zooms it, and it pans once
/// zoomed. It's the viewer's `ZoomableImage` without the viewer's pages and bars.
private struct FilePicture: View {
    let image: CGImage
    let name: String

    @State private var step = 0
    @State private var zoomed = false

    var body: some View {
        ZoomableImage(image: image, step: $step, resets: 0, isCurrent: true, zoomed: $zoomed,
                      cornerRadius: FileMediaView.cornerRadius)
            .accessibilityLabel(name)
            .clipped()
            .padding(16)
    }
}

/// The video's first frame with a play button and its length (`inspectorVideo`). Play hands it
/// to the system player's own controls. The viewer's poster is the card's picture of the video;
/// a file in the tree has none, so its poster is the player's first frame.
private struct FileVideo: View {
    let video: VideoPlayback
    let player: AVPlayer
    let name: String

    @State private var playing = false

    var body: some View {
        ZStack {
            SystemPlayer(player: player, controls: playing)
                .accessibilityLabel(name)
            if !playing {
                MediaPlayButton(name: name, size: 56) {
                    playing = true
                    player.play()
                }
                if let duration = video.duration {
                    Text(MediaViewing.clock(duration))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .aspectRatio(video.size ?? CGSize(width: 16, height: 9), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: FileMediaView.cornerRadius, style: .continuous))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reads one media file for the File tab: a picture in one read through the backend, a video
/// streamed a stretch at a time (docs/inspector.md §2.8, docs/widgets.md §9.3).
@Observable
final class FileMediaModel {
    enum Content {
        case loading
        case picture(CGImage)
        case video(VideoPlayback)
        case failed(MediaProblem)
    }

    let path: String
    let type: MediaFileType
    private(set) var content = Content.loading
    private var pixels: (width: Int, height: Int)?
    private var bytes: Int64?

    @ObservationIgnored private let backend: BackendClient?
    @ObservationIgnored private let profile: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let log = Logger(subsystem: "co.caffeinatedcode.hermes", category: "inspector")

    init(path: String, type: MediaFileType, backend: BackendClient?, profile: String?) {
        self.path = path
        self.type = type
        self.backend = backend
        self.profile = profile
    }

    var name: String { ProjectPath.lastComponent(path) }

    /// "JPEG · 4,032 × 3,024 · 3.1 MB"; nothing until the file has answered.
    var footer: String? {
        switch content {
        case .picture:
            return MediaViewing.summary(type, width: pixels?.width, height: pixels?.height, duration: nil, bytes: bytes)
        case .video(let video) where video.phase == .ready:
            return MediaViewing.summary(type, width: video.size.map { Int($0.width) }, height: video.size.map { Int($0.height) },
                                        duration: video.duration, bytes: video.bytes)
        default:
            return nil
        }
    }

    /// Opens the file when the tab shows it, and again after it was closed and shown once more.
    func load() {
        guard task == nil, case .loading = content else { return }
        start()
    }

    /// Try Again.
    func start() {
        guard let backend else {
            content = .failed(.needsBotMode)
            return
        }
        switch type.kind {
        case .video:
            // It waits in the system player for a tap there; only what the first frame needs is read.
            let video = VideoPlayback(source: .gateway(client: backend, path: path, profile: profile), type: type)
            content = .video(video)
            video.start(plays: false)
        case .picture:
            task?.cancel()
            content = .loading
            let path = path, profile = profile
            task = Task { [weak self] in
                do {
                    let (data, _) = try await backend.downloadPicture(path, profile: profile)
                    try Task.checkCancellation()
                    let size = await MediaDecoder.pixelSize(data)
                    guard let image = await MediaDecoder.image(data) else { throw FileMediaUndecodable() }
                    try Task.checkCancellation()
                    self?.pixels = size
                    self?.bytes = Int64(data.count)
                    self?.content = .picture(image)
                } catch is CancellationError {
                } catch {
                    if let error = error as? URLError {
                        Self.log.error("file picture failed: \(error.code.rawValue, privacy: .public)")
                    } else {
                        Self.log.error("file picture failed: \(String(describing: Swift.type(of: error)), privacy: .public)")
                    }
                    self?.content = .failed(MediaProblem.of(error, video: false))
                }
                self?.task = nil
            }
        }
    }

    /// The tab closed: the picture and every read in flight go with it.
    func tearDown() {
        task?.cancel()
        task = nil
        if case .video(let video) = content { video.stop() }
        content = .loading
    }
}

private struct FileMediaUndecodable: Error {}
