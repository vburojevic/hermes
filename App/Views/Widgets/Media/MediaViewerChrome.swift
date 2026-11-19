import HermesKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import Photos
#endif

// MARK: Bars

#if os(iOS)
/// The iPhone and iPad viewer's bars over the page: Close, the position, Save and Share at the
/// top, the caption at the bottom (design `mediaViewer`). A tap on the page hides them.
struct MediaViewerChrome: View {
    let model: MediaViewerModel
    let close: () -> Void
    /// The height the top bar and the caption take, so a page's words can stay clear of them.
    let measured: (_ top: CGFloat, _ bottom: CGFloat) -> Void

    @State private var top: CGFloat = 0
    @State private var bottom: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            MediaTopBarLayout {
                MediaRoundButton(symbol: "xmark", label: String(localized: "Close"), action: close)
                    .keyboardShortcut(.cancelAction)
                    .layoutValue(key: MediaTopBarSlot.self, value: .leading)
                MediaPosition(model: model)
                    .layoutValue(key: MediaTopBarSlot.self, value: .center)
                MediaSaveShare(model: model)
                    .layoutValue(key: MediaTopBarSlot.self, value: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            // The bars sit over the picture: past this size they'd cover it, and a long press
            // on a button shows it large instead.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { top = $0; measured(top, bottom) }
            Spacer(minLength: 0)
            MediaCaption(item: model.shown?.item)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottom = $0; measured(top, bottom) }
        }
    }
}
/// Where a view sits in ``MediaTopBarLayout``.
nonisolated enum MediaTopBarSlot: LayoutValueKey {
    case leading, center, trailing
    static let defaultValue = MediaTopBarSlot.center
}

/// Close at the leading edge, Save and Share at the trailing edge, and the position centred on
/// the bar. With large text the buttons leave the middle too little room, so the position moves
/// over to sit between them, and is cut short only when even that isn't wide enough.
nonisolated struct MediaTopBarLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var leadingEdge = bounds.minX
        var trailingEdge = bounds.maxX
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            switch subview[MediaTopBarSlot.self] {
            case .leading:
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
                leadingEdge = bounds.minX + size.width + spacing
            case .trailing:
                subview.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(size))
                trailingEdge = bounds.maxX - size.width - spacing
            case .center:
                break
            }
        }
        for subview in subviews where subview[MediaTopBarSlot.self] == .center {
            let room = max(trailingEdge - leadingEdge, 0)
            let ideal = subview.sizeThatFits(.unspecified)
            let size = ideal.width <= room ? ideal : subview.sizeThatFits(ProposedViewSize(width: room, height: ideal.height))
            let width = min(size.width, room)
            let x = min(max(bounds.midX - width / 2, leadingEdge), trailingEdge - width)
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: size.height))
        }
    }
}
#else
/// The Mac viewer's top bar, in the window's title bar: Close after the window's buttons, the
/// file's name and position in the middle, zoom, Share and Save at the trailing edge.
struct MediaViewerTopBar: View {
    let model: MediaViewerModel
    let close: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                MediaRoundButton(symbol: "xmark", label: String(localized: "Close"), size: .small, action: close)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let page = model.shown, !page.isVideo, case .shown = page.content {
                    MediaRoundButton(symbol: "minus", label: String(localized: "Zoom Out"), size: .small) { model.zoomStep = -1 }
                        .disabled(!model.zoomed)
                    MediaRoundButton(symbol: "plus", label: String(localized: "Zoom In"), size: .small) { model.zoomStep = 1 }
                }
                MediaSaveShare(model: model, size: .small)
            }
            VStack(spacing: 1) {
                if let page = model.shown {
                    Text(page.fileName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                }
                if let position = model.current.flatMap({ MediaViewing.position($0, of: model.pages.count) }) {
                    Text("\(position.current) of \(position.total)")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(maxWidth: 360)
            .accessibilityElement(children: .combine)
        }
        // Clears the window's close, minimize and zoom buttons on the leading side.
        .padding(.leading, 80)
        .padding(.trailing, 16)
        .frame(height: 52)
    }
}

/// The Mac viewer's previous and next buttons at the window's edges.
struct MediaEdgeChevrons: View {
    let model: MediaViewerModel

    var body: some View {
        HStack {
            if let current = model.current, current > 0 {
                MediaRoundButton(symbol: "chevron.left", label: String(localized: "Previous")) { model.go(-1) }
            }
            Spacer()
            if let current = model.current, current < model.pages.count - 1 {
                MediaRoundButton(symbol: "chevron.right", label: String(localized: "Next")) { model.go(1) }
            }
        }
        .padding(.horizontal, 28)
    }
}
#endif

/// "4 of 12" in a glass capsule; nothing for a viewer with one item.
private struct MediaPosition: View {
    let model: MediaViewerModel

    var body: some View {
        if let position = model.current.flatMap({ MediaViewing.position($0, of: model.pages.count) }) {
            Text("\(position.current) of \(position.total)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .accessibilityShowsLargeContentViewer()
        }
    }
}

/// The item's caption and credit under the page.
struct MediaCaption: View {
    let item: MediaViewerItem?

    var body: some View {
        if let item, item.caption != nil || item.credit != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let caption = item.caption {
                    Text(caption).font(.body).foregroundStyle(Theme.primaryText)
                }
                if let credit = item.credit {
                    Text(credit).font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A round glass button with one glyph, as the design's viewer bars draw them.
struct MediaRoundButton: View {
    let symbol: String
    let label: String
    var size = ControlSize.large
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MediaGlyph(symbol: symbol, size: size)
        }
        .buttonStyle(.glass)
        .tint(nil)
        .buttonBorderShape(.circle)
        .controlSize(size)
        .accessibilityLabel(label)
        .help(label)
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: symbol)
        }
    }
}

/// A round button's glyph, growing with the text size so it stays in step with the position
/// beside it.
private struct MediaGlyph: View {
    let symbol: String
    let size: ControlSize

    @ScaledMetric(relativeTo: .body) private var large: CGFloat = 17
    @ScaledMetric(relativeTo: .footnote) private var small: CGFloat = 13

    var body: some View {
        let points = size == .small ? small : large
        Image(systemName: symbol)
            .font(.system(size: points, weight: .medium))
            .frame(width: points * 24 / 17, height: points * 24 / 17)
    }
}

// MARK: Save and Share

/// Save and Share for the picture shown. A private widget's pictures stay in the app, and a
/// page still loading, in a state or playing a video has nothing to save.
private struct MediaSaveShare: View {
    let model: MediaViewerModel
    var size = ControlSize.large

    @State private var saved = false
    @State private var exporting = false
    @State private var photosDenied = false

    var body: some View {
        if !model.request.isPrivate, let page = model.shown, !page.isVideo,
           case .shown(let image) = page.content, let data = page.data {
            // The phone's bar has Save first; the Mac's top bar ends with it.
            HStack(spacing: 10) {
                #if os(iOS)
                save(page: page, data: data)
                share(page: page, image: image)
                #else
                share(page: page, image: image)
                save(page: page, data: data)
                #endif
            }
            .id(page.id)
        }
    }

    @ViewBuilder
    private func save(page: MediaPage, data: Data) -> some View {
        let label = String(localized: "Save")
        #if os(iOS)
        MediaRoundButton(symbol: saved ? "checkmark" : "arrow.down.to.line", label: label, size: size) {
            Task {
                switch await PhotoSaver.save(data) {
                case .saved: break
                case .denied:
                    DeviceSetup.shared.refresh()
                    photosDenied = true
                    return
                case .failed: return
                }
                saved = true
                AccessibilityNotification.Announcement(String(localized: "Saved to Photos")).post()
                try? await Task.sleep(for: .seconds(1.5))
                saved = false
            }
        }
        .sensoryFeedback(.success, trigger: saved) { _, now in now }
        // docs/setup.md §4.15: Photos turned off for Hermes says so, with the way to turn it on.
        .alert("Photos is off for Hermes", isPresented: $photosDenied) {
            if DeviceSetup.shared.photos == .denied {
                Button("Open Settings") { DeviceSetup.openSettings(.photos) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(DeviceSetup.settingsPath(for: .photos)) Until then you can share the picture instead.")
        }
        #else
        MediaRoundButton(symbol: "arrow.down.to.line", label: label, size: size) { exporting = true }
            .fileExporter(isPresented: $exporting,
                          document: MediaFileDocument(data: data),
                          contentType: MediaFileType(path: page.item.media.src).flatMap { UTType($0.uniformType) } ?? .jpeg,
                          defaultFilename: page.fileName) { _ in }
        #endif
    }

    private func share(page: MediaPage, image: CGImage) -> some View {
        let preview = Image(decorative: image, scale: 1)
        let label = String(localized: "Share")
        return ShareLink(item: preview, preview: SharePreview(page.item.media.alt, image: preview)) {
            MediaGlyph(symbol: "square.and.arrow.up", size: size)
        }
        .buttonStyle(.glass)
        .tint(nil)
        .buttonBorderShape(.circle)
        .controlSize(size)
        .accessibilityLabel(label)
        .help(label)
    }
}

#if os(iOS)
/// Adds a picture to Photos with add-only access: the app never reads the library.
nonisolated enum PhotoSaver {
    enum Outcome { case saved, denied, failed }

    static func save(_ data: Data) async -> Outcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return .saved
        } catch {
            return .failed
        }
    }
}
#else
/// A picture's own bytes, saved where the person chooses.
nonisolated struct MediaFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.image]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif

// MARK: States

/// Why a picture or video didn't open, each with the design's own words and the fix where
/// there is one (docs/widgets.md §9.2).
struct MediaStateView: View {
    let problem: MediaProblem
    let fileName: String
    let video: Bool
    let references: ReferenceContext
    /// The https server a web picture or video comes from; nil for a gateway file.
    var host: String?
    let retry: () -> Void

    var body: some View {
        MediaClearOfBars { content }
    }

    @ViewBuilder
    private var content: some View {
        switch problem {
        case .needsBotMode:
            VStack(spacing: 12) {
                StateMessage(symbol: "server.rack", title: String(localized: "Bot Mode isn't linked"),
                             message: String(localized: "Files Hermes keeps on the gateway open through Bot Mode. On the gateway's computer, run hermes serve, then link it in Edit Gateway."))
                    .fixedSize(horizontal: false, vertical: true)
                if let workspace = references.workspace {
                    HStack(spacing: 10) {
                        BotModeLinkButton(workspace: workspace)
                        SetupCheckButton(check: { await workspace.setup.check() }, style: .card)
                            .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .couldntLoad, .couldntPlay:
            StateMessage(symbol: symbol, title: title, message: message,
                         actionTitle: String(localized: "Try Again"), action: retry)
        default:
            StateMessage(symbol: symbol, title: title, message: message)
        }
    }

    private var symbol: String {
        switch problem {
        case .gone, .tooBig: video ? "video.fill" : "photo"
        case .notAllowed: "lock.fill"
        case .couldntLoad: "exclamationmark.triangle"
        case .couldntPlay: "video.fill"
        case .needsBotMode: "server.rack"
        }
    }

    private var title: String {
        switch problem {
        case .gone: video ? String(localized: "This video is gone") : String(localized: "This picture is gone")
        case .tooBig: String(localized: "This picture is too big to open")
        case .notAllowed: String(localized: "Hermes doesn't share this file")
        case .couldntLoad: String(localized: "Couldn't load this picture")
        case .couldntPlay: String(localized: "Couldn't play this video")
        case .needsBotMode: String(localized: "Bot Mode isn't linked")
        }
    }

    private var message: String {
        switch problem {
        case .gone:
            return String(localized: "\(fileName) isn't on the gateway anymore. Ask Hermes to send it again.")
        case .tooBig(let bytes):
            let size = bytes.formatted(.byteCount(style: .file))
            return String(localized: "It's \(size), and the app opens pictures up to 50 MB. Ask Hermes for a smaller copy.")
        case .notAllowed:
            return String(localized: "The gateway keeps files like this one private, so the app can't open it.")
        case .couldntLoad:
            if let host { return String(localized: "Can't reach \(host). Try again later.") }
            return references.workspace?.bot.baseURL.host().map { String(localized: "Can't reach Hermes at \($0).") }
                ?? String(localized: "Check that Hermes is reachable, then try again.")
        case .couldntPlay:
            // A web video comes from its own server, which the gateway has no part in.
            if let host { return String(localized: "Couldn't stream it from \(host). Try again later.") }
            return String(localized: "The gateway stopped sending it. Check that Hermes is reachable, then try again.")
        case .needsBotMode:
            return ""
        }
    }
}

extension EnvironmentValues {
    /// What the viewer's bars cover at the top and bottom of a page (iPhone and iPad).
    @Entry var mediaBarInsets = EdgeInsets()
}

/// Words on a page of the viewer: kept clear of the bars over it, and scrolling once the text
/// is too large to fit between them.
struct MediaClearOfBars<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.mediaBarInsets) private var insets

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.top, insets.top)
        .padding(.bottom, insets.bottom)
    }
}
