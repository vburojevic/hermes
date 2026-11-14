import HermesKit
import SwiftUI

/// Routines → Past runs (`routineRuns`): every routine's runs that said something, newest first.
/// A Bot's runs are kept in its own profile, where the app can't open them as chats, so they read
/// in place: a tap expands the whole reply, and Copy is in the context menu (`docs/tasks.md` §5).
struct RoutineRunsView: View {
    let roster: BotRoster
    let botName: String
    let routines: [BotRoutine]
    /// The gateway's own profile (nil for the main one): only its runs open as chats.
    let gatewayProfile: String?
    /// Opens a run as a chat, titled after its routine; nil where this sheet can't.
    let open: ((CronRun, String) -> Void)?

    /// Nil until they're read.
    @State private var runs: [RoutineRun]?
    @State private var failed = false
    @State private var expanded: Set<String> = []
    /// What each run said, read from its chat as its row shows.
    @State private var replies: [String: String] = [:]
    @State private var reading: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .navigationTitle("Past runs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let runs, !runs.isEmpty {
            list(runs)
        } else if runs != nil {
            StateMessage(
                symbol: "clock.arrow.circlepath",
                title: String(localized: "No past runs yet"),
                message: String(localized: "Runs that said something show here, newest first.")
            )
        } else if failed {
            StateMessage(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Couldn't load past runs"),
                message: roster.isConnected ? nil : String(localized: "Past runs need Bot Mode connected."),
                actionTitle: String(localized: "Try Again"),
                action: { Task { await load() } }
            )
        } else {
            SkeletonRows()
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func list(_ runs: [RoutineRun]) -> some View {
        List {
            Section {
                ForEach(runs) { entry in
                    row(entry)
                }
            } footer: {
                #if os(macOS)
                Text("Click a run to read all of it. Results post in the Bot Chat when the routine sends them there.")
                #else
                Text("Tap a run to read all of it. Results post in the Bot Chat when the routine sends them there.")
                #endif
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
        .refreshable { await load() }
    }

    private func row(_ entry: RoutineRun) -> some View {
        let run = entry.run
        let opens = open != nil && run.opensAsChat(gatewayProfile: gatewayProfile)
        let isExpanded = expanded.contains(entry.id)
        let item = RunRow(run: run, routine: entry.routine, opens: opens, reply: replies[entry.id],
                          isReading: reading.contains(entry.id), isExpanded: isExpanded)
        return Button {
            if opens {
                open?(run, entry.routine)
            } else {
                withAnimation(reduceMotion ? nil : .smooth) {
                    if expanded.remove(entry.id) == nil { expanded.insert(entry.id) }
                }
            }
        } label: {
            item
        }
        .buttonStyle(.plain)
        .accessibilityHint(opens ? Text("Opens the run as a chat") : isExpanded ? Text("Shows less") : Text("Shows all of it"))
        .contextMenu {
            if let text = item.line, !reading.contains(entry.id) {
                Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(text) }
            }
        }
        .task(id: entry.id) { await read(entry) }
    }

    /// Reads what a run said from its chat, in the profile that keeps it. Rows read as they show,
    /// so a long history doesn't read every run at once.
    private func read(_ entry: RoutineRun) async {
        guard replies[entry.id] == nil, let id = entry.run.sessionID else { return }
        reading.insert(entry.id)
        defer { reading.remove(entry.id) }
        let profile = entry.run.profile ?? gatewayProfile ?? "default"
        guard let transcript = try? await roster.transcript(storedSessionID: id, profile: profile, limit: 20),
              let reply = ScheduledRuns.reply(in: transcript) else { return }
        replies[entry.id] = reply
    }

    /// Hermes keeps each routine's runs apart, so it reads them all and merges them. Most runs of
    /// a frequent routine say nothing, so it asks for Hermes's most and keeps the rest.
    private func load() async {
        failed = false
        guard roster.isConnected else {
            failed = runs == nil
            return
        }
        var loaded: [(routine: String, runs: [CronRun])] = []
        var anyFailed = false
        for routine in routines {
            if let runs = try? await roster.cronRuns(jobID: routine.id, profile: botName, limit: 100) {
                loaded.append((routine: routine.title, runs: runs))
            } else {
                anyFailed = true
            }
        }
        if anyFailed, loaded.isEmpty, !routines.isEmpty {
            failed = runs == nil
            return
        }
        runs = ScheduledRuns.merged(loaded)
    }
}
