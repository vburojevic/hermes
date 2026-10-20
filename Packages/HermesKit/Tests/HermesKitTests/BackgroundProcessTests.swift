import Foundation
import Testing
@testable import HermesKit

@Suite("Background processes: names (docs/background-processes.md §2)")
struct ProcessNamingTests {
    private let bots: (String) -> String? = { ["engineer": "Engineer", "default": "C.O.R.E."][$0] }

    @Test(arguments: [
        ("npm run dev", "Dev server"),
        ("pnpm dev", "Dev server"),
        ("cd ~/Code/hermes-docs && npm run docs:dev", "Docs site"),
        ("bun run dev", "Dev server"),
        ("npx vite --port 4321", "Dev server"),
        ("next dev", "Dev server"),
        ("astro dev --host", "Dev server"),
        ("python3 -m http.server 8000", "Web server"),
        ("caddy file-server --listen :8080", "Web server"),
        ("npx serve dist", "Web server"),
        ("npm test", "Tests"),
        ("swift test --filter Snapshot", "Tests"),
        ("pytest -x tests/", "Tests"),
        ("go test ./...", "Tests"),
        ("cargo test", "Tests"),
        ("xcodebuild -scheme Hermes -destination 'platform=iOS Simulator,name=iPhone 18' test", "Tests"),
        ("make release", "Release build"),
        ("xcodebuild -scheme Hermes archive", "Release build"),
        ("swift build -c release", "Release build"),
        ("make", "Build"),
        ("swift build", "Build"),
        ("cargo build", "Build"),
        ("npm run build", "Build"),
        ("docker compose up web", "Docker: web"),
        ("docker run -d -p 5432:5432 --name db postgres:16", "Docker: postgres"),
        ("tail -f /var/log/caddy/access.log", "Watching access.log"),
        ("journalctl -f -u caddy", "Watching caddy"),
        ("hermes -p engineer chat -q 'Rotate the Trailhead keys'", "Message to Engineer"),
        ("hermes chat -q hello", "Message to C.O.R.E."),
        ("hermes cron run backups", "Hermes: cron"),
        ("hermes gateway restart", "Hermes: gateway"),
        ("rsync backups/ nas:/volume1/backups", "rsync backups"),
        ("ffmpeg -i in.mov out.mp4", "ffmpeg"),
        ("python3 scripts/sync_photos.py --all", "sync_photos.py"),
        ("supercalifragilistic-tool expialidocious", "supercalifragilistic-to…"),
        ("cd ~/site && npm ci && npm run dev", "Dev server"),
        ("bash -lc \"cd ~/site && npm run dev\"", "Dev server"),
        ("set +m; make release", "Release build"),
    ])
    func names(command: String, expected: String) {
        #expect(ProcessNaming.name(for: command, botName: bots) == expected)
    }

    @Test func cleaningDropsWhatDoesntSayWhatItIs() {
        #expect(ProcessNaming.clean("cd /Users/sam/Code/hermes && NODE_ENV=dev nohup npm run dev > dev.log 2>&1 &") == "npm run dev")
        #expect(ProcessNaming.clean("exec make release >> build.log") == "make release")
        #expect(ProcessNaming.clean("tail -f /Users/sam/deploys/trailhead.log") == "tail -f ~/deploys/trailhead.log")
        #expect(ProcessNaming.clean("FOO=1 BAR=two swift test 2> errors.txt") == "swift test")
        #expect(ProcessNaming.clean("npm run dev | tee dev.log") == "npm run dev | tee dev.log")
        #expect(ProcessNaming.clean("bash -lc 'cd /Users/ada/site && npm run dev'") == "npm run dev")
    }

    @Test func aJSONArgvIsACommandLine() {
        #expect(ProcessNaming.name(for: #"["npm", "run", "docs:dev"]"#) == "Docs site")
        #expect(ProcessNaming.clean(#"["/home/ada/bin/hermes", "-p", "engineer", "chat", "-q", "hi there"]"#)
            == "~/bin/hermes -p engineer chat -q 'hi there'")
    }

    @Test func hermesOwnDeliveryNamesTheBot() {
        let delivery = #"/opt/hermes/venv/bin/python /opt/hermes/tools/bot_mode_dm.py --run-delivery --author '{"id":"core"}' query-file /tmp/dm.json /usr/local/bin/hermes -p engineer chat --in ~ -c 'Bot Chat'"#
        #expect(ProcessNaming.name(for: delivery, botName: bots) == "Message to Engineer")
        #expect(ProcessNaming.clean(delivery) == "hermes -p engineer chat --in ~ -c 'Bot Chat'")
        // Cut at 200 characters before the profile: still a message.
        #expect(ProcessNaming.name(for: String(delivery.prefix(90))) == "Message to a Bot")
        #expect(ProcessNaming.clean(String(delivery.prefix(90))) == "python bot_mode_dm.py --run-delivery …")
        #expect(ProcessNaming.name(for: "python3 /opt/hermes/tools/bot_mode_dm.py --wait-reply /tmp/r.json Engineer 600") == "Waiting for Engineer")
    }
}

@Suite("Background processes: output (§3)")
struct ProcessOutputTests {
    @Test func ansiCodesGoEvenSplitAcrossChunks() {
        var output = ProcessOutput()
        output.append("\u{1B}[32mready\u{1B}[0m in 412 ms\n\u{1B}[1")
        output.append(";34mLocal:\u{1B}[0m http://localhost:4321/\n")
        output.append("\u{1B}]0;title\u{07}done\n")
        #expect(output.text == "ready in 412 ms\nLocal: http://localhost:4321/\ndone\n")
    }

    @Test func characterSetSequencesLeaveNothingBehind() {
        // `tput sgr0` writes `ESC ( B ESC [ m`.
        var output = ProcessOutput()
        output.append("\u{1B}(B\u{1B}[mready\u{1B}#8\n")
        #expect(output.text == "ready\n")
    }

    @Test func theLastLinesComeFromTheEnd() {
        let output = ProcessOutput(cleaning: "one\ntwo\nthree\n__HERMES_CWD_ab__x__HERMES_CWD_ab__\nfour")
        #expect(output.lastLines(2) == ["three", "four"])
        #expect(output.lastLines(10) == ["one", "two", "three", "four"])
    }

    @Test func aRedrawnLineKeepsItsLastState() {
        var output = ProcessOutput()
        output.append("Downloading 10%\rDownloading 50%\r")
        output.append("Downloading 100%\r\nDone\r\n")
        #expect(output.text == "Downloading 100%\nDone\n")
        #expect(output.latestLine == "Done")
    }

    @Test func hermesWorkingFolderMarkerNeverShows() {
        var output = ProcessOutput()
        output.append("Compiling…\n__HERMES_CWD_3fa9c2__/Users/ada/Code__HERMES_CWD_3fa9c2__\n")
        output.append("Built in 2.1 s\n__HERMES_CWD_77")
        #expect(!output.text.contains("Compiling…\n__HERMES"))
        #expect(output.lines.allSatisfy { !$0.contains("__HERMES_CWD_") })
        #expect(output.latestLine == "Built in 2.1 s")
        output.append("aa__/x__HERMES_CWD_77aa__\nNext\n")
        #expect(!output.text.contains("__HERMES_CWD_"))
        #expect(output.latestLine == "Next")
    }

    @Test func theLatestLineIsTheLastWithSomethingOnIt() {
        let output = ProcessOutput(cleaning: "one\n  two  \n\n   \n")
        #expect(output.latestLine == "two")
        #expect(ProcessOutput(cleaning: "\n\n").latestLine == nil)
    }

    @Test func aJSONErrorIsItsMessageInPlainWords() {
        let raw = #"{"error": "target_busy: profile 'engineer' is busy with another message. Try again in 2 minutes.", "code": 1}"#
        #expect(ProcessOutput.errorMessage(in: raw, botName: { $0 == "engineer" ? "Engineer" : nil }) == "Engineer is busy with another message.")
        #expect(ProcessOutput.errorMessage(in: #"{"message": "build failed: 3 errors"}"#) == "Build failed: 3 errors")
        #expect(ProcessOutput.errorMessage(in: #"{"message": "Disk is full"}"#) == "Disk is full")
        #expect(ProcessOutput.errorMessage(in: "error: not JSON") == nil)
        #expect(ProcessOutput.errorMessage(in: #"{"ok": true}"#) == nil)
    }

    @Test func longOutputKeepsItsEndFromALineStart() {
        var output = ProcessOutput(limit: 20)
        for index in 0..<10 { output.append("line \(index)\n") }
        #expect(output.text.utf8.count <= 40)
        #expect(output.text.hasPrefix("line"))
        #expect(output.latestLine == "line 9")
    }
}

@Suite("Background processes: state (§1, §4)")
struct ProcessTrackerTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func row(_ id: String, _ command: String, status: String = "running", uptime: Double = 180,
                     exit: Int? = nil, reason: String? = nil, exitedAt: Double? = nil) -> JSONValue {
        var row: [String: JSONValue] = [
            "session_id": .string(id), "command": .string(command), "status": .string(status),
            "uptime_seconds": .number(uptime), "cwd": .string("/Users/ada/Code/hermes"), "pid": .number(48213),
        ]
        if let exit { row["exit_code"] = .number(Double(exit)) }
        if let reason { row["completion_reason"] = .string(reason) }
        if let exitedAt { row["exited_at"] = .number(exitedAt) }
        return .object(row)
    }

    @Test func outputStartsAProcessAndTheListNamesIt() {
        var tracker = ProcessTracker()
        let isNew = tracker.receiveOutput("\u{1B}[2mbuilding…\u{1B}[0m\n", for: "proc_a", now: now)
        let isNewAgain = tracker.receiveOutput("signing\n", for: "proc_a", now: now)
        #expect(isNew && !isNewAgain)
        #expect(tracker["proc_a"]?.name == "Background process")
        tracker.apply(list: [row("proc_a", "make release")], now: now)
        let process = tracker["proc_a"]
        #expect(process?.name == "Release build" && process?.state == .running)
        #expect(process?.output.text == "building…\nsigning\n")
        #expect(process?.stateLabel(now: now) == "Running · 3 min")
    }

    @Test func exitsComeOnlyFromTheList() {
        var tracker = ProcessTracker()
        tracker.apply(list: [row("proc_ok", "make release"), row("proc_bad", "hermes -p engineer chat -q hi"),
                             row("proc_kill", "tail -f /var/log/x.log")], now: now)
        // `terminal.close` only closes a tab.
        tracker.terminalClosed("proc_ok")
        #expect(tracker["proc_ok"]?.state == .running)
        let endings = tracker.apply(list: [
            row("proc_ok", "make release", status: "exited", uptime: 240, exit: 0, reason: "exited", exitedAt: now.timeIntervalSince1970),
            row("proc_bad", "hermes -p engineer chat -q hi", status: "exited", exit: 1, reason: "exited"),
            row("proc_kill", "tail -f /var/log/x.log", status: "exited", uptime: 720, exit: -15, reason: "killed", exitedAt: now.timeIntervalSince1970),
        ], now: now)
        #expect(endings.map(\.state) == [.finished, .failed, .stopped])
        #expect(tracker["proc_ok"]?.stateLabel(now: now) == "Finished · 4 min")
        #expect(tracker["proc_bad"]?.stateLabel(now: now) == "Failed · exit 1")
        #expect(tracker["proc_kill"]?.stateLabel(now: now) == "Stopped · 12 min")
        // Seen ending once: the next look reports nothing new.
        let again = tracker.apply(list: [row("proc_ok", "make release", status: "exited", exit: 0)], now: now)
        #expect(again.isEmpty)
    }

    @Test func alreadyEndedWhenFirstSeenIsNoNews() {
        var tracker = ProcessTracker()
        // An old chat: the build finished long before this device looked.
        let endings = tracker.apply(list: [row("proc_old", "make release", status: "exited", exit: 1, exitedAt: 0)], now: now)
        #expect(endings.isEmpty)
        // Hermes's 0 means "not known yet", not 1970.
        #expect(tracker["proc_old"]?.finishedAt == now)
        // Cleared here: it stays gone, whatever the list says.
        var cleared = ProcessTracker()
        cleared.apply(list: [row("proc_c", "make", status: "exited", exit: 0)], now: now, ignoring: ["proc_c"])
        #expect(cleared.processes.isEmpty)
    }

    @Test func aListThatMissedItIsntTheLastWord() {
        var tracker = ProcessTracker()
        tracker.link("proc_new", turnID: "t", toolCallID: "c", name: nil, command: "npm run dev", started: true, now: now)
        #expect(tracker["proc_new"]?.state == .running && tracker["proc_new"]?.name == "Dev server")
        // A list asked for just before it started.
        tracker.apply(list: [], now: now)
        #expect(tracker["proc_new"]?.state == .ended)
        // The next list (or its output) says it runs.
        tracker.apply(list: [row("proc_new", "npm run dev")], now: now)
        #expect(tracker["proc_new"]?.state == .running)
        tracker.apply(list: [], now: now)
        tracker.receiveOutput("ready\n", for: "proc_new", now: now)
        #expect(tracker["proc_new"]?.state == .running)
        // An exit is final: a stale list saying it runs doesn't undo it.
        tracker.apply(list: [row("proc_new", "npm run dev", status: "exited", exit: 0)], now: now)
        tracker.apply(list: [row("proc_new", "npm run dev")], now: now)
        #expect(tracker["proc_new"]?.state == .finished)
    }

    @Test func goneFromTheListMeansEnded() {
        var tracker = ProcessTracker()
        tracker.apply(list: [row("proc_a", "npm run dev"), row("proc_b", "make")], now: now)
        tracker.stopRequested("proc_b")
        #expect(tracker["proc_b"]?.stateLabel(now: now) == "Stopping…")
        let endings = tracker.apply(list: [], now: now)
        #expect(tracker["proc_a"]?.state == .ended && tracker["proc_a"]?.stateLabel(now: now) == "Ended")
        #expect(tracker["proc_b"]?.state == .stopped)
        #expect(endings.count == 2 && tracker.hasListed)
    }

    @Test func theCallThatStartedItLinksAndNames() {
        var tracker = ProcessTracker()
        tracker.link("proc_m", turnID: "turn-1", toolCallID: "call_9", name: "Message to Engineer", command: nil)
        tracker.apply(list: [row("proc_m", "/venv/bin/python /opt/hermes/tools/bot_mode_dm.py --run-delivery --author '{\"id\":\"x\"}'")], now: now)
        #expect(tracker["proc_m"]?.name == "Message to Engineer")
        #expect(tracker["proc_m"]?.turnID == "turn-1" && tracker["proc_m"]?.toolCallID == "call_9")
    }

    @Test func stepsFindTheirProcess() {
        let terminal = ToolActivity(id: "t1", callID: "call_1", name: "terminal",
                                    arguments: .object(["command": .string("npm run docs:dev"), "background": .bool(true)]),
                                    result: #"{"output": "Background process started", "session_id": "proc_3fa9c2d1e0b4", "pid": 48213, "exit_code": 0, "error": null}"#,
                                    status: .succeeded)
        #expect(terminal.startedProcessID == "proc_3fa9c2d1e0b4" && terminal.startedCommand == "npm run docs:dev")
        let message = ToolActivity(id: "t2", name: "message_agent",
                                   result: #"{"status": "queued", "to": "Engineer", "process_id": "proc_77aa", "detail": "…"}"#, status: .succeeded)
        #expect(message.startedProcessID == "proc_77aa" && message.startedProcessName == "Message to Engineer")
        let failedStart = ToolActivity(id: "t3", name: "terminal", result: #"{"output": "", "exit_code": -1, "error": "spawn failed"}"#, status: .failed)
        #expect(failedStart.startedProcessID == nil)
        let foreground = ToolActivity(id: "t4", name: "terminal", result: #"{"output": "ok", "exit_code": 0}"#, status: .succeeded)
        #expect(foreground.startedProcessID == nil)
        // Only a result that names a process is parsed: a byte scan, through any text.
        #expect(ToolActivity.mentionsProcess(#"{"session_id": "proc_3fa9"}"#))
        #expect(!ToolActivity.mentionsProcess(String(repeating: "Compiling module, ünïcode ✓ ", count: 400)))
        #expect(ToolActivity.mentionsProcess("Ünïcode first ✓ then proc_1"))
        #expect(!ToolActivity.mentionsProcess("proc"))
    }
}

@Suite("Background processes: the composer chip (§5)")
struct ProcessChipTests {
    private func process(_ id: String, _ command: String, _ state: BackgroundProcess.State) -> BackgroundProcess {
        BackgroundProcess(id: id, command: command, state: state)
    }

    @Test func hiddenWhenNothingRuns() {
        #expect(ProcessChip(processes: [], justFinished: nil) == .hidden)
        #expect(ProcessChip(processes: [process("a", "make", .finished), process("b", "make", .stopped)], justFinished: nil) == .hidden)
    }

    @Test func oneRunningShowsItsNameSeveralTheirCount() {
        #expect(ProcessChip(processes: [process("a", "npm run docs:dev", .running)], justFinished: nil)
            == .one(id: "a", name: "Docs site", startedAt: nil))
        #expect(ProcessChip(processes: [process("a", "npm run docs:dev", .running), process("b", "make release", .running)], justFinished: nil)
            == .several(count: 2))
    }

    @Test func justFinishedShowsTheCheckThenWhatStillRuns() {
        let processes = [process("a", "npm run docs:dev", .running), process("b", "make release", .finished)]
        #expect(ProcessChip(processes: processes, justFinished: "b") == .finished(id: "b", name: "Release build"))
        #expect(ProcessChip(processes: processes, justFinished: nil) == .one(id: "a", name: "Docs site", startedAt: nil))
    }

    @Test func aFailureStaysUntilTheTerminalShowedIt() {
        var tracker = ProcessTracker()
        tracker.apply(list: [.object(["session_id": .string("f"), "command": .string("hermes -p engineer chat -q hi"),
                                      "status": .string("exited"), "exit_code": .number(1)])])
        #expect(ProcessChip(processes: tracker.processes, justFinished: nil) == .failed(count: 1))
        tracker.markSeen("f")
        #expect(ProcessChip(processes: tracker.processes, justFinished: nil) == .hidden)
    }
}
