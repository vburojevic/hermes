import HermesKit
import SwiftUI

#if DEBUG

/// Every example in every state, at both densities (`docs/widgets.md` §13): Settings → Developer
/// → Widgets in Debug builds, or `-HERMES_GALLERY widgets[:<type or example>[:<state>]]` for
/// screenshots ("widgets:table-1:ready" is that one card). It's what the designs are compared with.
struct WidgetGallery: View {
    var type: WidgetType?
    var example: String?
    var state: WidgetGalleryState?

    @State private var compact = WidgetDensity.platform == .compact

    init(page: String = "widgets") {
        let parts = page.split(separator: ":").map(String.init)
        // "table" is a type; "table-1" one of its examples.
        let named = parts.count > 1 ? parts[1] : ""
        type = WidgetType(rawValue: named) ?? WidgetType(rawValue: String(named.prefix { $0 != "-" }))
        example = named.contains("-") ? named : nil
        state = parts.count > 2 ? WidgetGalleryState(rawValue: parts[2]) : nil
        if parts.contains("compact") { _compact = State(initialValue: true) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Picker("Density", selection: $compact) {
                    Text("Regular").tag(false)
                    Text("Compact").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                ForEach(types, id: \.self) { type in
                    section(type)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .environment(\.widgetDensity, compact ? .compact : .regular)
        .navigationTitle("Widgets")
        .onAppear { WidgetGalleryLook.apply() }
    }

    private var types: [WidgetType] {
        type.map { [$0] } ?? WidgetType.allCases
    }

    private func section(_ type: WidgetType) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(type.rawValue).font(.title3.weight(.semibold))
            ForEach(Self.examples(for: type).filter { self.example == nil || $0.name == self.example }, id: \.name) { example in
                ForEach(states(for: example.json), id: \.self) { state in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(example.name) · \(state.rawValue)").font(.caption.monospaced()).foregroundStyle(Theme.tertiaryText)
                        WidgetGalleryItem(json: example.json, state: state)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("gallery.\(example.name).\(state.rawValue)")
                }
            }
        }
    }

    /// The bundled examples, plus `weather-alert`: the first forecast with the compact example's
    /// warning, so the banner over a full forecast (`Things.weatherAlert`) has a card to compare.
    static func examples(for type: WidgetType) -> [(name: String, json: JSONValue)] {
        let examples = WidgetSpec.shared.examples(for: type)
        guard type == .weather, case .object(var forecast)? = examples.first(where: { $0.name == "weather-1" })?.json,
              let alerts = examples.lazy.compactMap({ $0.json["alerts"] }).first else { return examples }
        forecast["alerts"] = alerts
        forecast["id"] = .string("w_galleryalert1")
        return examples + [("weather-alert", .object(forecast))]
    }

    private func states(for json: JSONValue) -> [WidgetGalleryState] {
        if let state { return [state] }
        return type == nil ? [.ready] : WidgetGalleryState.allCases.filter { $0.applies(to: json) }
    }
}

/// `-HERMES_GALLERY_LOOK light|dark|light+contrast|dark+contrast`: the window's appearance and
/// Increase Contrast, so the snapshot test (`WidgetGalleryUITests`) can draw every look in one run.
enum WidgetGalleryLook {
    static func apply() {
        guard let look = UserDefaults.standard.string(forKey: "HERMES_GALLERY_LOOK") else { return }
        let dark = look.hasPrefix("dark")
        let contrast = look.contains("contrast")
        #if os(iOS)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = dark ? .dark : .light
                window.traitOverrides.accessibilityContrast = contrast ? .high : .normal
            }
        }
        #else
        let name: NSAppearance.Name = switch (dark, contrast) {
        case (false, false): .aqua
        case (true, false): .darkAqua
        case (false, true): .accessibilityHighContrastAqua
        case (true, true): .accessibilityHighContrastDarkAqua
        }
        NSApp.appearance = NSAppearance(named: name)
        #endif
    }
}

enum WidgetGalleryState: String, CaseIterable, Hashable {
    case ready, loading, stale, missing, fallback, sending, queued, elsewhere, noAnswer, notSent, expired, superseded, notAnswered, readOnly

    func applies(to json: JSONValue) -> Bool {
        switch self {
        case .stale: json["stale_after"] != nil
        case .expired: json["expires_at"] != nil
        case .notAnswered: ["choice", "form"].contains(json["type"]?.stringValue ?? "")
        default: true
        }
    }
}

/// One example in one state.
struct WidgetGalleryItem: View {
    let json: JSONValue
    let state: WidgetGalleryState

    var body: some View {
        let result = WidgetReader.read(Self.stamped(json))
        switch (state, result) {
        case (.loading, _):
            WidgetLoadingCard(title: json["title"]?.stringValue, kind: WidgetType(rawValue: json["type"]?.stringValue ?? "")?.skeleton ?? .rows)
        case (.missing, _):
            WidgetMissingCard(alt: json["title"]?.stringValue) {}
        case (.fallback, _):
            WidgetFallbackView(fallback: WidgetFallback(
                id: json["id"]?.stringValue, rev: 1, type: json["type"]?.stringValue, title: json["title"]?.stringValue,
                text: json["fallback_text"]?.stringValue, reason: .unknownType("example"), isPrivate: false, json: json))
        case (_, .fallback(let fallback)):
            WidgetFallbackView(fallback: fallback)
        case (_, .ready(let payload)):
            WidgetCard(payload: payload)
                .environment(\.widgetPreview, preview(payload))
        }
    }

    /// The producer the plugin would stamp: a `bot:` icon's Bot (examples carry none), so the
    /// gallery draws that Bot's face as a reply would.
    static func stamped(_ json: JSONValue) -> JSONValue {
        guard case .object(var object) = json, object["producer"] == nil else { return json }
        var icons = [object["icon"]?.stringValue]
        if case .array(let children)? = object["children"] { icons += children.map { $0["icon"]?.stringValue } }
        guard let handle = icons.compactMap({ WidgetSymbols.botHandle($0) }).first else { return json }
        let producer = JSONValue.object(["name": .string(handle.replacingOccurrences(of: "-", with: " ").capitalized), "bot": .string(handle)])
        object["producer"] = producer
        if case .array(let children)? = object["children"] {
            object["children"] = .array(children.map { child in
                guard case .object(var fields) = child else { return child }
                fields["producer"] = producer
                return .object(fields)
            })
        }
        return .object(object)
    }

    private func preview(_ payload: WidgetPayload) -> WidgetPreview {
        let asOf = WidgetClock.date(payload.envelope.asOf) ?? .now
        let answer = WidgetChatFacts.Answer(
            rowID: "gallery", rev: payload.rev, action: "approve", mid: "gallery", device: "Mac", at: asOf,
            text: WidgetAnswer(widgetID: payload.id, rev: payload.rev, action: "approve", mid: "gallery").message)
        switch state {
        case .stale:
            return WidgetPreview(now: asOf.addingTimeInterval(TimeInterval(payload.envelope.staleAfter ?? 3600) + 3 * 3600))
        case .expired:
            return WidgetPreview(now: WidgetClock.date(payload.envelope.expiresAt).map { $0.addingTimeInterval(60) } ?? asOf, interaction: .expired)
        case .sending: return WidgetPreview(now: asOf, interaction: .sending(action: "approve", queued: false))
        case .queued: return WidgetPreview(now: asOf, interaction: .sending(action: "approve", queued: true))
        case .elsewhere: return WidgetPreview(now: asOf, interaction: .waiting(action: "approve", mine: false, device: "Mac"))
        case .noAnswer: return WidgetPreview(now: asOf, interaction: .noAnswer(answer: answer))
        case .notSent: return WidgetPreview(now: asOf, interaction: .notSent(action: "approve"))
        case .superseded: return WidgetPreview(now: asOf, interaction: .superseded(by: "w_gallery0001"))
        case .notAnswered: return WidgetPreview(now: asOf, interaction: .notAnswered)
        case .readOnly: return WidgetPreview(now: asOf, interaction: .readOnly(for: "Maya"))
        default: return WidgetPreview(now: asOf)
        }
    }
}
#endif

/// Settings → Developer (`docs/widgets.md` §11): Render Inline Widgets in every build, for agents'
/// developers and the mock; the widget gallery in Debug builds.
struct WidgetDeveloperSection: View {
    @AppStorage(WidgetSettings.renderInlineKey) private var rendersInline = false

    var body: some View {
        Section {
            Toggle("Render Inline Widgets", isOn: $rendersInline)
            #if DEBUG
            NavigationLink("Widgets") { WidgetGallery().settingsPage(back: String(localized: "Developer")) }
            #endif
        } header: {
            Text("Developer")
        } footer: {
            Text("Draws ```widget blocks in any reply, not only in deliveries from the widgets plugin. For testing agents.")
        }
    }
}
