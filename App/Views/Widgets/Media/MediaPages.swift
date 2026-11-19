import AVFoundation
import HermesKit
import ImageIO
import OSLog
import SwiftUI

/// One page of the full-screen viewer: where its bytes come from and what it shows now
/// (docs/widgets.md §9.1, §9.2).
@Observable
final class MediaPage: Identifiable {
    enum Source: Equatable {
        /// An https picture the card let in: read without the key, never stored.
        case web(URL)
        /// A file on the gateway, read through the backend with the chat's Bot profile.
        case gateway(path: String, profile: String?)
        /// An https address on another server that the card hasn't been let to load yet.
        case asksWeb(host: String)
        case needsBotMode
        /// An address the app can't read: plain http, another scheme, no file.
        case unloadable
    }

    enum Content {
        case loading
        case shown(CGImage)
        case failed(MediaProblem)
    }

    let id: Int
    let item: MediaViewerItem
    private(set) var source: Source
    private(set) var content = Content.loading
    /// The picture's bytes, kept only while the page is near the one shown, for Save and Share.
    private(set) var data: Data?
    /// A video page's player; nil for a picture.
    private(set) var video: VideoPlayback?

    var isVideo: Bool { item.media.kind == .video }
    /// A video the tap that opened it may play: not one waiting for the card's tap to load,
    /// nor one the app can't read.
    var playsOnTap: Bool {
        switch source {
        case .asksWeb, .unloadable: false
        default: isVideo
        }
    }
    /// The https server a web item comes from, so its states name it rather than the gateway.
    var webHost: String? {
        if case .web(let url) = source { url.host(percentEncoded: true) } else { nil }
    }
    var fileName: String {
        let name = item.media.src.split(separator: "/").last.map(String.init) ?? item.media.src
        return name.removingPercentEncoding ?? name
    }

    private let references: ReferenceContext
    private var task: Task<Void, Never>?
    private static let log = Logger(subsystem: "co.caffeinatedcode.hermes", category: "widgets")

    init(id: Int, item: MediaViewerItem, references: ReferenceContext, gatewayHosts: Set<String>, webAllowed: Bool) {
        self.id = id
        self.item = item
        self.references = references
        source = Self.source(of: item.media, references: references, gatewayHosts: gatewayHosts, webAllowed: webAllowed)
        if isVideo { video = makeVideo() }
    }

    /// Where an item's bytes come from. The rule a card's pictures follow (docs/widgets.md §9):
    /// https on the gateway's own host loads, https elsewhere waits for the card's tap, anything
    /// else doesn't load.
    static func source(of media: WidgetMedia, references: ReferenceContext, gatewayHosts: Set<String>, webAllowed: Bool) -> Source {
        if let url = URL(string: media.src), let scheme = url.scheme?.lowercased(), scheme != "hermes-file" {
            guard scheme == "https" else { return .unloadable }
            if webAllowed || WebLink.isOnGateway(url, gatewayHosts: gatewayHosts) { return .web(url) }
            return .asksWeb(host: url.host(percentEncoded: true) ?? "")
        }
        switch references.gatewayPicture(.widget(media.src)) {
        case let .file(path, profile): return .gateway(path: path, profile: profile)
        case .needsBotMode: return .needsBotMode
        case .unreadable: return .unloadable
        }
    }

    /// The card's tap to load let https pictures in.
    func allowWeb() {
        guard case .asksWeb = source, let url = URL(string: item.media.src) else { return }
        source = .web(url)
        if isVideo { video = makeVideo() }
        if task != nil || data != nil { unload() }
    }

    private func makeVideo() -> VideoPlayback {
        let type = MediaFileType(path: item.media.src)
        switch source {
        case let .web(url):
            return VideoPlayback(source: .web(url), type: type)
        case let .gateway(path, profile):
            guard let client = references.roster?.boardClient else { return VideoPlayback(source: nil, type: type, problem: .needsBotMode) }
            return VideoPlayback(source: .gateway(client: client, path: path, profile: profile), type: type)
        case .needsBotMode:
            return VideoPlayback(source: nil, type: type, problem: .needsBotMode)
        case .asksWeb, .unloadable:
            return VideoPlayback(source: nil, type: type)
        }
    }

    /// Reads and decodes the picture, once, while the page is near the one shown. A video's
    /// poster is the card's; the video itself streams only when it's played.
    func prepare() {
        guard !isVideo, task == nil else { return }
        if case .shown = content { return }
        let source = source
        let references = references
        content = .loading
        task = Task { [weak self] in
            do {
                let bytes: Data
                switch source {
                case let .web(url):
                    bytes = try await RemoteMedia.picture(at: url)
                case let .gateway(path, profile):
                    guard let client = references.roster?.boardClient else { throw MediaPageNeedsBotMode() }
                    bytes = try await client.downloadPicture(path, profile: profile).0
                case .needsBotMode:
                    throw MediaPageNeedsBotMode()
                case .asksWeb, .unloadable:
                    return
                }
                try Task.checkCancellation()
                guard let image = await MediaDecoder.image(bytes) else { throw MediaPageUndecodable() }
                try Task.checkCancellation()
                self?.data = bytes
                self?.content = .shown(image)
            } catch is CancellationError {
            } catch is MediaPageNeedsBotMode {
                self?.content = .failed(.needsBotMode)
            } catch {
                if let error = error as? URLError {
                    Self.log.error("viewer picture failed: \(error.code.rawValue, privacy: .public)")
                } else {
                    Self.log.error("viewer picture failed: \(String(describing: type(of: error)), privacy: .public)")
                }
                self?.content = .failed(MediaProblem.of(error, video: false))
            }
            self?.task = nil
        }
    }

    /// Try Again.
    func retry() {
        if let video {
            video.start(plays: true)
        } else {
            unload()
            prepare()
        }
    }

    /// Lets go of the picture's bytes and a playing video: only the pages near the one shown
    /// hold anything.
    func unload() {
        task?.cancel()
        task = nil
        data = nil
        content = .loading
        video?.stop()
    }

    func tearDown() {
        unload()
    }
}

private struct MediaPageNeedsBotMode: Error {}
private struct MediaPageUndecodable: Error {}

/// Decodes a picture off the main actor, fitted to a size a full screen needs.
nonisolated enum MediaDecoder {
    /// Large enough for a zoomed Retina screen, small enough that a 48 MP photo doesn't take
    /// hundreds of megabytes.
    static let maxPixels = 3072

    @concurrent
    static func image(_ data: Data, maxPixels: Int = maxPixels) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A picture's pixel size from its header, without decoding it.
    @concurrent
    static func pixelSize(_ data: Data) async -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }
}

/// What the viewer pages through and which page is shown (docs/widgets.md §9.1).
@Observable
final class MediaViewerModel {
    let request: MediaViewerRequest
    let pages: [MediaPage]
    var current: Int?
    var chromeHidden = false
    /// The shown picture is zoomed in: paging and swipe down to close wait.
    var zoomed = false
    /// Steps of ⌘+ and ⌘− for the shown picture, read by its page.
    var zoomStep = 0
    var zoomResets = 0
    /// The tap that opened the viewer on a video plays it, the first time its page shows.
    private var playsOpenedVideo = true

    init(request: MediaViewerRequest) {
        self.request = request
        pages = request.items.map {
            MediaPage(id: $0.id, item: $0, references: request.references, gatewayHosts: request.gatewayHosts, webAllowed: request.webAllowed)
        }
        current = pages.indices.contains(request.start) ? request.start : 0
    }

    var shown: MediaPage? { current.flatMap { pages.indices.contains($0) ? pages[$0] : nil } }

    /// Keeps the shown page and its neighbours read, lets go of the rest, and stops a video
    /// that paged away.
    func pageChanged() {
        zoomed = false
        zoomStep = 0
        guard let current else { return }
        for (index, page) in pages.enumerated() {
            if abs(index - current) <= 1 {
                if index != current { page.video?.stop(keepingPlace: false) }
                page.prepare()
            } else {
                page.unload()
            }
        }
        if playsOpenedVideo {
            playsOpenedVideo = false
            if let page = shown, page.playsOnTap { page.video?.start(plays: true) }
        }
    }

    /// The card's tap to load, from inside the viewer: every https page on that card loads.
    func allowWeb() {
        request.allowWeb()
        pages.forEach { $0.allowWeb() }
        pageChanged()
    }

    func go(_ step: Int) {
        guard let current else { return }
        let next = current + step
        guard pages.indices.contains(next) else { return }
        self.current = next
    }

    func tearDown() {
        pages.forEach { $0.tearDown() }
    }
}

// MARK: Pages

/// The pages side by side, one screen each, paging with a swipe, the arrow keys or the
/// chevrons.
struct MediaPager: View {
    @Bindable var model: MediaViewerModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(model.pages) { page in
                        MediaPageView(page: page, model: model, isCurrent: model.current == page.id)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(page.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $model.current)
            // The viewer grows from the tile, so its first layouts are narrower than a page will
            // be, and a rotation or a resized window changes the width too: each time, the shown
            // page is put back in place, or the pages would rest one off from the label.
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, _ in
                if let current = model.current { proxy.scrollTo(current) }
            }
        }
        .scrollDisabled(model.zoomed || model.pages.count < 2)
        .scrollIndicators(.hidden)
        #if os(iOS)
        .ignoresSafeArea()
        #else
        // On the Mac the pages sit between the top bar and the caption, never under them.
        .clipped()
        #endif
    }
}

struct MediaPageView: View {
    let page: MediaPage
    let model: MediaViewerModel
    let isCurrent: Bool

    var body: some View {
        Group {
            if page.isVideo, let video = page.video {
                VideoPage(page: page, video: video, model: model, isCurrent: isCurrent)
            } else {
                picture
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var picture: some View {
        switch page.source {
        case .asksWeb(let host):
            MediaAskView(media: page.item.media, host: host) { model.allowWeb() }
        case .unloadable:
            MediaUnloadableView(media: page.item.media)
        default:
            switch page.content {
            case .loading:
                MediaLoadingView()
            case .shown(let image):
                ZoomablePicture(image: image, page: page, model: model, isCurrent: isCurrent)
            case .failed(let problem):
                MediaStateView(problem: problem, fileName: page.fileName, video: false,
                               references: model.request.references, host: page.webHost) { page.retry() }
            }
        }
    }
}

/// A viewer page's picture: the zoomable picture, where a single tap shows or hides the bars and
/// ⌘+, ⌘− and ⌘0 come from the viewer's keys.
struct ZoomablePicture: View {
    let image: CGImage
    let page: MediaPage
    @Bindable var model: MediaViewerModel
    let isCurrent: Bool
    @Environment(\.mediaBarInsets) private var bars

    var body: some View {
        ZoomableImage(image: image, step: $model.zoomStep, resets: model.zoomResets, isCurrent: isCurrent,
                      zoomed: $model.zoomed, clearOf: bars) { model.chromeHidden.toggle() }
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [page.item.media.alt]
        if let caption = page.item.caption { parts.append(caption) }
        if let position = MediaViewing.position(page.id, of: model.pages.count) {
            parts.append(String(localized: "Picture \(position.current) of \(position.total)"))
        }
        return parts.joined(separator: ", ")
    }
}

/// A video page: the card's poster with a play button until it's played, then the system
/// player (docs/widgets.md §9.3).
struct VideoPage: View {
    let page: MediaPage
    let video: VideoPlayback
    let model: MediaViewerModel
    let isCurrent: Bool

    var body: some View {
        switch video.phase {
        case .ready:
            if let player = video.player {
                SystemPlayer(player: player)
                    .accessibilityLabel(page.item.media.alt)
            }
        case .failed(let problem):
            MediaStateView(problem: problem, fileName: page.fileName, video: true,
                           references: model.request.references, host: page.webHost) { page.retry() }
        case .idle, .loading:
            switch page.source {
            case .asksWeb(let host):
                MediaAskView(media: page.item.media, host: host) { model.allowWeb() }
            case .unloadable:
                MediaUnloadableView(media: page.item.media)
            default:
                poster
            }
        }
    }

    private var poster: some View {
        ZStack {
            if let thumb = page.item.media.thumb {
                MediaPoster(media: page.item.media, thumb: thumb, gatewayHosts: model.request.gatewayHosts)
            }
            if video.phase == .loading {
                Spinner(size: .regular)
                    .frame(width: 64, height: 64)
                    .glassEffect(.regular, in: Circle())
            } else {
                MediaPlayButton(name: page.item.media.alt, size: 64) { video.start(plays: true) }
                    .keyboardShortcut(isCurrent ? KeyboardShortcut(.space, modifiers: []) : nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.chromeHidden.toggle() }
    }
}

/// The glass play button over a video's poster, in the viewer and the File tab alike.
struct MediaPlayButton: View {
    let name: String
    /// 64 in the viewer, 56 in the File tab's smaller frame.
    let size: CGFloat
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(String(localized: "Play \(name)"))
    }
}

/// A video's poster in the viewer, fitted: the card's own picture of it.
private struct MediaPoster: View {
    let media: WidgetMedia
    let thumb: String
    let gatewayHosts: Set<String>

    var body: some View {
        Group {
            if let url = URL(string: thumb), url.scheme?.lowercased() == "https" {
                if WebLink.isOnGateway(url, gatewayHosts: gatewayHosts) {
                    RemoteImage(url: url) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFit() }
                    }
                }
            } else if WidgetFile.path(thumb) != nil {
                GatewayFileImage(source: .widget(thumb)) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFit() }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A picture still reading: the canvas, with a Spinner (which waits half a second itself).
struct MediaLoadingView: View {
    var body: some View {
        Spinner(size: .regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(String(localized: "Loading"))
    }
}

/// An https item on another server that the card hasn't loaded yet: the card's own tap to load.
struct MediaAskView: View {
    let media: WidgetMedia
    let host: String
    let allow: () -> Void

    var body: some View {
        MediaClearOfBars {
            Button(action: allow) {
                VStack(spacing: 8) {
                    Image(systemName: media.kind == .video ? "video" : "photo")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.tertiaryText)
                    Text(media.alt).font(.subheadline).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                    Text("Tap to load from \(host)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.primaryText)
                }
                .padding(32)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// An item the app can't load: what it shows, in words.
struct MediaUnloadableView: View {
    let media: WidgetMedia

    var body: some View {
        MediaClearOfBars {
            VStack(spacing: 8) {
                Image(systemName: media.kind == .video ? "video" : "photo")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.tertiaryText)
                Text(media.alt).font(.subheadline).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}
