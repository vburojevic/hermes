import Charts
import CoreImage
import CoreImage.CIFilterBuiltins
import HermesKit
import HermesMarkdown
import MapKit
import SwiftUI

// The Things family (`widgets/things.elyx`): entity, media, code, sources, weather, route, pass.

// MARK: - entity

/// One thing as a card: a listing, product, person, place, event, file, link, review or pull
/// request (`Things.entity` and its recipes).
struct EntityBody: View {
    let model: EntityWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    private var position: EntityWidget.VisualPosition {
        guard model.visualPosition == .auto else { return model.visualPosition }
        switch model.kind {
        case .listing, .place: return .top
        case .link: return .trailing
        default: return .leading
        }
    }

    var body: some View {
        if model.gone {
            WidgetEmpty(context: context, fallback: String(localized: "This is no longer available."))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let visual = model.visual, position == .top || typeSize.isAccessibilitySize { topVisual(visual) }
                HStack(alignment: .top, spacing: 12) {
                    if let visual = model.visual, position == .leading, !typeSize.isAccessibilitySize {
                        // A product's photo sits beside its name, a little larger (`Things.entityProduct`).
                        WidgetLeadingView(leading: visual, size: model.kind == .product ? 60 : 44)
                    }
                    text
                    if let visual = model.visual, position == .trailing, !typeSize.isAccessibilitySize {
                        Spacer(minLength: 6)
                        WidgetLeadingView(leading: visual, size: 52)
                    }
                }
                facts
                if let contact = model.contact { reach(contact) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if let url = model.url { context.open(url) } }
        }
    }

    @ViewBuilder
    private func topVisual(_ visual: WidgetLeading) -> some View {
        switch visual.kind {
        case .image:
            if let media = visual.media { WidgetImage(media: media, maxHeight: 180) }
        case .map:
            if let location = visual.location {
                WidgetMapSnapshot(points: [CLLocationCoordinate2D(latitude: location.lat, longitude: location.lon)], label: location.label)
                    .frame(height: 140)
            }
        default:
            WidgetLeadingView(leading: visual, size: 44)
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let eyebrow = model.eyebrow ?? model.pullRequest.map({ "\($0.repo) #\($0.number)" }) {
                Text(eyebrow)
                    .font(model.pullRequest != nil ? WidgetFont.mono : WidgetFont.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Text(model.name).font(WidgetFont.valueSmall).foregroundStyle(Theme.primaryText).fixedSize(horizontal: false, vertical: true)
            if let detail = model.detail {
                Text(widgetLinking: detail).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.note {
                Text(widgetLinking: note).font(WidgetFont.caption).foregroundStyle(Theme.tertiaryText)
            }
            if model.kind == .product, let rating = model.rating, let value = rating.value {
                // "★ 4.7 · 2,140 reviews": a product's rating reads as one line under its name.
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.primaryText)
                    Text([WidgetFormatter.number(value, digits: 1), rating.count.map { String(localized: "\($0.formatted()) reviews") }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(WidgetFont.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([String(localized: "\(WidgetFormatter.number(value, digits: 1)) of \(rating.scale) stars"),
                                     rating.count.map { String(localized: "\($0.formatted()) reviews") }].compactMap { $0 }.joined(separator: ", "))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var facts: some View {
        if let price = model.price {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatter.string(price.amount)).font(WidgetFont.value.monospacedDigit())
                if let per = price.per { Text(per).font(WidgetFont.label).foregroundStyle(Theme.secondaryText) }
                if let was = price.was {
                    Text(formatter.string(was)).font(WidgetFont.label.monospacedDigit()).foregroundStyle(Theme.tertiaryText).strikethrough()
                        .accessibilityLabel(String(localized: "was \(formatter.string(was))"))
                }
                let atLowest = price.lowest.flatMap { lowest in
                    WidgetFormatter.number(price.amount).flatMap { now in WidgetFormatter.number(lowest.amount).map { now <= $0 * 1.02 } }
                } ?? false
                if let change = price.change, !atLowest { DeltaLabel(delta: change) }
                if let lowest = price.lowest, atLowest {
                    Spacer(minLength: 6)
                    // "Lowest in 90 days" when the price is at or near its best (`Things.entityProduct`).
                    Text(lowest.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.success)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 18)
                        .background(Theme.successTint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
            if let history = price.history, history.count > 1 {
                PriceHistory(points: history)
            }
        }
        if let rating = model.rating, model.kind != .product || rating.value == nil {
            HStack(spacing: 4) {
                if let value = rating.value {
                    ForEach(0..<rating.scale, id: \.self) { index in
                        Image(systemName: Double(index) + 0.5 <= value ? "star.fill" : (Double(index) < value ? "star.leadinghalf.filled" : "star"))
                            .font(.system(size: 11))
                    }
                    Text(WidgetFormatter.number(value, digits: 1)).font(WidgetFont.label.weight(.semibold))
                } else {
                    Text("No ratings yet").font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
                }
                if let count = rating.count { Text("(\(count))").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText) }
            }
            .foregroundStyle(Theme.primaryText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rating.value.map { String(localized: "\(WidgetFormatter.number($0, digits: 1)) of \(rating.scale) stars") } ?? String(localized: "No ratings yet"))
        }
        if let when = model.when {
            let response = when.response.map { response -> String in
                switch response {
                case .accepted: String(localized: "Going")
                case .tentative: String(localized: "Maybe")
                case .declined: String(localized: "Not going")
                case .notAnswered: String(localized: "Not answered")
                }
            }
            let start = when.allDay ? formatter.date(when.start) : formatter.dateTime(when.start)
            Label([start, when.end.flatMap { formatter.time($0) }.map { "– \($0)" }, response].compactMap { $0 }.joined(separator: " "), systemImage: "calendar")
                .font(WidgetFont.label)
        }
        if let place = model.place {
            Button {
                if let url = place.url { context.open(url) }
            } label: {
                Label([place.name, place.address].compactMap { $0 }.joined(separator: " · "), systemImage: "mappin.and.ellipse")
                    .font(WidgetFont.label)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .disabled(place.url == nil)
        }
        if let file = model.file {
            Text([file.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
                  file.pages.map { String(localized: "\($0) pages") }, file.from, file.modified.flatMap { formatter.dateTime($0) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(WidgetFont.label)
                .foregroundStyle(Theme.secondaryText)
        }
        if let attributes = model.attributes, !attributes.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(Array(attributes.enumerated()), id: \.offset) { _, attribute in
                    HStack(spacing: 4) {
                        if let glyph = WidgetSymbols.resolve(attribute.glyph) { Image(systemName: glyph).font(.system(size: 10)) }
                        // The value when there is one ("3 bd"), else the label ("Balcony"); both are read out.
                        Text(attribute.value ?? attribute.label)
                            .font(WidgetFont.label)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([attribute.label, attribute.value].compactMap { $0 }.joined(separator: ", "))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 26)
                    .background(Theme.canvas, in: Capsule())
                }
            }
        }
        if let body = model.body {
            Text("“\(body)”").font(WidgetFont.body).foregroundStyle(Theme.primaryText).fixedSize(horizontal: false, vertical: true)
        }
        if let people = model.people, !people.isEmpty {
            HStack(spacing: -6) {
                ForEach(Array(people.prefix(5).enumerated()), id: \.offset) { _, person in
                    Text(person.initials ?? String(person.name.prefix(1)))
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Theme.controlFill, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                }
                Text(people.map(\.name).joined(separator: ", "))
                    .font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).padding(.leading, 12).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(people.map(\.name).joined(separator: ", "))
        }
        if let request = model.pullRequest { pullRequest(request) }
        if let tags = model.tags, !tags.isEmpty {
            FlowLayout(spacing: 6) { ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in WidgetTagView(tag: tag) } }
        }
    }

    private func pullRequest(_ request: EntityWidget.PullRequest) -> some View {
        let checks: (String, WidgetTone) = switch request.checks.state {
        case .passed: (String(localized: "Checks passed"), .ok)
        case .failed: (String(localized: "\(request.checks.failed ?? 0) checks failed"), .critical)
        case .running: (String(localized: "Checks running"), .pending)
        case .none: (String(localized: "No checks"), .neutral)
        case .unknown: (String(localized: "Checks unknown"), .unverified)
        }
        return VStack(alignment: .leading, spacing: 6) {
            if let author = request.author {
                Text([author.name, request.head.map { "\($0) → \(request.base ?? "main")" }].compactMap { $0 }.joined(separator: " · "))
                    .font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 10) {
                WidgetBadge(tone: checks.1, word: checks.0)
                if let reviews = request.reviews, reviews.state != EntityWidget.PullRequest.Reviews.State.none {
                    Label(reviews.state == .approved ? String(localized: "\(reviews.approvals ?? 0) approvals") : String(localized: "Review required"),
                          systemImage: reviews.state == .approved ? "checkmark.circle" : "person.badge.clock")
                        .font(WidgetFont.caption)
                }
                if let additions = request.additions, let deletions = request.deletions {
                    HStack(spacing: 4) {
                        Text("+\(additions)").foregroundStyle(Theme.success)
                        Text("−\(deletions)").foregroundStyle(Theme.danger)
                    }
                    .font(WidgetFont.caption.monospacedDigit())
                    .accessibilityLabel(String(localized: "\(additions) lines added, \(deletions) removed"))
                }
            }
        }
    }

    /// Phone numbers and addresses are fields, never links: the app makes the buttons.
    private func reach(_ contact: EntityWidget.Contact) -> some View {
        HStack(spacing: 10) {
            if let phone = contact.phone, let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                reachButton(String(localized: "Call"), "phone.fill", url)
                if let message = URL(string: "sms:" + phone.filter { $0.isNumber || $0 == "+" }) {
                    reachButton(String(localized: "Message"), "message.fill", message)
                }
            }
            if let email = contact.email, let url = URL(string: "mailto:" + email) {
                reachButton(String(localized: "Mail"), "envelope.fill", url)
            }
            if let website = contact.website {
                Button { context.open(website) } label: {
                    Image(systemName: "safari").font(.system(size: 15)).frame(width: 44, height: 44).background(Theme.controlFill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Website"))
            }
        }
    }

    @Environment(\.openURL) private var openURL

    private func reachButton(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Button { openURL(url) } label: {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.primaryText)
                .frame(width: 44, height: 44).background(Theme.controlFill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// A picture from a payload. One from the internet waits for a tap that names its domain, so
/// the person's address reaches a third party only when they choose (contract §9).
struct WidgetImage: View {
    let media: WidgetMedia
    var maxHeight: CGFloat = 220

    @Environment(\.gatewayHosts) private var gatewayHosts
    @State private var fetches = false

    var body: some View {
        Group {
            if let url = URL(string: media.src), url.scheme?.lowercased() == "https",
               fetches || WebLink.isOnGateway(url, gatewayHosts: gatewayHosts) {
                AsyncImage(url: url, transaction: Transaction(animation: .smooth(duration: 0.3))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: placeholder(String(localized: "Couldn't load this image"))
                    default: Theme.controlFill
                    }
                }
            } else if let url = URL(string: media.src), url.scheme?.lowercased() == "https" {
                Button { fetches = true } label: {
                    placeholder(String(localized: "Tap to load from \(url.host(percentEncoded: true) ?? "")"))
                }
                .buttonStyle(.plain)
            } else {
                placeholder(nil)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(media.alt)
        .accessibilityAddTraits(.isImage)
    }

    private var height: CGFloat {
        guard let width = media.width, let height = media.height, width > 0 else { return min(maxHeight, 180) }
        let ratio = min(max(Double(height) / Double(width), 0.5), 4.0 / 3.0)
        return min(maxHeight, 330 * ratio)
    }

    private func placeholder(_ note: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: media.kind == .video ? "video" : "photo").font(.system(size: 20)).foregroundStyle(Theme.tertiaryText)
            Text(media.alt).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center).lineLimit(3)
            if let note { Text(widgetLinking: note).font(WidgetFont.caption.weight(.semibold)).foregroundStyle(Theme.primaryText) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.controlFill)
    }
}

/// A map drawn on this device from coordinates (`MKMapSnapshotter`): no image from the payload.
struct WidgetMapSnapshot: View {
    let points: [CLLocationCoordinate2D]
    var label: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: PlatformImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.controlFill
                if let image {
                    Image(platformImage: image).resizable().scaledToFill()
                }
            }
            .task(id: "\(Int(proxy.size.width))-\(colorScheme == .dark)") {
                image = await snapshot(size: proxy.size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.map { String(localized: "Map of \($0)") } ?? String(localized: "Map"))
    }

    private func snapshot(size: CGSize) async -> PlatformImage? {
        guard !points.isEmpty, size.width > 0 else { return nil }
        let options = MKMapSnapshotter.Options()
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((lats.max()! - lats.min()!) * 1.4, 0.006), longitudeDelta: max((lons.max()! - lons.min()!) * 1.4, 0.006))
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = size
        #if os(iOS)
        options.traitCollection = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        #else
        options.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        #endif
        guard let shot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        return Self.draw(shot, points: points, size: size)
    }

    private static func draw(_ shot: MKMapSnapshotter.Snapshot, points: [CLLocationCoordinate2D], size: CGSize) -> PlatformImage {
        let mapped = points.map { shot.point(for: $0) }
        #if os(iOS)
        return UIGraphicsImageRenderer(size: size).image { context in
            shot.image.draw(at: .zero)
            stroke(mapped, in: context.cgContext)
        }
        #else
        guard let base = shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return shot.image }
        let scale = CGFloat(base.width) / size.width
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        // The snapshot's points run from the top left; the bitmap's from the bottom left.
        context.translateBy(x: 0, y: CGFloat(base.height))
        context.scaleBy(x: scale, y: -scale)
        stroke(mapped, in: context)
        guard let drawn = context.makeImage() else { return shot.image }
        return NSImage(cgImage: drawn, size: size)
        #endif
    }

    private static func stroke(_ points: [CGPoint], in context: CGContext) {
        context.setStrokeColor(CGColor(gray: 0.08, alpha: 1))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        if points.count > 1 {
            context.setLineWidth(4)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addLines(between: points)
            context.strokePath()
        }
        for point in [points.first, points.count > 1 ? points.last : nil].compactMap({ $0 }) {
            context.fillEllipse(in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
        }
    }
}

// MARK: - media

/// Images, a video or a voice note (`Things.media`, `mediaGrid`, `mediaAudio`). Nothing plays by
/// itself.
struct MediaBody: View {
    let model: MediaWidget
    let context: WidgetContext

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var page = 0

    var body: some View {
        let audio = model.items.filter { $0.media.kind == .audio }
        if !audio.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(audio.enumerated()), id: \.offset) { _, item in AudioRow(item: item, context: context) }
            }
        } else if model.items.count == 1 || model.layout == .single {
            single(model.items[0])
        } else if model.layout == .carousel {
            carousel
        } else {
            grid
        }
    }

    private func single(_ item: MediaWidget.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                WidgetImage(media: item.media.kind == .video ? posterMedia(item.media) : item.media)
                if item.media.kind == .video {
                    Label(item.media.duration.map { WidgetFormatter().duration($0) } ?? "—:—", systemImage: "play.fill")
                        .font(WidgetFont.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(8)
                }
            }
            caption(item)
        }
    }

    private func posterMedia(_ media: WidgetMedia) -> WidgetMedia {
        guard let thumb = media.thumb else { return media }
        var poster = media
        poster.src = thumb
        return poster
    }

    private var grid: some View {
        let columns = typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
        let shown = Array(model.items.prefix(4))
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                ZStack {
                    WidgetImage(media: item.media, maxHeight: 140)
                    if index == 3, model.items.count > 4 {
                        Text("+\(model.items.count - 4)")
                            .font(WidgetFont.value)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous))
                            .accessibilityLabel(String(localized: "\(model.items.count - 4) more photos"))
                    }
                }
                .frame(height: 140)
            }
        }
    }

    private var carousel: some View {
        VStack(alignment: .leading, spacing: 6) {
            TabView(selection: $page) {
                ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                    WidgetImage(media: item.media).tag(index)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .always))
            #endif
            .frame(height: 220)
            if let item = model.items[safe: page] { caption(item) }
        }
    }

    @ViewBuilder
    private func caption(_ item: MediaWidget.Item) -> some View {
        let parts = [item.caption, item.credit].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
        }
    }
}

/// A voice note: play, a waveform that fills as it plays, the duration; the transcript under it.
/// It plays from the web only after a tap, like a picture.
private struct AudioRow: View {
    let item: MediaWidget.Item
    let context: WidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    context.open(item.media.src)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.inkForeground)
                        .frame(width: 36, height: 36)
                        .background(Theme.ink, in: Circle())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Play"))
                Waveform(levels: item.waveform ?? Array(repeating: 0.3, count: 32))
                    .frame(height: 26)
                Text(item.media.duration.map { WidgetFormatter().duration($0) } ?? "—:—")
                    .font(WidgetFont.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            if let transcript = item.transcript {
                Text(transcript).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel([item.media.alt, item.media.duration.map { WidgetFormatter().duration($0) }].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct Waveform: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.prefix(48).enumerated()), id: \.offset) { _, level in
                Capsule().fill(Theme.secondaryText).frame(width: 2.5, height: max(3, 26 * min(max(level, 0), 1)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

// MARK: - code

/// Code, a log or command output in monospace, with copy, folding and a result
/// (`Things.code`, `codeLog`, `codeLogFiltered`).
struct CodeBody: View {
    let model: CodeWidget
    let context: WidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.kind == .log { log } else { block }
            if let result = model.result { resultLine(result) }
        }
    }

    // A snippet shows its first 12 lines, output its last 12.
    private var block: some View {
        let text = model.text ?? ""
        let all = text.components(separatedBy: "\n")
        let folded = all.count > 12 && !context.view.showsAll
        let shown = folded ? (model.kind == .output ? Array(all.suffix(12)) : Array(all.prefix(12))) : all
        let first = (model.range?.start ?? 1) + (folded && model.kind == .output ? all.count - 12 : 0)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.kind == .output ? String(localized: "Output") : (CodeHighlighter.displayName(for: model.language) ?? String(localized: "Code")))
                    .font(WidgetFont.caption.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                if let path = model.path {
                    Button(path.split(separator: "/").last.map(String.init) ?? path) { context.open("hermes-file:" + path) }
                        .font(WidgetFont.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.link)
                        .lineLimit(1)
                }
                Spacer()
                Button { context.copy(text) } label: {
                    Image(systemName: "square.on.square").font(.system(size: 11)).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityLabel(String(localized: "Copy"))
            }
            if let command = model.command {
                Text(code: "$ \(command)").font(WidgetFont.mono).foregroundStyle(Theme.secondaryText)
            }
            if model.kind == .snippet {
                // A snippet keeps its lines and scrolls sideways inside the well, never widening it.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .trailing, spacing: 0) {
                            ForEach(0..<shown.count, id: \.self) { index in
                                Text("\(first + index)").font(WidgetFont.mono).foregroundStyle(Theme.tertiaryText)
                            }
                        }
                        .accessibilityHidden(true)
                        Text(CodeBlockView.highlight(shown.joined(separator: "\n"), language: model.language))
                            .font(WidgetFont.mono)
                            .foregroundStyle(Theme.primaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
            } else {
                // Output wraps its long lines (`Things.code`).
                Text(code: shown.joined(separator: "\n"))
                    .font(WidgetFont.mono)
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, .leftToRight)
            }
            if all.count > 12 {
                ShowAllButton(total: all.count, isExpanded: context.view.showsAll) {
                    withAnimation(.spring(response: 0.3)) { context.updateView { $0.showsAll.toggle() } }
                }
            }
        }
        .widgetWell(padding: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(CodeHighlighter.displayName(for: model.language) ?? String(localized: "Code")), \(all.count) lines"))
    }

    // A log opens at its tail; level chips filter it on the device.
    private var log: some View {
        let lines = model.lines ?? []
        let hidden = context.view.hiddenLevels
        let filtered = lines.filter { !hidden.contains($0.level?.rawValue ?? "") }
        let tail = context.density == .compact ? 5 : 12
        let shown = context.view.showsAll ? filtered : Array(filtered.suffix(tail))
        return VStack(alignment: .leading, spacing: 8) {
            if model.filter { levelChips(lines) }
            if let omitted = model.omitted, omitted > 0 {
                Text("\(omitted) earlier lines not sent").font(WidgetFont.caption).foregroundStyle(Theme.tertiaryText)
            }
            if filtered.count > tail {
                ShowAllButton(total: filtered.count, isExpanded: context.view.showsAll) {
                    withAnimation(.spring(response: 0.3)) { context.updateView { $0.showsAll.toggle() } }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    logLine(line)
                }
            }
            .widgetWell(padding: 10)
        }
    }

    private func levelChips(_ lines: [CodeWidget.Line]) -> some View {
        let errors = model.counts?.error ?? lines.filter { $0.level == .error || $0.level == .critical }.count
        let warnings = model.counts?.warning ?? lines.filter { $0.level == .warning }.count
        let hidden = context.view.hiddenLevels
        let onlyErrors = hidden == ["trace", "debug", "info", "notice", "warning"]
        let onlyWarnings = hidden == ["trace", "debug", "info", "notice", "error", "critical"]
        return HStack(spacing: 6) {
            chip(String(localized: "All"), selected: hidden.isEmpty) { [] }
            if errors > 0 { chip(String(localized: "Errors \(errors)"), selected: onlyErrors) { ["trace", "debug", "info", "notice", "warning"] } }
            if warnings > 0 { chip(String(localized: "Warnings \(warnings)"), selected: onlyWarnings) { ["trace", "debug", "info", "notice", "error", "critical"] } }
        }
    }

    private func chip(_ title: String, selected: Bool, hides: @escaping () -> Set<String>) -> some View {
        Button {
            context.updateView { $0.hiddenLevels = hides() }
        } label: {
            Text(title)
                .font(WidgetFont.caption.weight(.semibold))
                .foregroundStyle(selected ? Theme.inkForeground : Theme.primaryText)
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .background(selected ? Theme.ink : Theme.controlFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func logLine(_ line: CodeWidget.Line) -> some View {
        let (word, color) = levelLook(line.level)
        let time = line.at.flatMap { WidgetFormatter.parse($0) }.map { date, zone in
            date.formatted(Date.FormatStyle(timeZone: zone).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let time { Text(time).foregroundStyle(Theme.tertiaryText) }
            if let word { Text(word).fontWeight(line.level == .error || line.level == .critical ? .bold : .regular).foregroundStyle(color) }
            Text(widgetLinking: line.text + (line.repeat.map { $0 > 1 ? " ×\($0)" : "" } ?? ""))
                .foregroundStyle(line.level == .error || line.level == .critical ? Theme.danger : Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(WidgetFont.mono)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([time, word?.lowercased(), line.text, line.repeat.flatMap { $0 > 1 ? String(localized: "repeated \($0) times") : nil }].compactMap { $0 }.joined(separator: ", "))
    }

    private func levelLook(_ level: CodeWidget.Line.Level?) -> (String?, Color) {
        switch level {
        case .critical?: ("CRIT", Theme.danger)
        case .error?: ("ERROR", Theme.danger)
        case .warning?: ("WARN", Theme.warning)
        case .notice?, .info?: ("INFO", Theme.secondaryText)
        case .debug?, .trace?: ("DEBUG", Theme.tertiaryText)
        case nil: (nil, Theme.secondaryText)
        }
    }

    private func resultLine(_ result: CodeWidget.Outcome) -> some View {
        let tone: WidgetTone = switch result.state {
        case .ok: .ok
        case .warning: .warning
        case .critical: .critical
        }
        // One line: the state glyph in its colour, the words (grey when it went fine), then a short
        // output beside them; a long one wraps under (`Things.code`).
        let words = Text(result.label ?? tone.word)
            .font(WidgetFont.label.weight(.medium))
            .foregroundStyle(tone == .ok ? Theme.secondaryText : tone.color)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: tone.symbol).font(WidgetFont.label).foregroundStyle(tone.color)
            if let output = result.output {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        words
                        Text(code: output).font(WidgetFont.mono).foregroundStyle(Theme.primaryText).lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        words
                        Text(code: output).font(WidgetFont.mono).foregroundStyle(Theme.primaryText).textSelection(.enabled)
                    }
                }
            } else {
                words
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - sources

/// The references behind an answer, numbered to match [1] markers, each with how far to trust
/// it; one with an excerpt is a quote (`Things.sources`, `sourcesQuote`).
struct SourcesBody: View {
    let model: SourcesWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter

    var body: some View {
        if model.items.isEmpty {
            WidgetEmpty(context: context, fallback: String(localized: "No sources for this answer."))
        } else if model.layout == .quote || (model.layout == .auto && model.items.count == 1 && model.items[0].excerpt != nil) {
            quote(model.items[0])
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    row(item, number: index + 1)
                }
            }
        }
    }

    private func row(_ item: SourcesWidget.Item, number: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .frame(width: 20, height: 20)
                .background(Theme.canvas, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(WidgetFont.body).foregroundStyle(Theme.primaryText).lineLimit(2)
                Text(meta(item)).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                TrustTag(trust: item.trust)
                if let usedFor = item.usedFor {
                    Text(usedFor).font(WidgetFont.caption).foregroundStyle(Theme.tertiaryText)
                }
                if let actions = item.actions, !actions.isEmpty {
                    RowActions(actions: actions, item: (item.id ?? "\(number)", item.title), context: context)
                }
            }
            // The whole width, not a share of it with a spacer: titles wrap at the card's edge.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if let url = item.url { context.open(url) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number), \(item.title), \(meta(item)), \(TrustTag.word(item.trust))")
        .accessibilityAddTraits(item.url != nil ? .isButton : [])
    }

    private func meta(_ item: SourcesWidget.Item) -> String {
        if let note = item.note { return note }
        let host = item.url.flatMap { URL(string: $0)?.host(percentEncoded: true) }
        return [item.site ?? host, item.published.flatMap { formatter.date($0) }].compactMap { $0 }.joined(separator: " · ")
    }

    private func quote(_ item: SourcesWidget.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule().fill(Theme.ink).frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                Text("“\(item.excerpt ?? item.title)”").font(WidgetFont.body).foregroundStyle(Theme.primaryText).fixedSize(horizontal: false, vertical: true)
                Text([item.title, item.locator, meta(item)].compactMap { $0 }.joined(separator: " · "))
                    .font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                TrustTag(trust: item.trust)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { if let url = item.url { context.open(url) } }
        .accessibilityElement(children: .combine)
    }
}

private struct TrustTag: View {
    let trust: SourcesWidget.Item.Trust

    var body: some View {
        WidgetTagView(tag: WidgetTag(label: Self.word(trust), state: state))
    }

    private var state: WidgetTag.State {
        switch trust {
        case .primary: .ok
        case .secondary: .neutral
        case .unverified: .unverified
        case .retracted: .critical
        }
    }

    static func word(_ trust: SourcesWidget.Item.Trust) -> String {
        switch trust {
        case .primary: String(localized: "Primary source")
        case .secondary: String(localized: "Secondary")
        case .unverified: String(localized: "Unverified")
        case .retracted: String(localized: "Retracted")
        }
    }
}

// MARK: - weather

/// The weather for one place: now, the hours, the days on a shared scale, and one tip
/// (`Things.weather`, `weatherDays`, `weatherCompact`). Hours and days are in the place's time.
struct WeatherBody: View {
    let model: WeatherWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if model.layout == .compact {
            compact
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // The first, most severe alert leads as the banner; more say how many (`Things.weatherAlert`).
                if let alert = model.alerts?.first {
                    let more = (model.alerts?.count ?? 1) - 1
                    WidgetBanner(tone: alert.severity == .critical ? .critical : alert.severity == .warning ? .warning : .info,
                                 symbol: alert.severity == .info ? "info.circle.fill" : "exclamationmark.triangle.fill",
                                 text: [alert.title, alert.issuer, alert.until.flatMap { formatter.dateTime($0) }.map { String(localized: "until \($0)") },
                                        more > 0 ? String(localized: "+\(more) more") : nil].compactMap { $0 }.joined(separator: " · "))
                }
                if let now = model.now { nowView(now) }
                if let hours = model.hours, !hours.isEmpty { hoursView(hours) }
                if let days = model.days, !days.isEmpty { daysView(days) }
                if let tip = model.tip {
                    Label(tip.text, systemImage: WidgetSymbols.resolve(tip.symbol) ?? "lightbulb")
                        .font(WidgetFont.label)
                        .foregroundStyle(Theme.primaryText)
                }
            }
        }
    }

    private func degrees(_ value: Double?) -> String {
        value.flatMap { Int(checking: $0.rounded()) }.map { "\($0)°" } ?? WidgetFormatter.unknown
    }

    private var compact: some View {
        HStack(spacing: 10) {
            WeatherGlyph(condition: model.now?.condition?.rawValue ?? model.days?.first?.condition?.rawValue, night: model.now?.night == true, size: 22)
            Text(degrees(model.now?.temp ?? model.days?.first?.high)).font(WidgetFont.value.monospacedDigit())
            // The first alert takes the tip's place, with its state glyph (`weather.md`, layout compact).
            if let alert = model.alerts?.first {
                let tone: WidgetTone = alert.severity == .critical ? .critical : alert.severity == .warning ? .warning : .info
                Label(alert.title, systemImage: alert.severity == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .font(WidgetFont.label)
                    .foregroundStyle(tone.color)
                    .lineLimit(2)
            } else if let text = model.tip?.text ?? model.now?.label {
                Text(widgetLinking: text).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func nowView(_ now: WeatherWidget.Now) -> some View {
        HStack(alignment: .center, spacing: 12) {
            WeatherGlyph(condition: now.condition?.rawValue, night: now.night == true, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(degrees(now.temp)).font(WidgetFont.valueHero.monospacedDigit())
                Text([now.label ?? now.condition.map { WeatherGlyph.word($0.rawValue) }, now.feels.map { String(localized: "feels \(degrees($0))") }].compactMap { $0 }.joined(separator: " · "))
                    .font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let high = now.high { Text("H \(degrees(high))").font(WidgetFont.label.weight(.semibold)) }
                if let low = now.low { Text("L \(degrees(low))").font(WidgetFont.label).foregroundStyle(Theme.secondaryText) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([degrees(now.temp), now.label ?? now.condition.map { WeatherGlyph.word($0.rawValue) },
                             now.feels.map { String(localized: "feels like \(degrees($0))") },
                             now.high.map { String(localized: "High \(degrees($0))") }, now.low.map { String(localized: "low \(degrees($0))") }]
            .compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder
    private func hoursView(_ hours: [WeatherWidget.Hour]) -> some View {
        let shown = Array(hours.prefix(12))
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, hour in
                    Text(hourSentence(hour, first: index == 0)).font(WidgetFont.label)
                }
            }
        } else if shown.count <= 6 {
            // A few hours spread across the well (`Things.weather`); more scroll sideways.
            HStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, hour in
                    hourColumn(hour, first: index == 0).frame(maxWidth: .infinity)
                }
            }
            .widgetWell(padding: 10)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, hour in
                        hourColumn(hour, first: index == 0)
                    }
                }
                .padding(.horizontal, 2)
            }
            .widgetWell(padding: 10)
        }
    }

    private func hourColumn(_ hour: WeatherWidget.Hour, first: Bool) -> some View {
        VStack(spacing: 4) {
            Text(first ? String(localized: "Now") : hourLabel(hour)).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            WeatherGlyph(condition: hour.condition?.rawValue, night: hour.night == true, size: 15)
            Text(degrees(hour.temp)).font(WidgetFont.label.weight(.semibold).monospacedDigit())
            Text(hour.precipChance.flatMap { $0 >= 0.3 ? formatter.percent($0, precision: 0) : nil } ?? " ")
                .font(WidgetFont.caption.weight(.semibold))
                .foregroundStyle(Theme.info)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hourSentence(hour, first: first))
    }

    private func hourLabel(_ hour: WeatherWidget.Hour) -> String {
        WidgetFormatter.parse(hour.at).map { date, zone in date.formatted(Date.FormatStyle(timeZone: zone).hour(.defaultDigits(amPM: .abbreviated))) } ?? hour.at
    }

    private func hourSentence(_ hour: WeatherWidget.Hour, first: Bool) -> String {
        [first ? String(localized: "Now") : (formatter.time(hour.at) ?? hour.at), degrees(hour.temp), hour.condition.map { WeatherGlyph.word($0.rawValue) },
         hour.precipChance.map { String(localized: "\(formatter.percent($0, precision: 0)) chance of rain") }].compactMap { $0 }.joined(separator: ", ")
    }

    private func daysView(_ days: [WeatherWidget.Day]) -> some View {
        let lows = days.compactMap(\.low), highs = days.compactMap(\.high)
        let low = lows.min() ?? 0, high = max(highs.max() ?? 1, low + 1)
        // A row per day between hairlines, the chance of rain under its glyph (`Things.weatherDays`).
        return VStack(spacing: 0) {
            ForEach(Array(days.prefix(10).enumerated()), id: \.offset) { index, day in
                if index > 0 { Divider().overlay(Theme.hairline) }
                HStack(spacing: 10) {
                    Text(dayName(day.date, first: index == 0)).font(WidgetFont.body).frame(width: 52, alignment: .leading)
                    VStack(spacing: 1) {
                        WeatherGlyph(condition: day.condition?.rawValue, night: false, size: 14)
                        if let chance = day.precipChance, chance >= 0.3 {
                            Text(formatter.percent(chance, precision: 0))
                                .font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.info)
                                .fixedSize()
                        }
                    }
                    .frame(width: 34)
                    Text(degrees(day.low)).font(WidgetFont.body.monospacedDigit()).foregroundStyle(Theme.secondaryText).frame(width: 34, alignment: .trailing)
                    if !typeSize.isAccessibilitySize {
                        GeometryReader { proxy in
                            let start = ((day.low ?? low) - low) / (high - low), end = ((day.high ?? high) - low) / (high - low)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.controlFill)
                                Capsule().fill(Theme.ink)
                                    .frame(width: max(6, proxy.size.width * (end - start)))
                                    .offset(x: proxy.size.width * start)
                            }
                        }
                        .frame(height: 5)
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityHidden(true)
                    }
                    Text(degrees(day.high)).font(WidgetFont.body.weight(.semibold).monospacedDigit()).frame(width: 34, alignment: .trailing)
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([dayName(day.date, first: index == 0), day.condition.map { WeatherGlyph.word($0.rawValue) },
                                     day.precipChance.map { String(localized: "\(formatter.percent($0, precision: 0)) chance of rain") },
                                     String(localized: "low \(degrees(day.low))"), String(localized: "high \(degrees(day.high))")].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }

    private func dayName(_ raw: String, first: Bool) -> String {
        if first { return String(localized: "Today") }
        guard let components = JSONSchemaValidator.parseDate(raw) else { return raw }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components).map { $0.formatted(Date.FormatStyle(locale: formatter.locale, timeZone: calendar.timeZone).weekday(.abbreviated)) } ?? raw
    }
}

/// A condition as a monochrome glyph (never multicolour) and a word.
private struct WeatherGlyph: View {
    let condition: String?
    let night: Bool
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: Self.symbol(condition, night: night))
            .font(.system(size: size))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Theme.primaryText)
            .accessibilityHidden(true)
    }

    static func symbol(_ condition: String?, night: Bool) -> String {
        switch condition ?? "" {
        case "clear": night ? "moon.stars.fill" : "sun.max.fill"
        case "mostly-clear", "partly-cloudy": night ? "cloud.moon.fill" : "cloud.sun.fill"
        case "mostly-cloudy", "cloudy": "cloud.fill"
        case "fog", "haze", "smoke", "dust": "cloud.fog.fill"
        case "windy": "wind"
        case "drizzle": "cloud.drizzle.fill"
        case "rain", "heavy-rain": "cloud.rain.fill"
        case "showers": "cloud.sun.rain.fill"
        case "thunderstorm", "thunderstorms": "cloud.bolt.rain.fill"
        case "snow", "flurries", "heavy-snow", "blizzard": "cloud.snow.fill"
        case "sleet", "freezing-rain", "hail", "wintry-mix": "cloud.sleet.fill"
        case "hot": "thermometer.sun.fill"
        default: "cloud.fill"
        }
    }

    static func word(_ condition: String) -> String {
        condition.replacingOccurrences(of: "-", with: " ").capitalized(with: .current)
    }
}

// MARK: - route

/// How to get from A to B: the total time, the legs as a bar and as steps, live delays
/// (`Things.route`, `routeMap`, `routeDelayed`).
struct RouteBody: View {
    let model: RouteWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if model.mode == .flight, let flight = model.flight {
            FlightBody(flight: flight, context: context)
        } else {
            journey
        }
    }

    private var journey: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            if let path = model.map?.path, path.count > 1 {
                WidgetMapSnapshot(points: path.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil },
                                  label: "\(model.from.name) – \(model.to.name)")
                    .frame(height: 140)
            } else if let legs = model.legs, !legs.isEmpty {
                legBar(legs)
            }
            ForEach(Array((model.alerts ?? []).enumerated()), id: \.offset) { _, alert in
                Label(alert.text, systemImage: alert.state == .critical ? "xmark.octagon.fill" : alert.state == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(WidgetFont.label)
                    .foregroundStyle(alert.state == .critical ? Theme.danger : alert.state == .warning ? Theme.warning : Theme.info)
            }
            if let legs = model.legs, !legs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in step(leg) }
                }
            }
        }
    }

    private var summary: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        let times = [model.from.time.flatMap { formatter.time($0) }, model.to.time.flatMap { formatter.time($0) }].compactMap { $0 }
        return layout {
            Text(formatter.duration(model.duration)).font(WidgetFont.value.monospacedDigit())
            if model.mode == .drive || times.count < 2 {
                Text([String(localized: "by car"), model.distance.map { distance($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
            } else {
                Text(times.joined(separator: " → ")).font(WidgetFont.label.monospacedDigit()).foregroundStyle(Theme.secondaryText)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 6) }
            if let status = model.status {
                WidgetBadge(tone: status.state == .ok ? .ok : status.state == .warning ? .warning : status.state == .critical ? .critical : .unverified, word: status.label)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road).locale(formatter.locale))
    }

    private func legBar(_ legs: [RouteWidget.Leg]) -> some View {
        let total = max(legs.map(\.duration).reduce(0, +), 1)
        return GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
                    let transit = !["walk", "bike", "drive", "wait"].contains(leg.mode.rawValue)
                    // The mode's glyph, then the line or the minutes (`Things.route`).
                    HStack(spacing: 3) {
                        Image(systemName: Self.symbol(leg.mode.rawValue)).font(.system(size: 9, weight: .semibold))
                        Text(transit ? (leg.line ?? leg.label) : Int(checking: leg.duration / 60).map { "\($0)′" } ?? WidgetFormatter.unknown)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                        .foregroundStyle(transit ? Theme.inkForeground : Theme.secondaryText)
                        .padding(.horizontal, 4)
                        .frame(width: max(30, (proxy.size.width - CGFloat(legs.count - 1) * 3) * CGFloat(leg.duration / total)), height: 22)
                        .background((leg.delay ?? 0) > 0 ? Theme.warning : (transit ? Theme.ink : Theme.controlFill), in: Capsule())
                }
            }
        }
        .frame(height: 22)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(legs.map { "\($0.label) \(formatter.duration($0.duration))" }.joined(separator: ", "))
    }

    private func step(_ leg: RouteWidget.Leg) -> some View {
        var parts: [String] = []
        if let depart = leg.depart.flatMap({ formatter.time($0) }) { parts.append(String(localized: "Leaves \(depart)")) }
        if let meters = leg.distance { parts.append(distance(meters)) }
        parts.append(formatter.duration(leg.duration))
        if let stops = leg.stops { parts.append(String(localized: "\(stops) stops")) }
        if let every = leg.every { parts.append(String(localized: "every \(formatter.duration(every))")) }
        if let platform = leg.platform { parts.append(String(localized: "platform \(platform)")) }
        if leg.live == false { parts.append(String(localized: "scheduled")) }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(leg.mode.rawValue)).font(.system(size: 13)).frame(width: 22).foregroundStyle(Theme.primaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(leg.label).font(WidgetFont.body)
                Text(parts.joined(separator: " · ")).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                if let delay = leg.delay, delay > 0 {
                    Text("+\(formatter.duration(delay)) · delayed").font(WidgetFont.caption.weight(.semibold)).foregroundStyle(Theme.warning)
                }
                if let note = leg.note { Text(widgetLinking: note).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ mode: String) -> String {
        switch mode {
        case "walk": "figure.walk"
        case "bike": "bicycle"
        case "drive", "taxi": "car.fill"
        case "bus": "bus.fill"
        case "tram": "tram.fill"
        case "train": "train.side.front.car"
        case "subway": "tram.tunnel.fill"
        case "ferry": "ferry.fill"
        case "coach": "bus.doubledecker.fill"
        case "wait": "clock"
        default: "location.fill"
        }
    }
}

// MARK: - price history

/// A watched price over time (`Things.entityProduct`): a step line, since a price holds until it
/// changes, oldest on the left. Points are daily or per check, so the ends read "Earlier" and "Today".
struct PriceHistory: View {
    let points: [Double]

    var body: some View {
        VStack(spacing: 4) {
            Chart {
                // The last price repeats one step on, so today's price has its own run after the drop.
                ForEach(Array((points + points.suffix(1)).enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("Day", index), y: .value("Price", value))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: WidgetRange.padded(points))
            .frame(height: 44)
            .environment(\.layoutDirection, .leftToRight)
            HStack {
                Text("Earlier").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("Today").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Price history, from \(WidgetFormatter.number(points.first ?? 0)) to \(WidgetFormatter.number(points.last ?? 0))"))
    }
}

// MARK: - flight

/// A flight's state words and colours (`route.md`, `flight.state`): delayed is orange, cancelled
/// and diverted red; the rest read as on their way.
enum WidgetFlight {
    static func badge(_ state: RouteWidget.Flight.State) -> (WidgetTone, String?) {
        switch state {
        case .scheduled: (.info, String(localized: "Scheduled"))
        case .boarding: (.info, String(localized: "Boarding"))
        case .departed: (.ok, String(localized: "Departed"))
        case .inAir: (.ok, String(localized: "In the air"))
        case .landed: (.ok, String(localized: "Landed"))
        case .arrived: (.ok, String(localized: "Arrived"))
        case .delayed: (.warning, String(localized: "Delayed"))
        case .cancelled: (.critical, String(localized: "Cancelled"))
        case .diverted: (.critical, String(localized: "Diverted"))
        }
    }
}

/// A flight's status (`Things.routeFlight`): the two airports with their times and how late or
/// early, the plane along the line while it's in the air, how long is left, then gate,
/// terminal, baggage belt and aircraft.
struct FlightBody: View {
    let flight: RouteWidget.Flight
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                end(flight.depart.airport, city: flight.depart.city, scheduled: flight.depart.scheduled,
                    estimated: flight.depart.estimated, actual: flight.depart.actual, departing: true, alignment: .leading)
                Spacer(minLength: 12)
                end(flight.arrive.airport, city: flight.arrive.city, scheduled: flight.arrive.scheduled,
                    estimated: flight.arrive.estimated, actual: flight.arrive.actual, departing: false, alignment: .trailing)
            }
            if flight.state != .cancelled { track }
            if let line = statusLine {
                Text(line)
                    .font(WidgetFont.label)
                    .foregroundStyle(tone == .ok || tone == .info ? Theme.secondaryText : tone.color)
            }
            ForEach(Array((flight.changes ?? []).prefix(3).enumerated()), id: \.offset) { _, change in
                Label { Text(widgetLinking: change) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .font(WidgetFont.label)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !facts.isEmpty {
                Divider().overlay(Theme.hairline)
                let columns = typeSize.isAccessibilitySize ? 2 : min(facts.count, 4)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: facts.count, by: columns)), id: \.self) { start in
                        GridRow {
                            ForEach(Array(facts[start..<min(start + columns, facts.count)].enumerated()), id: \.offset) { _, fact in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fact.label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                                    Text(fact.value).font(WidgetFont.valueSmall.monospacedDigit())
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(fact.label), \(fact.value)")
                            }
                        }
                    }
                }
            }
        }
    }

    private var tone: WidgetTone { WidgetFlight.badge(flight.state).0 }

    private func end(_ airport: String, city: String?, scheduled: String, estimated: String?, actual: String?,
                     departing: Bool, alignment: HorizontalAlignment) -> some View {
        let shown = actual ?? estimated ?? scheduled
        let late = lateness(scheduled: scheduled, shown: shown, done: actual != nil, departing: departing)
        return VStack(alignment: alignment, spacing: 2) {
            Text(airport).font(WidgetFont.valueHero)
            if let city { Text(city).font(WidgetFont.label).foregroundStyle(Theme.secondaryText) }
            Text(formatter.time(shown) ?? shown)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .strikethrough(flight.state == .cancelled)
            if let late {
                // A few minutes either way is just information; orange is for a flight that is delayed.
                Text(late.text).font(WidgetFont.caption)
                    .foregroundStyle(late.isLate && flight.state == .delayed ? Theme.warning : Theme.tertiaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "left 7 min late", "4 min early", "on time": the time shown against the timetable.
    private func lateness(scheduled: String, shown: String, done: Bool, departing: Bool) -> (text: String, isLate: Bool)? {
        guard shown != scheduled, let planned = WidgetClock.date(scheduled), let real = WidgetClock.date(shown) else { return nil }
        let minutes = Int((real.timeIntervalSince(planned) / 60).rounded())
        guard minutes != 0 else { return (String(localized: "on time"), false) }
        let amount = String(localized: "\(abs(minutes)) min")
        if minutes > 0 {
            return (departing && done ? String(localized: "left \(amount) late") : String(localized: "\(amount) late"), true)
        }
        return (departing && done ? String(localized: "left \(amount) early") : String(localized: "\(amount) early"), false)
    }

    /// The line between the airports, the flown part in ink and the plane where it is.
    private var track: some View {
        let progress = min(max(flight.progress ?? (flight.state == .landed || flight.state == .arrived ? 1 : 0), 0), 1)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.controlFill).frame(height: 2)
                Capsule().fill(Theme.ink).frame(width: max(0, proxy.size.width * progress), height: 3)
                Image(systemName: "airplane")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .offset(x: min(max(proxy.size.width * progress - 8, 0), proxy.size.width - 16))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 18)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(Int(progress * 100)) percent of the way"))
    }

    /// "In the air · 1 h 04 min to go", "Boarding · gate B12", "Cancelled".
    private var statusLine: String? {
        let word = WidgetFlight.badge(flight.state).1 ?? ""
        switch flight.state {
        case .inAir, .departed:
            guard let arrival = WidgetClock.date(flight.arrive.estimated ?? flight.arrive.scheduled) else { return word }
            let left = arrival.timeIntervalSince(context.now)
            guard left > 0 else { return word }
            return String(localized: "\(word) · \(TimelineDuration.text(left)) to go")
        case .boarding:
            return flight.depart.gate.map { String(localized: "\(word) · gate \($0)") } ?? word
        default:
            return nil
        }
    }

    private var facts: [(label: String, value: String)] {
        var facts: [(label: String, value: String)] = []
        if let gate = flight.depart.gate { facts.append((String(localized: "Gate"), gate)) }
        if let terminal = flight.arrive.terminal { facts.append((String(localized: "Arrives"), "T\(terminal)")) }
        if let belt = flight.arrive.baggage { facts.append((String(localized: "Baggage"), belt)) }
        if let aircraft = flight.aircraft { facts.append((String(localized: "Aircraft"), Self.shortAircraft(aircraft))) }
        return facts
    }

    /// "Airbus A220-300" reads "A220" in the fact row; the whole name is in the fallback text.
    static func shortAircraft(_ name: String) -> String {
        let model = name.split(separator: " ").first { $0.first?.isLetter == true && $0.contains(where: \.isNumber) } ?? Substring(name)
        return String(model.split(separator: "-").first ?? model)
    }
}

/// "1 h 04 min", "45 min": what's left of a journey.
enum TimelineDuration {
    static func text(_ seconds: TimeInterval) -> String {
        guard let minutes = Int(checking: (seconds / 60).rounded()) else { return WidgetFormatter.unknown }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return String(localized: "\(rest) min") }
        return String(localized: "\(hours) h \(String(format: "%02d", rest)) min")
    }
}

// MARK: - pass

/// A boarding pass, ticket, membership card or coupon: big fields and a code drawn on this
/// device (`Things.pass`, `passTicket`, `passGateChange`).
struct PassBody: View {
    let model: PassWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsCode = false

    private var isExpired: Bool { context.interaction == .expired }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            dashed
            fieldsRow
            if hasCodeArea {
                dashed
                codeArea
            } else if let note = model.note {
                Text(widgetLinking: note).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            }
            if let pkpass = model.pkpass, Self.canAddToWallet {
                Button { context.open(pkpass) } label: {
                    Label("Add to Wallet", systemImage: "wallet.pass.fill")
                }
                .buttonStyle(WidgetActionButtonStyle(role: .primary))
            }
        }
    }

    private var hasCodeArea: Bool { model.code != nil || model.holder != nil || model.reference != nil }

    /// The client's own line after the producer's note, where opening the code turns the screen up
    /// (`pass.md`, Brightness).
    private static var brightnessLine: String? {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? String(localized: "The screen brightens while it’s open.") : nil
        #else
        nil
        #endif
    }

    private static var canAddToWallet: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private var dashed: some View {
        Rectangle()
            .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var headline: some View {
        if let trip = model.trip {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.from.code ?? trip.from.name).font(WidgetFont.valueHero)
                    Text([trip.from.name, trip.from.time.flatMap { formatter.time($0) }].compactMap { $0 }.joined(separator: " · "))
                        .font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: trip.mode == .plane ? "airplane" : trip.mode == .train ? "tram.fill" : trip.mode == .bus ? "bus.fill" : "ferry.fill")
                    .font(.system(size: 16)).foregroundStyle(Theme.secondaryText).padding(.top, 10)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(trip.to.code ?? trip.to.name).font(WidgetFont.valueHero)
                    Text([trip.to.name, trip.to.time.flatMap { formatter.time($0) }].compactMap { $0 }.joined(separator: " · "))
                        .font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(trip.from.name) \(trip.from.time.flatMap { formatter.time($0) } ?? "") \(String(localized: "to")) \(trip.to.name) \(trip.to.time.flatMap { formatter.time($0) } ?? "")")
        } else if let event = model.event {
            HStack(spacing: 12) {
                if let starts = event.starts, let (date, zone) = WidgetFormatter.parse(starts) {
                    VStack(spacing: 0) {
                        Text(date.formatted(Date.FormatStyle(timeZone: zone).month(.abbreviated)).uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.danger)
                        Text(date.formatted(Date.FormatStyle(timeZone: zone).day())).font(WidgetFont.value)
                    }
                    .frame(width: 50, height: 50)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.name).font(WidgetFont.valueSmall)
                    Text([event.venue, event.doors.flatMap { formatter.time($0) }.map { String(localized: "doors \($0)") }].compactMap { $0 }.joined(separator: " · "))
                        .font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var fieldsRow: some View {
        let columns = typeSize.isAccessibilitySize ? 2 : min(max(model.fields.count, 1), 4)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), alignment: .leading, spacing: 10) {
            ForEach(Array(model.fields.enumerated()), id: \.offset) { _, field in
                let changed = field.state == .warning || field.state == .critical
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    if let previous = field.previous {
                        Text(previous).font(WidgetFont.caption).strikethrough().foregroundStyle(Theme.tertiaryText)
                    }
                    Text(field.value)
                        .font(WidgetFont.valueSmall.monospacedDigit())
                        .foregroundStyle(changed ? Theme.warning : Theme.primaryText)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(field.label) \(field.value)" + (field.previous.map { ", " + String(localized: "changed from \($0)") } ?? ""))
            }
        }
    }

    private var codeArea: some View {
        let square = model.code.map { $0.format == .qr || $0.format == .aztec } ?? true
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let code = model.code, square { codeTile(code, height: 96) }
                VStack(alignment: .leading, spacing: 4) {
                    if let holder = model.holder { Text(holder.uppercased()).font(WidgetFont.label.weight(.semibold)) }
                    if let reference = model.reference {
                        Text([reference.label, reference.value].compactMap { $0 }.joined(separator: " "))
                            .font(WidgetFont.mono).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
                    }
                    if let admits = model.admits, admits > 1 {
                        Text("Admits \(admits)").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                    }
                    // The note sits beside the holder, under the reference (`Things.pass`).
                    let note = [model.note, model.code == nil ? nil : Self.brightnessLine].compactMap { $0 }.joined(separator: " ")
                    if !note.isEmpty {
                        Text(widgetLinking: note).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
            if let code = model.code, !square { codeTile(code, height: 70).frame(maxWidth: .infinity) }
        }
    }

    private func codeTile(_ code: PassWidget.Code, height: CGFloat) -> some View {
        Button { showsCode = true } label: {
            ZStack {
                if let image = PassCode.image(code) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Text(code.text ?? code.value).font(WidgetFont.mono)
                }
                if isExpired {
                    Text("Expired").font(WidgetFont.title).foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.85))
                }
            }
            .frame(height: height)
            .frame(minWidth: height)
            .background(.white, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isExpired)
        .accessibilityLabel(String(localized: "\(code.format.word), double-tap to show full screen"))
        #if os(iOS)
        .fullScreenCover(isPresented: $showsCode) { PassCodeScreen(code: code) }
        #else
        .sheet(isPresented: $showsCode) { PassCodeScreen(code: code).frame(width: 420, height: 420) }
        #endif
    }
}

private extension PassWidget.Code.Format {
    var word: String {
        switch self {
        case .qr: String(localized: "QR code")
        case .aztec: String(localized: "Aztec code")
        case .pdf417: String(localized: "PDF417 code")
        case .code128: String(localized: "Barcode")
        }
    }
}

/// The scannable code, drawn on this device by Core Image; its value is never read aloud.
enum PassCode {
    static func image(_ code: PassWidget.Code) -> CGImage? {
        let data = Data(code.value.utf8)
        let output: CIImage?
        switch code.format {
        case .qr:
            let filter = CIFilter.qrCodeGenerator()
            filter.message = data
            filter.correctionLevel = "M"
            output = filter.outputImage
        case .aztec:
            let filter = CIFilter.aztecCodeGenerator()
            filter.message = data
            output = filter.outputImage
        case .pdf417:
            let filter = CIFilter.pdf417BarcodeGenerator()
            filter.message = data
            output = filter.outputImage
        case .code128:
            let filter = CIFilter.code128BarcodeGenerator()
            filter.message = data
            filter.quietSpace = 4
            output = filter.outputImage
        }
        guard let output else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

/// The code full screen; on iPhone the screen goes to full brightness until it closes.
private struct PassCodeScreen: View {
    let code: PassWidget.Code

    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var brightness: CGFloat?
    #endif

    var body: some View {
        VStack(spacing: 20) {
            if let image = PassCode.image(code) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit().padding(24)
            }
            if let text = code.text { Text(text).font(.system(.body, design: .monospaced)).foregroundStyle(.black) }
            Button("Done") { dismiss() }.buttonStyle(.bordered).tint(.black)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
        #if os(iOS)
        .onAppear {
            if let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen {
                brightness = screen.brightness
                screen.brightness = 1
            }
        }
        .onDisappear {
            if let brightness, let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen { screen.brightness = brightness }
        }
        #endif
    }
}
