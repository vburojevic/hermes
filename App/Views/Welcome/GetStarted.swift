import HermesKit
import SwiftUI
import TipKit

// The first chat (`firstChat`): the getting-started checklist and one tip at a time. Spec:
// docs/onboarding.md §4.

/// `getStartedCard`: progress and five things to try, and a sixth while the widgets plugin is
/// missing or off (`pluginChecklist`). Items tick themselves as the person does them
/// (`WelcomeProgress`); ✕ hides the card for good, and it hides itself once all are done.
struct GetStartedCard: View {
    let workspace: BotWorkspace
    @State private var progress = WelcomeProgress.shared

    private typealias Item = WelcomeProgress.Item

    private var botCount: Int {
        workspace.roster?.visibleBots.filter { !$0.isDefault }.count ?? 0
    }

    private var hasBotMode: Bool { workspace.roster != nil }

    /// The widgets row shows while the plugin is missing or off, and stays ticked once it's on;
    /// hidden with Don't Suggest Again, it's gone (`pluginChecklist`, `docs/onboarding.md` §4).
    private var showsCards: Bool {
        progress.isDone(.cards) || (hasBotMode && !workspace.pluginHub.answers.isHidden(AppPlugin.widgets.name))
    }

    private var items: [Item] { Item.allCases.filter { $0 != .cards || showsCards } }

    /// Done once the plugin is on, but not while its review is up: finishing the checklist hides
    /// this card, which would take the review's sheet with it mid-way.
    private func markCards() {
        if widgetsOn, !reviewingCards { progress.mark(.cards) }
    }

    private var doneCount: Int { items.filter(progress.isDone).count }

    @State private var reviewingCards = false

    var body: some View {
        // Rows are spelled out, not a ForEach: the empty chat's ViewThatFits measures this card
        // while it's hidden, sometimes on SwiftUI's render thread, and a ForEach builds its rows
        // there, which traps (they belong to the main actor). Body itself always runs on main.
        VStack(spacing: 0) {
            header
            row(.connect)
            row(.aboutYou)
            row(.runCommand)
            row(.meetBots)
            row(.checkpoints)
            if showsCards { row(.cards) }
        }
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task(id: workspace.connection.isOnline) {
            if workspace.connection.isOnline { progress.mark(.connect) }
        }
        .task(id: showsCards) { progress.showsCards = showsCards }
        .task(id: widgetsOn) { markCards() }
        .sheet(isPresented: $reviewingCards, onDismiss: markCards) {
            AppPluginReviewSheet(workspace: workspace, plugin: .widgets)
        }
    }

    /// The widgets plugin is on somewhere on this gateway.
    private var widgetsOn: Bool {
        workspace.plugins.survey.map { AppPluginPresence($0.entries(for: .widgets)) } == .on
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Theme.controlFill, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(doneCount) / CGFloat(items.count))
                    .stroke(Theme.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(doneCount)/\(items.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                    .monospacedDigit()
            }
            .frame(width: 30, height: 30)
            .animation(.smooth, value: doneCount)
            VStack(alignment: .leading, spacing: 0) {
                Text("Get to know Hermes")
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Text("A few things worth trying first")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.smooth) { progress.hideChecklist() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Get to Know Hermes")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Get to know Hermes, \(doneCount) of \(items.count) done"))
    }

    private func row(_ item: Item) -> some View {
        ChecklistRow(title: title(item), detail: detail(item), isDone: progress.isDone(item)) {
            act(item)
        }
    }

    private func title(_ item: Item) -> String {
        switch item {
        case .connect: String(localized: "Connect to your gateway")
        case .aboutYou: String(localized: "Tell Hermes about you")
        case .runCommand: String(localized: "Let Hermes run a command")
        case .meetBots: hasBotMode ? String(localized: "Meet your Bots") : String(localized: "Start a project")
        case .checkpoints: String(localized: "Turn on undo for files")
        case .cards: AppPlugin.widgets.words.checklist(workspace.bot.name).title
        }
    }

    private func detail(_ item: Item) -> String {
        switch item {
        case .connect:
            var version: String?
            if case .online(let number?) = workspace.connection { version = "Hermes \(number)" }
            return [workspace.bot.name, version].compactMap { $0 }.joined(separator: " · ")
        case .aboutYou:
            return progress.isDone(.aboutYou) ? String(localized: "Saved to Memory") : String(localized: "So it can get to the point")
        case .runCommand:
            return String(localized: "It asks first, you approve: “\(Self.diskQuestion)”")
        case .meetBots:
            if !hasBotMode { return String(localized: "Group chats and folders Hermes works in") }
            return botCount == 1 ? String(localized: "1 Bot is ready in Bot Mode") : String(localized: "\(botCount) Bots are ready in Bot Mode")
        case .checkpoints:
            return String(localized: "Checkpoints let you take back a turn")
        case .cards:
            return progress.isDone(.cards) ? String(localized: "On in Hermes and your Bots")
                : AppPlugin.widgets.words.checklist(workspace.bot.name).body
        }
    }

    static let diskQuestion = String(localized: "What’s using the disk?")

    private func act(_ item: Item) {
        switch item {
        case .connect:
            break
        case .aboutYou:
            workspace.startRememberChat(bot: nil)
        case .runCommand:
            workspace.startNewChat()
            workspace.draft.sendMessage(Self.diskQuestion)
        case .meetBots:
            if hasBotMode {
                workspace.sidebarMode = .bots
                workspace.selection = nil
            } else {
                workspace.sidebarMode = .chats
                workspace.selection = .allProjects
            }
        case .cards:
            // Its review: Install there is the consent.
            if !progress.isDone(.cards) { reviewingCards = true }
        case .checkpoints:
            // The off sheet (`checkpointsOff`) with Turn On; the timeline if they're already on.
            workspace.draft.checkpoints.showTimeline()
            if workspace.draft.checkpoints.sheet == nil || workspace.draft.checkpoints.list == nil {
                workspace.draft.checkpoints.sheet = .off
            }
        }
    }
}

/// One item (`checklistRow`, `checklistRowDone`): an open circle or an ink check, what to try,
/// why. Read as a list with checked and unchecked states.
struct ChecklistRow: View {
    let title: String
    let detail: String
    let isDone: Bool
    let action: () -> Void

    var body: some View {
        Button {
            if !isDone { action() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if isDone {
                        Circle().fill(Theme.ink)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.inkForeground)
                    } else {
                        Circle().strokeBorder(Theme.tertiaryText, lineWidth: 1.5)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isDone ? Theme.secondaryText : Theme.primaryText)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !isDone {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isDone ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(isDone ? Text("Done") : Text("Not done"))
    }
}

// MARK: - Tips (`tipBubble`)

/// TipKit, set up once at launch: each tip shows once, and no more than one an hour, so they
/// come one at a time. `-HERMES_TIPS reset|show|hide` starts over, shows them all (screenshots) or
/// none (UI tests).
enum HermesTips {
    static func configure() {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "HERMES_TIPS") {
        case "reset": try? Tips.resetDatastore()
        case "show": Tips.showAllTipsForTesting()
        case "hide": Tips.hideAllTipsForTesting()
        default: break
        }
        #endif
        try? Tips.configure([.displayFrequency(.hourly)])
    }

    /// Got It on any tip.
    nonisolated static var gotIt: Tip.Action { Tip.Action(id: "got-it", title: String(localized: "Got It")) }

    /// The tips' action handler: Got It puts the tip away for good.
    static func handle(_ action: Tip.Action, for tip: some Tip) {
        if action.id == "got-it" { tip.invalidate(reason: .actionPerformed) }
    }
}

/// The drawer, on the first chat.
struct DrawerTip: Tip {
    @Parameter static var firstChatShown: Bool = false

    var title: Text { Text("Everything lives here") }
    var message: Text? { Text("Your chats, Bots, projects, the Board and Skills. Swipe from the left edge any time.") }
    var image: Image? { Image(systemName: "sparkles") }
    var rules: [Rule] { #Rule(Self.$firstChatShown) { $0 } }
    var options: [any TipOption] { MaxDisplayCount(1) }
    var actions: [Action] { [HermesTips.gotIt] }
}

/// The Inspector pill, the first time something opens there.
struct InspectorTip: Tip {
    static let opened = Event(id: "inspector-opened")

    var title: Text { Text("What Hermes is working on") }
    var message: Text? { Text("Pages it builds, files it changes and its own screen open here. Tap to look.") }
    var image: Image? { Image(systemName: "sidebar.right") }
    var rules: [Rule] { #Rule(Self.opened) { $0.donations.count >= 1 } }
    var options: [any TipOption] { MaxDisplayCount(1) }
    var actions: [Action] { [HermesTips.gotIt] }
}

/// Send while Hermes works, the first time the person types then.
struct SteerTip: Tip {
    static let typedWhileWorking = Event(id: "typed-while-working")

    var title: Text { Text("Steer while it works") }
    var message: Text? { Text("Send now and Hermes takes it into account right away, or hold it for after this turn.") }
    var image: Image? { Image(systemName: "arrow.turn.down.right") }
    var rules: [Rule] { #Rule(Self.typedWhileWorking) { $0.donations.count >= 1 } }
    var options: [any TipOption] { MaxDisplayCount(1) }
    var actions: [Action] { [HermesTips.gotIt] }
}

/// The undo bar, the first time a turn changes files.
struct UndoTip: Tip {
    static let filesChanged = Event(id: "turn-changed-files")

    var title: Text { Text("Take back a turn") }
    var message: Text? { Text("Undo puts the files back the way they were before this reply.") }
    var image: Image? { Image(systemName: "clock.arrow.circlepath") }
    var rules: [Rule] { #Rule(Self.filesChanged) { $0.donations.count >= 1 } }
    var options: [any TipOption] { MaxDisplayCount(1) }
    var actions: [Action] { [HermesTips.gotIt] }
}

/// A Bot's face, the first time a Bot Chat opens.
struct BotFaceTip: Tip {
    static let botChatOpened = Event(id: "bot-chat-opened")

    var title: Text { Text("Its face says what it's doing") }
    var message: Text? { Text("Thinking, working, listening or asleep. Tap the face for the Bot's settings.") }
    var image: Image? { Image(systemName: "face.smiling") }
    var rules: [Rule] { #Rule(Self.botChatOpened) { $0.donations.count >= 1 } }
    var options: [any TipOption] { MaxDisplayCount(1) }
    var actions: [Action] { [HermesTips.gotIt] }
}

extension View {
    /// A tip over this view, put away for good by Got It.
    func hermesTip(_ tip: some Tip, arrowEdge: Edge = .top) -> some View {
        popoverTip(tip, arrowEdge: arrowEdge) { action in
            HermesTips.handle(action, for: tip)
        }
        .tipViewStyle(HermesTipStyle())
    }
}

/// `tipBubble`: the glyph, what this is, ✕, and Got It in ink (the only action tint).
struct HermesTipStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                configuration.image?
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    configuration.title?
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    configuration.message?
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    configuration.tip.invalidate(reason: .tipClosed)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            ForEach(configuration.actions) { action in
                Button {
                    action.handler()
                    if action.id == "got-it" { configuration.tip.invalidate(reason: .actionPerformed) }
                } label: {
                    action.label()
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .inkFilledButton()
            }
        }
        .padding(14)
        .frame(maxWidth: 320)
        .accessibilityElement(children: .contain)
    }
}
