import HermesKit
import SwiftUI

/// One picture or video the viewer pages through, in the card's order.
struct MediaViewerItem: Identifiable, Hashable {
    /// Its page: 0 for the first item the viewer shows.
    let id: Int
    let media: WidgetMedia
    let caption: String?
    let credit: String?
}

/// A media card's tap: what the viewer opens and where (docs/widgets.md §9.1).
struct MediaViewerRequest: Identifiable {
    let id = UUID()
    let items: [MediaViewerItem]
    let start: Int
    let title: String?
    /// A private widget's pictures are neither saved nor shared from the viewer.
    let isPrivate: Bool
    /// The card's tap to load already let its https pictures from other servers in.
    let webAllowed: Bool
    /// Lets them in on the card too, when the tap comes from inside the viewer.
    let allowWeb: () -> Void
    let references: ReferenceContext
    let gatewayHosts: Set<String>
    /// The tile the viewer grows from, and shrinks back to.
    let transitionID: String

    init(widget: MediaWidget, tapping index: Int, moreTile: Bool = false, payload: WidgetPayload, webAllowed: Bool,
         allowWeb: @escaping () -> Void, references: ReferenceContext, gatewayHosts: Set<String>) {
        items = MediaViewing.items(of: widget).enumerated().map { page, item in
            MediaViewerItem(id: page, media: item.media, caption: item.caption, credit: item.credit)
        }
        start = MediaViewing.startPage(tapping: index, in: widget, moreTile: moreTile)
        title = payload.title
        isPrivate = payload.isPrivate
        self.webAllowed = webAllowed
        self.allowWeb = allowWeb
        self.references = references
        self.gatewayHosts = gatewayHosts
        transitionID = MediaViewerPresenter.transitionID(payload: payload.id, tile: index)
    }
}

extension MediaViewerRequest {
    /// The pictures and videos a reply sent (`MEDIA:` lines, `docs/chat.md` §3a), in the reply's
    /// order, opened at `start`: read from the gateway like a widget's `hermes-file:` media, and
    /// saved or shared like any of a card's.
    init(files: [ReplyAttachment], start: Int, references: ReferenceContext, gatewayHosts: Set<String>, transitionID: String) {
        items = files.enumerated().map { page, file in
            MediaViewerItem(id: page, media: file.media, caption: nil, credit: nil)
        }
        self.start = files.indices.contains(start) ? start : 0
        title = nil
        isPrivate = false
        webAllowed = false
        allowWeb = {}
        self.references = references
        self.gatewayHosts = gatewayHosts
        self.transitionID = transitionID
    }
}

/// Opens and closes the full-screen viewer over the whole window, whichever chat or sheet the
/// card is in.
@Observable
final class MediaViewerPresenter {
    var request: MediaViewerRequest?

    static func transitionID(payload: String, tile: Int) -> String { "\(payload)-\(tile)" }

    func open(_ request: MediaViewerRequest, reducesMotion: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = reducesMotion
        withTransaction(transaction) { self.request = request }
    }

    func close(reducesMotion: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = reducesMotion
        withTransaction(transaction) { request = nil }
    }
}

extension EnvironmentValues {
    /// Where a media card opens its viewer; nil where there's no window to open it over.
    @Entry var mediaViewer: MediaViewerPresenter? = nil
    /// The namespace a card's tiles and the viewer share for the zoom between them.
    @Entry var mediaViewerNamespace: Namespace.ID? = nil
}

extension View {
    /// Lets the media cards below open the full-screen viewer over this view.
    func mediaViewerHost() -> some View { modifier(MediaViewerHost()) }
}

private struct MediaViewerHost: ViewModifier {
    @State private var presenter = MediaViewerPresenter()
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.mediaViewer, presenter)
            .environment(\.mediaViewerNamespace, namespace)
            #if os(iOS)
            .fullScreenCover(item: $presenter.request) { request in
                viewer(request)
                    .modifier(ZoomFrom(id: request.transitionID, namespace: namespace, enabled: !reduceMotion))
            }
            #else
            // A Mac window has no full-screen cover: the viewer fills the window over everything
            // else in it, the toolbar included.
            .overlay {
                if let request = presenter.request {
                    viewer(request)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: presenter.request?.id)
            .background(WindowToolbarHider(hidden: presenter.request != nil))
            #endif
    }

    private func viewer(_ request: MediaViewerRequest) -> some View {
        MediaViewer(request: request) { presenter.close(reducesMotion: reduceMotion) }
            .id(request.id)
    }
}

#if os(macOS)
/// Puts the window's toolbar away while the viewer covers the window. SwiftUI's hidden window
/// toolbar takes the title bar and its close, minimize and zoom buttons with it; the design keeps
/// those buttons beside the viewer's Close.
private struct WindowToolbarHider: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let visible = !hidden
        // The view joins its window after this first update.
        DispatchQueue.main.async { view.window?.toolbar?.isVisible = visible }
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        view.window?.toolbar?.isVisible = true
    }
}
#endif

#if os(iOS)
/// The viewer grows from the tile that opened it. Reduce Motion: it appears without the zoom.
private struct ZoomFrom: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}
#endif

/// The full-screen viewer: the card's pictures and videos, one screen each, on the canvas
/// (docs/widgets.md §9.1, design `mediaViewer`).
struct MediaViewer: View {
    @State private var model: MediaViewerModel
    let close: () -> Void

    #if os(iOS)
    /// How far a swipe down has pulled the page, before it closes or springs back.
    @State private var pull: CGFloat = 0
    /// The bars' heights and the screen's safe area, which the pages ignore.
    @State private var bars: (top: CGFloat, bottom: CGFloat) = (0, 0)
    @State private var safeArea = EdgeInsets()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    init(request: MediaViewerRequest, close: @escaping () -> Void) {
        _model = State(initialValue: MediaViewerModel(request: request))
        self.close = close
    }

    var body: some View {
        content
            .background(Theme.canvas.ignoresSafeArea())
            .background { keys }
            .environment(\.references, model.request.references)
            .environment(\.gatewayHosts, model.request.gatewayHosts)
            .onChange(of: model.current) { model.pageChanged() }
            .task { model.pageChanged() }
            .onDisappear { model.tearDown() }
            .accessibilityAction(.escape, close)
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        ZStack {
            MediaPager(model: model)
                .environment(\.mediaBarInsets, EdgeInsets(top: safeArea.top + bars.top, leading: 0,
                                                          bottom: safeArea.bottom + bars.bottom, trailing: 0))
                .offset(y: pull)
                .opacity(1 - min(pull / 600, 0.4))
            MediaViewerChrome(model: model, close: close) { bars = ($0, $1) }
                .opacity(model.chromeHidden ? 0 : 1)
                .allowsHitTesting(!model.chromeHidden)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.chromeHidden)
        }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
        .simultaneousGesture(swipeDown)
        .statusBarHidden(model.chromeHidden)
        .persistentSystemOverlays(model.chromeHidden ? .hidden : .automatic)
        #else
        VStack(spacing: 0) {
            MediaViewerTopBar(model: model, close: close)
            ZStack {
                MediaPager(model: model)
                MediaEdgeChevrons(model: model)
            }
            MediaCaption(item: model.shown?.item)
        }
        #endif
    }

    #if os(iOS)
    /// A swipe down on a picture that isn't zoomed closes the viewer.
    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard !model.zoomed, model.shown?.video?.phase != .ready,
                      value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) * 1.5
                else { return }
                pull = value.translation.height
            }
            .onEnded { value in
                if pull > 120 || (pull > 40 && value.predictedEndTranslation.height > 300) {
                    close()
                } else {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { pull = 0 }
                }
            }
    }
    #endif

    /// The keys the viewer answers: the arrows page, ⌘+ and ⌘− zoom, ⌘0 fits. Escape is Close's.
    private var keys: some View {
        Group {
            Button("") { model.go(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.go(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { model.zoomStep = 1 }.keyboardShortcut("+", modifiers: .command)
            Button("") { model.zoomStep = 1 }.keyboardShortcut("=", modifiers: .command)
            Button("") { model.zoomStep = -1 }.keyboardShortcut("-", modifiers: .command)
            Button("") { model.zoomResets += 1 }.keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}
