import HermesKit
import SwiftUI

/// Where a remote picture is: still loading, shown, or failed.
enum RemoteImagePhase {
    case empty
    case success(Image)
    case failure

    var image: Image? {
        if case .success(let image) = self { image } else { nil }
    }
}

/// A picture from the web, loaded through `RemotePicture`, whose session never follows a
/// redirect to another server (`docs/architecture.md`). Whether a picture may load at all, by
/// itself or after a tap, is each caller's to decide (`WebLink`).
struct RemoteImage<Content: View>: View {
    let url: URL
    var transaction = Transaction()
    @ViewBuilder let content: (RemoteImagePhase) -> Content

    @State private var phase = RemoteImagePhase.empty
    @State private var shown: URL?

    var body: some View {
        content(phase)
            .task(id: url) {
                // Shown already: a row scrolled back into view doesn't fetch it again.
                guard shown != url else { return }
                if case .empty = phase {} else { phase = .empty }
                do {
                    let image = try await RemotePicture.image(at: url)
                    withTransaction(transaction) {
                        phase = .success(Image(decorative: image, scale: 1))
                        shown = url
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    withTransaction(transaction) { phase = .failure }
                }
            }
    }
}

extension RemoteImage {
    /// The picture once it's there, and a placeholder until then, or when it fails.
    init<Picture: View, Placeholder: View>(
        url: URL, @ViewBuilder content: @escaping (Image) -> Picture, @ViewBuilder placeholder: @escaping () -> Placeholder
    ) where Content == _ConditionalContent<Picture, Placeholder> {
        self.init(url: url) { phase in
            if let image = phase.image { content(image) } else { placeholder() }
        }
    }
}
