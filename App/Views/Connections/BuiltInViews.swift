import HermesKit
import SwiftUI

// MARK: - Built-in tab (`builtInTab`)

/// How the app names Hermes's own toolsets. `toolsets.list` returns every toolset the gateway
/// knows (platform bundles, MCP servers, plugins) with no "built-in" flag, so the built-in ones are
/// the keys `hermes_cli/tools_config.py` lists as configurable: the eight in the design first, then
/// the rest under More.
enum BuiltInToolsetInfo {
    struct Info {
        let title: String
        let symbol: String
        /// What it allows on the gateway; `%@` is the gateway's name.
        let blurb: String
    }

    static let main = ["terminal", "file", "web", "browser", "vision", "image_gen", "memory", "delegation"]
    static let more = ["code_execution", "video", "video_gen", "x_search", "tts", "stt", "skills", "todo", "kanban",
                       "context_engine", "session_search", "connections", "clarify", "cronjob", "computer_use", "discord",
                       "discord_admin", "yuanbao"]

    static func info(_ name: String, gateway: String) -> Info? {
        switch name {
        case "terminal": Info(title: String(localized: "Terminal"), symbol: "terminal", blurb: String(localized: "Run commands on \(gateway)"))
        case "file": Info(title: String(localized: "Files"), symbol: "doc.text", blurb: String(localized: "Read and edit files"))
        case "web": Info(title: String(localized: "Web search"), symbol: "magnifyingglass", blurb: String(localized: "Search and read pages"))
        case "browser": Info(title: String(localized: "Browser"), symbol: "safari", blurb: String(localized: "Drive a real browser"))
        case "vision": Info(title: String(localized: "Vision"), symbol: "eye", blurb: String(localized: "Look at images and screenshots"))
        case "image_gen": Info(title: String(localized: "Image generation"), symbol: "photo", blurb: String(localized: "Make images"))
        case "memory": Info(title: String(localized: "Memory"), symbol: "brain", blurb: String(localized: "Remember things between chats"))
        case "delegation": Info(title: String(localized: "Helpers"), symbol: "person.2", blurb: String(localized: "Split work across parallel helpers"))
        case "code_execution": Info(title: String(localized: "Code execution"), symbol: "chevron.left.forwardslash.chevron.right", blurb: String(localized: "Run code in a sandbox"))
        case "video": Info(title: String(localized: "Video"), symbol: "film", blurb: String(localized: "Watch and describe videos"))
        case "video_gen": Info(title: String(localized: "Video generation"), symbol: "video", blurb: String(localized: "Make videos"))
        case "x_search": Info(title: String(localized: "X search"), symbol: "magnifyingglass.circle", blurb: String(localized: "Search posts on X"))
        case "tts": Info(title: String(localized: "Speech"), symbol: "speaker.wave.2", blurb: String(localized: "Read replies aloud"))
        case "stt": Info(title: String(localized: "Transcription"), symbol: "waveform", blurb: String(localized: "Turn voice into text"))
        case "skills": Info(title: String(localized: "Skills"), symbol: "book", blurb: String(localized: "Use and manage skills"))
        case "todo": Info(title: String(localized: "Planning"), symbol: "checklist", blurb: String(localized: "Keep a task list"))
        case "kanban": Info(title: String(localized: "Kanban"), symbol: "rectangle.split.3x1", blurb: String(localized: "Work a task board"))
        case "context_engine": Info(title: String(localized: "Context engine"), symbol: "square.stack.3d.up", blurb: String(localized: "Tools from the context engine"))
        case "session_search": Info(title: String(localized: "Chat search"), symbol: "text.magnifyingglass", blurb: String(localized: "Search past conversations"))
        case "connections": Info(title: String(localized: "Connections"), symbol: "app.connected.to.app.below.fill", blurb: String(localized: "Ask to connect apps mid-chat"))
        case "clarify": Info(title: String(localized: "Questions"), symbol: "questionmark.bubble", blurb: String(localized: "Ask you to choose"))
        case "cronjob": Info(title: String(localized: "Tasks"), symbol: "clock", blurb: String(localized: "Create and run scheduled tasks"))
        case "computer_use": Info(title: String(localized: "Computer use"), symbol: "cursorarrow.click.2", blurb: String(localized: "Use apps on \(gateway)"))
        case "discord": Info(title: String(localized: "Discord"), symbol: "bubble.left.and.bubble.right", blurb: String(localized: "Read and post in Discord"))
        case "discord_admin": Info(title: String(localized: "Discord admin"), symbol: "shield", blurb: String(localized: "Manage a Discord server"))
        case "yuanbao": Info(title: String(localized: "Yuanbao"), symbol: "bubble.left", blurb: String(localized: "Groups and DMs in Yuanbao"))
        default: nil
        }
    }

    /// Turning these off takes something basic away: confirm first.
    static func confirmation(_ name: String, gateway: String) -> String? {
        switch name {
        case "terminal": String(localized: "Hermes won't be able to run commands on \(gateway).")
        case "file": String(localized: "Hermes won't be able to edit files on \(gateway).")
        default: nil
        }
    }
}

struct BuiltInTabSections: View {
    let model: AppsAndToolsModel
    @State private var showsMore = false
    @State private var confirming: BuiltInToolset?

    private func rows(_ names: [String]) -> [BuiltInToolset] {
        names.compactMap { name in model.toolsets.first { $0.name == name } }
    }

    var body: some View {
        let main = rows(BuiltInToolsetInfo.main)
        let more = rows(BuiltInToolsetInfo.more)
        Section {
            if let error = model.toolsetsError, model.toolsets.isEmpty {
                Text(error).foregroundStyle(Theme.secondaryText)
            }
            ForEach(main) { toolset in
                row(toolset)
            }
        } header: {
            countedHeader(String(localized: "Built-in"), main.count)
        } footer: {
            Text("Changes apply to new chats on \(model.gatewayName); open chats reload their tools.")
        }
        .alert(String(localized: "Turn Off \(confirming.flatMap { BuiltInToolsetInfo.info($0.name, gateway: model.gatewayName)?.title } ?? "")?"),
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Turn Off", role: .destructive) {
                if let toolset = confirming { Task { await model.setToolset(toolset, enabled: false) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirming.flatMap { BuiltInToolsetInfo.confirmation($0.name, gateway: model.gatewayName) } ?? "")
        }
        if !more.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showsMore) {
                    ForEach(more) { toolset in
                        row(toolset)
                    }
                } label: {
                    Text("More · \(more.count)").foregroundStyle(Theme.primaryText)
                }
            }
        }
    }

    private func row(_ toolset: BuiltInToolset) -> some View {
        ToolsetRow(model: model, toolset: toolset) { on in
            if !on, BuiltInToolsetInfo.confirmation(toolset.name, gateway: model.gatewayName) != nil {
                confirming = toolset
            } else {
                Task { await model.setToolset(toolset, enabled: on) }
            }
        }
    }
}

/// One built-in toolset (`toolsetRow`): ink tile, name, what it allows, tool count, a switch.
private struct ToolsetRow: View {
    let model: AppsAndToolsModel
    let toolset: BuiltInToolset
    let set: (Bool) -> Void

    var body: some View {
        let info = BuiltInToolsetInfo.info(toolset.name, gateway: model.gatewayName)
        let tools = toolset.toolCount == 1 ? String(localized: "1 tool") : String(localized: "\(toolset.toolCount) tools")
        HStack(spacing: 12) {
            GlyphTile(symbol: info?.symbol ?? "wrench.and.screwdriver", ink: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(info?.title ?? toolset.name).foregroundStyle(Theme.primaryText)
                Text("\(info?.blurb ?? toolset.description) · \(tools)")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.isBusy("toolset:\(toolset.name)") {
                ProgressView().controlSize(.small)
            }
            Toggle(info?.title ?? toolset.name, isOn: Binding(get: { toolset.enabled }, set: { set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}
