import HermesMarkdown
import OSLog
import SwiftUI
import WebKit

/// Draws a reply's Mermaid diagrams, display math and SVG pictures (`docs/chat.md` §3b), on the
/// device and offline: one hidden web view, made the first time a reply needs one, runs the
/// bundled Mermaid and MathJax (`App/Resources/RenderKit`) and hands back a PNG.
///
/// The page loads nothing: its policy allows no source but `data:` images, every navigation is
/// cancelled, and its data store keeps nothing. A drawing becomes an `<img>` before it is
/// painted, so no script in an SVG runs and nothing it points to loads. Drawings are kept in
/// memory by what they are and how they look (source, colours, type size, scale), never per
/// frame or per width: a reply scrolled past draws nothing again.
@MainActor
final class DrawnBlockRenderer: NSObject, WKNavigationDelegate {
    static let shared = DrawnBlockRenderer()

    /// A drawing, or that the block couldn't be drawn.
    nonisolated final class Drawing: Sendable {
        let image: CGImage?
        /// Its size in points at the type size it was drawn for.
        let size: CGSize

        init(image: CGImage?, size: CGSize) {
            self.image = image
            self.size = size
        }
    }

    /// Everything that changes a drawing.
    nonisolated struct Request: Hashable, Sendable {
        var block: DrawnBlock
        var look: Look
        /// Pixels per point.
        var scale: CGFloat
    }

    /// The colours and type size a diagram or formula is drawn in.
    nonisolated struct Look: Hashable, Sendable {
        var dark: Bool
        var font: Double
        var canvas: String
        var text: String
        var secondary: String
        var line: String
        var fill: String
        var fill2: String
        var fill3: String
    }

    /// No side of a drawing past this many pixels, and no more than `maxPixels` in all: a huge
    /// diagram is drawn smaller rather than holding hundreds of megabytes.
    static let maxSide = 4096
    static let maxPixels = 16_000_000

    private let cache = NSCache<Key, Drawing>()
    private var running: [Request: Task<Drawing, Never>] = [:]
    /// Jobs run one at a time: Mermaid lays out in the one page.
    private var queue: Task<Void, Never>?
    private var web: WKWebView?
    private var page: Task<Bool, Never>?
    private var libraries: Set<String> = []
    /// Lets the page go once nothing has been drawn for a while.
    private var idle: Task<Void, Never>?
    private static let origin = URL(string: "https://drawing.hermes.invalid/")!
    private static let policy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; form-action 'none'"
    private let log = Logger(subsystem: "co.caffeinatedcode.hermes", category: "drawn-blocks")

    override private init() {
        super.init()
        // About 64 MB of decoded drawings; the oldest go first.
        cache.totalCostLimit = 64 * 1024 * 1024
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self, selector: #selector(memoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #endif
    }

    #if os(iOS)
    @objc private func memoryWarning() {
        cache.removeAllObjects()
        releasePage()
    }
    #endif

    /// The page holds Mermaid and MathJax, a web process of over 100 MB: it goes when nothing is
    /// drawing, and is made again (about 50 ms) for the next drawing.
    private func releasePage() {
        guard running.isEmpty else { return }
        idle?.cancel()
        idle = nil
        web = nil
        page = nil
        libraries = []
    }

    /// The drawing already made for this request.
    func drawing(for request: Request) -> Drawing? {
        cache.object(forKey: Key(request))
    }

    /// Draws the block, or waits for the same drawing already under way.
    func draw(_ request: Request) async -> Drawing {
        if let done = drawing(for: request) { return done }
        if let task = running[request] { return await task.value }
        idle?.cancel()
        let previous = queue
        let task = Task { @MainActor [weak self] () -> Drawing in
            await previous?.value
            guard let self else { return Drawing(image: nil, size: .zero) }
            return await self.run(request)
        }
        running[request] = task
        queue = Task { _ = await task.value }
        let drawing = await task.value
        running[request] = nil
        let cost = drawing.image.map { $0.bytesPerRow * $0.height } ?? 64
        cache.setObject(drawing, forKey: Key(request), cost: cost)
        if running.isEmpty {
            idle?.cancel()
            idle = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.releasePage()
            }
        }
        return drawing
    }

    private func run(_ request: Request) async -> Drawing {
        let started = ContinuousClock.now
        let failed = Drawing(image: nil, size: .zero)
        guard await ready(), let web, await load(library(for: request.block.kind), into: web) else { return failed }
        let job: [String: Any] = [
            "kind": request.block.kind.rawValue,
            "source": request.block.source,
            "scale": Double(request.scale),
            "maxSide": Self.maxSide,
            "maxPixels": Self.maxPixels,
            "theme": [
                "dark": request.look.dark, "font": request.look.font, "canvas": request.look.canvas,
                "text": request.look.text, "secondary": request.look.secondary, "line": request.look.line,
                "fill": request.look.fill, "fill2": request.look.fill2, "fill3": request.look.fill3,
            ] as [String: Any],
        ]
        do {
            let result = try await web.callAsyncJavaScript(
                "return await window.hermesDraw(job);", arguments: ["job": job], in: nil, contentWorld: .page)
            guard let result = result as? [String: Any], let png = result["png"] as? String,
                  let width = result["width"] as? Double, let height = result["height"] as? Double,
                  let data = Data(base64Encoded: png), let image = await Self.image(data) else { return failed }
            let elapsed = ContinuousClock.now - started
            let milliseconds = Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            log.info("drew \(request.block.kind.rawValue, privacy: .public) in \(milliseconds) ms")
            return Drawing(image: image, size: CGSize(width: width, height: height))
        } catch {
            // The source can be anything the reply said: only that it failed, never what it was.
            let error = error as NSError
            log.debug("couldn't draw \(request.block.kind.rawValue, privacy: .public): \(error.domain, privacy: .public) \(error.code)")
            return failed
        }
    }

    private func library(for kind: DrawnBlock.Kind) -> String? {
        switch kind {
        case .mermaid: "mermaid.min"
        case .math: "tex-svg-full"
        case .svg: nil
        }
    }

    /// The page, loaded once with the drawing script.
    private func ready() async -> Bool {
        if let page { return await page.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return await self.makePage()
        }
        page = task
        let ok = await task.value
        if !ok { page = nil }
        return ok
    }

    private var loaded: CheckedContinuation<Bool, Never>?

    private func makePage() async -> Bool {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // Out of any window: the page keeps running its work all the same.
        configuration.preferences.inactiveSchedulingPolicy = .none
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024), configuration: configuration)
        web.navigationDelegate = self
        self.web = web
        let headers = ["Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": Self.policy]
        guard let response = HTTPURLResponse(url: Self.origin, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return false }
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"margin:0\"></body></html>"
        let finished = await withCheckedContinuation { continuation in
            loaded = continuation
            expectsLoad = true
            web.loadSimulatedRequest(URLRequest(url: Self.origin), response: response, responseData: Data(html.utf8))
        }
        guard finished else { return false }
        return await load("drawn-blocks", into: web)
    }

    /// Evaluates one of the bundled scripts in the page, once.
    private func load(_ name: String?, into web: WKWebView) async -> Bool {
        guard let name else { return true }
        if libraries.contains(name) { return true }
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            log.error("missing \(name, privacy: .public).js")
            return false
        }
        do {
            _ = try await web.evaluateJavaScript(script + "\n;true")
            libraries.insert(name)
            return true
        } catch {
            let error = error as NSError
            log.error("couldn't load \(name, privacy: .public): \(error.domain, privacy: .public) \(error.code)")
            return false
        }
    }

    /// The PNG decoded off the main thread into the screen's own pixel format (premultiplied BGRA),
    /// so showing it again while scrolling neither decodes nor converts it.
    @concurrent private nonisolated static func image(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        return context.makeImage()
    }

    private var looks: [LookKey: Look] = [:]

    private struct LookKey: Hashable {
        var dark: Bool
        var highContrast: Bool
        var font: Double
    }

    /// The reply's colours, resolved once per appearance and type size: a view asks on every redraw.
    func look(dark: Bool, highContrast: Bool, font: Double) -> Look {
        let key = LookKey(dark: dark, highContrast: highContrast, font: font)
        if let look = looks[key] { return look }
        let look = Look.current(dark: dark, highContrast: highContrast, font: font)
        looks[key] = look
        return look
    }

    // MARK: Navigation

    private var expectsLoad = false

    /// Only the page itself loads; nothing navigates it anywhere else.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if expectsLoad, action.targetFrame?.isMainFrame ?? false, action.request.url == Self.origin {
            expectsLoad = false
            return .allow
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume(returning: true)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(returning: false)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(returning: false)
        loaded = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Made again for the next drawing.
        self.web = nil
        page = nil
        libraries = []
    }

    /// `NSCache` wants an object for a key.
    private nonisolated final class Key: NSObject {
        let request: Request
        /// Hashed once: an SVG's source can be long.
        private let hashed: Int
        init(_ request: Request) {
            self.request = request
            hashed = request.hashValue
        }
        override var hash: Int { hashed }
        override func isEqual(_ object: Any?) -> Bool { (object as? Key)?.request == request }
    }
}

extension DrawnBlockRenderer.Look {
    /// The reply's colours for this appearance, as opaque hex over the chat's background.
    static func current(dark: Bool, highContrast: Bool, font: Double) -> Self {
        func hex(_ color: Color) -> String { Self.hex(color, dark: dark, highContrast: highContrast) }
        return Self(
            dark: dark, font: font, canvas: hex(Theme.canvas), text: hex(Theme.primaryText), secondary: hex(Theme.secondaryText),
            line: hex(Theme.tertiaryText), fill: hex(Theme.surfaceRaised), fill2: hex(Theme.controlFill), fill3: hex(Theme.surface))
    }

    /// One colour for this appearance, as opaque hex over the chat's background.
    static func hex(_ color: Color, dark: Bool, highContrast: Bool) -> String {
        let canvas = Self.resolve(Theme.canvas, dark: dark, highContrast: highContrast)
        let (r, g, b, a) = Self.resolve(color, dark: dark, highContrast: highContrast)
        let over = { (top: Double, bottom: Double) in top * a + bottom * (1 - a) }
        let channels = [over(r, canvas.0), over(g, canvas.1), over(b, canvas.2)]
        return "#" + channels.map { String(format: "%02x", Int(($0 * 255).rounded()).clamped(0, 255)) }.joined()
    }

    private static func resolve(_ color: Color, dark: Bool, highContrast: Bool) -> (Double, Double, Double, Double) {
        #if os(macOS)
        let name: NSAppearance.Name = switch (dark, highContrast) {
        case (false, false): .aqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (true, true): .accessibilityHighContrastDarkAqua
        }
        var components = (0.0, 0.0, 0.0, 1.0)
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                components = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
            }
        }
        return components
        #else
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.accessibilityContrast = highContrast ? .high : .normal
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
        #endif
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}
