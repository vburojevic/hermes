import AVFoundation
import HermesKit
import HermesMarkdown
#if os(iOS)
import LinkPresentation
#endif
import OSLog
import QuickLook
import Synchronization
import SwiftUI
import UniformTypeIdentifiers

/// A reply's text with its widgets where its directives are (`docs/widgets.md` §2): Markdown as
/// before between them, and a card for each `::widget{…}` line. A reply without widgets is one
/// `MarkdownView`, untouched.
struct ReplyBody: View, Equatable {
    let text: String
    var streaming = false
    var caches = true
    /// Inline ` ```widget ` blocks draw (a delivery the plugin processed, or the developer setting).
    var inlineWidgets = WidgetSettings.rendersInlineBlocks
    /// A payload typed into a fence reads as its words, never code: a routine's delivery, where
    /// the model wrote the widget instead of making it.
    var typedAsText = false
    /// The sentence Listen is reading (`docs/voice.md` §3), in a reply that's all Markdown.
    var highlight: SpokenSentence?
    /// The files the reply sent (`AssistantTurn.attachments`), drawn where their notes are
    /// (`docs/chat.md` §3a).
    var attachments: [ReplyAttachment] = []
    /// The reply they're in (its turn's id), so their tiles' zooms into the viewer are their own.
    var owner = ""

    var body: some View {
        // A finished reply with files is split once and kept, with its parsed Markdown
        // (`MarkdownCache`); one without any is told so by a scan of its bytes, as before.
        let segments = caches && !streaming && !attachments.isEmpty
            ? MarkdownCache.segments(for: text, inlineWidgets: inlineWidgets, typedAsText: typedAsText, attachments: attachments)
            : ReplySplitter.split(text, inlineWidgets: inlineWidgets, streaming: streaming, typedAsText: typedAsText, attachments: attachments)
        if segments.count == 1, case .markdown(let markdown) = segments[0] {
            MarkdownView(text: markdown, caches: caches, highlight: highlight, selectsWhole: true)
        } else {
            let viewerFiles = ReplyAttachment.viewerFiles(in: segments)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    // Only the last segment can end the row (`docs/chat.md` §1): text before a
                    // widget never does, and a widget that ends a reply with no words lands on its
                    // card (`WidgetSlot`).
                    Group {
                        switch segment {
                        case .markdown(let markdown): MarkdownView(text: markdown, caches: caches, selectsWhole: true)
                        case .widget(let directive): WidgetSlot(directive: directive)
                        case .inline(let json): InlineWidgetSlot(json: json)
                        case .typed(let json): WidgetFallbackView(fallback: Self.typedFallback(json))
                        case .unreadable: WidgetFallbackView(fallback: Self.unreadableFallback)
                        case .attachments(let files):
                            ReplyAttachmentsView(files: files, viewerFiles: viewerFiles,
                                                 viewerStart: ReplyAttachment.viewerFiles(in: Array(segments[..<index])).count,
                                                 owner: owner)
                        case .preview(let directive):
                            PagePreviewCard(directive: directive, owner: owner, streaming: streaming)
                        }
                    }
                    .modifier(VoiceOverLandingEnds(isLast: index == segments.count - 1))
                }
            }
        }
    }

    /// Whether `text` has anything but Markdown in it.
    static func hasWidgets(_ text: String, inlineWidgets: Bool, typedAsText: Bool = false) -> Bool {
        ReplySplitter.split(text, inlineWidgets: inlineWidgets, typedAsText: typedAsText).contains { segment in
            if case .markdown = segment { false } else { true }
        }
    }

    /// A typed payload shown as its words, the way a widget the app can't draw is: never as a
    /// card, since nothing stored or checked it (`docs/widgets.md` §2).
    static func typedFallback(_ json: JSONValue) -> WidgetFallback {
        WidgetFallback(
            id: nil, rev: 1, type: json["type"]?.stringValue, title: json["title"]?.stringValue,
            text: ReplySplitter.typedWords(json),
            reason: .invalid(String(localized: "the routine wrote this widget out instead of making it")),
            isPrivate: json["sensitivity"]?.stringValue != "normal", json: json)
    }

    /// A payload that couldn't be read (cut off, not JSON, no words): a plain line in its place,
    /// never its raw text (`docs/widgets.md` §2).
    static var unreadableFallback: WidgetFallback {
        WidgetFallback(
            id: nil, rev: 1, type: nil, title: nil, text: String(localized: "Couldn't show this card."),
            reason: .invalid(String(localized: "its payload couldn't be read")),
            isPrivate: false, json: .object([:]))
    }
}

/// Your side of a widget's round trip (`Parts.actionBubble`): a small pill where the message
/// would be ("Approved · Lunch order"), never the raw `[widget …]` text.
struct ActionBubble: View {
    let answer: WidgetAnswer

    @Environment(\.widgetHost) private var host

    var body: some View {
        let payload = host?.store.payload(answer.widgetID)
        let detail = [payload?.title, answer.words].compactMap { $0 }.joined(separator: " · ")
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(answer.action))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.inkForeground)
                .frame(width: 30, height: 30)
                .background(Theme.ink, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.label(answer, payload: payload)).font(WidgetFont.body.weight(.semibold)).foregroundStyle(Theme.primaryText)
                if !detail.isEmpty {
                    Text(detail).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([Self.label(answer, payload: payload), detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// The answer as a past action, in whole phrases ("Approved"), or the payload's own button label.
    static func label(_ answer: WidgetAnswer, payload: WidgetPayload?) -> String {
        WidgetAnswer.pastTense(answer.action)
            ?? payload.flatMap { label(of: answer.action, in: $0) }
            ?? answer.action.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// A payload's own action's label, wherever it is (the action row, a row, a do-first).
    private static func label(of id: String, in payload: WidgetPayload) -> String? {
        func search(_ value: JSONValue) -> String? {
            switch value {
            case .object(let object):
                if object["id"]?.stringValue == id, let label = object["label"]?.stringValue, object["kind"]?.stringValue ?? "reply" == "reply" { return label }
                for child in object.values { if let found = search(child) { return found } }
            case .array(let array):
                for child in array { if let found = search(child) { return found } }
            default:
                break
            }
            return nil
        }
        return search(payload.json["actions"] ?? .null) ?? search(payload.json)
    }

    static func symbol(_ action: String) -> String {
        switch action {
        case "reject", "cancel": "xmark"
        case "edit": "pencil"
        case "undo": "arrow.uturn.backward"
        case "refresh", "retry": "arrow.clockwise"
        case "rate": "star.fill"
        case "set": "slider.horizontal.3"
        default: "checkmark"
        }
    }
}

// MARK: - Files a reply sends

/// Files Hermes sent on lines next to each other (`MEDIA:` lines, `docs/chat.md` §3a): pictures
/// and videos as tiles (`imageResult`), one drawn whole up to 480 pt and several in a grid, and
/// every other file as a card (`fileResult`). Nothing is read until it's on screen, and nothing
/// is written to disk but a copy the person saves.
struct ReplyAttachmentsView: View {
    let files: [ReplyAttachment]
    /// The reply's pictures and videos, which the viewer pages through, and where in them these
    /// files start.
    let viewerFiles: [ReplyAttachment]
    let viewerStart: Int
    /// The reply the files are in, so a tile's zoom into the viewer is its own.
    let owner: String

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.runs(files, viewerStart: viewerStart), id: \.offset) { run in
                if run.visual {
                    media(run)
                } else {
                    ForEach(Array(run.files.enumerated()), id: \.offset) { _, file in
                        ReplyFileCard(file: file)
                    }
                }
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    @ViewBuilder
    private func media(_ run: Run) -> some View {
        if run.files.count == 1, let file = run.files.first {
            ReplyMediaTile(file: file, page: run.firstPage, viewerFiles: viewerFiles, owner: owner, single: true)
        } else {
            let columns = typeSize.isAccessibilitySize ? 1 : 2
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(Array(stride(from: 0, to: run.files.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<min(start + columns, run.files.count), id: \.self) { index in
                            ReplyMediaTile(file: run.files[index], page: run.firstPage + index, viewerFiles: viewerFiles,
                                           owner: owner, single: false)
                                .frame(height: 160)
                        }
                    }
                }
            }
        }
    }

    struct Run {
        var offset: Int
        var visual: Bool
        var files: [ReplyAttachment]
        /// The viewer's page for the run's first file.
        var firstPage: Int
    }

    /// The files in runs: pictures and videos together, the other files together, in order.
    static func runs(_ files: [ReplyAttachment], viewerStart: Int) -> [Run] {
        var runs: [Run] = []
        var page = viewerStart
        for file in files {
            if let last = runs.last, last.visual == file.isVisual {
                runs[runs.count - 1].files.append(file)
            } else {
                runs.append(Run(offset: runs.count, visual: file.isVisual, files: [file], firstPage: page))
            }
            if file.isVisual { page += 1 }
        }
        return runs
    }
}

/// Decoded pictures and video posters of files replies sent, kept in memory only (never on
/// disk), so a reply scrolled back into view doesn't read its files again. The system takes
/// them back under memory pressure.
nonisolated enum ReplyMediaCache {
    final class Entry {
        let image: CGImage?
        let duration: Double?
        init(image: CGImage?, duration: Double?) {
            self.image = image
            self.duration = duration
        }
    }

    nonisolated(unsafe) private static let entries: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 60
        return cache
    }()

    static func entry(_ key: String) -> Entry? { entries.object(forKey: key as NSString) }
    static func keep(_ entry: Entry, for key: String) { entries.setObject(entry, forKey: key as NSString) }

    /// Cards' sizes, so a card scrolled back into view doesn't ask the gateway again.
    nonisolated(unsafe) private static let sizes: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 200
        return cache
    }()

    static func size(_ path: String) -> Int64? { sizes.object(forKey: path as NSString)?.int64Value }
    static func keepSize(_ size: Int64, for path: String) { sizes.setObject(NSNumber(value: size), forKey: path as NSString) }
}

/// One picture or video a reply sent. A picture is read whole (up to `MediaViewing.maxBytes`,
/// over that it's a card) and drawn at the size it's shown; a video shows its first frame and
/// length, read a stretch at a time like the viewer streams it. A tap opens the viewer on it.
/// What went wrong shows as the file's card, saying so (`ReplyFileCard`).
private struct ReplyMediaTile: View {
    let file: ReplyAttachment
    let page: Int
    let viewerFiles: [ReplyAttachment]
    let owner: String
    /// Drawn on its own, at its own shape, rather than in a grid's square.
    let single: Bool

    enum Phase {
        case loading
        case shown(CGImage?, duration: Double?)
        case failed(MediaProblem)
    }

    @Environment(\.references) private var references
    @Environment(\.gatewayHosts) private var gatewayHosts
    @Environment(\.mediaViewer) private var viewer
    @Environment(\.mediaViewerNamespace) private var namespace
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = Phase.loading
    @State private var attempt = 0
    @State private var copying = GatewayFileCopy.State()

    private var cacheKey: String { "\(file.path)\u{0}\(Int(displayScale))" }

    var body: some View {
        Group {
            if case .failed(let problem) = phase {
                // In a grid it keeps the tile's place; on its own it's the file's card.
                ReplyFileCard(file: file, problem: problem, fillsTile: !single) { attempt += 1 }
            } else {
                Button(action: open) { tile }
                    .buttonStyle(.plain)
                    .disabled(viewer == nil)
                    .overlay { if copying.isReading { Spinner() } }
                    // The viewer saves a picture to Photos; this keeps the file itself.
                    .contextMenu { if !copying.isReading { GatewayFileCopyMenu(keep: keep) } }
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityHint(String(localized: "Opens full screen"))
                    .modifier(GatewayFileCopyActions(enabled: !copying.isReading, keep: keep))
                    .modifier(ReplyMediaTransitionSource(id: transitionID, namespace: namespace))
            }
        }
        .gatewayFileCopies($copying, alerts: true, retry: keep)
        .task(id: Load(picture: references.gatewayPicture(.path(file.path)), attempt: attempt)) { await load() }
        #if DEBUG
        // Again once the reply has finished, so the viewer pages through all of its files.
        .task(id: viewerFiles.count) { if await ReplyFileLaunchFlag.opens(file) { open() } }
        #endif
    }

    private struct Load: Hashable {
        var picture: ReferenceContext.GatewayPicture
        var attempt: Int
    }

    @ViewBuilder
    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            switch phase {
            case .shown(let image?, _):
                let picture = Image(decorative: image, scale: displayScale)
                if single {
                    picture.resizable().scaledToFit()
                } else {
                    Color.clear.overlay { picture.resizable().scaledToFill() }
                }
            default:
                Theme.controlFill
                    .frame(height: single ? (file.kind == .video ? 220 : 200) : nil)
            }
            if file.kind == .video { videoMarks }
        }
        .frame(maxWidth: single ? 480 : .infinity, maxHeight: single ? 480 : .infinity, alignment: .leading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
        .contentShape(shape)
    }

    /// The play button and the video's length over its poster (design `mediaChat`).
    @ViewBuilder
    private var videoMarks: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .glassEffect(.regular, in: Circle())
            .accessibilityHidden(true)
        if case .shown(_, let duration?) = phase {
            Text(MediaViewing.clock(duration))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .accessibilityHidden(true)
        }
    }

    private var label: String {
        var parts = [file.fileName]
        if file.kind == .video {
            parts.append(String(localized: "video"))
            if case .shown(_, let duration?) = phase { parts.append(MediaViewing.clock(duration)) }
        } else {
            parts.append(String(localized: "picture"))
        }
        return parts.joined(separator: ", ")
    }

    private var transitionID: String { "\(owner)-file-\(page)" }

    private func open() {
        guard let viewer else { return }
        let request = MediaViewerRequest(files: viewerFiles, start: page, references: references, gatewayHosts: gatewayHosts,
                                         transitionID: transitionID)
        viewer.open(request, reducesMotion: reduceMotion)
    }

    private func keep(_ use: GatewayFileCopy.Use) {
        guard case .file(let path, let profile) = references.gatewayPicture(.path(file.path)) else { return }
        let client = references.roster?.boardClient
        Task { await GatewayFileCopy.keep(path, profile: profile, client: client, as: use, in: $copying) }
    }

    private func load() async {
        if let kept = ReplyMediaCache.entry(cacheKey) {
            phase = .shown(kept.image, duration: kept.duration)
            return
        }
        switch references.gatewayPicture(.path(file.path)) {
        case .needsBotMode:
            phase = .failed(.needsBotMode)
            return
        case .unreadable:
            phase = .failed(file.kind == .video ? .couldntPlay : .couldntLoad)
            return
        case .file(let path, let profile):
            guard let client = references.roster?.boardClient else {
                phase = .failed(.needsBotMode)
                return
            }
            if case .failed = phase { phase = .loading }
            do {
                let pixels = Int((480 * displayScale).rounded(.up))
                let entry: ReplyMediaCache.Entry
                if file.kind == .video {
                    entry = try await ReplyVideoPoster.read(path: path, profile: profile, client: client, maxPixels: pixels)
                } else {
                    let (data, _) = try await client.downloadPicture(path, profile: profile)
                    try Task.checkCancellation()
                    guard let image = await MediaDecoder.image(data, maxPixels: pixels) else { throw ReplyMediaUndecodable() }
                    entry = ReplyMediaCache.Entry(image: image, duration: nil)
                }
                try Task.checkCancellation()
                ReplyMediaCache.keep(entry, for: cacheKey)
                withTransaction(Transaction(animation: reduceMotion ? nil : .smooth(duration: 0.3))) {
                    phase = .shown(entry.image, duration: entry.duration)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                ReplyVideoPoster.log(error, video: file.kind == .video)
                phase = .failed(MediaProblem.of(error, video: file.kind == .video))
            }
        }
    }
}

private struct ReplyMediaUndecodable: Error {}

/// The tile the viewer grows from on iPhone and iPad; the Mac crossfades instead.
private struct ReplyMediaTransitionSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// A video's first frame and length, read through the gateway's stream a stretch at a time
/// (`MediaStreamLoader`), the way the viewer plays it: never the whole file.
nonisolated enum ReplyVideoPoster {
    private static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "widgets")

    @concurrent
    static func read(path: String, profile: String?, client: BackendClient, maxPixels: Int) async throws -> ReplyMediaCache.Entry {
        let failure = Mutex<(any Error)?>(nil)
        let loader = MediaStreamLoader(source: .gateway(client: client, path: path, profile: profile), type: MediaFileType(path: path)) { error in
            failure.withLock { $0 = $0 ?? error }
        }
        defer { loader.cancelAll() }
        let asset = loader.asset()
        do {
            let duration = try await asset.load(.duration).seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            let (image, _) = try await generator.image(at: .zero)
            return ReplyMediaCache.Entry(image: image, duration: duration.isFinite ? duration : nil)
        } catch {
            // The gateway's own answer (gone, kept private) says more than the player's.
            throw failure.withLock { $0 } ?? error
        }
    }

    /// Domain and code only: a URL error's description carries the gateway's address.
    static func log(_ error: any Error, video: Bool) {
        let nsError = error as NSError
        var status = 0
        if case BackendClient.Failure.http(let code, _) = error { status = code }
        logger.error("reply \(video ? "video" : "picture", privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code) HTTP \(status)")
    }
}

/// A file a reply sent that isn't drawn (`fileResult`): its kind, name, type and size, and what
/// a tap does. A document opens in the chat's Inspector (text in the File tab, a page or a PDF in
/// a Preview tab); any other file saves a copy where the person chooses. A picture or video that
/// couldn't be shown is one of these, saying why.
struct ReplyFileCard: View {
    let file: ReplyAttachment
    /// Why the picture or video this stands in for didn't show.
    var problem: MediaProblem?
    /// It stands in for a picture or video in a grid: centred in the tile's frame.
    var fillsTile = false
    var retry: (() -> Void)?

    @Environment(\.references) private var references
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var size: Int64?
    /// What a `HEAD` of the file said, when it refused it.
    @State private var checked: MediaProblem?
    @State private var copying = GatewayFileCopy.State()
    @State private var linkingBotMode = false

    private enum Action { case open, save, retry, linkBotMode, none }

    /// What the card says went wrong, if anything. A picture too big to draw isn't wrong: it
    /// saves a copy, like any file the Inspector can't show.
    private var shownProblem: MediaProblem? {
        if !references.isBotModeOn { return .needsBotMode }
        if let problem, !Self.isTooBig(problem) { return problem }
        return copying.problem ?? checked
    }

    private var action: Action {
        switch shownProblem {
        case .couldntLoad?, .couldntPlay?: return .retry
        // The fix is in the app: Edit Gateway's Bot Mode (docs/setup.md §4.1).
        case .needsBotMode?: return references.workspace == nil ? .none : .linkBotMode
        case .some: return .none
        case nil: break
        }
        if let problem, Self.isTooBig(problem) { return .save }
        return file.kind == .file ? .save : .open
    }

    private static func isTooBig(_ problem: MediaProblem) -> Bool {
        if case .tooBig = problem { true } else { false }
    }

    var body: some View {
        Group {
            if action == .none {
                // Nothing to do: words, not a dimmed button, so they read at full contrast.
                card
            } else {
                Button(action: perform) { card }
                    .buttonStyle(.plain)
                    .disabled(copying.isReading)
            }
        }
        // Save and Share for any file it can read, whatever its tap does (docs/chat.md §3a).
        .contextMenu {
            if offersCopy { GatewayFileCopyMenu(keep: keep) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([file.fileName, detail].joined(separator: ", "))
        .accessibilityHint(hint)
        .accessibilityAddTraits(action == .none ? [] : .isButton)
        .accessibilityAction { perform() }
        .modifier(GatewayFileCopyActions(enabled: offersCopy, keep: keep))
        .task(id: "\(file.path)\u{0}\(references.isBotModeOn)") { await checkSize() }
        #if DEBUG
        .task { if await ReplyFileLaunchFlag.opens(file) { perform() } }
        #endif
        .gatewayFileCopies($copying)
        .sheet(isPresented: $linkingBotMode) {
            if let workspace = references.workspace {
                NavigationStack {
                    BotEditorView(mode: .edit(workspace.bot)) { linkingBotMode = false }
                }
                #if os(macOS)
                .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
                #endif
            }
        }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: fillsTile ? 16 : 14, style: .continuous)
        return Group {
            if fillsTile {
                VStack(spacing: 6) {
                    glyph
                    Text(verbatim: file.fileName)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    actionLabel
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) { glyph; words }
                    actionLabel
                }
            } else {
                HStack(spacing: 10) {
                    glyph
                    words
                    Spacer(minLength: 8)
                    actionLabel
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: fillsTile ? .infinity : 480, alignment: .leading)
        .background(Theme.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
        .contentShape(shape)
    }

    private var glyph: some View {
        Image(systemName: shownProblem.map(Self.symbol) ?? Self.symbol(for: file))
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(shownProblem == nil ? Theme.primaryText : Theme.tertiaryText)
            .frame(width: 36, height: 36)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: file.fileName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .truncationMode(.middle)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionLabel: some View {
        if copying.isReading {
            Spinner()
        } else if action != .none {
            Text(actionTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Theme.controlFill, in: Capsule())
                .accessibilityHidden(true)
        }
    }

    private var actionTitle: String {
        switch action {
        case .open: String(localized: "Open")
        case .save: String(localized: "Save")
        case .retry: String(localized: "Try Again")
        case .linkBotMode: references.workspace.map(BotModeLinkButton.title(for:)) ?? ""
        case .none: ""
        }
    }

    private var hint: String {
        switch action {
        case .open:
            switch file.opens {
            case .preview: String(localized: "Opens in a Preview tab")
            case .quickLook: String(localized: "Opens in Quick Look")
            default: String(localized: "Opens in the Inspector")
            }
        case .save: String(localized: "Saves a copy to this device")
        case .retry: String(localized: "Tries again")
        case .linkBotMode: String(localized: "Opens Edit Gateway")
        case .none: ""
        }
    }

    /// "PDF · 44 KB", or what went wrong.
    private var detail: String {
        if let problem = shownProblem { return Self.note(problem, video: file.kind == .video) }
        var parts = [file.typeName]
        if case .tooBig(let bytes)? = problem {
            parts += [bytes.formatted(.byteCount(style: .file)), String(localized: "too big to show here")]
        } else if let size {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }

    /// The viewer's states, as one line (docs/widgets.md §9.2).
    static func note(_ problem: MediaProblem, video: Bool) -> String {
        switch problem {
        case .gone: String(localized: "Not on the gateway anymore")
        case .notAllowed: String(localized: "Hermes doesn't share this file")
        case .needsBotMode: String(localized: "Turn on Bot Mode to open it")
        case .couldntLoad: String(localized: "Couldn't load this file")
        case .couldntPlay: String(localized: "Couldn't play this video")
        case .tooBig(let bytes):
            String(localized: "It's \(bytes.formatted(.byteCount(style: .file))), too big to save here")
        }
    }

    private static func symbol(_ problem: MediaProblem) -> String {
        switch problem {
        case .notAllowed: "lock.fill"
        case .needsBotMode: "server.rack"
        case .gone: "questionmark.folder"
        case .couldntLoad, .couldntPlay, .tooBig: "exclamationmark.triangle"
        }
    }

    static func symbol(for file: ReplyAttachment) -> String {
        switch file.suffix {
        case "pdf": "doc.richtext"
        case "html", "htm": "globe"
        case "md", "markdown", "txt", "text", "rst", "log": "doc.text"
        case "csv", "tsv", "xlsx", "xls", "ods", "numbers": "tablecells"
        case "docx", "doc", "rtf", "odt", "pages": "doc.richtext"
        case "pptx", "ppt", "odp", "key": "rectangle.on.rectangle"
        case "json", "jsonl", "ndjson", "yaml", "yml", "toml", "xml": "curlybraces"
        case "zip", "gz", "tgz", "tar", "7z", "rar": "doc.zipper"
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg": "photo"
        case "mp4", "mov": "video"
        default: GatewayFileOpening.destination(for: file.fileName) == .fileTab ? "chevron.left.forwardslash.chevron.right" : "doc"
        }
    }

    private func perform() {
        switch action {
        case .open:
            if file.opens == .quickLook {
                keep(.look)
            } else {
                references.openInInspector(file.path)
            }
        case .save:
            keep(.save)
        case .retry:
            if copying.problem != nil {
                copying.problem = nil
            } else {
                retry?()
            }
        case .linkBotMode:
            linkingBotMode = true
        case .none:
            break
        }
    }

    /// The file's size and whether the gateway shares it, from a `HEAD`: nothing of it is read.
    private func checkSize() async {
        guard problem == nil, case .file(let path, let profile) = references.gatewayPicture(.path(file.path)),
              let client = references.roster?.boardClient else { return }
        if let kept = ReplyMediaCache.size(path) {
            size = kept
            return
        }
        do {
            size = try await client.fileSize(path, profile: profile)
            if let size { ReplyMediaCache.keepSize(size, for: path) }
            checked = nil
        } catch is CancellationError {
        } catch {
            // Only a refusal says something about the file: anything else leaves the card as it is.
            let found = MediaProblem.of(error, video: false)
            if found == .gone || found == .notAllowed { checked = found }
        }
    }

    /// Whether the card can keep a copy: the gateway shares the file and it isn't too big to.
    private var offersCopy: Bool { shownProblem == nil && !copying.isReading }

    private func keep(_ use: GatewayFileCopy.Use) {
        guard case .file(let path, let profile) = references.gatewayPicture(.path(file.path)) else { return }
        let client = references.roster?.boardClient
        Task { await GatewayFileCopy.keep(path, profile: profile, client: client, as: use, in: $copying) }
    }
}

#if DEBUG
/// `-HERMES_OPEN_SENT_FILE <name>`: the first file a reply sent with that name opens 5 s after it
/// shows (the reply has finished by then), as a tap on it would: the viewer, the Inspector or
/// Save, for screenshots and checks.
enum ReplyFileLaunchFlag {
    static func opens(_ file: ReplyAttachment) async -> Bool {
        guard UserDefaults.standard.string(forKey: "HERMES_OPEN_SENT_FILE") == file.fileName else { return false }
        // A tile drawn again as the reply finishes asks again: the flag is used up only once it acts.
        try? await Task.sleep(for: .seconds(5))
        return !Task.isCancelled && LaunchFlags.take("HERMES_OPEN_SENT_FILE") != nil
    }
}
#endif

/// A file's own bytes, saved where the person chooses: the save panel on the Mac, Files on
/// iPhone and iPad.
nonisolated struct ReplyFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    let data: Data
    let contentType: UTType

    init(data: Data, suffix: String) {
        self.data = data
        contentType = UTType(filenameExtension: suffix) ?? .data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = .data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Keeping a copy

/// Keeping a copy of a gateway file on this device: one path for a file card, a picture or video
/// tile and a Preview tab (`docs/chat.md` §3a, `docs/inspector.md` §2.4). Only on the person's
/// tap, the file is read whole through `/api/fs/download` with the chat's Bot profile, up to
/// `ReplyAttachment.maxSaveBytes`, and held in memory. It's written only where the person says:
/// Save opens the save panel on the Mac and Files on iPhone and iPad, Share the share sheet.
enum GatewayFileCopy {
    enum Use: Equatable {
        case save
        case share
        /// Shown in Quick Look from a copy in the caches, deleted when it closes (`QuickLookFiles`).
        case look
    }

    struct Copy: Identifiable {
        let id = UUID()
        let use: Use
        let document: ReplyFileDocument
        let fileName: String
        /// Where a copy for Quick Look goes: its folder for the path and profile it was read with.
        var folder: String?
    }

    /// A view's copy: being read, read and waiting for the person, or why it couldn't be.
    struct State {
        var reading: Use?
        var copy: Copy?
        var problem: MediaProblem?
        /// What the person asked for last, so Try Again asks again.
        var asked: Use?

        var isReading: Bool { reading != nil }
    }

    static func keep(_ path: String, profile: String?, client: BackendClient?, as use: Use, in state: Binding<State>) async {
        guard !state.wrappedValue.isReading else { return }
        guard let client else {
            state.wrappedValue = State(problem: .needsBotMode, asked: use)
            return
        }
        state.wrappedValue = State(reading: use, asked: use)
        do {
            let data = try await client.downloadCopy(path, profile: profile, limit: ReplyAttachment.maxSaveBytes)
            let name = (path as NSString).lastPathComponent
            let document = ReplyFileDocument(data: data, suffix: (name as NSString).pathExtension.lowercased())
            let folder = use == .look ? QuickLookCopy.folderName(path: path, profile: profile) : nil
            state.wrappedValue = State(copy: Copy(use: use, document: document, fileName: name, folder: folder), asked: use)
        } catch is CancellationError {
            state.wrappedValue.reading = nil
        } catch {
            ReplyVideoPoster.log(error, video: false)
            state.wrappedValue = State(problem: MediaProblem.of(error, video: false), asked: use)
        }
    }

    #if os(iOS)
    static let saveTitle = String(localized: "Save to Device…")
    #else
    static let saveTitle = String(localized: "Save As…")
    #endif
    static let shareTitle = String(localized: "Share…")
    /// On the Mac a copy is kept with the save panel; sending it on from there is the Finder's job.
    static let offersShare: Bool = {
        #if os(iOS)
        true
        #else
        false
        #endif
    }()
}

/// A header button that keeps a copy of a gateway file on this device: Share on iPhone and iPad
/// (the share sheet, which has Save to Files), Save As… on the Mac. The File tab carries it next to
/// its own Save, which writes an edit back to the gateway and is a different thing.
struct GatewayFileKeepButton: View {
    let path: String
    let profile: String?
    let client: BackendClient?

    @State private var copying = GatewayFileCopy.State()

    #if os(iOS)
    private static let use = GatewayFileCopy.Use.share
    private static let symbol = "square.and.arrow.up"
    private static let label = String(localized: "Share")
    private static let hint = String(localized: "Saves or sends a copy of the file")
    #else
    private static let use = GatewayFileCopy.Use.save
    private static let symbol = "square.and.arrow.down"
    private static let label = GatewayFileCopy.saveTitle
    private static let hint = String(localized: "Saves a copy to this device")
    #endif

    var body: some View {
        Button { keep(as: Self.use) } label: {
            ZStack {
                Image(systemName: Self.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .opacity(copying.isReading ? 0 : 1)
                if copying.isReading { Spinner() }
            }
        }
        .buttonStyle(IconButtonStyle(size: 30))
        .disabled(copying.isReading)
        .accessibilityLabel(Text(verbatim: "\(Self.label), \((path as NSString).lastPathComponent)"))
        .accessibilityHint(Self.hint)
        .help(Text(Self.label))
        .gatewayFileCopies($copying, alerts: true) { use in keep(as: use) }
    }

    private func keep(as use: GatewayFileCopy.Use) {
        let path = path, profile = profile, client = client
        Task { await GatewayFileCopy.keep(path, profile: profile, client: client, as: use, in: $copying) }
    }
}

/// Save to Device… and Share… in a file's context menu (Save As… on the Mac).
struct GatewayFileCopyMenu: View {
    let keep: (GatewayFileCopy.Use) -> Void

    var body: some View {
        Button(GatewayFileCopy.saveTitle, systemImage: "square.and.arrow.down") { keep(.save) }
        if GatewayFileCopy.offersShare {
            Button(GatewayFileCopy.shareTitle, systemImage: "square.and.arrow.up") { keep(.share) }
        }
    }
}

/// The context menu's Save and Share as VoiceOver actions, for an element that hides its children.
struct GatewayFileCopyActions: ViewModifier {
    let enabled: Bool
    let keep: (GatewayFileCopy.Use) -> Void

    func body(content: Content) -> some View {
        if enabled {
            #if os(iOS)
            content
                .accessibilityAction(named: Text(GatewayFileCopy.saveTitle)) { keep(.save) }
                .accessibilityAction(named: Text(GatewayFileCopy.shareTitle)) { keep(.share) }
            #else
            content
                .accessibilityAction(named: Text(GatewayFileCopy.saveTitle)) { keep(.save) }
            #endif
        } else {
            content
        }
    }
}

extension View {
    /// Asks the person where a copy goes once it's read: the save panel or Files, or the share
    /// sheet. With `alerts`, what went wrong shows as an alert, for a control with no room to
    /// say it; a card says it on itself.
    func gatewayFileCopies(_ state: Binding<GatewayFileCopy.State>, alerts: Bool = false,
                           retry: ((GatewayFileCopy.Use) -> Void)? = nil) -> some View {
        modifier(GatewayFileCopyPresenter(state: state, alerts: alerts, retry: retry))
    }
}

private struct GatewayFileCopyPresenter: ViewModifier {
    @Binding var state: GatewayFileCopy.State
    let alerts: Bool
    let retry: ((GatewayFileCopy.Use) -> Void)?
    /// The copy Quick Look shows, deleted when it closes.
    @State private var looking: URL?

    private var saving: Bool { state.copy?.use == .save }

    func body(content: Content) -> some View {
        content
            .fileExporter(isPresented: Binding(get: { saving }, set: { if !$0, saving { state.copy = nil } }),
                          document: saving ? state.copy?.document : nil,
                          contentType: state.copy?.document.contentType ?? .data,
                          defaultFilename: state.copy?.fileName) { _ in state.copy = nil }
            .quickLookPreview(Binding(get: { looking }, set: { shown in
                if shown == nil, let looking {
                    QuickLookFiles.discard(looking)
                    self.looking = nil
                }
            }))
            .onChange(of: state.copy?.id) { look() }
            .onDisappear {
                // The card scrolled away or the chat closed with Quick Look still up: the copy goes too.
                if let looking { QuickLookFiles.discard(looking) }
            }
            #if os(iOS)
            .background {
                // Only while there's a copy to share: nothing extra stays in a long chat.
                if let copy = state.copy, copy.use == .share {
                    GatewayFileShareSheet(copy: copy) { state.copy = nil }
                        .id(copy.id)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            #endif
            .alert(alertTitle, isPresented: Binding(get: { alerts && state.problem != nil },
                                                    set: { if !$0 { state.problem = nil } })) {
                if let retry, let use = state.asked, state.problem == .couldntLoad {
                    Button("Try Again") { retry(use) }
                }
                Button("OK", role: .cancel) {}
            }
    }

    private var alertTitle: String {
        state.problem.map { ReplyFileCard.note($0, video: false) } ?? ""
    }

    /// A copy read for Quick Look goes to the caches and shows; one Quick Look can't draw here is
    /// offered to save instead.
    private func look() {
        guard let copy = state.copy, copy.use == .look, let folder = copy.folder else { return }
        guard let url = QuickLookFiles.write(copy.document.data, name: copy.fileName, folder: folder) else {
            state = GatewayFileCopy.State(problem: .couldntLoad, asked: .look)
            return
        }
        guard QuickLookFiles.canShow(url) else {
            QuickLookFiles.discard(url)
            state.copy = GatewayFileCopy.Copy(use: .save, document: copy.document, fileName: copy.fileName)
            return
        }
        state.copy = nil
        looking = url
    }
}

/// The copies Quick Look shows (`docs/chat.md` §3a): one at a time, each in its own folder under
/// the caches' "Quick Look" folder, named for the gateway path and profile (`QuickLookCopy`),
/// written with the strongest file protection the system offers, and deleted when the preview
/// closes. Opening one clears whatever an earlier run left behind.
enum QuickLookFiles {
    private static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "widgets")

    static var root: URL {
        URL.cachesDirectory.appending(path: QuickLookCopy.folder, directoryHint: .isDirectory)
    }

    static func write(_ data: Data, name: String, folder: String) -> URL? {
        let manager = FileManager.default
        try? manager.removeItem(at: root)
        let directory = root.appending(path: folder, directoryHint: .isDirectory)
        let url = directory.appending(path: QuickLookCopy.fileName(of: name), directoryHint: .notDirectory)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            return url
        } catch {
            logger.error("Quick Look copy not written: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            return nil
        }
    }

    /// Whether Quick Look draws this kind of file here. The Mac's Quick Look shows any file, as
    /// its icon at worst.
    static func canShow(_ url: URL) -> Bool {
        #if os(iOS)
        QLPreviewController.canPreview(url as NSURL)
        #else
        true
        #endif
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

#if os(iOS)
/// The share sheet for a copy held in memory. The file goes to the sheet as data with its name
/// (an item provider), so the app writes nothing to disk itself: where the file goes (Files,
/// AirDrop, another app) is the person's choice there. On iPad it points at the control that
/// asked for it.
private struct GatewayFileShareSheet: UIViewControllerRepresentable {
    let copy: GatewayFileCopy.Copy
    let done: () -> Void

    func makeUIViewController(context: Context) -> Presenter { Presenter(copy: copy, done: done) }
    func updateUIViewController(_ controller: Presenter, context: Context) {}

    final class Presenter: UIViewController {
        private let copy: GatewayFileCopy.Copy
        private let done: () -> Void
        private var presented = false

        init(copy: GatewayFileCopy.Copy, done: @escaping () -> Void) {
            self.copy = copy
            self.done = done
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented else { return }
            presented = true
            let provider = NSItemProvider()
            provider.suggestedName = copy.fileName
            let data = copy.document.data
            provider.registerDataRepresentation(forTypeIdentifier: copy.document.contentType.identifier, visibility: .all) { load in
                load(data, nil)
                return nil
            }
            let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
            // The sheet's header names the file and its kind, as it would a file from Files.
            let metadata = LPLinkMetadata()
            metadata.title = copy.fileName
            metadata.originalURL = URL(filePath: copy.fileName)
            let title = copy.fileName
            configuration.metadataProvider = { key in
                switch key {
                case .title: title
                case .linkPresentationMetadata: metadata
                default: nil
                }
            }
            let sheet = UIActivityViewController(activityItemsConfiguration: configuration)
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = view.bounds
            let done = done
            sheet.completionWithItemsHandler = { _, _, _, _ in
                MainActor.assumeIsolated { done() }
            }
            present(sheet, animated: true)
        }
    }
}
#endif
