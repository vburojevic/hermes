import HermesKit
import SwiftUI

// The Time family (`widgets/time.elyx`): timeline, agenda.

// MARK: - timeline

/// Events in order on a rail, the current one ringed (`Time.timeline`, `timelineItinerary`,
/// `timelineIncident`, `timelineNow`). The client never advances it: only an update does.
struct TimelineBody: View {
    let model: TimelineWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isStale: Bool {
        WidgetClock.staleAt(context.payload.envelope).map { context.now >= $0 } ?? false
    }

    /// More than eight: six show, then Show all. Past timelines fold the oldest, future ones the latest.
    private var shown: [TimelineWidget.Event] {
        guard model.events.count > 8, !context.view.showsAll else { return model.events }
        return model.direction == .past ? Array(model.events.suffix(6)) : Array(model.events.prefix(6))
    }

    var body: some View {
        if model.events.isEmpty {
            WidgetEmpty(context: context, fallback: String(localized: "No updates yet."))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if model.events.count > 8, model.direction == .past {
                    showAll
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { index, event in
                    if model.direction == .future, let now = nowIndex, now == index { nowLine }
                    row(event, isLast: index == shown.count - 1)
                }
                if model.direction == .future, nowIndex == shown.count, isToday { nowLine }
                if model.events.count > 8, model.direction == .future {
                    showAll
                }
            }
        }
    }

    private var showAll: some View {
        ShowAllButton(total: model.events.count, isExpanded: context.view.showsAll) {
            withAnimation(.spring(response: 0.3)) { context.updateView { $0.showsAll.toggle() } }
        }
    }

    /// Where the device clock falls among the events (`timelineNow`); it marks nothing done.
    private var nowIndex: Int? {
        guard isToday else { return nil }
        let times = shown.map { $0.time.flatMap(WidgetClock.date) }
        return times.firstIndex { ($0 ?? .distantPast) > context.now } ?? shown.count
    }

    private var isToday: Bool {
        model.events.contains { $0.time.flatMap(WidgetClock.date).map(Calendar.current.isDateInToday) == true }
    }

    private var nowLine: some View {
        HStack(spacing: 6) {
            Text(context.now.formatted(date: .omitted, time: .shortened))
                .font(WidgetFont.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.danger)
                .frame(width: timeWidth, alignment: .leading)
            Rectangle().fill(Theme.danger).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Now, \(context.now.formatted(date: .omitted, time: .shortened))"))
    }

    private var timeWidth: CGFloat { typeSize.isAccessibilitySize ? 0 : 76 }

    private func row(_ event: TimelineWidget.Event, isLast: Bool) -> some View {
        let isCurrent = event.state == .current
        return HStack(alignment: .top, spacing: 10) {
            if !typeSize.isAccessibilitySize {
                Text(timeText(event))
                    .font(WidgetFont.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: timeWidth, alignment: .leading)
                    .padding(.top, 2)
            }
            VStack(spacing: 0) {
                dot(event)
                    .frame(width: 16, height: 18)
                if !isLast {
                    Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if typeSize.isAccessibilitySize {
                    Text(timeText(event)).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                }
                HStack(spacing: 5) {
                    if let glyph = WidgetSymbols.resolve(event.glyph) {
                        Image(systemName: glyph).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                    Text(event.title)
                        .font(isCurrent ? WidgetFont.body.weight(.semibold) : WidgetFont.body)
                        .foregroundStyle(event.state == .cancelled ? Theme.secondaryText : Theme.primaryText)
                        .strikethrough(event.state == .cancelled)
                }
                if let window = window(event) {
                    Text(window).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                }
                if let detail = detail(event) {
                    Text(widgetLinking: detail).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                if let place = event.place {
                    Button {
                        if let url = place.url { context.open(url) }
                    } label: {
                        Label(place.name, systemImage: "mappin.and.ellipse").font(WidgetFont.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .disabled(place.url == nil)
                }
                if let evidence = event.evidence { EvidenceLine(evidence: evidence) }
                if let actions = event.actions, !actions.isEmpty {
                    RowActions(actions: actions, item: (event.id, event.title), context: context)
                }
            }
            .padding(.bottom, isLast ? 0 : 12)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(event))
        .rowActions(event.actions, item: (event.id, event.title), context: context)
    }

    @ViewBuilder
    private func dot(_ event: TimelineWidget.Event) -> some View {
        switch event.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.success)
        case .current:
            Circle()
                .strokeBorder(isStale ? Theme.secondaryText : Theme.ink, lineWidth: 2)
                .background(Circle().fill(isStale ? Theme.secondaryText : Theme.ink).padding(4))
                .frame(width: 14, height: 14)
        case .upcoming:
            Circle().strokeBorder(Theme.tertiaryText, lineWidth: 1.5).frame(width: 11, height: 11)
        case .info:
            Image(systemName: "info.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.info)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warning)
        case .critical:
            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.danger)
        case .unverified:
            Image(systemName: "questionmark.circle").font(.system(size: 13)).foregroundStyle(Theme.primaryText)
        case .cancelled:
            Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(Theme.tertiaryText)
        }
    }

    /// Clock times today and for itineraries and logs; a weekday or a short date for older ones.
    private func timeText(_ event: TimelineWidget.Event) -> String {
        guard let time = event.time else { return WidgetFormatter.unknown }
        if time.count == 10 { return formatter.date(time) ?? time }
        guard let (date, zone) = WidgetFormatter.parse(time) else { return time }
        if model.direction == .future || model.kind == .incident {
            return formatter.time(time) ?? time
        }
        // One short line (`Time.timeline`): "Today 09:12", else the weekday and day, "Tue 13".
        if Calendar.current.isDateInToday(date) {
            return String(localized: "Today \(formatter.time(time) ?? "")")
        }
        return date.formatted(Date.FormatStyle(locale: formatter.locale, timeZone: zone).weekday(.abbreviated).day())
    }

    private func window(_ event: TimelineWidget.Event) -> String? {
        guard let end = event.end, let start = event.time, let from = formatter.time(start), let to = formatter.time(end) else { return nil }
        return String(localized: "Expected \(from)–\(to)")
    }

    private func detail(_ event: TimelineWidget.Event) -> String? {
        let parts = [event.detail, event.who?.name].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func spoken(_ event: TimelineWidget.Event) -> String {
        let state = switch event.state {
        case .done: String(localized: "done")
        case .current: String(localized: "now")
        case .upcoming: String(localized: "expected")
        case .info: String(localized: "note")
        case .warning: String(localized: "warning")
        case .critical: String(localized: "problem")
        case .unverified: String(localized: "not confirmed")
        case .cancelled: String(localized: "cancelled")
        }
        return [timeText(event).replacingOccurrences(of: "\n", with: " "), state, event.title, detail(event)].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - agenda

/// A schedule: one day as blocks with free time and the now line, or the days ahead as one line
/// each (`Time.agenda`, `agendaWeek`). The client computes the order, overlaps, free time and the
/// now line; it never adds, moves or answers an event.
struct AgendaBody: View {
    let model: AgendaWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    private var zone: TimeZone {
        model.timeZone.flatMap(TimeZone.init(identifier:)) ?? model.events.first.flatMap { WidgetFormatter.parse($0.start)?.1 } ?? .current
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = formatter.locale
        return calendar
    }

    var body: some View {
        if model.events.isEmpty {
            WidgetEmpty(context: context, fallback: model.view == .day
                ? (model.complete ? String(localized: "Nothing on your calendar today.") : String(localized: "Nothing in \(context.payload.envelope.source?.name ?? String(localized: "this calendar")) today."))
                : String(localized: "Nothing planned this week."))
        } else if model.view == .days {
            days
        } else {
            day
        }
    }

    // MARK: Day

    private var timed: [AgendaWidget.Event] {
        model.events.filter { !$0.allDay }.sorted { start($0) < start($1) }
    }

    private var day: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.events.filter(\.allDay), id: \.id) { event in
                HStack(spacing: 8) {
                    Text("All day")
                        .font(WidgetFont.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .frame(minHeight: 20)
                        .background(Theme.controlFill, in: Capsule())
                    Text(event.title).font(WidgetFont.body)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "All day: \(event.title)"))
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .event(let event, let overlaps): block(event, overlaps: overlaps)
                case .free(let from, let to): free(from: from, to: to)
                case .now: nowLine
                }
            }
        }
    }

    private enum Entry {
        case event(AgendaWidget.Event, overlaps: String?)
        case free(Date, Date)
        case now
    }

    private var isToday: Bool {
        JSONSchemaValidator.parseDate(model.date).map { calendar.date(from: $0).map(calendar.isDateInToday) ?? false } ?? false
    }

    private var entries: [Entry] {
        var entries: [Entry] = []
        var cursor: Date? = model.hours.flatMap { hours in dayTime(hours.start) }
        var nowPlaced = !isToday
        for (index, event) in timed.enumerated() {
            let begins = start(event)
            if !nowPlaced, begins > context.now {
                entries.append(.now)
                nowPlaced = true
            }
            if model.complete, let cursor, begins.timeIntervalSince(cursor) >= 30 * 60 {
                entries.append(.free(cursor, begins))
            }
            let overlap = timed.enumerated().first { other in
                other.offset != index && start(other.element) < finish(event) && finish(other.element) > begins
            }?.element.title
            entries.append(.event(event, overlaps: overlap))
            cursor = max(cursor ?? finish(event), finish(event))
        }
        if model.complete, let cursor, let end = model.hours.flatMap({ dayTime($0.end) }), end.timeIntervalSince(cursor) >= 30 * 60 {
            entries.append(.free(cursor, end))
        }
        if !nowPlaced { entries.append(.now) }
        return entries
    }

    private func start(_ event: AgendaWidget.Event) -> Date {
        WidgetClock.date(event.start) ?? JSONSchemaValidator.parseDate(event.start).flatMap { calendar.date(from: $0) } ?? .distantPast
    }

    private func finish(_ event: AgendaWidget.Event) -> Date {
        event.end.flatMap(WidgetClock.date) ?? start(event)
    }

    /// "HH:MM" on the agenda's date.
    private func dayTime(_ clock: String) -> Date? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, var components = JSONSchemaValidator.parseDate(model.date) else { return nil }
        components.hour = parts[0]
        components.minute = parts[1]
        return calendar.date(from: components)
    }

    private func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: formatter.locale, timeZone: zone))
    }

    private func block(_ event: AgendaWidget.Event, overlaps: String?) -> some View {
        let past = isToday && finish(event) < context.now
        let hollow = event.state == .tentative || event.state == .invited
        let range = event.end.map { _ in "\(clock(start(event)))–\(clock(finish(event)))" } ?? clock(start(event))
        let line = [range, event.place?.name, event.people?.map(\.name).joined(separator: ", "), event.note].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 8) {
            if !typeSize.isAccessibilitySize {
                Text(clock(start(event)))
                    .font(WidgetFont.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 44, alignment: .trailing)
                    .padding(.top, 8)
            }
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(hollow ? Color.clear : Theme.ink)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.ink, lineWidth: hollow ? 1.2 : 0))
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(WidgetFont.body.weight(.semibold))
                        .strikethrough(event.state == .cancelled)
                    Text(line).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    // Tags under the details ("Leave by 10:30"), so the event keeps the width (`Time.agenda`).
                    if overlaps != nil || event.tags?.isEmpty == false {
                        FlowLayout(spacing: 4) {
                            if overlaps != nil {
                                WidgetTagView(tag: WidgetTag(label: String(localized: "Overlaps"), state: .warning))
                            }
                            ForEach(Array((event.tags ?? []).prefix(2).enumerated()), id: \.offset) { _, tag in WidgetTagView(tag: tag) }
                        }
                        .padding(.top, 2)
                    }
                    if let actions = event.actions, !actions.isEmpty {
                        RowActions(actions: actions, item: (event.id, event.title), context: context)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
        }
        .opacity(past ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(event, range: range, overlaps: overlaps))
        .rowActions(event.actions, item: (event.id, event.title), context: context)
    }

    /// A free slot's length as the design writes it: "1 h 30", "2 h", "45 min".
    static func slot(_ seconds: TimeInterval) -> String {
        guard let minutes = Int(checking: (seconds / 60).rounded()) else { return WidgetFormatter.unknown }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return String(localized: "\(rest) min") }
        return rest == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(String(format: "%02d", rest))")
    }

    private func free(from: Date, to: Date) -> some View {
        let duration = Self.slot(to.timeIntervalSince(from))
        return HStack(spacing: 8) {
            if !typeSize.isAccessibilitySize { Color.clear.frame(width: 44) }
            Text("Free · \(duration)")
                .font(WidgetFont.caption)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .padding(.horizontal, 10)
                .overlay(RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous).strokeBorder(Theme.tertiaryText, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Free, \(clock(from)) to \(clock(to)), \(duration)"))
    }

    private var nowLine: some View {
        HStack(spacing: 6) {
            Text(clock(context.now))
                .font(WidgetFont.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.danger)
                .frame(width: typeSize.isAccessibilitySize ? nil : 44, alignment: .trailing)
            Rectangle().fill(Theme.danger).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Now, \(clock(context.now))"))
    }

    private func spoken(_ event: AgendaWidget.Event, range: String, overlaps: String?) -> String {
        var parts = [range, event.title]
        if let place = event.place?.name { parts.append(place) }
        switch event.state {
        case .tentative: parts.append(String(localized: "Maybe"))
        case .invited: parts.append(String(localized: "Not answered"))
        case .cancelled: parts.append(String(localized: "Cancelled"))
        case .confirmed: break
        }
        if let overlaps { parts.append(String(localized: "Overlaps \(overlaps)")) }
        parts += event.tags?.map(\.label) ?? []
        return parts.joined(separator: ", ")
    }

    // MARK: Days

    private var days: some View {
        let first = JSONSchemaValidator.parseDate(model.date).flatMap { calendar.date(from: $0) } ?? context.now
        let dates = (0..<max(model.span, 1)).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                if index > 0 { Divider().overlay(Theme.hairline) }
                dayRow(date)
            }
        }
    }

    private func dayRow(_ date: Date) -> some View {
        let events = model.events.filter { calendar.isDate(start($0), inSameDayAs: date) }.sorted { start($0) < start($1) }
        let key = date.formatted(.iso8601.year().month().day())
        let note = model.dayNotes?.first { $0.date == key }?.note
        let expanded = context.view.expanded.contains(key)
        let firstTimed = events.first { !$0.allDay }
        let summary: String = {
            if events.isEmpty { return note ?? String(localized: "Nothing planned · Free all day") }
            var parts: [String] = []
            if let firstTimed { parts.append("\(clock(start(firstTimed))) \(firstTimed.title)") } else if let first = events.first { parts.append(first.title) }
            if events.count > 1 { parts.append(String(localized: "\(events.count) events")) }
            if let note { parts.append(note) }
            return parts.joined(separator: " · ")
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                guard !events.isEmpty else { return }
                withAnimation(.spring(response: 0.3)) {
                    context.updateView { view in
                        if view.expanded.contains(key) { view.expanded.remove(key) } else { view.expanded.insert(key) }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(spacing: 0) {
                        Text(date.formatted(Date.FormatStyle(locale: formatter.locale, timeZone: zone).weekday(.abbreviated)).uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(calendar.isDateInToday(date) ? Theme.danger : Theme.secondaryText)
                        Text("\(calendar.component(.day, from: date))").font(WidgetFont.valueSmall.monospacedDigit())
                    }
                    .frame(width: 40, height: 40)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
                    Text(summary)
                        .font(WidgetFont.body)
                        .foregroundStyle(events.isEmpty ? Theme.secondaryText : Theme.primaryText)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    if !events.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(date.formatted(Date.FormatStyle(locale: formatter.locale, timeZone: zone).weekday(.wide).day().month(.wide))): \(summary)")
            if expanded {
                ForEach(events, id: \.id) { event in
                    block(event, overlaps: nil)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
