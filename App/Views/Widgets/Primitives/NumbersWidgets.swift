import Charts
import HermesKit
import SwiftUI

// The Numbers family (`widgets/numbers.elyx`): metric, meter, chart, calendar, verdict, scoreboard.

// MARK: - metric

/// Labelled numbers: one as a hero, two or three in a row, four to six in a grid, or a strip
/// (`Numbers.metric`, `metricRow`, `metricGrid`, `metricStrip`, `metricCountdown`).
struct MetricBody: View {
    let model: MetricWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Shape { case hero, row, grid, strip }

    private var shape: Shape {
        switch model.layout {
        case .strip: .strip
        case .row: .row
        case .grid: .grid
        case .auto: model.items.count == 1 ? .hero : model.items.count <= 3 ? .row : .grid
        }
    }

    var body: some View {
        switch shape {
        case .hero: hero(model.items[0])
        case .row: row
        case .grid: grid
        case .strip: strip
        }
    }

    private func hero(_ item: MetricWidget.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    MetricValue(quantity: item.value, font: WidgetFont.valueHero)
                    Text(item.label).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    MetricValue(quantity: item.value, font: WidgetFont.valueHero)
                    Text(item.label).font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
                }
            }
            if let delta = item.delta { DeltaLabel(delta: delta, showsPeriod: true) }
            if let note = item.note { noteText(note) }
            if let spark = item.spark { Sparkline(points: spark).frame(height: 28).padding(.top, 4) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(item))
    }

    private var row: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                if index > 0, !stacked {
                    Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity)
                }
                cell(item, valueFont: WidgetFont.value)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var grid: some View {
        let columns = typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    cell(item, valueFont: WidgetFont.value)
                    if let spark = item.spark { Sparkline(points: spark).frame(height: 22) }
                }
                .widgetWell()
            }
        }
    }

    private var strip: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    MetricValue(quantity: item.value, font: WidgetFont.valueSmall)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(item, includesDelta: false))
            }
        }
    }

    private func cell(_ item: MetricWidget.Item, valueFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let state = item.state, WidgetTone(state) < .info {
                    Image(systemName: WidgetTone(state).symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(WidgetTone(state).color)
                }
                Text(item.label).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
            MetricValue(quantity: item.value, font: valueFont)
            if let delta = item.delta { DeltaLabel(delta: delta) }
            if let note = item.note { noteText(note) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(item))
    }

    private func noteText(_ text: String) -> some View {
        Text(widgetLinking: text)
            .font(WidgetFont.caption)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Revenue, 1,284 euros so far today, up 12 percent versus last Tuesday."
    private func spoken(_ item: MetricWidget.Item, includesDelta: Bool = true) -> String {
        var parts = [item.label, formatter.string(item.value) == WidgetFormatter.unknown ? String(localized: "not known") : formatter.string(item.value)]
        if includesDelta, let delta = item.delta { parts.append(formatter.delta(delta).spoken) }
        if let state = item.state, WidgetTone(state) < .info { parts.append(WidgetTone(state).word) }
        if let note = item.note { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}

/// A number in tabular figures; a countdown ticks by itself (every minute, then every second in
/// the last one, then "Now" and "Closed").
struct MetricValue: View {
    let quantity: WidgetQuantity
    var font: Font = WidgetFont.value

    @Environment(\.widgetFormatter) private var formatter

    var body: some View {
        if quantity.format == .countdown, let raw = quantity.value?.string, let target = WidgetClock.date(raw) {
            CountdownText(target: target, font: font)
        } else {
            Text(formatter.string(quantity))
                .font(font.monospacedDigit())
                .foregroundStyle(quantity.value == nil || quantity.value == .null ? Theme.tertiaryText : Theme.primaryText)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

struct CountdownText: View {
    let target: Date
    var font: Font = WidgetFont.value

    var body: some View {
        TimelineView(.periodic(from: .now, by: abs(target.timeIntervalSinceNow) < 90 ? 1 : 60)) { timeline in
            Text(Self.text(remaining: target.timeIntervalSince(timeline.date)))
                .font(font.monospacedDigit())
                .foregroundStyle(Theme.primaryText)
                .contentTransition(.numericText(countsDown: true))
        }
    }

    static func text(remaining: TimeInterval) -> String {
        if remaining <= -60 { return String(localized: "Closed") }
        if remaining <= 0 { return String(localized: "Now") }
        if remaining < 60 { return String(localized: "\(Int(remaining)) s") }
        return WidgetFormatter().duration(remaining.rounded(.up) - remaining.truncatingRemainder(dividingBy: 60))
    }
}

/// A sparkline: decoration, in ink, no axes. Hidden from VoiceOver (the numbers are read).
struct Sparkline: View {
    let points: [Double]

    var body: some View {
        // The line over a faint area down to the baseline (`Numbers.metric`).
        ZStack {
            SparklineShape(points: points, closed: true)
                .fill(Theme.controlFill)
            SparklineShape(points: points)
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

nonisolated struct SparklineShape: Shape {
    let points: [Double]
    /// Down to the bottom edge and back, for the area under the line.
    var closed = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1, let low = points.min(), let high = points.max() else { return path }
        let span = max(high - low, 0.0001)
        for (index, point) in points.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(points.count - 1)
            let y = rect.maxY - rect.height * CGFloat((point - low) / span)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - meter

/// A value within a range or against a target: one bar as a hero, a bar per item, nested rings,
/// or an arc with zones (`Numbers.meter`, `meterBars`, `meterRing`, `meterArc`, `meterOver`).
struct MeterBody: View {
    let model: MeterWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if model.items.isEmpty {
            WidgetEmpty(context: context, fallback: String(localized: "Nothing to measure yet."))
        } else {
            switch model.style {
            case .ring: rings
            case .arc: arc(model.items[0])
            case .bar: model.items.count == 1 ? AnyView(hero(model.items[0])) : AnyView(bars)
            }
        }
    }

    // A single bar: the value as a hero, "of <target>", the bar, what's left and the note.
    private func hero(_ item: MeterWidget.Item) -> some View {
        let reading = Reading(item: item, widgetZones: model.zones)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MetricValue(quantity: item.value, font: WidgetFont.value)
                if let target = item.target {
                    Text("of \(formatter.string(target))")
                        .font(WidgetFont.body)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            bar(reading, height: 8)
            HStack {
                if item.remaining, let remaining = remainingText(item) {
                    Text(remaining)
                        .font(WidgetFont.label.weight(.medium))
                        .foregroundStyle(reading.isOver ? reading.color : Theme.primaryText)
                }
                Spacer(minLength: 8)
                if let note = item.note {
                    Text(widgetLinking: note).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(item, reading))
        .accessibilityValue(rangeValue(item))
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
                let reading = Reading(item: item, widgetZones: model.zones)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.label)
                            .font(item.mono ? WidgetFont.mono : WidgetFont.label)
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let zone = reading.zone, zone.isWarning, let label = zone.label {
                            Text(label).font(WidgetFont.caption.weight(.semibold)).foregroundStyle(reading.color)
                        }
                        Text(shortValue(item, reading))
                            .font(WidgetFont.label.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.primaryText)
                    }
                    bar(reading, height: 6)
                    if let note = item.note {
                        Text(widgetLinking: note).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(item, reading))
                .accessibilityValue(rangeValue(item))
            }
        }
    }

    private var rings: some View {
        let items = Array(model.items.prefix(3))
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(alignment: .center, spacing: 18))
        return layout {
            ZStack {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let reading = Reading(item: item, widgetZones: model.zones)
                    let inset = CGFloat(index) * 15
                    // Each ring inside its own frame, as `Numbers.meterRing` draws them: 104, 74, 44 pt across.
                    Circle().inset(by: 5.5).stroke(Theme.controlFill, lineWidth: 11).padding(inset)
                    Circle().inset(by: 5.5)
                        .trim(from: 0, to: min(reading.fraction, 1))
                        .stroke(reading.zone?.isWarning == true ? reading.color : ringColor(index), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(inset)
                }
            }
            .frame(width: 104, height: 104)
            .padding(6)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let reading = Reading(item: item, widgetZones: model.zones)
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(ringColor(index)).frame(width: 8, height: 8).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(formatter.string(item.value)).font(WidgetFont.valueSmall.monospacedDigit())
                                if let target = item.target {
                                    Text("/ \(formatter.string(target))").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                                }
                            }
                            if let note = item.note { Text(widgetLinking: note).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText) }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken(item, reading))
                    .accessibilityValue(rangeValue(item))
                }
            }
        }
    }

    private func arc(_ item: MeterWidget.Item) -> some View {
        let reading = Reading(item: item, widgetZones: model.zones)
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        return layout {
            ZStack {
                MeterArc(reading: reading)
                    .frame(width: 112, height: 112)
                VStack(spacing: 0) {
                    MetricValue(quantity: item.value, font: WidgetFont.value)
                    if let label = reading.zone?.label {
                        Text(label).font(WidgetFont.caption.weight(.semibold)).foregroundStyle(reading.zone.map { MeterZone.color($0.state) } ?? Theme.secondaryText)
                    }
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let headline = model.headline { Text(headline).font(WidgetFont.title).foregroundStyle(Theme.primaryText) }
                if let note = model.note ?? item.note {
                    Text(widgetLinking: note).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([spoken(item, reading), model.headline, model.note].compactMap { $0 }.joined(separator: ". "))
        .accessibilityValue(rangeValue(item))
    }

    private func bar(_ reading: Reading, height: CGFloat) -> some View {
        Group {
            if reading.value == nil {
                Capsule()
                    .strokeBorder(Theme.tertiaryText, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(height: height)
            } else {
                WidgetBar(fraction: reading.fraction, color: reading.color, marker: reading.targetMarker, height: height)
            }
        }
    }

    private func ringColor(_ index: Int) -> Color {
        [Theme.ink, Theme.secondaryText, Theme.tertiaryText][min(index, 2)]
    }

    private func remainingText(_ item: MeterWidget.Item) -> String? {
        guard let value = item.value.value?.number, let target = item.target?.value?.number else { return nil }
        var difference = item.value
        difference.value = .number(abs(target - value))
        difference.display = nil
        let amount = formatter.string(difference)
        return value > target ? String(localized: "\(amount) over") : String(localized: "\(amount) left")
    }

    private func shortValue(_ item: MeterWidget.Item, _ reading: Reading) -> String {
        if item.target == nil, item.max == nil || item.max == 100, item.value.format != .percent, item.value.unit == nil {
            return formatter.percent(reading.fraction)
        }
        return formatter.string(item.value)
    }

    private func spoken(_ item: MeterWidget.Item, _ reading: Reading) -> String {
        guard reading.value != nil else {
            return [item.label, String(localized: "not known"), item.note].compactMap { $0 }.joined(separator: ", ")
        }
        var parts = [item.label, formatter.string(item.value)]
        if let target = item.target { parts[1] += " " + String(localized: "of \(formatter.string(target))") }
        parts.append(formatter.percent(reading.fraction))
        if let zone = reading.zone?.label { parts.append(zone) }
        if item.remaining, let remaining = remainingText(item) { parts.append(remaining) }
        if let note = item.note { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    private func rangeValue(_ item: MeterWidget.Item) -> String {
        let reading = Reading(item: item, widgetZones: model.zones)
        return String(localized: "\(WidgetFormatter.number(reading.lower, digits: nil)) to \(WidgetFormatter.number(reading.upper, digits: nil))")
    }

    /// One item read against its scale and zones.
    struct Reading {
        let value: Double?
        let lower: Double
        let upper: Double
        let target: Double?
        let zone: MeterZone?

        init(item: MeterWidget.Item, widgetZones: [MeterWidget.Zone]?) {
            value = item.value.value?.number
            target = item.target?.value?.number
            lower = item.min
            upper = max(item.max ?? target ?? max(value ?? 1, 1), lower + 0.0001)
            let zones = item.zones?.map(MeterZone.init) ?? widgetZones?.map(MeterZone.init) ?? []
            zone = value.flatMap { value in zones.first { value >= $0.from && value < ($0.to ?? .infinity) } }
        }

        var fraction: Double {
            guard let value else { return 0 }
            return min(max((value - lower) / (upper - lower), 0), 1)
        }

        var isOver: Bool {
            guard let value, let target else { return false }
            return value > target
        }

        /// Ink, unless the value sits in a warning or critical zone.
        var color: Color {
            guard let zone, zone.isWarning else { return Theme.ink }
            return MeterZone.color(zone.state)
        }

        /// The target's tick, when it sits inside the scale.
        var targetMarker: Double? {
            guard let target, target < upper, target > lower else { return nil }
            return (target - lower) / (upper - lower)
        }
    }
}

/// A meter's zone, from the widget's or the item's own (the schemas spell them twice).
struct MeterZone {
    let from: Double
    let to: Double?
    let state: String
    let label: String?

    init(_ zone: MeterWidget.Zone) {
        from = zone.from
        to = zone.to
        state = zone.state.rawValue
        label = zone.label
    }

    init(_ zone: MeterWidget.Item.Zone) {
        from = zone.from
        to = zone.to
        state = zone.state.rawValue
        label = zone.label
    }

    var isWarning: Bool { state == "warning" || state == "critical" }

    static func color(_ state: String) -> Color {
        switch state {
        case "critical": Theme.danger
        case "warning": Theme.warning
        case "ok": Theme.success
        case "info": Theme.info
        default: Theme.ink
        }
    }
}

/// An open arc tinted by its zones, with the value as a dot.
private struct MeterArc: View {
    let reading: MeterBody.Reading

    var body: some View {
        let start = 0.125, span = 0.75
        ZStack {
            Circle()
                .trim(from: start, to: start + span)
                .stroke(Theme.controlFill, style: StrokeStyle(lineWidth: 9, lineCap: .round))
            Circle()
                .trim(from: start, to: start + span * reading.fraction)
                .stroke(reading.zone.map { MeterZone.color($0.state) } ?? Theme.ink, style: StrokeStyle(lineWidth: 9, lineCap: .round))
        }
        .rotationEffect(.degrees(90))
    }
}

// MARK: - chart

/// A series over time, bars to compare, or the parts of a whole, in ink and greys
/// (`Numbers.chart`, `chartBar`, `chartShare`). Scrubbing is local and sends nothing.
/// A fact as a small label over its value (`Numbers.chartMarket` stats); VoiceOver reads "Open, 239.10".
struct WidgetStatStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            configuration.label.font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
            configuration.content.font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.primaryText)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A chart for Audio Graphs (`docs/widgets.md` §10): VoiceOver plays each series as tones and reads
/// its points.
struct ChartAudioGraph: AXChartDescriptorRepresentable {
    let title: String
    let labels: [String]
    let isContinuous: Bool
    let series: [(name: String, values: [Double?])]

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = series.flatMap { $0.values.compactMap { $0 } }
        let low = values.min() ?? 0
        let high = max(values.max() ?? 1, low + 1)
        // Category names must be unique: a repeated label gets its position.
        var seen: Set<String> = []
        let categories = labels.enumerated().map { index, label in seen.insert(label).inserted ? label : "\(label) (\(index + 1))" }
        let xAxis = AXCategoricalDataAxisDescriptor(title: "", categoryOrder: categories)
        let yAxis = AXNumericDataAxisDescriptor(title: title, range: low...high, gridlinePositions: []) { $0.formatted() }
        let data = series.map { line in
            AXDataSeriesDescriptor(name: line.name, isContinuous: isContinuous, dataPoints: zip(categories, line.values).compactMap { label, value in
                value.map { AXDataPoint(x: label, y: $0) }
            })
        }
        return AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: data)
    }
}

struct ChartBody: View {
    let model: ChartWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @State private var selected: Int?

    private var xValues: [String] { model.x?.values ?? [] }
    private var series: [ChartWidget.Series] { Array((model.series ?? []).prefix(3)) }
    private var hasData: Bool {
        model.kind == .share ? !(model.parts ?? []).isEmpty : series.contains { $0.values.contains { $0 != nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let headline = model.headline {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    MetricValue(quantity: headline.value, font: WidgetFont.value)
                    if let label = headline.label { Text(label).font(WidgetFont.label).foregroundStyle(Theme.secondaryText) }
                    if let delta = headline.delta { DeltaLabel(delta: delta) }
                }
                .accessibilityElement(children: .combine)
            }
            if !hasData {
                WidgetEmpty(context: context, fallback: String(localized: "No data for this period."))
            } else if model.kind == .share {
                share
            } else {
                plot
                    .frame(height: context.density == .compact ? 120 : 140)
                    .accessibilityLabel(context.payload.envelope.summary ?? context.payload.title)
                    .accessibilityChartDescriptor(ChartAudioGraph(
                        title: context.payload.title, labels: xValues.indices.map(label), isContinuous: !isBar,
                        series: series.map { ($0.label, $0.values) }))
            }
            if let stats = model.stats, !stats.isEmpty {
                // Up to four facts under the plot: a quote's Open, High, Low and Volume (`Numbers.chartMarket`).
                Divider().overlay(Theme.hairline)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(stats.prefix(4).enumerated()), id: \.offset) { _, stat in
                        LabeledContent(stat.label, value: formatter.string(stat.value))
                            .labeledContentStyle(WidgetStatStyle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let note = model.note {
                Text(widgetLinking: note).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isBar: Bool { model.kind == .bar || model.kind == .stacked }

    @ChartContentBuilder
    private var marks: some ChartContent {
        if let baseline = model.baseline, !isBar {
            RectangleMark(yStart: .value("From", baseline.from), yEnd: .value("To", baseline.to))
                .foregroundStyle(Theme.controlFill)
                .annotation(position: .bottom, alignment: .leading) {
                    if let label = baseline.label { Text(label).font(.system(size: 9)).foregroundStyle(Theme.secondaryText) }
                }
        }
        ForEach(Array(series.enumerated()), id: \.offset) { seriesIndex, series in
            ForEach(Array(series.values.enumerated()), id: \.offset) { index, value in
                if let value {
                    if isBar {
                        BarMark(x: .value("x", label(index)), y: .value(series.label, value))
                            .foregroundStyle(barColor(index: index, series: seriesIndex, state: series.state))
                            .cornerRadius(3)
                            .annotation(position: .top, spacing: 3) {
                                // Bars have no y axis: the called-out bar carries its value (`chart.md`, callout).
                                if seriesIndex == 0, let callout = model.callout, xValues.firstIndex(of: callout.x) == index {
                                    Text(callout.label ?? formatter.string(yQuantity(value)))
                                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(Theme.primaryText)
                                }
                            }
                    } else {
                        let segment = segmentID(series: seriesIndex, index: index, values: series.values)
                        if model.kind == .area {
                            AreaMark(x: .value("x", index), y: .value(series.label, value), series: .value("segment", segment))
                                .foregroundStyle(lineColor(seriesIndex, state: series.state).opacity(0.18))
                        }
                        LineMark(x: .value("x", index), y: .value(series.label, value), series: .value("segment", segment))
                            .foregroundStyle(lineColor(seriesIndex, state: series.state))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                }
            }
        }
        if let target = model.target {
            // A target, or a quote's previous close ("Prev close 238.84"), as a dashed rule with its label.
            RuleMark(y: .value("Target", target.value))
                .foregroundStyle(Theme.secondaryText)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .bottom, alignment: .trailing, spacing: 2) {
                    if let label = target.label {
                        Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    }
                }
        }
        if let callout = model.callout, let index = xValues.firstIndex(of: callout.x), !isBar,
           let value = (series.first { $0.id == callout.series } ?? series.first)?.values[safe: index] ?? nil {
            PointMark(x: .value("x", index), y: .value("y", value))
                .foregroundStyle(Theme.ink)
                .symbolSize(30)
                .annotation(position: .top, alignment: .trailing) {
                    if let label = callout.label { pill(label) }
                }
        }
        if let selected, xValues.indices.contains(selected) {
            if isBar {
                RuleMark(x: .value("x", label(selected)))
                    .foregroundStyle(Theme.tertiaryText)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        pill(scrubText(selected))
                    }
            } else {
                RuleMark(x: .value("x", selected))
                    .foregroundStyle(Theme.tertiaryText)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        pill(scrubText(selected))
                    }
            }
        }
    }

    @ViewBuilder
    private var plot: some View {
        if isBar {
            Chart { marks }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            let text = value.as(String.self) ?? ""
                            Text(text).font(.system(size: 10, weight: text == calloutLabel ? .semibold : .regular))
                        }
                    }
                }
                .chartXSelection(value: Binding(get: { selected.map(label) }, set: { selected = $0.flatMap(index(ofLabel:)) }))
        } else {
            Chart { marks }
                .chartXScale(domain: 0...max(xValues.count - 1, 1))
                .chartYScale(domain: yDomain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel().font(.system(size: 10))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: tickIndices) { value in
                        AxisValueLabel {
                            if let index = value.as(Int.self) { Text(label(index)).font(.system(size: 10)) }
                        }
                    }
                }
                .chartXSelection(value: $selected)
        }
    }

    private var share: some View {
        let parts = model.parts ?? []
        let total = max(parts.compactMap { $0.value.value?.number }.reduce(0, +), 0.0001)
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        Rectangle()
                            .fill(shareColor(index))
                            .frame(width: max(2, proxy.size.width * CGFloat((part.value.value?.number ?? 0) / total) - 2))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(shareColor(index)).frame(width: 10, height: 10)
                    Text(part.label).font(WidgetFont.label)
                    Spacer(minLength: 6)
                    Text(formatter.string(part.value)).font(WidgetFont.label.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    Text(formatter.percent((part.value.value?.number ?? 0) / total, precision: 0))
                        .font(WidgetFont.label.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func shareColor(_ index: Int) -> Color {
        [Theme.ink, Theme.secondaryText, Theme.tertiaryText, Theme.controlFill][min(index, 3)]
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.inkForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.ink, in: Capsule())
    }

    private var calloutLabel: String? {
        model.callout.flatMap { callout in xValues.firstIndex(of: callout.x).map(label) }
    }

    private func barColor(index: Int, series: Int, state: ChartWidget.Series.State?) -> Color {
        if model.kind == .stacked { return lineColor(series, state: state) }
        if let state, state == .warning || state == .critical { return state == .critical ? Theme.danger : Theme.warning }
        let isCallout = model.callout.map { xValues.firstIndex(of: $0.x) == index } ?? (index == xValues.count - 1)
        return isCallout ? Theme.ink : Theme.secondaryText.opacity(0.55)
    }

    private func lineColor(_ index: Int, state: ChartWidget.Series.State?) -> Color {
        switch state {
        case .critical?: return Theme.danger
        case .warning?: return Theme.warning
        default: return [Theme.ink, Theme.secondaryText, Theme.tertiaryText][min(index, 2)]
        }
    }

    /// A line breaks at a gap (no reading), never bridging it: each run of values is its own segment.
    private func segmentID(series: Int, index: Int, values: [Double?]) -> String {
        let gaps = values.prefix(index).filter { $0 == nil }.count
        return "\(series)-\(gaps)"
    }

    private var yDomain: ClosedRange<Double> {
        let values = series.flatMap { $0.values.compactMap { $0 } } + [model.baseline?.from, model.baseline?.to, model.target?.value].compactMap { $0 }
        var low = model.y?.min ?? (values.min() ?? 0)
        let high = model.y?.max ?? (values.max() ?? 1)
        // A labelled target near the bottom ("Prev close 238.84") gets room under its rule for the label.
        if model.y?.min == nil, let target = model.target, target.label != nil, target.value <= low + (high - low) * 0.1 {
            low -= (high - low) * 0.12
        }
        return low...max(high, low + 1)
    }

    /// Three to five ticks: the first, the last and a few between.
    private var tickIndices: [Int] {
        let count = xValues.count
        guard count > 2 else { return Array(0..<count) }
        let step = max(1, (count - 1) / 3)
        var ticks = Array(stride(from: 0, to: count - 1, by: step))
        if (count - 1) - (ticks.last ?? 0) < step / 2 { ticks.removeLast() }
        return ticks + [count - 1]
    }

    private func label(_ index: Int) -> String {
        guard let raw = xValues[safe: index] else { return "" }
        switch model.x?.kind ?? .label {
        case .label: return raw
        case .date:
            if JSONSchemaValidator.parseDate(raw).map({ Calendar.current.isDateInToday(Calendar.current.date(from: $0) ?? .distantPast) }) == true {
                return String(localized: "Today")
            }
            if model.x?.unit == .month, let components = JSONSchemaValidator.parseDate(raw), let month = components.month {
                return Calendar.current.shortMonthSymbols[month - 1]
            }
            return formatter.date(raw).map { $0.split(separator: " ").suffix(2).joined(separator: " ") } ?? raw
        case .time:
            return formatter.time(raw) ?? raw
        }
    }

    private func index(ofLabel text: String) -> Int? {
        xValues.indices.first { label($0) == text }
    }

    /// A y value formatted as the axis, the callout and scrubbing read it.
    private func yQuantity(_ value: Double) -> WidgetQuantity {
        WidgetQuantity(
            value: .number(value), format: WidgetQuantity.Format(rawValue: model.y?.format.rawValue ?? "number") ?? .number,
            unit: model.y?.unit, currency: model.y?.currency, precision: model.y?.precision
        )
    }

    private func scrubText(_ index: Int) -> String {
        let values = series.map { series -> String in
            guard let value = series.values[safe: index] ?? nil else { return String(localized: "No reading") }
            let quantity = yQuantity(value)
            return series.label.isEmpty || self.series.count == 1 ? formatter.string(quantity) : "\(series.label) \(formatter.string(quantity))"
        }
        return ([label(index)] + values).joined(separator: " · ")
    }
}

// MARK: - calendar

/// Days with marks: a habit's weeks with a streak, a month with dated dots, or activity as
/// intensity (`Numbers.calendar`, `calendarMonth`, `calendarIntensity`).
struct CalendarBody: View {
    let model: CalendarWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = formatter.locale
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        switch model.weekStart {
        case .monday: calendar.firstWeekday = 2
        case .sunday: calendar.firstWeekday = 1
        case .locale: calendar.firstWeekday = Calendar.current.firstWeekday
        }
        return calendar
    }

    private var marks: [String: CalendarWidget.Mark] {
        Dictionary(model.marks.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var days: [Date] {
        guard let start = date(model.start), let end = date(model.end), start <= end else { return [] }
        var days: [Date] = []
        var day = start
        while day <= end, days.count < 400 {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? end.addingTimeInterval(1)
        }
        return days
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let streak = model.streak {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(streak.current)").font(WidgetFont.valueHero.monospacedDigit())
                    Text(streak.label ?? (streak.unit == .day ? String(localized: "day streak") : String(localized: "week streak")))
                        .font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 6)
                    if let best = streak.best {
                        Text("Best \(best)").font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if model.marks.isEmpty {
                WidgetEmpty(context: context, fallback: String(localized: "Nothing marked yet."))
            } else if model.style == .intensity {
                intensity
            } else {
                grid
            }
            legend
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var weeks: [[Date?]] {
        guard let first = days.first else { return [] }
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let cells: [Date?] = Array(repeating: nil, count: lead) + days.map { Optional($0) }
        return stride(from: 0, to: cells.count, by: 7).map { start in
            let week = Array(cells[start..<min(start + 7, cells.count)])
            return week + Array(repeating: nil, count: 7 - week.count)
        }
    }

    private var grid: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                GridRow {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        if let day { cell(day) } else { Color.clear.frame(height: 30) }
                    }
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private func cell(_ day: Date) -> some View {
        let key = isoDate(day)
        let mark = marks[key]
        let isToday = key == isoDate(.now)
        if model.view == .month || model.style == .dot {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(WidgetFont.label.monospacedDigit())
                    .foregroundStyle(isToday ? Theme.inkForeground : Theme.primaryText)
                    .frame(width: 26, height: 26)
                    .background(isToday ? Theme.ink : .clear, in: Circle())
                Circle().fill(mark.map(markColor) ?? .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(day, mark))
        } else {
            // `Numbers.calendar`: done days filled grey with a tick, a missed one outlined with a
            // dash, today in a bold ink outline, days to come faint.
            let isFuture = day > .now && !isToday
            let missed = mark?.status == .missed
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(mark != nil && !missed ? Theme.controlFill : isFuture ? Theme.controlFill.opacity(0.4) : Color.clear)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isToday ? Theme.ink : missed ? Theme.tertiaryText : Color.clear, lineWidth: isToday ? 2 : 1)
                if let mark {
                    Image(systemName: mark.status == .done ? "checkmark" : "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(mark.state == .neutral ? (missed ? Theme.secondaryText : Theme.primaryText) : markColor(mark))
                }
            }
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(day, mark))
        }
    }

    private var intensity: some View {
        HStack(alignment: .top, spacing: 3) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 3) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        let mark = day.flatMap { marks[isoDate($0)] }
                        RoundedRectangle(cornerRadius: 2)
                            .fill(day == nil ? .clear : intensityColor(mark?.level ?? (mark?.status == .done ? 1 : 0)))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(model.marks.filter { ($0.level ?? 0) > 0 || $0.status == .done }.count) active days from \(formatter.date(model.start) ?? model.start) to \(formatter.date(model.end) ?? model.end)"))
    }

    @ViewBuilder
    private var legend: some View {
        let labels = Array(Set(model.marks.compactMap(\.label))).sorted()
        if model.style == .intensity {
            HStack(spacing: 4) {
                Text("Less").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(intensityColor(level)).frame(width: 9, height: 9)
                }
                Text("More").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            }
            .accessibilityHidden(true)
        } else if model.view == .month, !labels.isEmpty, labels.count <= 4 {
            HStack(spacing: 10) {
                ForEach(labels, id: \.self) { label in
                    HStack(spacing: 4) {
                        Circle().fill(marks.values.first { $0.label == label }.map(markColor) ?? Theme.ink).frame(width: 5, height: 5)
                        Text(label).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func markColor(_ mark: CalendarWidget.Mark) -> Color {
        switch mark.state {
        case .critical: Theme.danger
        case .warning: Theme.warning
        case .info: Theme.info
        case .neutral: mark.status == .missed ? Theme.tertiaryText : Theme.ink
        }
    }

    private func intensityColor(_ level: Double) -> Color {
        level <= 0 ? Theme.controlFill : Theme.ink.opacity(0.25 + 0.75 * min(level, 1))
    }

    private func spoken(_ day: Date, _ mark: CalendarWidget.Mark?) -> String {
        let date = day.formatted(Date.FormatStyle(locale: formatter.locale, timeZone: calendar.timeZone).weekday(.wide).day().month(.wide))
        guard let mark else { return date }
        let status = switch mark.status {
        case .done: String(localized: "done")
        case .partial: String(localized: "partly done")
        case .missed: String(localized: "missed")
        }
        return [date, mark.label ?? status, mark.note].compactMap { $0 }.joined(separator: ", ")
    }

    private func date(_ raw: String) -> Date? {
        JSONSchemaValidator.parseDate(raw).flatMap { calendar.date(from: $0) }
    }

    private func isoDate(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - verdict

/// A judgement with its reasons: a pick, an is-it-safe check, or a scorecard, with every criterion
/// and how it is known (`Numbers.verdict`, `verdictSafe`, `verdictUnsafe`, `verdictUnverified`,
/// `verdictScore`).
struct VerdictBody: View {
    let model: VerdictWidget
    let context: WidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            outcome
            if let confidence = model.confidence {
                HStack(spacing: 8) {
                    Text("Confidence").font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { index in
                            Capsule().fill(index < confidence.level ? Theme.ink : Theme.controlFill).frame(width: 14, height: 4)
                        }
                    }
                    Text(confidence.word).font(WidgetFont.label.weight(.medium))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Confidence: \(confidence.word)"))
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.criteria.enumerated()), id: \.offset) { index, criterion in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    row(criterion)
                }
            }
            if let change = model.wouldChange {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What would change it").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                    Text(change).font(WidgetFont.label).foregroundStyle(Theme.primaryText).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var outcome: some View {
        let tone = WidgetTone(model.outcome.state)
        let filled = model.kind == .safety && (tone == .ok || tone == .critical)
        HStack(alignment: .top, spacing: 12) {
            if let grade = model.outcome.grade {
                Text(grade)
                    .font(WidgetFont.value)
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: 48, height: 48)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: model.kind == .decision ? "checkmark.seal.fill" : tone.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(model.kind == .decision ? Theme.primaryText : tone.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let score = model.outcome.score {
                    Text("\(WidgetFormatter.number(score.value, digits: nil)) / \(WidgetFormatter.number(score.max, digits: nil))")
                        .font(WidgetFont.value.monospacedDigit())
                }
                Text(model.outcome.label)
                    .font(model.outcome.score == nil ? WidgetFont.answer : WidgetFont.label.weight(.semibold))
                    .foregroundStyle(filled ? tone.color : Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = model.outcome.reason {
                    Text(widgetLinking: reason).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(filled ? tone.tint : Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous))
        .overlay {
            if tone.isDashed {
                RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous)
                    .strokeBorder(Theme.primaryText, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ criterion: VerdictWidget.Criterion) -> some View {
        let tone = criterion.tone
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: tone.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tone == .unverified ? Theme.primaryText : tone.color)
                    .accessibilityHidden(true)
                Text(criterion.label).font(WidgetFont.body).foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                if let score = criterion.score {
                    Text("\(WidgetFormatter.number(score.value, digits: nil))/\(WidgetFormatter.number(score.max, digits: nil))")
                        .font(WidgetFont.label.weight(.semibold).monospacedDigit())
                } else if let value = criterion.value {
                    Text(value)
                        .font(WidgetFont.label)
                        .foregroundStyle(tone == .critical ? Theme.danger : Theme.secondaryText)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let score = criterion.score {
                WidgetBar(fraction: score.value / max(score.max, 0.0001), height: 4)
            }
            if let note = criterion.note {
                Text(widgetLinking: note).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).padding(.leading, 20)
            }
            if let evidence = criterion.evidence {
                EvidenceLine(evidence: evidence).padding(.leading, 20)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([criterion.label, tone.word, criterion.value, criterion.note].compactMap { $0 }.joined(separator: ", "))
    }
}

private extension VerdictWidget.Criterion {
    var tone: WidgetTone {
        switch state {
        case .ok: .ok
        case .info: .info
        case .warning: .warning
        case .critical: .critical
        case .unverified: .unverified
        default: .neutral
        }
    }
}

private extension VerdictWidget.Confidence {
    var level: Int {
        switch self {
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    var word: String {
        switch self {
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        }
    }
}

// MARK: - scoreboard

/// Two to four sides with scores and a status: a match, a race, a poll or an A/B test
/// (`Numbers.scoreboard`, `scoreboardTest`).
struct ScoreboardBody: View {
    let model: ScoreboardWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine
            VStack(spacing: 8) {
                ForEach(Array(model.sides.enumerated()), id: \.offset) { _, side in
                    sideRow(side)
                }
            }
            if let significance = model.significance, let note = significance.note {
                Text(widgetLinking: note).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
            }
            if let note = model.note {
                Text(widgetLinking: note).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            switch model.status {
            case .live:
                StatusDot(color: Theme.danger, pulsing: true)
                Text([String(localized: "Live"), model.period].compactMap { $0 }.joined(separator: " · "))
                    .font(WidgetFont.label.weight(.semibold)).foregroundStyle(Theme.danger)
            case .final:
                Text(final).font(WidgetFont.label.weight(.semibold)).foregroundStyle(model.significance?.reached == true ? Theme.success : Theme.primaryText)
            case .scheduled:
                Text([String(localized: "Starts"), model.startsAt.flatMap { formatter.dateTime($0) }].compactMap { $0 }.joined(separator: " "))
                    .font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
            case .postponed:
                Text("Postponed").font(WidgetFont.label.weight(.semibold)).foregroundStyle(Theme.warning)
            }
            if let competition = model.competition {
                Text(competition).font(WidgetFont.label).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var final: String {
        if let significance = model.significance {
            let confidence = significance.confidence.map { " · " + String(localized: "\(formatter.percent($0, precision: 0)) confidence") } ?? ""
            return (significance.reached ? String(localized: "Finished") : String(localized: "Not conclusive")) + confidence
        }
        return [String(localized: "Final"), model.period].compactMap { $0 }.joined(separator: " · ")
    }

    private func sideRow(_ side: ScoreboardWidget.Side) -> some View {
        let isWinner = side.winner ?? (model.status == .final && side == leader)
        // The side in front reads bold and the others grey, live or final (`Numbers.scoreboard`).
        let isAhead = side.winner ?? (side == leader)
        let isBehind = leader != nil && !isAhead
        return HStack(spacing: 10) {
            Group {
                if let bot = side.bot {
                    WidgetBotFace(handle: bot, size: 28)
                } else {
                    Text(side.initials ?? String(side.name.prefix(2)).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 30, height: 30)
                        .background(Theme.canvas, in: Circle())
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(side.name).font(isAhead ? WidgetFont.title : WidgetFont.body).foregroundStyle(isBehind ? Theme.secondaryText : Theme.primaryText)
                if let detail = side.detail {
                    Text(widgetLinking: detail).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let delta = side.delta { DeltaLabel(delta: delta) }
            Text(formatter.string(side.score))
                .font((isAhead ? WidgetFont.value.weight(.bold) : WidgetFont.value.weight(.regular)).monospacedDigit())
                .foregroundStyle(isBehind ? Theme.secondaryText : Theme.primaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([side.name, formatter.string(side.score), isWinner ? String(localized: "winner") : nil, side.detail].compactMap { $0 }.joined(separator: ", "))
    }

    private var leader: ScoreboardWidget.Side? {
        let scored = model.sides.filter { $0.score.value?.number != nil }
        return model.better == .lower
            ? scored.min { ($0.score.value?.number ?? 0) < ($1.score.value?.number ?? 0) }
            : scored.max { ($0.score.value?.number ?? 0) < ($1.score.value?.number ?? 0) }
    }
}
