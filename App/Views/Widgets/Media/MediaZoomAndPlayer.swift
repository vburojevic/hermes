import AVFoundation
import AVKit
import SwiftUI

/// A picture fitted to its space that zooms with a pinch, a double tap or a zoom step, and pans
/// once zoomed: the viewer's pages and the File tab (docs/widgets.md §9.2, docs/inspector.md §2.8).
struct ZoomableImage: View {
    let image: CGImage
    /// A step in (1) or out (−1) asked from outside: the keys, or the bar's buttons.
    @Binding var step: Int
    /// Counts ⌘0s: each one fits the picture again.
    let resets: Int
    let isCurrent: Bool
    @Binding var zoomed: Bool
    /// The File tab rounds the picture's corners; the viewer shows it edge to edge.
    var cornerRadius: CGFloat = 0
    /// What the viewer's bars cover at the top and bottom. The picture fits between them, so the
    /// caption never lies over it, and only zooming takes it under them.
    var clearOf = EdgeInsets()
    /// A single tap; the viewer shows or hides its bars.
    var tap: (() -> Void)?

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    /// Measured from the screen's centre.
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let fitted = fittedSize(in: proxy.size)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(magnify(in: proxy.size, fitted: fitted))
                .simultaneousGesture(pan(in: proxy.size, fitted: fitted), including: scale > 1 ? .all : .subviews)
                .onTapGesture(count: 2) { location in
                    zoom(to: scale > 1 ? 1 : 2, around: location, in: proxy.size, fitted: fitted)
                }
                .onTapGesture { tap?() }
                .onChange(of: step) { _, step in
                    guard isCurrent, step != 0 else { return }
                    let target = step > 0 ? min(scale * 1.5, Self.maxScale) : max(scale / 1.5, 1)
                    zoom(to: target, around: nil, in: proxy.size, fitted: fitted)
                    self.step = 0
                }
                .onChange(of: resets) { if isCurrent { zoom(to: 1, around: nil, in: proxy.size, fitted: fitted) } }
                .onChange(of: isCurrent) { if !isCurrent { reset() } }
                .onAppear { if scale <= 1 { reset(animated: false) } }
                .onChange(of: rest) { if scale <= 1 { reset(animated: false) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: Text("Zoom")) {
            step = scale > 1 ? -100 : 1
        }
    }

    /// Where the fitted picture sits: centred between the bars, not on the screen.
    private var rest: CGSize { CGSize(width: 0, height: (clearOf.top - clearOf.bottom) / 2) }

    private func fittedSize(in size: CGSize) -> CGSize {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let room = CGSize(width: size.width, height: size.height - clearOf.top - clearOf.bottom)
        guard width > 0, height > 0, room.width > 0, room.height > 0 else { return size }
        let ratio = min(room.width / width, room.height / height)
        return CGSize(width: width * ratio, height: height * ratio)
    }

    private func magnify(in size: CGSize, fitted: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(settledScale * value.magnification, 1), Self.maxScale)
                offset = clamped(settledOffset, scale: scale, in: size, fitted: fitted)
                zoomed = scale > 1
            }
            .onEnded { _ in settle(in: size, fitted: fitted) }
    }

    private func pan(in size: CGSize, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard scale > 1 else { return }
                offset = clamped(CGSize(width: settledOffset.width + value.translation.width,
                                        height: settledOffset.height + value.translation.height),
                                 scale: scale, in: size, fitted: fitted)
            }
            .onEnded { _ in if scale > 1 { settledOffset = offset } }
    }

    private func zoom(to target: CGFloat, around location: CGPoint?, in size: CGSize, fitted: CGSize) {
        var newOffset = rest
        if target > 1, let location {
            // Keeps the point tapped under the finger as it zooms.
            let dx = location.x - size.width / 2, dy = location.y - size.height / 2
            let factor = target / scale
            newOffset = CGSize(width: offset.width * factor - dx * (factor - 1),
                               height: offset.height * factor - dy * (factor - 1))
        } else if target > 1 {
            newOffset = CGSize(width: offset.width * target / scale, height: offset.height * target / scale)
        }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            scale = target
            offset = clamped(newOffset, scale: target, in: size, fitted: fitted)
        }
        settledScale = target
        settledOffset = offset
        zoomed = target > 1
    }

    private func settle(in size: CGSize, fitted: CGSize) {
        settledScale = scale
        if scale <= 1.01 { reset() } else { settledOffset = offset }
    }

    private func reset(animated: Bool = true) {
        withAnimation(animated && !reduceMotion ? .smooth(duration: 0.25) : nil) {
            scale = 1
            offset = rest
        }
        settledScale = 1
        settledOffset = rest
        if isCurrent { zoomed = false }
    }

    /// How far a zoomed picture can move: no further than its own edges. One still shorter than
    /// the screen stays as near its place between the bars as it fits.
    private func clamped(_ proposed: CGSize, scale: CGFloat, in size: CGSize, fitted: CGSize) -> CGSize {
        let maxX = max(0, (fitted.width * scale - size.width) / 2)
        let overflowY = (fitted.height * scale - size.height) / 2
        let y = overflowY > 0
            ? min(max(proposed.height, -overflowY), overflowY)
            : min(max(rest.height, overflowY), -overflowY)
        return CGSize(width: min(max(proposed.width, -maxX), maxX), height: y)
    }
}

// MARK: System player

#if os(iOS)
/// The system's own player, with its controls, AirPlay and captions. Picture in Picture is off:
/// the video lives only as long as the viewer that streams it.
struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    /// Off while the File tab shows the first frame under its own play button.
    var controls = true

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.updatesNowPlayingInfoCenter = false
        controller.view.backgroundColor = .clear
        controller.showsPlaybackControls = controls
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        if controller.showsPlaybackControls != controls { controller.showsPlaybackControls = controls }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}
#else
/// The system's own player, with its floating controls. Picture in Picture is off: the video
/// lives only as long as the viewer that streams it.
struct SystemPlayer: NSViewRepresentable {
    let player: AVPlayer
    /// Off while the File tab shows the first frame under its own play button.
    var controls = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controls ? .floating : .none
        view.allowsPictureInPicturePlayback = false
        view.showsFullScreenToggleButton = false
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        let style: AVPlayerViewControlsStyle = controls ? .floating : .none
        if view.controlsStyle != style { view.controlsStyle = style }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
#endif
