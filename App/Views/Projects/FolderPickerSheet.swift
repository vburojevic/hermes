import HermesKit
import SwiftUI

/// Choose Another Folder… / Add Folder…: walks the folders on the gateway with `complete.path`,
/// starting at its home folder. "Use This Folder" picks the folder being shown.
struct FolderPickerSheet: View {
    let workspace: BotWorkspace
    let title: String
    let onPick: (String?) -> Void

    /// `~/…` as the gateway completes it (it expands `~` itself when storing the folder).
    @State private var path = "~/"
    @State private var entries: [String] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var typed = ""

    private var projects: ProjectsModel { workspace.projects }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isLoading, entries.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.secondaryText)
                    } else if entries.isEmpty {
                        Text("No folders inside.")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(entries, id: \.self) { entry in
                        Button {
                            open(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder")
                                    .foregroundStyle(Theme.secondaryText)
                                    .accessibilityHidden(true)
                                Text(ProjectPath.lastComponent(entry))
                                    .foregroundStyle(Theme.primaryText)
                                if let owner = projects.owner(ofFolder: projects.absolute(entry)) {
                                    Text("· \(owner.name)")
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack(spacing: 6) {
                        if path != "~/" {
                            Button {
                                goUp()
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Enclosing folder")
                        }
                        Text(path)
                            .font(.system(.footnote, design: .monospaced))
                            .textCase(nil)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Section {
                    TextField("~/Code/my-app", text: $typed)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { jump() }
                } header: {
                    Text("Go to Folder")
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onPick(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This Folder") { onPick(trimmed(path)) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(path == "~/")
                }
            }
            .task(id: path) { await load() }
        }
        #if os(macOS)
        .frame(width: 460, height: 520)
        #endif
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await projects.folders(under: path)
                // Hidden folders stay out of the way, except Hermes's own (its agent checkout).
                .filter { !ProjectPath.lastComponent($0).hasPrefix(".") || ProjectPath.lastComponent($0) == ".hermes" }
            error = nil
        } catch {
            entries = []
            self.error = error.localizedDescription
        }
    }

    private func open(_ entry: String) {
        path = entry.hasSuffix("/") ? entry : entry + "/"
    }

    private func goUp() {
        var parts = trimmed(path).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        parts.removeLast()
        let parent = parts.joined(separator: "/")
        path = parent.isEmpty || parent == "~" ? "~/" : parent + "/"
    }

    private func jump() {
        var text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if !text.hasPrefix("~") && !text.hasPrefix("/") { text = "~/" + text }
        path = text.hasSuffix("/") ? text : text + "/"
        typed = ""
    }

    private func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

extension ProjectsModel {
    /// `~/Code/app/` → the gateway's absolute path, when its home is known; the gateway expands
    /// `~` itself, so this is only for matching against stored folders.
    func absolute(_ path: String) -> String {
        var value = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if value.hasPrefix("~"), let home = gatewayHomeFolder {
            value = home + value.dropFirst()
        }
        return value
    }
}
