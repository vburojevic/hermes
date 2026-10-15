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

    private var generalHome: some View {
        // Short spaces (landscape with the keyboard up) drop the greeting, then everything.
        ViewThatFits(in: .vertical) {
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
        }
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

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        return switch hour {
        case 5..<12: String(localized: "Good morning")
        case 12..<18: String(localized: "Good afternoon")
        case 18..<23: String(localized: "Good evening")
        default: String(localized: "Up late?")
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
            HStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.title) { suggestion in
                    Button {
                        conversation.draft = suggestion.prompt
                        focused.wrappedValue = true
                    } label: {
                        ChipLabel(title: suggestion.title, symbol: suggestion.symbol)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollClipDisabled()
        .frame(maxWidth: centered ? 680 : .infinity)
    }
}
