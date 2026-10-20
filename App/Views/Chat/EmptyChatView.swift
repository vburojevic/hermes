import HermesKit
import SwiftUI

/// A new chat: the mark, a greeting and a few things to try.
struct EmptyChatView: View {
    let workspace: BotWorkspace
    @Bindable var conversation: ConversationModel
    let centersComposer: Bool
    var composerFocused: Binding<Bool>

    @State private var appeared = false

    /// The project a new chat starts in, if any (`projectNewChat`).
    private var projectID: String? {
        guard conversation.sessionID == nil, workspace.projects.isAvailable else { return nil }
        return (conversation.placement ?? workspace.projects.defaultPlacement).projectID
    }

    var body: some View {
        if let projectID {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                ProjectNewChatHero(workspace: workspace, conversation: conversation, projectID: projectID, composerFocused: composerFocused)
                if centersComposer {
                    // Right above the composer, which the chat screen lifts to the middle.
                    Spacer().frame(height: 28)
                } else {
                    // A little above the middle, as in the design.
                    Spacer(minLength: 24)
                    Spacer().frame(height: 80)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            generalHome
        }
    }

    /// The getting-started checklist (`firstChat`) until it's dismissed or done.
    private var showsChecklist: Bool { !WelcomeProgress.shared.checklistHidden }

    private var generalHome: some View {
        // Short spaces (landscape with the keyboard up) drop the greeting, then everything.
        ViewThatFits(in: .vertical) {
            if showsChecklist { firstChat }
            full
            if !centersComposer {
                VStack {
                    Spacer(minLength: 0)
                    ChatSuggestionChips(conversation: conversation, focused: composerFocused, centered: false)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
            Color.clear
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.05)) {
                appeared = true
            }
            // The drawer's tip, on the first chat.
            DrawerTip.firstChatShown = true
        }
    }

    /// The first chat (`firstChat`): the greeting with their name and the checklist.
    private var firstChat: some View {
        VStack(alignment: centersComposer ? .center : .leading, spacing: 16) {
            if !centersComposer { Spacer().frame(height: 108) } else { Spacer(minLength: 24) }
            Text(greeting)
                .font(.system(.title, design: .default, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(centersComposer ? .center : .leading)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
                .accessibilityAddTraits(.isHeader)
            GetStartedCard(workspace: workspace)
                .frame(maxWidth: 480)
                .opacity(appeared ? 1 : 0)
            if centersComposer {
                Spacer().frame(height: 28)
            } else {
                Spacer(minLength: 24)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: centersComposer ? .center : .topLeading)
    }

    private var full: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                HermesMarkView()
                    .frame(width: centersComposer ? 64 : 56)
                    .scaleEffect(appeared ? 1 : 0.85)
                    .opacity(appeared ? 1 : 0)
                Text(greeting)
                    .font(.system(.title, design: .default, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 6)
            }
            // Centred on iPad and Mac: the greeting sits right above the composer, which the chat
            // screen lifts to the middle (and glides down on the first send).
            if centersComposer {
                Spacer().frame(height: 28)
            } else {
                Spacer(minLength: 24)
                ChatSuggestionChips(conversation: conversation, focused: composerFocused, centered: false)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Good morning, Sam" once setup has their name.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let name = WelcomeProgress.shared.name
        if name.isEmpty {
            return switch hour {
            case 5..<12: String(localized: "Good morning")
            case 12..<18: String(localized: "Good afternoon")
            case 18..<23: String(localized: "Good evening")
            default: String(localized: "Up late?")
            }
        }
        return switch hour {
        case 5..<12: String(localized: "Good morning, \(name)")
        case 12..<18: String(localized: "Good afternoon, \(name)")
        case 18..<23: String(localized: "Good evening, \(name)")
        default: String(localized: "Up late, \(name)?")
        }
    }
}

/// Things to try in a new chat, as chips that fill the composer.
struct ChatSuggestionChips: View {
    @Bindable var conversation: ConversationModel
    var focused: Binding<Bool>
    let centered: Bool

    private static let suggestions: [(title: String, symbol: String, prompt: String)] = [
        ("Plan my day", "calendar", "Look at what I have going on and help me plan today."),
        ("Research a topic", "globe", "Research the latest developments in "),
        ("Check my server", "server.rack", "Check disk usage, memory and the busiest processes on this machine."),
        ("Write some code", "chevron.left.forwardslash.chevron.right", "Write a script that "),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Spelled out, not a ForEach: the empty chat's ViewThatFits measures hidden layouts,
            // sometimes on SwiftUI's render thread, where a ForEach building its rows traps.
            HStack(spacing: 8) {
                chip(Self.suggestions[0])
                chip(Self.suggestions[1])
                chip(Self.suggestions[2])
                chip(Self.suggestions[3])
            }
            .padding(.horizontal, 4)
        }
        .scrollClipDisabled()
        .frame(maxWidth: centered ? 680 : .infinity)
    }

    private func chip(_ suggestion: (title: String, symbol: String, prompt: String)) -> some View {
        Button {
            conversation.draft = suggestion.prompt
            focused.wrappedValue = true
        } label: {
            ChipLabel(title: suggestion.title, symbol: suggestion.symbol)
        }
        .buttonStyle(PressableStyle())
    }
}
