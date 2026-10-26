import HermesKit
import SwiftUI

/// A widget where a reply's directive is (`docs/widgets.md` §2, §9): the card once its payload is
/// known, a skeleton under the directive's `alt` until then, and "Couldn't load this widget" when
/// it can't be found on this device.
struct WidgetSlot: View {
    let directive: WidgetDirective

    @Environment(\.widgetHost) private var host

    var body: some View {
        if let host {
            switch host.store.result(directive.id) {
            case .ready(let payload)?:
                WidgetCard(payload: payload)
            case .fallback(let fallback)?:
                WidgetFallbackView(fallback: fallback)
            case nil:
                if host.store.missing.contains(directive.id) {
                    WidgetMissingCard(alt: directive.alt) {
                        host.store.retryMissing(directive.id, conversation: host.conversation)
                    }
                } else {
                    WidgetLoadingCard(title: directive.alt, kind: .rows)
                        .task(id: directive.id) { host.store.loadMissing(directive.id, conversation: host.conversation) }
                }
            }
        } else {
            WidgetLoadingCard(title: directive.alt, kind: .rows)
        }
    }
}

/// An inline ` ```widget ` block a delivery carried (§2). The store's copy wins once a newer
/// revision arrives as a tool result.
struct InlineWidgetSlot: View {
    let json: JSONValue

    @Environment(\.widgetHost) private var host
    @State private var initial: WidgetReader.Result

    init(json: JSONValue) {
        self.json = json
        _initial = State(initialValue: WidgetReader.read(json))
    }

    var body: some View {
        let id = json["id"]?.stringValue
        let current = id.flatMap { host?.store.result($0) }.flatMap { $0.rev >= initial.rev ? $0 : nil } ?? initial
        Group {
            switch current {
            case .ready(let payload): WidgetCard(payload: payload)
            case .fallback(let fallback): WidgetFallbackView(fallback: fallback)
            }
        }
        .task(id: id) { host?.store.ingest(json, fromText: true) }
    }
}

/// The shared card (`Parts.card`): header, banner, body, the resolution or status line, footer
/// and actions, with the widget menu.
struct WidgetCard: View {
    let payload: WidgetPayload

    @Environment(\.widgetHost) private var host
    @Environment(\.widgetDensity) private var density
    @Environment(\.openURL) private var openURL
    @Environment(\.references) private var references
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = Date.now
    @State private var pendingOpen: URL?
    @State private var copied = false
    @State private var showsSource = false
    @Environment(\.widgetPreview) private var preview

    /// The clock the card reads: the gallery's, else the one it keeps.
    private var now: Date { preview?.now ?? clock }

    var body: some View {
        let interaction = preview?.interaction ?? host?.interaction(for: payload, now: now)
            ?? WidgetInteraction.evaluate(payload, facts: WidgetChatFacts(), now: now)
        let view = host?.store.view(payload.id) ?? WidgetViewState()
        Group {
            if host?.store.hidden.contains(payload.id) == true {
                EmptyView()
            } else if case .choice(let choice) = payload.content, choice.style == .suggestions {
                // Follow-ups have no card (`Asking.choiceSuggestions`).
                SuggestionRows(payload: payload, model: choice)
            } else if let reason = foldReason(interaction), !view.unfolded {
                WidgetFoldedCard(payload: payload, reason: reason) {
                    host?.store.updateView(payload.id) { $0.unfolded = true }
                }
            } else {
                card(interaction: unfoldedInteraction(interaction, view: view))
            }
        }
        .task(id: nextDeadline(interaction)) {
            // Wakes once at the next moment the card changes by itself: expiry, staleness, the
            // 60 s answer timeout. No timer runs in between.
            guard let deadline = nextDeadline(interaction) else { return }
            let wait = deadline.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait + 0.05)) }
            guard !Task.isCancelled else { return }
            clock = .now
        }
    }

    private func card(interaction: WidgetInteraction) -> some View {
        Group {
            if case .stack(let stack) = payload.content {
                stackContainer(stack, interaction: interaction)
            } else {
                surfaceCard(interaction: interaction)
            }
        }
        // Both kinds of card: a stack's widgets open their links through it too.
        .confirmationDialog(openTitle, isPresented: Binding(get: { pendingOpen != nil }, set: { if !$0 { pendingOpen = nil } }), titleVisibility: .visible) {
            if let url = pendingOpen {
                Button("Open") { perform(url) }
            }
        } message: {
            if let url = pendingOpen { Text(url.absoluteString) }
        }
    }

    private func makeContext(_ interaction: WidgetInteraction) -> WidgetContext {
        WidgetContext(
            payload: payload, interaction: interaction, density: density, now: now, host: host,
            answer: { answer in host?.send(answer) },
            open: { open($0) },
            copy: { copy($0) }
        )
    }

    /// A stack has no card of its own: a header line, then its widgets (`Composition.stack`).
    private func stackContainer(_ stack: StackWidget, interaction: WidgetInteraction) -> some View {
        let context = makeContext(interaction)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if let bot = payload.envelope.producer?.bot {
                    WidgetBotFace(handle: bot, size: 26)
                } else {
                    WidgetGlyph(name: payload.envelope.icon, fallback: payload.type.defaultSymbol, size: 15)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(payload.title).font(WidgetFont.valueSmall).accessibilityAddTraits(.isHeader)
                    let subtitle = payload.envelope.subtitle
                    let schedule = stack.schedule.map(\.label).flatMap { label in subtitle?.contains(label) == true ? nil : label }
                    let line = [schedule, subtitle, String(localized: "\(stack.children.count) widgets")].compactMap { $0 }
                    Text(line.joined(separator: " · ")).font(WidgetFont.subtitle).foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 6)
                // A scheduled stack's schedule already says so (`Composition.stack` shows no tag then).
                if let tag = stack.tag, stack.schedule == nil { WidgetTagView(tag: WidgetTag(label: tag)) }
                if payload.isPrivate {
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                        .accessibilityLabel(String(localized: "Private"))
                }
            }
            .accessibilityElement(children: .combine)
            StackBody(model: stack, context: context)
            WidgetActionRow(context: context)
        }
        .frame(maxWidth: payload.isWide ? WidgetDensity.wideMaxWidth : WidgetDensity.maxWidth, alignment: .leading)
        .environment(\.widgetContext, context)
        .environment(\.openURL, linkAction)
        .contextMenu { menu(interaction) }
        .modifier(WidgetAuthAlert(id: payload.id))
        .modifier(PrivateWidgetCover(isPrivate: WidgetReader.Result.ready(payload).isPrivate, radius: density.radius))
    }

    private func surfaceCard(interaction: WidgetInteraction) -> some View {
        let context = WidgetContext(
            payload: payload, interaction: interaction, density: density, now: now, host: host,
            answer: { answer in host?.send(answer) },
            open: { open($0) },
            copy: { copy($0) }
        )
        return VStack(alignment: .leading, spacing: density.gap) {
            WidgetHeader(payload: payload, now: now, interaction: interaction)
            banners(interaction)
            WidgetBodyView(context: context)
            WidgetStatusLine(context: context)
            WidgetFooter(payload: payload, context: context)
            WidgetActionRow(context: context)
        }
        .padding(.top, density.padTop)
        .padding(.horizontal, density.pad)
        .padding(.bottom, density.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: density.radius, style: .continuous))
        .overlay(alignment: .top) {
            if copied {
                Text("Copied")
                    .font(WidgetFont.caption.weight(.semibold))
                    .foregroundStyle(Theme.inkForeground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.ink, in: Capsule())
                    .offset(y: -10)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: payload.isWide ? WidgetDensity.wideMaxWidth : WidgetDensity.maxWidth, alignment: .leading)
        .environment(\.widgetContext, context)
        .environment(\.openURL, linkAction)
        #if os(iOS)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: density.radius, style: .continuous))
        #endif
        .contextMenu { menu(interaction) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle(interaction))
        .sheet(isPresented: $showsSource) {
            WidgetSourceSheet(payload: payload)
        }
        .modifier(WidgetAuthAlert(id: payload.id))
        .modifier(PrivateWidgetCover(isPrivate: payload.isPrivate, radius: density.radius))
        #if os(macOS)
        .onCopyCommand { [NSItemProvider(object: copyText as NSString)] }
        #endif
    }

    /// An alert is a tinted card; everything else is `surface`.
    private var background: Color {
        if case .alert(let alert) = payload.content, alert.status != .resolved {
            switch alert.severity {
            case .critical: return Theme.dangerTint
            case .warning: return Theme.warningTint
            case .info: return Theme.infoTint
            }
        }
        return Theme.surface
    }

    @ViewBuilder
    private func banners(_ interaction: WidgetInteraction) -> some View {
        if case .expired = interaction, let expires = payload.envelope.expiresAt {
            WidgetBanner(tone: .pending, symbol: "hourglass", text: String(localized: "This request expired at \(WidgetFormatter().time(expires) ?? expires)."))
        } else if let staleAt = WidgetClock.staleAt(payload.envelope), now >= staleAt, let asOf = WidgetClock.date(payload.envelope.asOf) {
            WidgetBanner(tone: .stale, symbol: "clock.fill", text: staleText(asOf: asOf))
        }
        if let banner = payload.envelope.banner {
            WidgetBanner(tone: tone(banner.state), symbol: tone(banner.state).symbol, text: banner.text)
        }
    }

    private func staleText(asOf: Date) -> String {
        let formatter = WidgetFormatter(now: now)
        let time = formatter.time(payload.envelope.asOf) ?? ""
        let age = formatter.age(since: asOf)
        if payload.envelope.refresh?.mode == .agent {
            return String(localized: "Data from \(time), \(age). Refresh for the latest.")
        }
        return String(localized: "Data from \(time), \(age).")
    }

    private func tone(_ state: WidgetEnvelope.Banner.State) -> WidgetTone {
        switch state {
        case .info: .info
        case .warning: .warning
        case .unverified: .unverified
        }
    }

    // MARK: - Folding

    private func foldReason(_ interaction: WidgetInteraction) -> String? {
        switch interaction {
        case .superseded where payload.type != .approval:
            String(localized: "Updated · the newer one is below")
        case .notAnswered:
            String(localized: "Not answered · you replied in the chat")
        default:
            nil
        }
    }

    /// A question opened again can still be answered until it expires (Answer Anyway).
    private func unfoldedInteraction(_ interaction: WidgetInteraction, view: WidgetViewState) -> WidgetInteraction {
        if case .notAnswered = interaction, view.unfolded { return .open }
        return interaction
    }

    // MARK: - Time

    private func nextDeadline(_ interaction: WidgetInteraction) -> Date? {
        var dates: [Date] = []
        if let expires = WidgetClock.date(payload.envelope.expiresAt), expires > now { dates.append(expires) }
        if let stale = WidgetClock.staleAt(payload.envelope), stale > now { dates.append(stale) }
        if case .waiting(_, true, _) = interaction, let host, let answer = host.facts.answer(to: payload.id, rev: payload.rev),
           let since = host.store.enteredTurn[answer.mid] ?? answer.at {
            let timeout = since.addingTimeInterval(WidgetInteraction.answerTimeout)
            if timeout > now { dates.append(timeout) }
        }
        if case .resolved = interaction, let until = WidgetClock.date(payload.envelope.resolution?.undo?.until), until > now { dates.append(until) }
        return dates.min()
    }

    // MARK: - Open and copy

    /// An address in the widget's words (`Text(widgetLinking:)`): asked about first, like its links.
    /// What the app's own buttons open (a contact's Call, Message and Mail) goes on as before.
    private var linkAction: OpenURLAction {
        OpenURLAction { url in
            guard WebLink.isWeb(url) else { return .systemAction }
            open(url.absoluteString)
            return .handled
        }
    }

    /// Where a link goes is shown first: the host as the network sees it (punycode), or the file.
    private func open(_ string: String) {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "hermes-file" else { return }
        pendingOpen = url
    }

    private var openTitle: String {
        guard let url = pendingOpen else { return "" }
        if url.scheme?.lowercased() == "hermes-file" {
            return String(localized: "Open \(url.absoluteString.dropFirst("hermes-file:".count).split(separator: "/").last.map(String.init) ?? "")?")
        }
        return String(localized: "Open \(url.host(percentEncoded: true) ?? url.absoluteString)?")
    }

    private func perform(_ url: URL) {
        pendingOpen = nil
        if url.scheme?.lowercased() == "hermes-file" {
            let path = String(url.absoluteString.dropFirst("hermes-file:".count))
            references.openInInspector(path.removingPercentEncoding ?? path)
        } else if WebLink.isWeb(url) {
            openURL(url)
        }
    }

    private func copy(_ value: String) {
        Pasteboard.copy(value)
        withAnimation(Theme.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Theme.snappy) { copied = false }
        }
    }

    private var copyText: String { payload.envelope.fallbackText }

    // MARK: - The widget menu

    @ViewBuilder
    private func menu(_ interaction: WidgetInteraction) -> some View {
        Button("Copy as Text", systemImage: "doc.on.doc") { Pasteboard.copy(copyText) }
        if payload.envelope.refresh?.mode == .agent, interaction.acceptsAnswers {
            Button("Refresh", systemImage: "arrow.clockwise") { host?.send(.plain(payload, "refresh")) }
        }
        Button("Where This Came From", systemImage: "info.circle") { showsSource = true }
        Divider()
        Button("Hide", systemImage: "eye.slash") { host?.store.hide(payload.id) }
    }

    private func accessibilityTitle(_ interaction: WidgetInteraction) -> String {
        var parts = [payload.envelope.summary ?? payload.title]
        if let badge = WidgetHeader.badge(for: payload, now: now, interaction: interaction) { parts.append(badge.word) }
        return parts.joined(separator: ", ")
    }
}

extension WidgetPayload {
    /// Wide layouts take 720 pt on iPad and Mac: lanes, option cards, a stack's grid.
    var isWide: Bool {
        switch content {
        case .compare(let compare): compare.layout != .grid
        case .list(let list): list.layout == .lanes
        case .stack(let stack): stack.layout == .grid || stack.layout == .carousel
        default: false
        }
    }
}

// MARK: - Header

/// `Parts.cardHeader`: the glyph or the producing Bot's face, the title and subtitle, and the one
/// state badge (or a lock when private).
struct WidgetHeader: View {
    let payload: WidgetPayload
    let now: Date
    /// Where its request stands: an answer on its way reads "Waiting" until the update.
    var interaction: WidgetInteraction = .open

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            leading
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(payload.title)
                    .font(WidgetFont.title)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = payload.envelope.subtitle, !subtitle.isEmpty {
                    Text(widgetLinking: subtitle)
                        .font(WidgetFont.subtitle)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let badge = Self.badge(for: payload, now: now, interaction: interaction) {
                WidgetBadge(tone: badge.tone, word: badge.word)
            } else if let meta = payload.headerMeta {
                // A trailing meta where there's no badge ("4 of 9", "14 open", "Step 3 of 5").
                Text(meta)
                    .font(WidgetFont.label.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
                    .padding(.top, 1)
            }
            if payload.isPrivate {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 3)
                    .accessibilityLabel(String(localized: "Private"))
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        // The card's own icon wins; a `bot:` icon is the producer's face only when it names the
        // producer (contract §9); with no icon, the producing Bot's face.
        let producer = payload.envelope.producer?.bot
        if let handle = WidgetSymbols.botHandle(payload.envelope.icon) {
            if handle == producer {
                WidgetBotFace(handle: handle, size: 20)
            } else {
                WidgetGlyph(name: nil, fallback: payload.type.defaultSymbol, size: 13)
            }
        } else if payload.envelope.icon == nil, let producer {
            WidgetBotFace(handle: producer, size: 20)
        } else {
            WidgetGlyph(name: payload.envelope.icon, fallback: payload.type.defaultSymbol, size: 13)
        }
    }

    /// One badge, by precedence: critical, stale, unverified, warning, pending, info, ok. Without a
    /// state the worst item state decides; nothing is shown for plain good news.
    static func badge(for payload: WidgetPayload, now: Date, interaction: WidgetInteraction = .open) -> (tone: WidgetTone, word: String)? {
        var candidates: [(WidgetTone, String?)] = []
        // An answer in flight, from this device or another (`Asking.approvalPending`): "Waiting".
        switch interaction {
        case .sending, .waiting: candidates.append((.pending, String(localized: "Waiting")))
        default: break
        }
        if let stale = WidgetClock.staleAt(payload.envelope), now >= stale, let asOf = WidgetClock.date(payload.envelope.asOf) {
            candidates.append((.stale, WidgetFormatter(now: now).age(since: asOf)))
        }
        if let state = payload.envelope.state {
            candidates.append((WidgetTone(state), payload.envelope.stateLabel))
        } else if let derived = payload.derivedBadge {
            candidates.append(derived)
        } else if let worst = payload.itemTones.min(), worst < .info {
            candidates.append((worst, nil))
        }
        guard let pick = candidates.min(by: { $0.0 < $1.0 }) else { return nil }
        return (pick.0, pick.1 ?? pick.0.word)
    }
}

extension WidgetPayload {
    /// The header's trailing meta where the primitive has one (each primitive's spec, "Header").
    var headerMeta: String? {
        switch content {
        case .checklist(let list) where !list.items.isEmpty:
            let done = list.items.filter(\.checked).count
            switch list.progress {
            case .bar, .count: return String(localized: "\(done) of \(list.items.count)")
            case .open: return String(localized: "\(list.items.count - done) open")
            case .none: return nil
            }
        case .outline(let outline):
            func leaves(_ nodes: [OutlineWidget.Node]) -> [OutlineWidget.Node] {
                nodes.flatMap { node in node.children?.isEmpty == false ? leaves(node.children ?? []) : [node] }
            }
            let all = leaves(outline.nodes)
            if outline.mode == .files { return String(localized: "\(all.count) files") }
            let stated = all.filter { $0.state != nil }
            guard !stated.isEmpty else { return nil }
            return String(localized: "\(stated.filter { $0.state == .done }.count) of \(stated.count)")
        case .list(let list):
            guard let noun = list.noun else { return nil }
            return "\(list.total ?? list.items.count) \(noun)"
        case .steps(let steps):
            guard let index = steps.steps.firstIndex(where: { $0.state == .running }) else { return nil }
            return String(localized: "Step \(index + 1) of \(steps.steps.count)")
        case .sources(let sources):
            return "\(sources.items.count)"
        default:
            return nil
        }
    }

    /// A badge the client derives from the content when the payload sends no `state`: a weather
    /// alert's severity, a flight's state (each primitive's spec, "Header").
    var derivedBadge: (WidgetTone, String?)? {
        switch content {
        case .weather(let weather):
            guard let alert = weather.alerts?.first, alert.severity != .info else { return nil }
            return (alert.severity == .critical ? .critical : .warning, String(localized: "Warning"))
        case .route(let route):
            return route.flight.map { WidgetFlight.badge($0.state) }
        default:
            return nil
        }
    }

    /// The states of a payload's items, for a header without a state of its own.
    var itemTones: [WidgetTone] {
        switch content {
        case .metric(let metric): metric.items.compactMap(\.state).map(WidgetTone.init)
        case .status(let status): status.items.map { WidgetTone($0.state) }
        case .list(let list): list.items.compactMap(\.state).map(WidgetTone.init)
        default: []
        }
    }
}

// MARK: - Banner, footer, status

/// `Parts.cardBanner`: one line to read before the body.
struct WidgetBanner: View {
    let tone: WidgetTone
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone == .unverified ? Theme.primaryText : tone.color)
                .accessibilityHidden(true)
            Text(widgetLinking: text)
                .font(WidgetFont.label)
                .foregroundStyle(tone == .info ? Theme.info : Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone == .unverified ? Theme.canvas : tone.tint, in: RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous))
        .overlay {
            if tone.isDashed {
                RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous)
                    .strokeBorder(Theme.primaryText.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// `Parts.cardFooter`: where the data came from and when, and Refresh when the agent can.
struct WidgetFooter: View {
    let payload: WidgetPayload
    let context: WidgetContext

    var body: some View {
        let source = payload.envelope.source
        let time = WidgetFormatter().time(payload.envelope.asOf)
        if source != nil || payload.envelope.refresh?.mode == .agent {
            HStack(spacing: 5) {
                if let source {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    // Where in the source when the producer says ("invoices/0042.pdf", "listed 9 days
                    // ago"), else when (`Parts.cardFooter`).
                    Text([source.name, source.detail ?? time].compactMap { $0 }.joined(separator: " · "))
                        .font(WidgetFont.caption)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if payload.envelope.refresh?.mode == .agent, context.canAnswer {
                    Button {
                        context.answer(.plain(payload, "refresh"))
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Refresh"))
                }
            }
            .foregroundStyle(Theme.tertiaryText)
            .accessibilityElement(children: .contain)
        }
    }
}

/// What happened to the widget's request (`Parts.resolutionLine`), or where it stands: queued,
/// waiting, answered on another device, no answer yet, not sent, expired, for someone else.
struct WidgetStatusLine: View {
    let context: WidgetContext

    var body: some View {
        switch context.interaction {
        case .resolved:
            if let resolution = context.payload.envelope.resolution { resolutionLine(resolution) }
        case .sending(_, true):
            note("clock", String(localized: "Queued · sends after the current turn"))
        case .waiting(_, false, let device):
            note("checkmark.circle", device.map { String(localized: "Answered on \($0) · waiting") } ?? String(localized: "Answered · waiting"))
        case .noAnswer(let answer):
            HStack(spacing: 6) {
                note("exclamationmark.circle", String(localized: "No answer from \(producer) yet"))
                Spacer(minLength: 4)
                Button("Try Again") { context.host?.resend(answer.text) }
                    .font(WidgetFont.label.weight(.semibold))
                    .underline()
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.primaryText)
                    .frame(minHeight: 32)
            }
        case .notSent:
            note("wifi.slash", String(localized: "Not sent: you're offline"))
        case .expired:
            let time = WidgetFormatter().time(context.payload.envelope.expiresAt ?? "") ?? ""
            note("hourglass", String(localized: "Expired at \(time) · nothing happened"))
        case .readOnly(let name):
            note("person", String(localized: "For \(name)"))
        case .superseded:
            note("arrow.down", String(localized: "Updated · the newer one is below"))
        case .open, .notAnswered, .sending(_, false), .waiting(_, true, _):
            EmptyView()
        }
    }

    private var producer: String {
        context.payload.envelope.producer?.name ?? String(localized: "Hermes")
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(widgetLinking: text)
                .font(WidgetFont.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.secondaryText)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func resolutionLine(_ resolution: WidgetResolution) -> some View {
        let look = Self.look(resolution.state)
        let time = WidgetFormatter().time(resolution.at)
        let canUndo = resolution.undo.map { WidgetClock.date($0.until).map { $0 > context.now } ?? false } ?? false
        HStack(spacing: 6) {
            Image(systemName: look.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(look.color)
                .accessibilityHidden(true)
            Text(resolution.message ?? look.word)
                .font(WidgetFont.label.weight(.medium))
                .foregroundStyle(resolution.state == .failed ? Theme.danger : Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if resolution.state == .failed, context.host != nil {
                Button("Retry") { context.answer(.plain(context.payload, "retry")) }
                    .font(WidgetFont.label.weight(.semibold))
                    .underline()
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.primaryText)
                    .frame(minHeight: 32)
            } else if canUndo, let undo = resolution.undo, context.host != nil {
                Button("Undo") { context.answer(.plain(context.payload, undo.action)) }
                    .font(WidgetFont.label.weight(.semibold))
                    .underline()
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.primaryText)
                    .frame(minHeight: 32)
            }
            // Who answered and when (contract §6.4): "Mac · 10:16".
            let meta = [resolution.by, time].compactMap { $0 }.filter { !$0.isEmpty }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · "))
                    .font(WidgetFont.caption.monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    static func look(_ state: WidgetResolution.State) -> (symbol: String, color: Color, word: String) {
        switch state {
        case .done: ("checkmark.circle.fill", Theme.success, String(localized: "Done"))
        case .failed: ("xmark.octagon.fill", Theme.danger, String(localized: "Failed"))
        case .rejected: ("xmark.circle", Theme.secondaryText, String(localized: "Rejected · nothing happened"))
        case .cancelled: ("minus.circle", Theme.secondaryText, String(localized: "Cancelled"))
        case .expired: ("hourglass", Theme.secondaryText, String(localized: "Expired · nothing happened"))
        case .elsewhere: ("checkmark.circle", Theme.secondaryText, String(localized: "Answered elsewhere"))
        }
    }
}

/// `Parts.actionRow`: at most two buttons, the secondary left and the one primary right; more go
/// in "…". Off once the request is resolved, expired or answered.
struct WidgetActionRow: View {
    let context: WidgetContext

    var body: some View {
        let actions = context.payload.envelope.actions ?? []
        if !actions.isEmpty, showsActions {
            let primary = actions.first { $0.style == .primary }
            let rest = actions.filter { $0.id != primary?.id }
            let secondary = rest.first
            let overflow = Array(rest.dropFirst())
            HStack(spacing: 8) {
                if let secondary { button(secondary) }
                if let primary { button(primary) }
                if !overflow.isEmpty {
                    Menu {
                        ForEach(overflow, id: \.id) { action in
                            Button(action.label, role: action.style == .destructive ? .destructive : nil) { tap(action) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                            .frame(width: 44, height: 44)
                            .background(Theme.controlFill, in: Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "More Actions"))
                    .disabled(!context.canAnswer)
                }
            }
        }
    }

    private var showsActions: Bool {
        switch context.interaction {
        case .resolved, .expired, .superseded, .readOnly: false
        default: true
        }
    }

    @State private var confirming: WidgetAction?

    private func button(_ action: WidgetAction) -> some View {
        let role: WidgetActionButtonStyle.Role = action.style == .primary ? .primary : action.style == .destructive ? .destructive : .secondary
        return Button(action.label) { tap(action) }
            .buttonStyle(WidgetActionButtonStyle(role: role, isPending: context.pendingAction == action.id))
            .disabled(!context.canAnswer)
            .confirmationDialog(action.confirm?.title ?? action.label, isPresented: Binding(
                get: { confirming?.id == action.id }, set: { if !$0 { confirming = nil } }
            ), titleVisibility: .visible) {
                Button(action.label, role: .destructive) { context.perform(action) }
            } message: {
                if let message = action.confirm?.message { Text(message) }
            }
    }

    private func tap(_ action: WidgetAction) {
        if action.confirm != nil {
            confirming = action
        } else {
            context.perform(action)
        }
    }
}

// MARK: - States

/// `Parts.cardLoading`: the directive's `alt` as the title over the primitive's skeleton.
struct WidgetLoadingCard: View {
    let title: String?
    let kind: WidgetSkeletonKind

    @Environment(\.widgetDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: density.gap) {
            HStack(spacing: 8) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
                Text(title ?? String(localized: "Loading widget"))
                    .font(WidgetFont.title)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            WidgetSkeleton(kind: kind)
        }
        .padding(.top, density.padTop)
        .padding(.horizontal, density.pad)
        .padding(.bottom, density.pad)
        .frame(maxWidth: WidgetDensity.maxWidth, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: density.radius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading: \(title ?? "")"))
    }
}

/// `Parts.skeleton*`: grey blocks in the primitive's shape, with a slow shimmer (none with Reduce
/// Motion).
struct WidgetSkeleton: View {
    let kind: WidgetSkeletonKind

    var body: some View {
        Group {
            // The blocks fade towards what's right behind them; the code well stays still under
            // its lines, as the card does under the others.
            if kind == .code {
                blocks.modifier(SkeletonShimmer(towards: Theme.canvas)).widgetWell()
            } else {
                blocks.modifier(SkeletonShimmer(towards: Theme.surface))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var blocks: some View {
        switch kind {
        case .value:
            VStack(alignment: .leading, spacing: 8) {
                block(width: 110, height: 10)
                block(width: 150, height: 26)
                block(width: 80, height: 10)
            }
        case .rows:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 10) {
                        block(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 6) {
                            block(width: [180, 140, 160][index], height: 9)
                            block(width: 90, height: 8)
                        }
                    }
                }
            }
        case .chart:
            VStack(alignment: .leading, spacing: 8) {
                block(width: 90, height: 18)
                block(width: nil, height: 90)
            }
        case .media:
            VStack(alignment: .leading, spacing: 8) {
                block(width: nil, height: 140)
                block(width: 160, height: 9)
            }
        case .grid:
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<4, id: \.self) { _ in
                    GridRow {
                        ForEach(0..<7, id: \.self) { _ in block(width: nil, height: 14) }
                    }
                }
            }
        case .code:
            VStack(alignment: .leading, spacing: 7) {
                ForEach([0.85, 0.6, 0.9, 0.5, 0.7], id: \.self) { fraction in
                    GeometryReader { proxy in block(width: proxy.size.width * fraction, height: 8) }
                        .frame(height: 8)
                }
            }
        }
    }

    private func block(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Theme.controlFill)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// The skeleton's slow shimmer (1.4 s): the blocks fade halfway towards what's right behind them,
/// the card's surface or the code well, and back. Towards the canvas, black in dark, blocks on a
/// card sank below it. Its moving part exists only while the loop runs, so it stops when the card
/// goes or can't be seen (`DecorativeLoop`).
private struct SkeletonShimmer: ViewModifier {
    let towards: Color

    func body(content: Content) -> some View {
        DecorativeLoop { runs in
            content.overlay {
                if runs { SkeletonGlow(towards: towards).mask(content) }
            }
        }
    }
}

private struct SkeletonGlow: View {
    let towards: Color

    @State private var bright = false

    var body: some View {
        towards
            .opacity(bright ? 0.5 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

/// The directive's id has no payload on this device (`Parts.cardError`).
struct WidgetMissingCard: View {
    let alt: String?
    let retry: () -> Void

    @Environment(\.widgetDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityHidden(true)
                Text("Couldn't load this widget")
                    .font(WidgetFont.title)
            }
            .foregroundStyle(Theme.primaryText)
            Text([alt, String(localized: "Not available on this device")].compactMap { $0 }.joined(separator: " · "))
                .font(WidgetFont.label)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again", action: retry)
                .buttonStyle(WidgetActionButtonStyle(fillsWidth: false))
        }
        .padding(.top, density.padTop)
        .padding(.horizontal, density.pad)
        .padding(.bottom, density.pad)
        .frame(maxWidth: WidgetDensity.maxWidth, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: density.radius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// A widget the app shows as text (`Parts.fallbackText`): its `fallback_text` as reply prose with
/// a quiet "Shown as text", and why in the menu.
struct WidgetFallbackView: View {
    let fallback: WidgetFallback

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownView(text: fallback.text ?? fallback.title ?? String(localized: "A widget this app can't show."))
            Label("Shown as text", systemImage: "info.circle")
                .font(WidgetFont.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
        .contextMenu {
            Button("Copy as Text", systemImage: "doc.on.doc") { Pasteboard.copy(fallback.text ?? "") }
            Section(reason) {}
        }
    }

    private var reason: String {
        switch fallback.reason {
        case .unknownType, .newerVersion: String(localized: "Update Hermes to see this widget")
        case .invalid(let why): String(localized: "Shown as text: \(why)")
        }
    }
}

/// One line for a widget folded away (`Parts.cardFolded`, `cardFoldedUnanswered`).
struct WidgetFoldedCard: View {
    let payload: WidgetPayload
    let reason: String
    let open: () -> Void

    @Environment(\.widgetDensity) private var density

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                WidgetGlyph(name: payload.envelope.icon, fallback: payload.type.defaultSymbol, size: 12, color: Theme.secondaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(payload.title)
                        .font(WidgetFont.title)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(reason)
                        .font(WidgetFont.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, density.pad)
            .frame(minHeight: 48)
            .frame(maxWidth: WidgetDensity.maxWidth, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: density.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: density.radius, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(payload.title), \(reason)")
        .accessibilityHint(String(localized: "Shows the widget"))
    }
}

/// Where This Came From: the source, when the data is from, who made it, its id and revision.
struct WidgetSourceSheet: View {
    let payload: WidgetPayload

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let source = payload.envelope.source {
                    Section("Source") {
                        LabeledContent("Name", value: source.name)
                        if let kind = source.kind { LabeledContent("Kind", value: kind.rawValue.capitalized) }
                        if let detail = source.detail { LabeledContent("Detail", value: detail) }
                        if let url = source.url { LabeledContent("Address", value: url).textSelection(.enabled) }
                    }
                }
                Section("This widget") {
                    LabeledContent("Data from", value: WidgetFormatter().dateTime(payload.envelope.asOf) ?? payload.envelope.asOf)
                    if let producer = payload.envelope.producer { LabeledContent("Made by", value: producer.name) }
                    LabeledContent("Kind", value: payload.type.rawValue)
                    LabeledContent("ID", value: payload.id).textSelection(.enabled)
                    LabeledContent("Revision", value: String(payload.rev))
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Where This Came From")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 380)
        #else
        .presentationDetents([.medium])
        #endif
    }
}

/// Why an answer that needed Face ID wasn't sent (`docs/widgets.md` §6).
private struct WidgetAuthAlert: ViewModifier {
    let id: String

    @Environment(\.widgetHost) private var host

    func body(content: Content) -> some View {
        let problem = host?.store.authProblem[id]
        content.alert(String(localized: "Not sent"), isPresented: Binding(get: { problem != nil }, set: { if !$0 { host?.store.authProblem[id] = nil } })) {
            if problem?.opensSettings == true {
                Button("Open Settings") { DeviceSetup.openSettings(.app) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem?.message ?? "")
        }
    }
}

/// A private widget is blurred while the app isn't in front, so the app switcher's picture of it
/// shows nothing (contract §9).
struct PrivateWidgetCover: ViewModifier {
    let isPrivate: Bool
    let radius: CGFloat

    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        #if os(iOS)
        let covered = isPrivate && phase != .active
        content
            .blur(radius: covered ? 24 : 0, opaque: false)
            .overlay {
                if covered {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Theme.surface.opacity(0.7))
                        .overlay {
                            Label("Private", systemImage: "lock.fill")
                                .font(WidgetFont.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                        }
                }
            }
        #else
        content
        #endif
    }
}
