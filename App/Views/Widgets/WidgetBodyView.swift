import HermesKit
import SwiftUI

/// Every primitive's body, by type: the renderer registry (`docs/widgets.md` §9). The switch is
/// exhaustive, so a type without a renderer doesn't build.
struct WidgetBodyView: View {
    let context: WidgetContext

    var body: some View {
        switch context.payload.content {
        case .metric(let model): MetricBody(model: model, context: context)
        case .meter(let model): MeterBody(model: model, context: context)
        case .chart(let model): ChartBody(model: model, context: context)
        case .calendar(let model): CalendarBody(model: model, context: context)
        case .verdict(let model): VerdictBody(model: model, context: context)
        case .scoreboard(let model): ScoreboardBody(model: model, context: context)
        case .list(let model): ListBody(model: model, context: context)
        case .checklist(let model): ChecklistBody(model: model, context: context)
        case .table(let model): TableBody(model: model, context: context)
        case .details(let model): DetailsBody(model: model, context: context)
        case .outline(let model): OutlineBody(model: model, context: context)
        case .diff(let model): DiffBody(model: model, context: context)
        case .timeline(let model): TimelineBody(model: model, context: context)
        case .agenda(let model): AgendaBody(model: model, context: context)
        case .entity(let model): EntityBody(model: model, context: context)
        case .media(let model): MediaBody(model: model, context: context)
        case .code(let model): CodeBody(model: model, context: context)
        case .sources(let model): SourcesBody(model: model, context: context)
        case .weather(let model): WeatherBody(model: model, context: context)
        case .route(let model): RouteBody(model: model, context: context)
        case .pass(let model): PassBody(model: model, context: context)
        case .status(let model): StatusBody(model: model, context: context)
        case .steps(let model): StepsBody(model: model, context: context)
        case .alert(let model): AlertBody(model: model, context: context)
        case .choice(let model): ChoiceBody(model: model, context: context)
        case .form(let model): FormBody(model: model, context: context)
        case .approval(let model): ApprovalBody(model: model, context: context)
        case .receipt(let model): ReceiptBody(model: model, context: context)
        case .control(let model): ControlBody(model: model, context: context)
        case .summary(let model): SummaryBody(model: model, context: context)
        case .guide(let model): GuideBody(model: model, context: context)
        case .compare(let model): CompareBody(model: model, context: context)
        case .handoff(let model): HandoffBody(model: model, context: context)
        case .flashcard(let model): FlashcardBody(model: model, context: context)
        case .stack(let model): StackBody(model: model, context: context)
        }
    }
}

/// The primitive's own sentence when there's nothing to show (`Parts.cardEmpty`): the payload's
/// `empty_text`, or the primitive's default. Never a blank card.
struct WidgetEmpty: View {
    let context: WidgetContext
    let fallback: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text(context.payload.envelope.emptyText ?? fallback)
                .font(WidgetFont.body)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A row's own buttons (up to two per row, contract §6.1): small and grey, sending `{item}`.
struct RowActions: View {
    let actions: [WidgetAction]
    let item: (id: String, title: String)
    let context: WidgetContext

    var body: some View {
        if !actions.isEmpty {
            HStack(spacing: 6) {
                ForEach(actions.prefix(2), id: \.id) { action in
                    Button(action.label) { context.perform(action, item: item) }
                        .font(WidgetFont.label.weight(.semibold))
                        .foregroundStyle(action.style == .destructive ? Theme.danger : Theme.primaryText)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 30)
                        .background(Theme.controlFill, in: Capsule())
                        .buttonStyle(PressableStyle())
                        .disabled(!context.canAnswer && action.kind == .reply)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
    }
}

extension View {
    /// Row actions as VoiceOver custom actions on the row they belong to.
    func rowActions(_ actions: [WidgetAction]?, item: (id: String, title: String), context: WidgetContext) -> some View {
        accessibilityActions {
            ForEach(actions ?? [], id: \.id) { action in
                Button(action.label) { context.perform(action, item: item) }
            }
        }
    }
}
