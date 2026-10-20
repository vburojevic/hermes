import HermesKit
import SwiftUI

// The Collections family (`widgets/collections.elyx`): list, checklist, table, details, outline, diff.

// MARK: - list

/// Rows of things: plain, ranked, a digest in groups, or lanes (`Collections.list`, `listRanked`,
/// `listDigest`, `listLanes`).
struct ListBody: View {
    let model: ListWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The first rows, then Show all (three in a stack).
    private var shownCount: Int { context.density == .compact ? 3 : 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let counts = model.counts, !counts.isEmpty { countsLine(counts) }
            if model.items.isEmpty {
                WidgetEmpty(context: context, fallback: String(localized: "Nothing here right now."))
            } else if model.layout == .lanes, let groups = model.groups, showsLanes {
                lanes(groups)
            } else if let groups = model.groups, !groups.isEmpty {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    let rows = visibleItems.filter { $0.group == group.id }
                    if !rows.isEmpty {
                        groupHeading(group, count: rows.count)
                        rowList(rows)
                    }
                }
            } else {
                rowList(visibleItems)
            }
            if filteredItems.count > shownCount {
                ShowAllButton(total: filteredItems.count, isExpanded: context.view.showsAll) {
                    withAnimation(.spring(response: 0.3)) { context.updateView { $0.showsAll.toggle() } }
                }
            }
        }
    }

    private var showsLanes: Bool {
        #if os(macOS)
        !typeSize.isAccessibilitySize
        #else
        sizeClass == .regular && !typeSize.isAccessibilitySize && context.density == .regular
        #endif
    }

    /// The filter chips pick a group (`filter: true`), on this device only.
    private var filteredItems: [ListWidget.Item] {
        guard model.filter, let group = context.view.filter else { return model.items }
        return model.items.filter { $0.group == group }
    }

    private var visibleItems: [ListWidget.Item] {
        context.view.showsAll ? filteredItems : Array(filteredItems.prefix(shownCount))
    }

    private func countsLine(_ counts: [ListWidget.Count]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(counts.enumerated()), id: \.offset) { _, count in
                let selected = model.filter && count.group != nil && context.view.filter == count.group
                Button {
                    guard model.filter, let group = count.group else { return }
                    context.updateView { $0.filter = $0.filter == group ? nil : group }
                } label: {
                    Text("\(count.value) \(count.label)")
                        .font(WidgetFont.caption.weight(.semibold))
                        .foregroundStyle(selected ? Theme.inkForeground : Theme.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 24)
                        .background(selected ? Theme.ink : Theme.controlFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!model.filter || count.group == nil)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: model.filter ? .contain : .combine)
    }

    private func groupHeading(_ group: ListWidget.Group, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(group.title).font(WidgetFont.label.weight(.semibold)).foregroundStyle(Theme.primaryText)
            Text("\(group.count ?? count)").font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 2)
        .accessibilityAddTraits(.isHeader)
    }

    private func rowList(_ rows: [ListWidget.Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider().overlay(Theme.hairline) }
                row(item)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ListWidget.Item) -> some View {
        let content = rowContent(item)
        Group {
            if let url = item.url {
                Button { context.open(url) } label: { content }
                    .buttonStyle(PressableStyle())
                    .accessibilityHint(String(localized: "Opens \(URL(string: url)?.host(percentEncoded: true) ?? url)"))
            } else {
                content
            }
        }
        .contextMenu {
            ForEach(item.actions ?? [], id: \.id) { action in
                Button(action.label) { context.perform(action, item: (item.id ?? item.title, item.title)) }
            }
        }
        .rowActions(item.actions, item: (item.id ?? item.title, item.title), context: context)
    }

    private func rowContent(_ item: ListWidget.Item) -> some View {
        let gone = item.tags?.contains { $0.state == .removed } == true
        let stacked = typeSize.isAccessibilitySize
        return HStack(alignment: .center, spacing: 10) {
            if model.layout == .ranked, let rank = item.rank {
                Text("\(rank)")
                    .font(WidgetFont.valueSmall.monospacedDigit())
                    .frame(minWidth: 24, alignment: .leading)
            } else if let leading = item.leading {
                WidgetLeadingView(leading: leading, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(WidgetFont.body)
                    .foregroundStyle(Theme.primaryText)
                    .strikethrough(gone)
                    .lineLimit(2)
                if let subtitle = subtitle(item) {
                    Text(widgetLinking: subtitle).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
                if stacked { trailing(item) }
                if let actions = item.actions, !actions.isEmpty {
                    #if os(macOS)
                    RowActions(actions: actions, item: (item.id ?? item.title, item.title), context: context)
                    #endif
                }
            }
            Spacer(minLength: 8)
            if !stacked { trailing(item) }
        }
        .padding(.vertical, 8)
        .frame(minHeight: context.density.rowHeight)
        .opacity(gone ? 0.6 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(item))
    }

    @ViewBuilder
    private func trailing(_ item: ListWidget.Item) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let previous = item.previous {
                Text(formatter.string(previous))
                    .font(WidgetFont.caption.monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                    .strikethrough()
            }
            if let value = item.value {
                Text(formatter.string(value))
                    .font(WidgetFont.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(value.value == nil ? Theme.tertiaryText : Theme.primaryText)
            }
            if let delta = item.delta { DeltaLabel(delta: delta) }
            if let movement = item.movement { movementLabel(movement) }
            if let tags = item.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(tags.prefix(2).enumerated()), id: \.offset) { _, tag in WidgetTagView(tag: tag) }
                }
            }
        }
    }

    @ViewBuilder
    private func movementLabel(_ movement: ListWidget.Item.Movement) -> some View {
        if movement.new == true {
            WidgetTagView(tag: WidgetTag(label: String(localized: "New"), state: .new))
        } else if let rank = movement.previous {
            HStack(spacing: 2) {
                Text(movement.good == .up ? "▲" : movement.good == .down ? "▼" : "=").font(.system(size: 8))
                Text("\(rank)").font(WidgetFont.caption.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(movement.good == .up ? Theme.success : movement.good == .down ? Theme.danger : Theme.secondaryText)
        }
    }

    private func subtitle(_ item: ListWidget.Item) -> String? {
        let time = item.at.flatMap { formatter.relative($0) }
        let parts = [item.subtitle, time].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func spoken(_ item: ListWidget.Item) -> String {
        var parts: [String] = []
        if model.layout == .ranked, let rank = item.rank { parts.append("\(rank)") }
        parts.append(item.title)
        if let subtitle = subtitle(item) { parts.append(subtitle) }
        if let value = item.value { parts.append(formatter.string(value)) }
        if let previous = item.previous { parts.append(String(localized: "was \(formatter.string(previous))")) }
        if let delta = item.delta { parts.append(formatter.delta(delta).spoken) }
        if let movement = item.movement {
            if movement.new == true { parts.append(String(localized: "new")) } else if let previous = movement.previous {
                parts.append(movement.good == .up ? String(localized: "up from \(previous)") : movement.good == .down ? String(localized: "down from \(previous)") : String(localized: "was \(previous)"))
            }
        }
        parts += item.tags?.map(\.label) ?? []
        return parts.joined(separator: ", ")
    }

    private func lanes(_ groups: [ListWidget.Group]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                let rows = model.items.filter { $0.group == group.id }
                VStack(alignment: .leading, spacing: 6) {
                    groupHeading(group, count: rows.count)
                    ForEach(Array(rows.prefix(context.view.showsAll ? rows.count : 3).enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(WidgetFont.label).foregroundStyle(Theme.primaryText).lineLimit(2)
                            if let subtitle = subtitle(item) {
                                Text(widgetLinking: subtitle).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                            }
                            if let tags = item.tags, !tags.isEmpty {
                                HStack(spacing: 4) { ForEach(Array(tags.prefix(2).enumerated()), id: \.offset) { _, tag in WidgetTagView(tag: tag) } }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(spoken(item))
                    }
                    if rows.count > 3, !context.view.showsAll {
                        Text("+\(rows.count - 3) more").font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - checklist

/// Items the person ticks off; a tick is a request the agent confirms (`Collections.checklist`,
/// `checklistMeds`, `checklistTasks`, `checklistPending`).
struct ChecklistBody: View {
    let model: ChecklistWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    private var ticks: ChecklistTicks? { context.host?.store.ticks[context.payload.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.items.isEmpty {
                WidgetEmpty(context: context, fallback: String(localized: "Nothing on the list."))
            } else {
                if model.progress == .bar {
                    WidgetBar(fraction: Double(doneCount) / Double(max(model.items.count, 1)), height: 4)
                        .accessibilityHidden(true)
                }
                if let groups = model.groups, !groups.isEmpty {
                    let shownGroups = context.view.showsAll ? groups : Array(groups.prefix(2))
                    ForEach(Array(shownGroups.enumerated()), id: \.offset) { _, group in
                        let items = model.items.filter { $0.group == group.id }
                        if !items.isEmpty {
                            HStack(spacing: 6) {
                                Text(group.title).font(WidgetFont.label.weight(.semibold))
                                Text("\(items.filter(isChecked).count) of \(items.count)").font(WidgetFont.label).foregroundStyle(Theme.secondaryText)
                            }
                            .padding(.top, 4)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                            itemList(items)
                        }
                    }
                    let ungrouped = model.items.filter { item in !groups.contains { $0.id == item.group } }
                    if !ungrouped.isEmpty { itemList(ungrouped) }
                    if groups.count > 2 {
                        Button {
                            withAnimation(.spring(response: 0.3)) { context.updateView { $0.showsAll.toggle() } }
                        } label: {
                            HStack(spacing: 4) {
                                Text(context.view.showsAll ? String(localized: "Show fewer groups") : String(localized: "Show \(groups.count - 2) more groups"))
                                Image(systemName: context.view.showsAll ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                            }
                            .font(WidgetFont.label.weight(.medium))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(minHeight: 32)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    itemList(model.items)
                }
                if let ticks, !ticks.unsent.isEmpty {
                    Label(String(localized: "Saving \(ticks.unsent.count) ticks…"), systemImage: "hourglass")
                        .font(WidgetFont.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private var doneCount: Int { model.items.filter(isChecked).count }

    private func isChecked(_ item: ChecklistWidget.Item) -> Bool {
        ticks?.isChecked(item) ?? item.checked
    }

    private func itemList(_ items: [ChecklistWidget.Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 34) }
                row(item)
            }
        }
    }

    private func row(_ item: ChecklistWidget.Item) -> some View {
        let checked = isChecked(item)
        let pending = ticks?.isPending(item.id) == true
        let canTick = context.canAnswer || isBatchable
        return HStack(alignment: .top, spacing: 12) {
            Button {
                context.host?.tick(item.id, in: context.payload)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(checked ? Color.clear : Theme.tertiaryText, lineWidth: 1.5)
                        .background(Circle().fill(checked ? Theme.ink : .clear))
                    if checked {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.inkForeground)
                    }
                }
                .frame(width: 22, height: 22)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canTick)
            .padding(.horizontal, -11)
            .padding(.vertical, -8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(WidgetFont.body)
                    .foregroundStyle(checked ? Theme.secondaryText : Theme.primaryText)
                    .strikethrough(checked)
                if let detail = detail(item) {
                    Text(widgetLinking: detail).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                }
                if let evidence = item.evidence { EvidenceLine(evidence: evidence) }
                if typeSize.isAccessibilitySize { tags(item) }
            }
            Spacer(minLength: 6)
            if pending {
                Image(systemName: "hourglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            }
            if !typeSize.isAccessibilitySize { tags(item) }
        }
        .padding(.vertical, 8)
        .contextMenu {
            ForEach(item.actions ?? [], id: \.id) { action in
                Button(action.label) { context.perform(action, item: (item.id, item.label)) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.label, detail(item), item.tags?.map(\.label).joined(separator: ", ")].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue((checked ? String(localized: "checked") : String(localized: "not checked")) + (pending ? ", " + String(localized: "not confirmed yet") : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if canTick { context.host?.tick(item.id, in: context.payload) } }
        .rowActions(item.actions, item: (item.id, item.label), context: context)
    }

    /// Ticks keep working while a batch waits: they're the person's own list.
    private var isBatchable: Bool {
        switch context.interaction {
        case .sending, .waiting(_, true, _), .noAnswer: true
        default: false
        }
    }

    @ViewBuilder
    private func tags(_ item: ChecklistWidget.Item) -> some View {
        if let tags = item.tags, !tags.isEmpty {
            HStack(spacing: 4) { ForEach(Array(tags.prefix(2).enumerated()), id: \.offset) { _, tag in WidgetTagView(tag: tag) } }
        }
    }

    private func detail(_ item: ChecklistWidget.Item) -> String? {
        let due = item.due.flatMap { raw in raw.count == 10 ? formatter.date(raw) : formatter.dateTime(raw) }.map { String(localized: "Due \($0)") }
        let parts = [item.detail, due, item.assignee?.name].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - table

/// A small grid of values, sortable on the device; reflowed into blocks when it doesn't fit
/// (`Collections.table`, `tableReflow`).
struct TableBody: View {
    let model: TableWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if model.rows.isEmpty {
            WidgetEmpty(context: context, fallback: String(localized: "No rows yet."))
        } else if typeSize.isAccessibilitySize {
            reflowed
        } else {
            // Spelled-out candidates: never a lazy ForEach inside ViewThatFits.
            ViewThatFits(in: .horizontal) {
                TableGrid(model: model, rows: sortedRows, formatter: formatter, sort: context.view.sortKey, ascending: context.view.sortAscending) { key in
                    sortBy(key)
                }
                reflowed
            }
        }
    }

    private var sortedRows: [[String: WidgetCell]] {
        guard let key = context.view.sortKey, model.sortable else { return model.rows }
        let ascending = context.view.sortAscending
        return model.rows.sorted { lhs, rhs in
            let left = lhs[key]?.value, right = rhs[key]?.value
            switch (left, right) {
            case (.number(let a)?, .number(let b)?): return ascending ? a < b : a > b
            case (.string(let a)?, .string(let b)?): return ascending ? a.localizedStandardCompare(b) == .orderedAscending : a.localizedStandardCompare(b) == .orderedDescending
            case (nil, _), (.null?, _): return false
            default: return true
            }
        }
    }

    private func sortBy(_ key: String) {
        guard model.sortable else { return }
        context.updateView { view in
            if view.sortKey == key { view.sortAscending.toggle() } else { view.sortKey = key; view.sortAscending = false }
        }
    }

    private var reflowed: some View {
        let rows = context.view.showsAll ? sortedRows : Array(sortedRows.prefix(2))
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    if let first = model.columns.first {
                        Text(TableGrid.text(row[first.key], first, formatter)).font(WidgetFont.title)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        ForEach(Array(model.columns.dropFirst().enumerated()), id: \.offset) { _, column in
                            GridRow {
                                Text(column.label).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                                TableGrid.cell(row[column.key], column, formatter)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                Divider().overlay(Theme.hairline)
            }
            if sortedRows.count > 2 {
                ShowAllButton(total: sortedRows.count, isExpanded: context.view.showsAll) {
                    context.updateView { $0.showsAll.toggle() }
                }
            }
        }
    }
}

/// The table as columns. A plain struct built with its rows, so `ViewThatFits` can measure it.
private struct TableGrid: View {
    let model: TableWidget
    let rows: [[String: WidgetCell]]
    let formatter: WidgetFormatter
    let sort: String?
    let ascending: Bool
    let onSort: (String) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                    // The first column takes the room the others leave, so the table spans the card.
                    header(column, isFirst: index == 0)
                        .frame(maxWidth: index == 0 ? .infinity : nil, alignment: .leading)
                }
            }
            .padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().overlay(Theme.hairline).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                        Self.cell(row[column.key], column, formatter, isTitle: index == 0)
                            .gridColumnAlignment(Self.alignment(column, isFirst: index == 0))
                    }
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(row))
            }
            if let total = model.total {
                Rectangle().fill(Theme.primaryText.opacity(0.4)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                        Group {
                            if index == 0 {
                                Text("Total").font(WidgetFont.body.weight(.semibold))
                            } else {
                                Self.cell(total[column.key], column, formatter).fontWeight(.semibold)
                            }
                        }
                    }
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Total") + ". " + spoken(total, skipsFirst: true))
            }
        }
    }

    private func header(_ column: TableWidget.Column, isFirst: Bool) -> some View {
        Button {
            onSort(column.key)
        } label: {
            HStack(spacing: 2) {
                Text(column.label).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                if sort == column.key {
                    Image(systemName: ascending ? "arrow.up" : "arrow.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.sortable)
        .gridColumnAlignment(Self.alignment(column, isFirst: isFirst))
        .accessibilityLabel(sort == column.key ? String(localized: "\(column.label), sorted \(ascending ? String(localized: "ascending") : String(localized: "descending"))") : column.label)
    }

    static func alignment(_ column: TableWidget.Column, isFirst: Bool) -> HorizontalAlignment {
        switch column.align {
        case .start?: .leading
        case .center?: .center
        case .end?: .trailing
        case nil: isFirst || column.format == .text ? .leading : .trailing
        }
    }

    @ViewBuilder
    static func cell(_ cell: WidgetCell?, _ column: TableWidget.Column, _ formatter: WidgetFormatter, isTitle: Bool = false) -> some View {
        if column.format == .delta, case .number(let value)? = cell?.value {
            DeltaLabel(delta: delta(value, column), font: WidgetFont.label.weight(.semibold))
        } else if let state = cell?.state {
            WidgetTagView(tag: WidgetTag(label: text(cell, column, formatter), state: state))
        } else {
            Text(widgetLinking: text(cell, column, formatter))
                .font((isTitle ? WidgetFont.body.weight(.semibold) : WidgetFont.body).monospacedDigit())
                .fontDesign(column.mono ? .monospaced : .default)
                .foregroundStyle(cell?.value == nil ? Theme.tertiaryText : Theme.primaryText)
                .lineLimit(column.width == .wide ? 3 : 2)
        }
    }

    static func text(_ cell: WidgetCell?, _ column: TableWidget.Column, _ formatter: WidgetFormatter) -> String {
        if let display = cell?.display { return display }
        guard let value = cell?.value else { return WidgetFormatter.unknown }
        let format = WidgetQuantity.Format(rawValue: column.format.rawValue) ?? .number
        return formatter.string(WidgetQuantity(value: value, format: format, unit: column.unit, currency: column.currency, precision: column.precision))
    }

    static func delta(_ value: Double, _ column: TableWidget.Column) -> WidgetDelta {
        let format = WidgetDelta.Format(rawValue: column.deltaFormat.rawValue) ?? .percent
        let good = WidgetDelta.Good(rawValue: column.good?.rawValue ?? "neutral") ?? .neutral
        return WidgetDelta(value: value, format: format, currency: column.currency, good: good)
    }

    private func spoken(_ row: [String: WidgetCell], skipsFirst: Bool = false) -> String {
        model.columns.enumerated().compactMap { index, column -> String? in
            if index == 0 { return skipsFirst ? nil : Self.text(row[column.key], column, formatter) }
            if column.format == .delta, case .number(let value)? = row[column.key]?.value {
                return "\(column.label), \(formatter.delta(Self.delta(value, column)).spoken)"
            }
            return "\(column.label), \(Self.text(row[column.key], column, formatter))"
        }.joined(separator: ". ")
    }
}

// MARK: - details

/// Labelled values about one thing, in sections, with mono values and Copy
/// (`Collections.details`, `detailsSections`).
struct DetailsBody: View {
    let model: DetailsWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(model.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 0) {
                    if let title = section.title {
                        Text(title)
                            .font(WidgetFont.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(Array(section.fields.enumerated()), id: \.offset) { index, field in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        row(field)
                    }
                }
            }
        }
    }

    private func row(_ field: DetailsWidget.Section.Field) -> some View {
        let value = field.value.map { $0.string(formatter) } ?? WidgetFormatter.unknown
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        return layout {
            Text(field.label).font(WidgetFont.body).foregroundStyle(Theme.secondaryText)
            if !stacked { Spacer(minLength: 10) }
            VStack(alignment: stacked ? .leading : .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    if let state = field.state {
                        WidgetTagView(tag: WidgetTag(label: value, state: WidgetTag.State(rawValue: state.rawValue) ?? .neutral))
                    } else if let url = field.url {
                        Button(value) { context.open(url) }
                            .font(WidgetFont.body)
                            .foregroundStyle(Theme.link)
                            .buttonStyle(.plain)
                    } else if field.mono {
                        // Codes stay on one line, a size down, so an IBAN reads in its groups
                        // (`Collections.details`).
                        Text(value)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(field.value == nil ? Theme.tertiaryText : Theme.primaryText)
                            .lineLimit(stacked ? nil : 1)
                            .minimumScaleFactor(0.75)
                            .textSelection(.enabled)
                    } else {
                        Text(value)
                            .font(field.emphasis ? WidgetFont.valueSmall.monospacedDigit() : WidgetFont.body.monospacedDigit())
                            .foregroundStyle(field.value == nil ? Theme.tertiaryText : Theme.primaryText)
                            .multilineTextAlignment(stacked ? .leading : .trailing)
                            .textSelection(.enabled)
                    }
                    if field.copy, !field.masked, field.value != nil {
                        Button {
                            context.copy(value)
                        } label: {
                            Image(systemName: "square.on.square").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Copy \(field.label)"))
                    }
                }
                if let detail = field.detail {
                    Text(detail).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).multilineTextAlignment(stacked ? .leading : .trailing)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(field.label), \(field.masked ? String(localized: "ending in \(value.filter(\.isNumber).suffix(4))") : value)")
    }
}

// MARK: - outline

/// A tree up to four levels deep: a plan with progress, or files with what changed; branches
/// fold on the device (`Collections.outline`, `outlineFiles`).
struct OutlineBody: View {
    let model: OutlineWidget
    let context: WidgetContext

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if model.nodes.isEmpty {
            WidgetEmpty(context: context, fallback: model.mode == .files ? String(localized: "No files changed.") : String(localized: "No plan yet."))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(flattened.enumerated()), id: \.offset) { _, entry in
                    row(entry.node, path: entry.path, level: entry.level)
                }
            }
        }
    }

    private struct Entry {
        let node: OutlineWidget.Node
        let path: String
        let level: Int
    }

    /// The visible nodes, in order: a folded branch hides its children (a running one never folds).
    private var flattened: [Entry] {
        var entries: [Entry] = []
        func walk(_ nodes: [OutlineWidget.Node], parent: String, level: Int) {
            for (index, node) in nodes.enumerated() where level < 4 {
                let path = parent + "/" + (node.id ?? "\(index)")
                entries.append(Entry(node: node, path: path, level: level))
                if let children = node.children, !children.isEmpty, isOpen(node, path: path) {
                    walk(children, parent: path, level: level + 1)
                }
            }
        }
        walk(model.nodes, parent: "", level: 0)
        return entries
    }

    private func isOpen(_ node: OutlineWidget.Node, path: String) -> Bool {
        if node.state == .running || containsRunning(node) { return true }
        let toggled = context.view.expanded.contains(path)
        return node.folded ? toggled : !toggled
    }

    private func containsRunning(_ node: OutlineWidget.Node) -> Bool {
        (node.children ?? []).contains { $0.state == .running || containsRunning($0) }
    }

    private func row(_ node: OutlineWidget.Node, path: String, level: Int) -> some View {
        let isBranch = !(node.children ?? []).isEmpty
        let open = isBranch && isOpen(node, path: path)
        let indent = CGFloat(level) * (typeSize.isAccessibilitySize ? 12 : 22)
        return HStack(alignment: .top, spacing: 6) {
            Group {
                if isBranch {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            context.updateView { view in
                                if view.expanded.contains(path) { view.expanded.remove(path) } else { view.expanded.insert(path) }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityLabel(open ? String(localized: "Collapse") : String(localized: "Expand"))
                } else {
                    Color.clear.frame(width: 22, height: 22)
                }
            }
            glyph(node, isBranch: isBranch)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(node.label)
                        .font(model.mode == .files ? WidgetFont.mono : (level == 0 ? WidgetFont.body.weight(.semibold) : WidgetFont.body))
                        .strikethrough(node.change == .deleted)
                        .foregroundStyle(Theme.primaryText)
                    if !open, isBranch, let count = node.children?.count {
                        Text("\(count)").font(WidgetFont.caption).foregroundStyle(Theme.tertiaryText)
                    }
                }
                if let detail = node.detail {
                    Text(widgetLinking: detail).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 6)
            if let change = node.change {
                WidgetTagView(tag: WidgetTag(label: change.word, state: change.tagState))
            }
        }
        .padding(.leading, indent)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .onTapGesture { if let url = node.url { context.open(url) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(node, level: level, isBranch: isBranch, open: open))
        .accessibilityAddTraits(node.url != nil ? .isButton : [])
    }

    @ViewBuilder
    private func glyph(_ node: OutlineWidget.Node, isBranch: Bool) -> some View {
        if model.mode == .files {
            Image(systemName: isBranch ? "folder.fill" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18, height: 22)
        } else if let state = node.state.flatMap({ WidgetProgress(rawValue: $0.rawValue) }) {
            Image(systemName: state == .running ? "circle.lefthalf.filled" : state.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state.color)
                .frame(width: 18, height: 22)
        } else {
            WidgetGlyph(name: node.glyph, fallback: "circle", size: 11, color: Theme.secondaryText)
        }
    }

    private func spoken(_ node: OutlineWidget.Node, level: Int, isBranch: Bool, open: Bool) -> String {
        var parts = [node.label]
        if let state = node.state.flatMap({ WidgetProgress(rawValue: $0.rawValue) }) { parts.append(state.word) }
        if let change = node.change { parts.append(change.word) }
        if let detail = node.detail { parts.append(detail) }
        parts.append(String(localized: "level \(level + 1)"))
        if isBranch, !open { parts.append(String(localized: "collapsed, \(node.children?.count ?? 0) items")) }
        return parts.joined(separator: ", ")
    }
}

private extension OutlineWidget.Node.Change {
    var word: String {
        switch self {
        case .added: String(localized: "Added")
        case .modified: String(localized: "Modified")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        }
    }

    var tagState: WidgetTag.State {
        switch self {
        case .added: .ok
        case .modified: .warning
        case .deleted: .critical
        case .renamed: .info
        }
    }
}

// MARK: - diff

/// What changed: fields before and after, or a passage with removed and added words
/// (`Collections.diff`, `diffText`).
struct DiffBody: View {
    let model: DiffWidget
    let context: WidgetContext

    @Environment(\.widgetFormatter) private var formatter

    var body: some View {
        if model.mode == .text, let text = model.text {
            textDiff(text)
        } else if let rows = model.rows, !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    valueRow(row)
                }
            }
        } else {
            WidgetEmpty(context: context, fallback: String(localized: "No changes."))
        }
    }

    private func valueRow(_ row: DiffWidget.Row) -> some View {
        let before = row.before?.string(formatter)
        let after = row.after?.string(formatter)
        // The label in a fixed column, the values left-aligned beside it, the change at the edge (`Things.diff`).
        return HStack(alignment: .center, spacing: 10) {
            Text(row.label).font(WidgetFont.body).foregroundStyle(Theme.secondaryText)
                .frame(width: context.density == .compact ? 80 : 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if row.change != .added {
                    Text(before ?? WidgetFormatter.unknown)
                        .font(WidgetFont.caption.monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                        .strikethrough(row.change != .added)
                }
                if row.change != .removed {
                    Text(after ?? WidgetFormatter.unknown)
                        .font(WidgetFont.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(row.after == nil ? Theme.tertiaryText : Theme.primaryText)
                }
                if let note = row.note { Text(widgetLinking: note).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText) }
            }
            Spacer(minLength: 8)
            if let delta = row.delta {
                DeltaLabel(delta: delta)
            } else if let tag = row.tag {
                WidgetTagView(tag: tag)
            } else if row.change == .added {
                WidgetTagView(tag: WidgetTag(label: String(localized: "New"), state: .new))
            } else if row.change == .removed {
                WidgetTagView(tag: WidgetTag(label: String(localized: "Removed"), state: .removed))
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(row, before: before, after: after))
    }

    private func spoken(_ row: DiffWidget.Row, before: String?, after: String?) -> String {
        var parts = [row.label]
        switch row.change {
        case .added: parts.append(String(localized: "new, \(after ?? String(localized: "not known"))"))
        case .removed: parts.append(String(localized: "removed, was \(before ?? String(localized: "not known"))"))
        case .changed: parts.append(String(localized: "\(after ?? String(localized: "not known")), was \(before ?? String(localized: "not known"))"))
        }
        if let delta = row.delta { parts.append(formatter.delta(delta).spoken) }
        if let note = row.note { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    private func textDiff(_ text: DiffWidget.Text) -> some View {
        let segments = WordDiff.diff(text.before, text.after)
        var attributed = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text)
            switch segment.kind {
            case .same: break
            case .removed:
                part.foregroundColor = Theme.danger
                part.strikethroughStyle = .single
            case .added:
                part.foregroundColor = Theme.success
                part.underlineStyle = .single
            }
            attributed += part
        }
        let changed = segments.contains { $0.kind != .same }
        return VStack(alignment: .leading, spacing: 6) {
            if changed {
                Text(attributed)
                    .font(WidgetFont.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .widgetWell(padding: 12)
                    .accessibilityLabel(String(localized: "Removed: \(segments.filter { $0.kind == .removed }.map(\.text).joined(separator: " ")). Added: \(segments.filter { $0.kind == .added }.map(\.text).joined(separator: " "))."))
                HStack(spacing: 12) {
                    Text("Removed").strikethrough().foregroundStyle(Theme.danger)
                    Text("Added").underline().foregroundStyle(Theme.success)
                }
                .font(WidgetFont.caption)
                .accessibilityHidden(true)
            } else {
                WidgetEmpty(context: context, fallback: String(localized: "No changes."))
            }
        }
    }
}
