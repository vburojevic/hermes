import HermesKit
import SwiftUI

/// Tidying (`learnedTidying`): the curator's card (the switch pauses it; Tidy Up Now), what the
/// last tidy did with Undo and Restore, the rules, and every archived skill.
struct LearnedTidyingPage: View {
    let model: LearnedModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LearnedMacTitle(title: String(localized: "Tidying"))
                CuratorCard(model: model)
                lastTidy
                rules
                archivedList
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("Tidying")
        #if os(iOS)
        .toolbarTitleDisplayMode(.large)
        #endif
        .task {
            if model.curator == nil { await model.load() }
            await model.loadArchived()
        }
        .refreshable {
            await model.load()
            await model.loadArchived()
        }
        .modifier(LearnedMessages(model: model))
    }

    // MARK: Last tidy

    @ViewBuilder
    private var lastTidy: some View {
        if let report = model.report, report.changedSomething {
            LearnedSectionTitle(title: report.startedAt.map { String(localized: "Last Tidy · \($0.formatted(.dateTime.month(.abbreviated).day()))") } ?? String(localized: "Last Tidy"))
            LearnedCard {
                ForEach(report.mergeGroups, id: \.into) { group in
                    CuratorChangeRow(
                        symbol: "arrow.triangle.2.circlepath",
                        title: group.names.count == 1 ? String(localized: "Merged \(group.names[0]) into \(group.into)") : String(localized: "Merged \(group.names.count) skills into \(group.into)"),
                        subtitle: group.reason.isEmpty ? String(localized: "\(group.names.formatted(.list(type: .and))) overlapped") : group.reason,
                        actionTitle: String(localized: "Undo"),
                        isBusy: group.names.contains(where: model.busy.contains),
                        isDone: group.names.allSatisfy(model.restoredNames.contains)
                    ) {
                        Task { await model.restore(group.names) }
                    }
                    .accessibilityHint(Text("Restores the original skills"))
                }
                ForEach(report.archived) { removal in
                    CuratorChangeRow(
                        symbol: "archivebox",
                        title: String(localized: "Archived \(removal.name)"),
                        subtitle: removal.reason.isEmpty ? archivedWhy : removal.reason,
                        actionTitle: String(localized: "Restore"),
                        isBusy: model.busy.contains(removal.name),
                        isDone: model.restoredNames.contains(removal.name)
                    ) {
                        Task { await model.restore([removal.name]) }
                    }
                }
                ForEach(model.staleSkills) { skill in
                    NavigationLink(value: LearnedRoute.skill(skill.id)) {
                        LearnedSkillRow(skill: skill, subtitle: staleSubtitle(skill), badge: .stale)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if !model.staleSkills.isEmpty {
            LearnedSectionTitle(title: String(localized: "Stale"))
            LearnedCard {
                ForEach(model.staleSkills) { skill in
                    NavigationLink(value: LearnedRoute.skill(skill.id)) {
                        LearnedSkillRow(skill: skill, subtitle: staleSubtitle(skill), badge: .stale)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var archivedWhy: String {
        let days = model.curator?.archiveAfterDays ?? 90
        return String(localized: "Unused for over \(days) days")
    }

    private func staleSubtitle(_ skill: LearningNode) -> String {
        let archiveAfter = model.curator?.archiveAfterDays ?? 90
        guard let date = skill.date else { return String(localized: "Unused · archived after \(archiveAfter) days") }
        let days = max(0, Int(Date.now.timeIntervalSince(date) / 86_400))
        return String(localized: "Unused for \(days) days · archived after \(archiveAfter)")
    }

    // MARK: Rules

    private var rules: some View {
        VStack(alignment: .leading, spacing: 6) {
            LearnedSectionTitle(title: String(localized: "Rules"))
            LearnedCard {
                rule(String(localized: "Stale after"), String(localized: "\(model.curator?.staleAfterDays ?? 30) days unused"))
                rule(String(localized: "Archived after"), String(localized: "\(model.curator?.archiveAfterDays ?? 90) days unused"))
            }
            Text("Skills a task uses are never archived. Change the rules on \(model.gatewayName) in the curator's settings.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16)
        }
    }

    private func rule(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.primaryText)
            Spacer()
            Text(value).foregroundStyle(Theme.secondaryText)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    // MARK: Archived

    @ViewBuilder
    private var archivedList: some View {
        if let archived = model.archived, !archived.isEmpty {
            LearnedSectionTitle(title: String(localized: "Archived · \(archived.count)"))
            LearnedCard {
                ForEach(archived, id: \.self) { name in
                    CuratorChangeRow(
                        symbol: "archivebox",
                        title: name,
                        subtitle: String(localized: "Archived, kept on \(model.gatewayName)"),
                        actionTitle: String(localized: "Restore"),
                        isBusy: model.busy.contains(name),
                        isDone: model.restoredNames.contains(name)
                    ) {
                        Task { await model.restore([name]) }
                    }
                }
            }
        } else if model.archived != nil {
            Text("No archived skills.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16)
        }
    }
}
