import HermesKit
import HermesMarkdown
import SwiftUI
import WebKit

// MARK: - In the transcript

/// `artifactCard`: something Hermes made or opened that shows in the Inspector. "Showing" (and an
/// ink outline) while it's the Inspector's open tab.
struct InspectorCard: View {
    let symbol: String
    let title: String
    let detail: String
    let isShowing: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 52, height: 52)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button(isShowing ? "Showing" : "Open", action: open)
                .font(.footnote.weight(.medium))
                .cardButton()
                .allowsHitTesting(!isShowing)
                .accessibilityLabel(isShowing ? Text("\(title), showing in the Inspector") : Text("Open \(title) in the Inspector"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if isShowing {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.ink, lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { if !isShowing { open() } }
        .frame(maxWidth: 460, alignment: .leading)
    }
}

/// The cards a reply carries: its artifacts (each at the version this reply made), and pages
/// Hermes opened during the turn (`desktop_preview`).
struct TurnInspectorCards: View {
    let turn: AssistantTurn
    let inspector: InspectorModel

    var body: some View {
        let artifacts = turnArtifacts
        let pages = openedPages
        if !artifacts.isEmpty || !pages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pages, id: \.url) { page in
                    let target = PreviewTarget(page.url)
                    InspectorCard(
                        symbol: "globe",
                        title: page.label ?? target.displayURL,
                        detail: String(localized: "\(target.displayURL) · opened by Hermes"),
                        isShowing: inspector.isPresented && inspector.selected.map { $0.kind == .preview && target.matches($0.key) } == true
                    ) {
                        inspector.openPage(url: page.url, label: page.label)
                    }
                }
                ForEach(artifacts, id: \.artifact.slug) { item in
                    InspectorCard(
                        symbol: item.artifact.detection.kind == .code ? "chevron.left.forwardslash.chevron.right" : "sparkles",
                        title: item.artifact.detection.title,
                        detail: detail(item.artifact, version: item.version),
                        isShowing: inspector.isPresented && inspector.selected?.id == "artifact:\(item.artifact.slug)"
                            && (inspector.artifactVersions["artifact:\(item.artifact.slug)"] ?? item.artifact.versions.count) == item.version
                    ) {
                        inspector.openArtifact(item.artifact, version: item.version == item.artifact.versions.count ? nil : item.version)
                    }
                }
            }
        }
    }

    /// This reply's artifacts, each with the version number it made.
    private var turnArtifacts: [(artifact: Artifact, version: Int)] {
        inspector.artifacts.compactMap { artifact in
            guard let index = artifact.versions.firstIndex(where: { $0.turnID == turn.id }) else { return nil }
            return (artifact, index + 1)
        }
    }

    private var openedPages: [(url: String, label: String?)] {
        var seen = Set<String>()
        return turn.steps.compactMap { step -> (String, String?)? in
            guard case .tool(let tool) = step, tool.name == "desktop_preview", tool.arguments?["action"]?.stringValue == "open",
                  let url = tool.arguments?["url"]?.stringValue, !url.isEmpty, seen.insert(url).inserted else { return nil }
            return (url, tool.arguments?["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// "HTML · version 3 · updated just now".
    private func detail(_ artifact: Artifact, version: Int) -> String {
        let kind = switch artifact.detection.kind {
        case .html: "HTML"
        case .svg: "SVG"
        case .code: CodeHighlighter.displayName(for: artifact.detection.language) ?? String(localized: "Code")
        }
        var parts = [kind]
        if artifact.versions.count > 1 || version > 1 { parts.append(String(localized: "version \(version)")) }
        if let at = artifact.versions[version - 1].at { parts.append(String(localized: "updated \(Formatting.relativePhrase(at))")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The Artifact tab

/// An Artifact tab (`macInspectorArtifact`): `artifactBar` with the version stepper, Preview / Code,
/// Copy and Save, over the artifact rendered in a sandboxed web view with no network unless the
/// person allows it.
struct ArtifactTabView: View {
    let inspector: InspectorModel
    let tab: InspectorTab

    @State private var showsCode = false
    @State private var copied = false
    @State private var saving = false
    @State private var savePath = ""
    @State private var saveNote: String?
    @State private var lastCount = 0

    private var artifact: Artifact? { inspector.artifact(tab.key) }

    var body: some View {
        if let artifact {
            let count = artifact.versions.count
            let version = min(inspector.artifactVersions[tab.id] ?? count, count)
            let content = artifact.versions[version - 1].content
            VStack(spacing: 0) {
                bar(artifact, version: version, count: count, content: content)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                Divider().overlay(Theme.hairline)
                if let saveNote {
                    Text(saveNote)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.surface)
                }
                if showsCode || artifact.detection.kind == .code {
                    CodeTextView(text: .constant(content), language: artifact.detection.kind == .svg ? "xml" : artifact.detection.language)
                } else {
                    SandboxedArtifactView(html: Self.document(for: artifact, content: content),
                                          allowsNetwork: inspector.networkArtifacts.contains(artifact.slug))
                        .background(Theme.surface)
                }
            }
            .onChange(of: count) { old, new in
                if new > old { inspector.markChanged(tab.id) }
            }
            .alert("Save to the Project", isPresented: $saving) {
                TextField("Path", text: $savePath)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Cancel", role: .cancel) {}
                Button("Save") { save(content) }
            } message: {
                Text("Where on \(inspector.gatewayMachineName) this version goes.")
            }
        } else {
            StateMessage(symbol: "sparkles", title: String(localized: "This artifact isn't in the chat anymore"), message: nil)
        }
    }

    private func bar(_ artifact: Artifact, version: Int, count: Int, content: String) -> some View {
        HStack(spacing: 8) {
            Button {
                inspector.artifactVersions[tab.id] = version - 1
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .disabled(version <= 1)
            .opacity(version <= 1 ? 0.4 : 1)
            .accessibilityLabel("Previous Version")
            Text("Version \(version) of \(count)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
            Button {
                inspector.artifactVersions[tab.id] = version + 1 >= count ? nil : version + 1
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .disabled(version >= count)
            .opacity(version >= count ? 0.4 : 1)
            .accessibilityLabel("Next Version")
            Spacer(minLength: 6)
            if artifact.detection.kind != .code {
                Picker("View", selection: $showsCode) {
                    Text("Preview").tag(false)
                    Text("Code").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                if !showsCode, artifact.detection.kind == .html {
                    let allowed = inspector.networkArtifacts.contains(artifact.slug)
                    Button {
                        if allowed { inspector.networkArtifacts.remove(artifact.slug) } else { inspector.networkArtifacts.insert(artifact.slug) }
                    } label: {
                        Image(systemName: allowed ? "network" : "network.slash").font(.system(size: 13))
                    }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .foregroundStyle(allowed ? Theme.primaryText : Theme.secondaryText)
                    .accessibilityLabel(allowed ? "Block Network" : "Allow Network")
                    .help(allowed ? "Block network access" : "Allow network access")
                }
            }
            Button {
                Pasteboard.copy(content)
                withAnimation(Theme.snappy) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(Theme.snappy) { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .accessibilityLabel(copied ? "Copied" : "Copy")
            .help("Copy")
            Button {
                let folder = inspector.workingFolder ?? ""
                savePath = (folder as NSString).appendingPathComponent(ArtifactDetector.fileName(for: artifact.detection))
                saving = true
            } label: {
                Image(systemName: "square.and.arrow.down").font(.system(size: 13))
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .disabled(inspector.backend == nil)
            .accessibilityLabel("Save to the Project")
            .help("Save to the Project")
        }
        .foregroundStyle(Theme.primaryText)
        .frame(height: 36)
    }

    private func save(_ content: String) {
        let path = savePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let backend = inspector.backend else { return }
        Task {
            do {
                try await backend.writeText(path, content: content, profile: inspector.profile)
                saveNote = String(localized: "Saved to \(path)")
                inspector.fileSaved(path)
            } catch {
                saveNote = FileEditorModel.describe(error)
            }
        }
    }

    /// The page an artifact renders as: HTML as written, SVG centred on a page.
    static func document(for artifact: Artifact, content: String) -> String {
        switch artifact.detection.kind {
        case .svg:
            return "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width\"><style>html,body{margin:0;height:100%;display:flex;align-items:center;justify-content:center;background:transparent}svg{max-width:100%;max-height:100%}</style></head><body>\(content)</body></html>"
        default:
            return content
        }
    }
}

/// An artifact rendered on its own: no cookies or storage, and no network unless allowed (a
/// content security policy that lets only inline code and data run).
struct SandboxedArtifactView: View {
    let html: String
    let allowsNetwork: Bool

    var body: some View {
        SandboxedWebView(html: html, allowsNetwork: allowsNetwork)
            .id(allowsNetwork)
    }
}

private struct SandboxedWebView {
    let html: String
    let allowsNetwork: Bool

    static let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data: blob:; media-src data: blob:; style-src 'unsafe-inline' data:; script-src 'unsafe-inline'; font-src data:\">"

    func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        #endif
        load(view, context: context)
        return view
    }

    func load(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(allowsNetwork ? html : Self.sandboxed(html), baseURL: nil)
    }

    /// The policy goes first in the head, before anything it should cover.
    static func sandboxed(_ html: String) -> String {
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var out = html
            out.insert(contentsOf: policy, at: head.upperBound)
            return out
        }
        return policy + html
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        /// Only the artifact itself loads here; links open in the browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .other || action.request.url?.scheme == "about" { return .allow }
            if let url = action.request.url, url.scheme == "https" || url.scheme == "http" {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                await UIApplication.shared.open(url)
                #endif
            }
            return .cancel
        }
    }
}

#if os(macOS)
extension SandboxedWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ view: WKWebView, context: Context) { load(view, context: context) }
}
#else
extension SandboxedWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ view: WKWebView, context: Context) { load(view, context: context) }
}
#endif
