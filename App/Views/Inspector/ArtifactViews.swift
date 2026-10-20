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
            stepper(version: version, count: count)
            Spacer(minLength: 6)
            if artifact.detection.kind != .code {
                Picker("View", selection: $showsCode) {
                    Text("Preview").tag(false)
                    Text("Code").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            // Every action as a button where there's room; on a phone, a menu.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    if !showsCode, artifact.detection.kind == .html {
                        networkButton(artifact)
                    }
                    copyButton(content)
                    saveButton(artifact)
                }
                Menu {
                    Button(copied ? "Copied" : "Copy", systemImage: "doc.on.doc") { copy(content) }
                    Button("Save to the Project…", systemImage: "square.and.arrow.down") { askToSave(artifact) }
                        .disabled(inspector.backend == nil)
                    if !showsCode, artifact.detection.kind == .html {
                        let allowed = inspector.networkArtifacts.contains(artifact.slug)
                        Toggle("Allow Network", systemImage: "network", isOn: Binding(
                            get: { allowed },
                            set: { if $0 { inspector.networkArtifacts.insert(artifact.slug) } else { inspector.networkArtifacts.remove(artifact.slug) } }
                        ))
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("More")
            }
        }
        .foregroundStyle(Theme.primaryText)
        .frame(height: 36)
    }

    private func stepper(version: Int, count: Int) -> some View {
        HStack(spacing: 4) {
            Button {
                inspector.artifactVersions[tab.id] = version - 1
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .disabled(version <= 1)
            .opacity(version <= 1 ? 0.4 : 1)
            .accessibilityLabel("Previous Version")
            ViewThatFits(in: .horizontal) {
                Text("Version \(version) of \(count)")
                Text("\(version) of \(count)")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityLabel(Text("Version \(version) of \(count)"))
            Button {
                inspector.artifactVersions[tab.id] = version + 1 >= count ? nil : version + 1
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .disabled(version >= count)
            .opacity(version >= count ? 0.4 : 1)
            .accessibilityLabel("Next Version")
        }
    }

    private func networkButton(_ artifact: Artifact) -> some View {
        let allowed = inspector.networkArtifacts.contains(artifact.slug)
        return Button {
            if allowed { inspector.networkArtifacts.remove(artifact.slug) } else { inspector.networkArtifacts.insert(artifact.slug) }
        } label: {
            Image(systemName: allowed ? "network" : "network.slash").font(.system(size: 13))
        }
        .buttonStyle(IconButtonStyle(size: 30))
        .foregroundStyle(allowed ? Theme.primaryText : Theme.secondaryText)
        .accessibilityLabel(allowed ? "Block Network" : "Allow Network")
        .help(allowed ? "Block network access" : "Allow network access")
    }

    private func copyButton(_ content: String) -> some View {
        Button {
            copy(content)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IconButtonStyle(size: 30))
        .accessibilityLabel(copied ? "Copied" : "Copy")
        .help("Copy")
    }

    private func saveButton(_ artifact: Artifact) -> some View {
        Button {
            askToSave(artifact)
        } label: {
            Image(systemName: "square.and.arrow.down").font(.system(size: 13))
        }
        .buttonStyle(IconButtonStyle(size: 30))
        .disabled(inspector.backend == nil)
        .accessibilityLabel("Save to the Project")
        .help("Save to the Project")
    }

    private func copy(_ content: String) {
        Pasteboard.copy(content)
        withAnimation(Theme.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(Theme.snappy) { copied = false }
        }
    }

    private func askToSave(_ artifact: Artifact) {
        let folder = inspector.workingFolder ?? ""
        savePath = (folder as NSString).appendingPathComponent(ArtifactDetector.fileName(for: artifact.detection))
        saving = true
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

    /// Without network: nothing loads from anywhere, inline code and `data:` resources only.
    static let policy = "default-src 'none'; img-src data: blob:; media-src data: blob:; style-src 'unsafe-inline' data:; script-src 'unsafe-inline'; font-src data:; frame-src data: blob: about:; form-action 'none'"

    /// Where an artifact "comes from": a name that never resolves, so a relative address goes
    /// nowhere, as it did with no base URL.
    static let origin = URL(string: "https://artifact.hermes.invalid/")!

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
        let head = html.range(of: "name=\"viewport\"", options: .caseInsensitive) == nil ? Self.viewport : ""
        // The policy travels as the response's header, so it covers the page from its first
        // byte, wherever the page's own head (or a script before it) sits.
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        if !allowsNetwork { headers["Content-Security-Policy"] = Self.policy }
        let response = HTTPURLResponse(url: Self.origin, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        context.coordinator.expectsLoad = true
        view.loadSimulatedRequest(URLRequest(url: Self.origin), response: response, responseData: Data(Self.inserting(head, into: html).utf8))
    }

    /// Phones lay the page out at their own width, as a browser tab would.
    static let viewport = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"

    /// What goes first in the head, before anything it should cover.
    static func inserting(_ head: String, into html: String) -> String {
        guard !head.isEmpty else { return html }
        if let range = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var out = html
            out.insert(contentsOf: head, at: range.upperBound)
            return out
        }
        return head + html
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        /// The artifact's own load is next; nothing else replaces the page.
        var expectsLoad = false

        /// Only the artifact itself loads here (a script or a meta refresh can't take the page
        /// elsewhere); links the person taps open in the browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = action.request.url
            if action.targetFrame?.isMainFrame ?? true {
                if expectsLoad, url == SandboxedWebView.origin {
                    expectsLoad = false
                    return .allow
                }
                // A jump within the page (`#section`).
                if let url, url.fragment() != nil, url.host() == SandboxedWebView.origin.host(), url.path() == SandboxedWebView.origin.path() {
                    return .allow
                }
            } else if action.navigationType == .other {
                // The page's own frames; the policy decides what they may load.
                return .allow
            }
            if action.navigationType == .linkActivated, let url, WebLink.isWeb(url), url.host() != SandboxedWebView.origin.host() {
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
