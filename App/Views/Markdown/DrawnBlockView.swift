import HermesMarkdown
import SwiftUI

/// A Mermaid diagram, display math or an SVG picture in a reply, drawn on the device
/// (`docs/chat.md` §3b). It is drawn once, when it first comes on screen, for its colours and
/// type size, and kept (`DrawnBlockRenderer`): scrolling draws nothing again. Until then it keeps
/// a quiet space; a block that can't be drawn shows its source and says so. A tap opens it larger,
/// with its source a tap away.
struct DrawnBlockView: View {
    let block: DrawnBlock
    /// The fence's language, for the code shown when it can't be drawn.
    let language: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.markdownBodyFont) private var bodyFont
    @Environment(\.markdownOpenTail) private var isArriving
    @Environment(\.drawnBlockPresenter) private var presenter
    @State private var drawn: DrawnBlockRenderer.Drawing?
    @State private var opens = false

    var body: some View {
        if isArriving, block.kind != .math {
            // Still arriving: its source as it comes, drawn once the reply moves past it.
            CodeBlockView(language: language, code: block.source)
        } else {
            let request = request
            let drawing = DrawnBlockRenderer.shared.drawing(for: request) ?? drawn
            Group {
                if let drawing, let image = drawing.image {
                    picture(image, size: drawing.size)
                } else if drawing != nil {
                    failed
                } else {
                    placeholder
                }
            }
            .task(id: request) {
                guard DrawnBlockRenderer.shared.drawing(for: request) == nil else { return }
                drawn = await DrawnBlockRenderer.shared.draw(request)
            }
            .modifier(OwnSheet(isPresented: $opens, hasHost: presenter != nil) {
                DrawnBlockSheet(block: block, request: request)
            })
        }
    }

    private func open() {
        if let presenter {
            presenter.request = DrawnBlockPresenter.Request(block: block, request: request)
        } else {
            opens = true
        }
    }

    private var request: DrawnBlockRenderer.Request {
        DrawnBlockRenderer.Request(
            block: block,
            look: DrawnBlockRenderer.shared.look(dark: colorScheme == .dark, highContrast: contrast == .increased, font: fontSize),
            scale: displayScale)
    }

    /// The reply's own type size: a diagram's words read as large as the reply's.
    private var fontSize: Double {
        #if os(macOS)
        bodyFont == Theme.Typography.compactMessage ? 13 : 15
        #else
        let category = UIContentSizeCategory(typeSize)
        let base: CGFloat = bodyFont == Theme.Typography.compactMessage ? 15 : 17
        let size = UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        // Past this the diagram only shrinks back to fit the reply.
        return min(Double(size), 34)
        #endif
    }

    @ViewBuilder
    private func picture(_ image: CGImage, size: CGSize) -> some View {
        let shown = Image(decorative: image, scale: CGFloat(image.width) / max(size.width, 1))
            .resizable()
            .interpolation(.high)
            .aspectRatio(size, contentMode: .fit)
            // Never larger than drawn: it would blur.
            .frame(maxWidth: size.width)
        Button {
            open()
        } label: {
            switch block.kind {
            case .mermaid:
                shown
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .surface()
            case .math:
                shown
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
            case .svg:
                // A picture keeps its own colours, on paper, as an image file would show.
                shown
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { open() }
            Button("Copy Source", systemImage: "square.on.square") { Pasteboard.copy(block.source) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(block.name)
        .accessibilityValue(block.kind == .svg ? "" : block.source)
        .accessibilityAddTraits(.isImage)
        .accessibilityHint(String(localized: "Opens it larger"))
        .accessibilityAction(named: Text("Copy Source")) { Pasteboard.copy(block.source) }
    }

    /// A quiet space about as tall as the drawing will be, so the reply barely moves when it lands.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.code, style: .continuous)
            .fill(block.kind == .math ? Color.clear : Theme.surface)
            .frame(height: block.kind == .math ? fontSize * 2.6 : 160)
            .frame(maxWidth: .infinity)
            .accessibilityElement()
            .accessibilityLabel(block.name)
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodeBlockView(language: language, code: block.source)
            Label(Self.failure(block.kind), systemImage: "exclamationmark.triangle")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    static func failure(_ kind: DrawnBlock.Kind) -> String {
        switch kind {
        case .mermaid: String(localized: "This diagram couldn't be drawn")
        case .math: String(localized: "This formula couldn't be drawn")
        case .svg: String(localized: "This picture couldn't be drawn")
        }
    }
}

/// Opens drawn blocks larger from the window's root, one sheet for the window rather than one
/// waiting on every drawing of a long chat (`docs/chat.md` §3b).
@Observable
final class DrawnBlockPresenter {
    struct Request: Identifiable {
        let id = UUID()
        let block: DrawnBlock
        let request: DrawnBlockRenderer.Request
    }

    var request: Request?
}

extension View {
    /// Lets the drawn blocks below open larger over this view.
    func drawnBlockHost() -> some View { modifier(DrawnBlockHost()) }
}

private struct DrawnBlockHost: ViewModifier {
    @State private var presenter = DrawnBlockPresenter()

    func body(content: Content) -> some View {
        content
            .environment(\.drawnBlockPresenter, presenter)
            .sheet(item: $presenter.request) { open in
                DrawnBlockSheet(block: open.block, request: open.request)
            }
    }
}

/// A block's own sheet, only where no window root opens it (a preview).
private struct OwnSheet<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let hasHost: Bool
    @ViewBuilder let sheet: () -> Sheet

    func body(content: Content) -> some View {
        if hasHost {
            content
        } else {
            content.sheet(isPresented: $isPresented, content: sheet)
        }
    }
}

/// A drawn block larger: pinch, double tap or ⌘+ to zoom, and its source beside it.
private struct DrawnBlockSheet: View {
    let block: DrawnBlock
    let request: DrawnBlockRenderer.Request

    @Environment(\.dismiss) private var dismiss
    @State private var showsSource = false
    @State private var drawing: DrawnBlockRenderer.Drawing?
    @State private var step = 0
    @State private var resets = 0
    @State private var zoomed = false

    var body: some View {
        NavigationStack {
            Group {
                if showsSource {
                    ScrollView {
                        CodeBlockView(language: block.kind.rawValue, code: block.source)
                            .padding()
                    }
                } else if let image = drawing?.image {
                    ZoomableImage(image: image, step: $step, resets: resets, isCurrent: true, zoomed: $zoomed)
                        .background(block.kind == .svg ? Color.white : Color.clear)
                        .padding()
                        .accessibilityLabel(block.name)
                } else if drawing != nil {
                    ContentUnavailableView(DrawnBlockView.failure(block.kind), systemImage: "exclamationmark.triangle")
                } else {
                    Spinner(size: .regular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(block.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $showsSource) {
                        Text(block.kind == .math ? "Formula" : block.kind == .svg ? "Picture" : "Diagram").tag(false)
                        Text("Source").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy Source", systemImage: "square.on.square") { Pasteboard.copy(block.source) }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 760, minHeight: 420, idealHeight: 600)
        #endif
        .task {
            // Drawn again larger, so zooming in stays sharp.
            var large = request
            large.scale = request.scale * 3
            drawing = await DrawnBlockRenderer.shared.draw(large)
        }
    }
}

extension EnvironmentValues {
    /// The block is the last of a reply still arriving: a fence in it may not be closed yet, so a
    /// diagram shows as its source until the reply moves past it (`docs/chat.md` §3b).
    @Entry var markdownOpenTail = false
    /// Where a drawn block opens larger; nil where no window root hosts it.
    @Entry var drawnBlockPresenter: DrawnBlockPresenter? = nil
}
