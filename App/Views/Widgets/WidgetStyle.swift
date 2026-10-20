import HermesKit
import SwiftUI

/// Regular on iPhone and iPad; compact on the Mac and inside a stack of four or more
/// (`tokens/widgets.elyx` `widget`, `widget-compact`; `docs/widgets.md` §9).
nonisolated enum WidgetDensity: Hashable, Sendable {
    case regular, compact

    var radius: CGFloat { self == .regular ? 18 : 14 }
    var padTop: CGFloat { self == .regular ? 12 : 9 }
    var pad: CGFloat { self == .regular ? 14 : 11 }
    var gap: CGFloat { self == .regular ? 12 : 8 }
    var rowGap: CGFloat { self == .regular ? 10 : 7 }
    var rowHeight: CGFloat { self == .regular ? 44 : 32 }
    var leading: CGFloat { self == .regular ? 28 : 22 }

    static let wellRadius: CGFloat = 10
    static let tileRadius: CGFloat = 8
    static let barRadius: CGFloat = 3
    static let inlineGap: CGFloat = 6
    /// A single widget's width on iPad and Mac, so data stays scannable; wide layouts (lanes,
    /// option cards, a stack's grid) take more.
    static let maxWidth: CGFloat = 560
    static let wideMaxWidth: CGFloat = 720

    static var platform: WidgetDensity {
        #if os(macOS)
        .compact
        #else
        .regular
        #endif
    }
}

extension EnvironmentValues {
    @Entry var widgetDensity: WidgetDensity = .platform
}

/// The widget type roles (`tokens/widgets.elyx` `widget-type`). On iPhone and iPad they are the
/// text styles of those sizes, so Dynamic Type scales them; the Mac has fixed sizes.
nonisolated enum WidgetFont {
    #if os(macOS)
    static let title = Font.system(size: 14, weight: .semibold)
    static let subtitle = Font.system(size: 12)
    static let label = Font.system(size: 12)
    static let body = Font.system(size: 14)
    static let caption = Font.system(size: 11)
    static let valueHero = Font.system(size: 30, weight: .bold)
    static let value = Font.system(size: 22, weight: .semibold)
    static let valueSmall = Font.system(size: 16, weight: .semibold)
    static let badge = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let amount = Font.system(size: 24, weight: .bold)
    static let question = Font.system(size: 19, weight: .bold)
    static let answer = Font.system(size: 16, weight: .bold)
    #else
    static let title = Font.subheadline.weight(.semibold)
    static let subtitle = Font.footnote
    static let label = Font.footnote
    static let body = Font.subheadline
    static let caption = Font.caption
    static let valueHero = Font.largeTitle.bold()
    static let value = Font.title2.weight(.semibold)
    static let valueSmall = Font.headline
    static let badge = Font.caption.weight(.semibold)
    static let mono = Font.system(.caption, design: .monospaced)
    /// An approval's amount (`Asking.approval`: title 1, bold).
    static let amount = Font.title.bold()
    /// A flashcard's side (`Content.flashcard`: title 2, bold).
    static let question = Font.title2.bold()
    /// A verdict's answer (`Numbers.verdict`: title 3, bold).
    static let answer = Font.title3.bold()
    #endif
}

/// One look per meaning: each state has a colour, a glyph and a word (`docs/widgets.md` §9,
/// design README §2). State is never colour alone.
nonisolated enum WidgetTone: Hashable, Sendable, Comparable {
    // In badge precedence: the worst first.
    case critical, stale, unverified, warning, pending, info, ok, neutral

    init(_ state: WidgetState) {
        switch state {
        case .ok: self = .ok
        case .info: self = .info
        case .warning: self = .warning
        case .critical: self = .critical
        case .unverified: self = .unverified
        case .pending: self = .pending
        }
    }

    init(_ state: WidgetItemState) {
        switch state {
        case .ok: self = .ok
        case .info: self = .info
        case .warning: self = .warning
        case .critical: self = .critical
        case .unverified: self = .unverified
        case .stale: self = .stale
        case .pending: self = .pending
        }
    }

    init(_ tag: WidgetTag.State) {
        switch tag {
        case .ok: self = .ok
        case .info: self = .info
        case .warning: self = .warning
        case .critical, .removed: self = .critical
        case .unverified: self = .unverified
        case .neutral, .new: self = .neutral
        }
    }

    var color: Color {
        switch self {
        case .ok: Theme.success
        case .info: Theme.info
        case .warning: Theme.warning
        case .critical: Theme.danger
        case .unverified: Theme.primaryText
        case .stale, .pending, .neutral: Theme.secondaryText
        }
    }

    var tint: Color {
        switch self {
        case .ok: Theme.successTint
        case .info: Theme.infoTint
        case .warning: Theme.warningTint
        case .critical: Theme.dangerTint
        case .unverified: Theme.canvas
        case .stale, .pending, .neutral: Theme.controlFill
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .unverified: "questionmark.circle.fill"
        case .stale: "clock.fill"
        case .pending: "hourglass"
        case .neutral: "circle"
        }
    }

    /// The default badge word; producers' `state_label` reads better when they have one.
    var word: String {
        switch self {
        case .ok: String(localized: "OK")
        case .info: String(localized: "Info")
        case .warning: String(localized: "Check this")
        case .critical: String(localized: "Failed")
        case .unverified: String(localized: "Unverified")
        case .stale: String(localized: "Old")
        case .pending: String(localized: "Updating")
        case .neutral: ""
        }
    }

    /// Unverified reads in greyscale too: a dashed outline and a question mark.
    var isDashed: Bool { self == .unverified }
}

/// The one progress vocabulary (`steps`, `outline`): waiting, running, done, failed, skipped,
/// blocked, unknown. Unknown is drawn like unverified.
nonisolated enum WidgetProgress: String, Hashable, Sendable {
    case waiting, running, done, failed, skipped, blocked, unknown

    var symbol: String {
        switch self {
        case .waiting: "circle"
        case .running: "circle.dotted"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        case .blocked: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .done: Theme.success
        case .failed: Theme.danger
        case .blocked: Theme.warning
        case .running, .unknown: Theme.primaryText
        case .waiting, .skipped: Theme.tertiaryText
        }
    }

    var word: String {
        switch self {
        case .waiting: String(localized: "Waiting")
        case .running: String(localized: "Running")
        case .done: String(localized: "Done")
        case .failed: String(localized: "Failed")
        case .skipped: String(localized: "Skipped")
        case .blocked: String(localized: "Blocked")
        case .unknown: String(localized: "Not known")
        }
    }
}

extension WidgetPayload {
    /// The symbol the header draws: the payload's when the app can draw it, else the
    /// primitive's own.
    var headerSymbol: String {
        WidgetSymbols.resolve(envelope.icon) ?? type.defaultSymbol
    }
}

extension WidgetType {
    /// Each primitive's glyph when the payload names none (or one the app can't draw).
    var defaultSymbol: String {
        switch self {
        case .metric: "chart.bar.fill"
        case .meter: "gauge.with.dots.needle.67percent"
        case .chart: "chart.line.uptrend.xyaxis"
        case .calendar: "calendar"
        case .verdict: "checkmark.seal"
        case .scoreboard: "sportscourt.fill"
        case .list: "list.bullet"
        case .checklist: "checklist"
        case .table: "tablecells"
        case .details: "doc.text"
        case .outline: "list.bullet.indent"
        case .diff: "arrow.left.arrow.right"
        case .timeline: "point.topleft.down.to.point.bottomright.curvepath"
        case .agenda: "calendar.day.timeline.left"
        case .entity: "square.text.square"
        case .media: "photo.on.rectangle"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .sources: "books.vertical"
        case .weather: "cloud.sun.fill"
        case .route: "map.fill"
        case .pass: "ticket.fill"
        case .status: "server.rack"
        case .steps: "list.number"
        case .alert: "exclamationmark.triangle.fill"
        case .choice: "questionmark.bubble"
        case .form: "square.and.pencil"
        case .approval: "hand.raised.fill"
        case .receipt: "checkmark.seal.fill"
        case .control: "slider.horizontal.3"
        case .summary: "text.alignleft"
        case .guide: "list.bullet.clipboard"
        case .compare: "square.split.2x1"
        case .handoff: "arrow.triangle.swap"
        case .flashcard: "rectangle.on.rectangle.angled"
        case .stack: "square.stack.3d.up.fill"
        }
    }

    /// The skeleton a loading card shows (`catalog.json` `skeleton`).
    var skeleton: WidgetSkeletonKind {
        switch self {
        case .metric, .meter, .scoreboard, .weather, .receipt, .pass: .value
        case .chart: .chart
        case .calendar: .grid
        case .code, .diff: .code
        case .media, .entity: .media
        default: .rows
        }
    }

    /// Wide layouts take 720 pt on iPad and Mac.
    var isWide: Bool { self == .compare || self == .stack }
}

nonisolated enum WidgetSkeletonKind: Sendable {
    case value, rows, chart, media, grid, code
}
