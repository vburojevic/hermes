import Charts
import HermesKit
import SwiftUI

// What Hermes Learned's pieces (`blocks/learned.elyx`). Content only: solid fills, never glass.

// MARK: - The story (`learnedHero`, `learningChart`)

/// The weekly chart: ink for skills, light grey for memories, newest week on the right. Swift Charts
/// gives VoiceOver its audio graph; the summary names the busiest week.
struct LearningChart: View {
    let weeks: [LearningWeek]
    let summary: String
    var height: CGFloat = 110

    private struct Bar: Identifiable {
        let week: LearningWeek
        let kind: String
        let count: Int
        var id: String { "\(week.start.timeIntervalSince1970)-\(kind)" }
    }

    private var bars: [Bar] {
        weeks.flatMap { week in
            [Bar(week: week, kind: "skills", count: week.skills), Bar(week: week, kind: "memories", count: week.memories)]
        }
    }

    /// Month names under the first week of each month.
    private var monthMarks: [Date] {
        var seen = Set<Int>()
        let calendar = LearningGraph.weekCalendar
        return weeks.map(\.start).filter { seen.insert(calendar.component(.month, from: $0)).inserted }
    }

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("Week", bar.week.start, unit: .weekOfYear),
                y: .value("Count", max(bar.count, 0)),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Kind", bar.kind))
            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
        }
        .chartForegroundStyleScale(["skills": Theme.ink, "memories": Theme.tertiaryText])
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: monthMarks) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.month(.abbreviated)))
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel(Text("Learned each week"))
        .accessibilityValue(Text(summary))
    }
}

/// The colour key: "■ Skills · 11   ■ Memories · 20".
struct LearningLegend: View {
    let skills: Int
    let memories: Int

    var body: some View {
        HStack(spacing: 22) {
            key(color: Theme.ink, text: String(localized: "Skills · \(skills)"))
            key(color: Theme.tertiaryText, text: String(localized: "Memories · \(memories)"))
        }
        .accessibilityElement(children: .combine)
    }

    private func key(color: Color, text: String) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// `learnedHero`: the sentence, the counts and the chart.
struct LearnedHero: View {
    let model: LearnedModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(compact ? model.shortStory : model.story)
                .font(compact ? .headline : .title3.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            LearningLegend(skills: model.skills.count, memories: model.memories.count)
            LearningChart(weeks: model.weeks, summary: model.chartSummary, height: compact ? 96 : 110)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

// MARK: - Rows (`learnedSkillRow`, `curatorMergeRow`, `curatorArchiveRow`)

/// A skill's glyph tile.
struct LearnedGlyph: View {
    let symbol: String

    // The tile stays 32 pt so rows line up; its glyph follows the text size up to it.
    var body: some View {
        Image(systemName: symbol)
            .font(.subheadline.weight(.medium))
            .imageScale(.small)
            .foregroundStyle(Theme.primaryText)
            .frame(width: 32, height: 32)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One learned skill: glyph, name, where it came from or how it's used, New / Stale.
struct LearnedSkillRow: View {
    enum Badge { case none, new, stale }

    let skill: LearningNode
    let subtitle: String
    var badge = Badge.none
    var symbol: String?

    var body: some View {
        HStack(spacing: 12) {
            LearnedGlyph(symbol: symbol ?? (badge == .new ? "sparkles" : SkillGlyph.symbol(name: skill.label, category: skill.category)))
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.label)
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch badge {
            case .new: TagLabel(title: String(localized: "New"), style: .ink)
            case .stale: TagLabel(title: String(localized: "Stale"), style: .warning)
            case .none: EmptyView()
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A merge or an archive from the last tidy, with Undo / Restore.
struct CuratorChangeRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let actionTitle: String
    var isBusy = false
    var isDone = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if isDone {
                Text("Restored")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
            } else if isBusy {
                // Undo or Restore the person tapped, on its way (`Spinner`: the app's own waiting).
                Spinner()
                    .accessibilityLabel(Text("\(actionTitle) on its way"))
            } else {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .cardButton()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - The curator (`curatorCard`)

/// On / paused, the schedule, the last tidy in a sentence with its counts, and Tidy Up Now.
struct CuratorCard: View {
    let model: LearnedModel
    var showsCounts = true

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 36
    @ScaledMetric(relativeTo: .subheadline) private var buttonHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wand.and.sparkles")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: iconSize, height: iconSize)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                    if model.tidyingIsOff {
                        // Off in config, not paused (`docs/setup.md` §4.10).
                        Text("Turned off in \(model.gatewayName)'s settings. Hermes still learns skills; nothing merges or archives them.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !model.schedule.isEmpty {
                        Text(model.schedule)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Tidying", isOn: Binding(
                    get: { !(model.curator?.paused ?? false) && !model.tidyingIsOff },
                    set: { on in
                        Task {
                            if on, model.tidyingIsOff { await model.turnOnTidying() } else { await model.setPaused(!on) }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.curator == nil)
                .accessibilityLabel("Tidying")
            }
            Text(model.lastTidySentence)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if showsCounts, let report = model.report, report.changedSomething {
                HStack(spacing: 8) {
                    count(report.merges.count, String(localized: "merged"))
                    count(report.archivedCount, String(localized: "archived"))
                    count(report.markedStaleCount, String(localized: "stale"))
                }
            }
            Button {
                Task { await model.tidyUpNow() }
            } label: {
                Group {
                    if model.isTidying {
                        // Hermes's work, not the app's: one shimmering line (`curatorCard`).
                        ShimmerText(text: String(localized: "Tidying \(model.learnerName)'s skills…"), tone: .row)
                    } else {
                        Label("Tidy Up Now", systemImage: "wand.and.sparkles")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.primaryText)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: buttonHeight)
                .background(model.isTidying ? Color.clear : Theme.surface, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .disabled(model.isTidying || !model.isOnline || model.tidyingIsOff)
            // PressableStyle doesn't dim a disabled button by itself.
            .opacity(!model.isOnline || model.tidyingIsOff ? 0.45 : 1)
        }
        .padding(16)
        .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var title: LocalizedStringKey {
        if model.tidyingIsOff { return "Tidying is off" }
        if model.curator?.paused == true { return "Tidying is paused" }
        return showsCounts ? "Tidying is on" : "Tidying"
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A white card holding rows with hairlines between them.
struct LearnedCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 16) }
                    subview
                }
            }
        }
        .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

extension View {
    /// The page's one prominent action (Open Skill): ink. On the Mac it follows the window,
    /// dropping the fill in an inactive one rather than leaving its label on nothing.
    func learnedPrimaryButton() -> some View {
        #if os(macOS)
        inkDefaultButton().buttonBorderShape(.capsule)
        #else
        inkFilledButton()
        #endif
    }
}

/// A pushed page's large title on the Mac, whose window doesn't show toolbar titles; nothing
/// elsewhere (the navigation bar has it).
struct LearnedMacTitle: View {
    let title: String

    var body: some View {
        #if os(macOS)
        Text(title)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(Theme.primaryText)
            .lineLimit(1)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
        #endif
    }
}

/// A section's small heading ("New This Week").
struct LearnedSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - The Mac's row actions

extension View {
    /// A skill row on the Mac: a hover fill, help, and a menu with what its page offers (Open
    /// Skill, Keep As Is, Use in a Chat). Archive stays on the page, where it's confirmed.
    func learnedSkillActions(model: LearnedModel, skill: LearningNode, open: @escaping () -> Void) -> some View {
        modifier(LearnedSkillActions(model: model, skill: skill, open: open))
    }
}

private struct LearnedSkillActions: ViewModifier {
    let model: LearnedModel
    let skill: LearningNode
    let open: () -> Void

    @State private var hovering = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .background(hovering ? Theme.controlFill : Color.clear)
            .onHover { hovering = $0 }
            .help(Text("Open \(skill.label)"))
            .contextMenu {
                Button("Open Skill", action: open)
                // A checked item, as the page's switch is.
                Toggle("Keep As Is", isOn: Binding(
                    get: { model.isPinned(skill) },
                    set: { pinned in Task { await model.setPinned(skill, pinned) } }
                ))
                .disabled(model.busy.contains(skill.id) || !model.isOnline)
                Button("Use in a Chat") { model.useInChat(skill) }
                    .disabled(skill.state == .archived)
            }
        #else
        content
        #endif
    }
}
