#if DEBUG && os(macOS)
import AppKit
import HermesKit
import HermesPush

/// Drives the Mac app from inside for checks, without touching the person's screen: a window on
/// another Space can't take input from outside (cua-driver refuses it), but the app can press its
/// own controls through its accessibility tree, as VoiceOver does, and hand a window a key
/// equivalent.
///
/// `-HERMES_MAC_DRIVE "wait 9; press Developer; wait 3; tap 150 190; wait 3; click top-button"`.
/// Steps: `wait <seconds>`; `press <label>` (a toolbar item); `tap <x> <y>` (points from the
/// Settings window's top left: a screenshot's pixels halved; `maintap <x> <y>` the same in the
/// main window); `click top-button` (the topmost AppKit button, which on a pushed page is its
/// back button); `key cmd+[`, `key return` (a sheet's default button); `tabs` (Settings tabs
/// shown and clipped; `maintabs` the chats window's toolbar items); `frame <width> <height>`
/// (resizes the chats window, top left kept, which a locked screen refuses from outside);
/// `menu <title>` (a menu bar menu's items and shortcuts, which a locked or off-Space screen
/// can't capture); `item <menu> > <item>` (chooses a menu bar item, as a click on it would);
/// `mainkey esc` (Esc in the chats window; `mainkey cmd+r` ⌘R there, then the menus; `mainkey
/// tab|up|down|left|right|return` typed there; `key cmd+r` ⌘R in Settings, then the menus); `sidebar`
/// (the sidebar button's action); `select group:<id>|bot:<name>` (a sidebar row, as a click on it
/// would; `select bots` the Bots home); `dump`, `views` and `toolbar` (the accessibility, content
/// and toolbar view trees, with frames; `maindump` the chats window's accessibility tree). The ⌘K
/// palette: `paletteopen`, `palettekey up|down|return|esc|space|cmd+return|cmd+<digit>`,
/// `palettetype <text>` (typed into its field as keys, one per character), `paletteblur` (takes
/// the field out of editing) and `palette` (the field's text, the field editor's corrections and
/// the chats windows' titles). `badge needsYou|unreadChats` sets what the Dock badge counts, as
/// Settings → Notifications → Dock Badge does, whose pop-up menu a drive can't use. `mute
/// chat:<id>|bot:<name>|group:<id>` mutes that row until it's turned back on, as its context menu's
/// Mute does, whose submenu a drive can't use; `unread` and `read` with the same targets do what
/// its Mark as Unread and Mark as Read do (a group chat has only Mark as Read). `remove gateway
/// <name>` removes a gateway as Remove in Settings → Gateways does once confirmed, without the
/// alert; only a gateway on this Mac (127.0.0.1, localhost or ::1), so a run can't remove a real
/// one. `stopnotifications gateway <name>` does what Stop Notifications on that gateway's
/// notification page does once confirmed, for a gateway on this Mac only. Each step logs
/// `HERMES_MAC_DRIVE` with its result and the Settings window's title, which is the page it shows,
/// to `-HERMES_MAC_DRIVE_LOG <file>` too when it's given.
///
/// The freeze scenarios (docs/development.md, Hangs) mark each step in the hang log
/// (`-HERMES_HANG_LOG`): `mark <text>`; `mode chats|bots` (the sidebar's list); `scroll sidebar
/// <points/s> <rounds>` (the sidebar's list from the top to the bottom and back);
/// `cycle <rounds> <target>,<target>…` (opens each in turn and stays 4 s: `chat:<id>`,
/// `chat:#<n>` the n-th chat in the list, `bot:<name>`, `bot:#<n>`, `group:<id>`, `group:#<n>`);
/// `burst <count> <seconds>` (the mock backend sends that many messages across chats, through
/// `/api/mock/burst`); `sleepwake <seconds>` (the Mac's sleep as the app hears it: the sleep
/// notice, the mock's sockets cut for that long, then the wake notice). The mock calls go to
/// `-HERMES_BOOTSTRAP_BACKEND` on this Mac only, with `-HERMES_MOCK_TOKEN`, the mock's `--token`.
/// `window` logs whether the chats window is on screen, which a run needs to mean anything.
/// `sidebarlists` logs each of the sidebar's lists: hidden or shown, its rows, where it's scrolled,
/// whether Tab, a click or VoiceOver can reach it; `sidebarat <points>` scrolls the shown one to
/// that far from its top.
@MainActor
enum MacDebugDriver {
    static func runIfAsked(router: WindowRouter, app: AppModel, workspace: () -> BotWorkspace?) async {
        guard let script = UserDefaults.standard.string(forKey: "HERMES_MAC_DRIVE") else { return }
        for step in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !step.isEmpty {
            let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            var result = "ok"
            switch parts[0] {
            case "wait":
                try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
            case "press":
                result = press(argument)
            case "key":
                result = key(argument)
            case "dump":
                if let window = settingsWindow { dump(window, depth: 0) }
            case "maindump":
                if let window = mainWindow { dump(window, depth: 0) } else { result = "no chats window" }
            case "click":
                result = clickTopButton()
            case "tap":
                result = tap(argument)
            case "maintap":
                result = tap(argument, in: mainWindow)
            case "tabs":
                result = tabs()
            case "frame":
                result = frame(argument)
            case "menu":
                result = menu(argument)
            case "item":
                result = item(argument)
            case "mainkey":
                result = mainKey(argument)
            case "sidebar":
                // What the sidebar button, ⌃⌘S and View > Show Sidebar call: a locked screen
                // leaves no key window, so the menu item is disabled and a click is swallowed.
                router.toggleSidebar()
                result = router.layout.showsSidebar ? "shown" : "put away"
            case "maintabs":
                result = mainToolbarItems()
            case "select":
                result = select(argument, in: workspace())
            case "toolbar":
                if let frame = settingsWindow?.contentView?.superview { dumpToolbar(frame, depth: 0) }
            case "views":
                if let view = settingsWindow?.contentView { dumpViews(view, depth: 0) }
            case "palettekey":
                result = paletteKey(argument)
            case "palettetype":
                result = paletteType(argument)
            case "paletteopen":
                // What ⌘K does in the first window, whose menu item an off-Space app leaves
                // disabled.
                router.showsSearchPalette = true
            case "paletteblur":
                result = paletteField.map { $0.window?.makeFirstResponder(nil) == true ? "blurred" : "refused" } ?? "no palette"
            case "palette":
                result = paletteDump()
            case "mark":
                HangLog.shared.mark(argument)
            case "window":
                // A covered window or one on another Space draws no frames, so a run there measures nothing.
                result = mainWindow.map { window in
                    let shown = window.occlusionState.contains(.visible) ? "visible" : "covered"
                    return "\(shown), \(window.isOnActiveSpace ? "this Space" : "another Space"), \(NSApp.isActive ? "app active" : "app behind")"
                } ?? "no chats window"
            case "mode":
                result = mode(argument, in: workspace())
            case "scroll":
                result = await scroll(argument)
            case "sidebarlists":
                result = sidebarLists()
            case "sidebarat":
                result = sidebarAt(argument)
            case "search":
                // What typing in the sidebar's search field does; no argument clears it.
                if let workspace = workspace() {
                    workspace.searchText = argument
                    result = argument.isEmpty ? "cleared" : "searching"
                } else {
                    result = "no workspace"
                }
            case "cycle":
                result = await cycle(argument, in: workspace())
            case "burst":
                result = await burst(argument)
            case "sleepwake":
                result = await sleepWake(argument)
            case "badge":
                result = badge(argument)
            case "mute":
                result = mute(argument, in: workspace())
            case "unread", "read":
                result = mark(argument, unread: parts[0] == "unread", in: workspace())
            case "remove":
                result = remove(argument, in: app)
            case "stopnotifications":
                result = stopNotifications(argument, in: app)
            default:
                result = "unknown step"
            }
            log("\(step) → \(result) · window: \(settingsWindow?.title ?? "none")")
        }
        log("done")
    }

    /// `badge needsYou|unreadChats`: what the Dock Badge picker's choice sets.
    private static func badge(_ mode: String) -> String {
        #if HERMES_PUSH
        guard let mode = PushShared.BadgeMode(rawValue: mode) else { return "unknown mode" }
        PushCenter.shared.badgeMode = mode
        return "counts \(mode.rawValue)"
        #else
        return "no push in this build"
        #endif
    }

    /// `mute chat:<id>|bot:<name>|group:<id>`: what Mute → Until I Turn It Back On does on that
    /// row. A target that isn't in the lists is logged, never guessed.
    private static func mute(_ target: String, in workspace: BotWorkspace?) -> String {
        guard let workspace else { return "no workspace" }
        guard let key = unreadKey(target, in: workspace) else { return "unknown target" }
        workspace.unread.mute(key, for: .untilTurnedOff)
        return workspace.unread.isMuted(key) ? "muted \(key)" : "not muted"
    }

    /// `unread <target>` and `read <target>`: what the row's Mark as Unread and Mark as Read do,
    /// for the same targets as `mute`. A group chat's menu has no Mark as Unread, so neither does this.
    private static func mark(_ target: String, unread: Bool, in workspace: BotWorkspace?) -> String {
        guard let workspace else { return "no workspace" }
        guard let key = unreadKey(target, in: workspace) else { return "unknown target" }
        if unread, target.hasPrefix("group:") { return "refused: a group chat has no Mark as Unread" }
        if unread { workspace.unread.markUnread(key) } else { workspace.unread.markRead(key) }
        return "\(unread ? "marked unread" : "marked read") \(key)"
    }

    /// The unread store's key for a `chat:<id>`, `bot:<name>` or `group:<id>` in the lists.
    private static func unreadKey(_ target: String, in workspace: BotWorkspace) -> String? {
        let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "chat":
            let session = workspace.session(forKey: parts[1]) ?? workspace.sessions.first { $0.id == parts[1] }
            return session?.stableID
        case "bot":
            let bots = (workspace.roster?.visibleBots ?? []) + (workspace.roster?.hiddenBots ?? [])
            return bots.contains(where: { $0.name == parts[1] }) ? UnreadStore.botKey(parts[1]) : nil
        case "group":
            let rooms = workspace.roster?.groupRooms.rooms ?? []
            return rooms.contains(where: { $0.id == parts[1] }) ? UnreadStore.groupKey(parts[1]) : nil
        default:
            return nil
        }
    }

    /// `remove gateway <name>`: what Remove does once its alert is confirmed. Only a gateway on
    /// this Mac, so a drive aimed at the shared Hermes Dev preferences can't remove a real one.
    private static func remove(_ argument: String, in app: AppModel) -> String {
        guard argument.hasPrefix("gateway ") else { return "remove needs gateway <name>" }
        let name = String(argument.dropFirst("gateway ".count))
        guard let bot = app.bots.first(where: { $0.name == name }) else { return "no gateway named that" }
        guard let host = bot.baseURL.host(), ["127.0.0.1", "localhost", "::1"].contains(host) else {
            return "refused: not a gateway on this Mac"
        }
        do {
            try app.removeBot(bot.id)
            return "removed"
        } catch {
            return "failed: \((error as NSError).domain) \((error as NSError).code)"
        }
    }

    /// `stopnotifications gateway <name>`: what Stop Notifications on the gateway's notification page
    /// does once confirmed. Only a gateway on this Mac, for the same reason as `remove`.
    private static func stopNotifications(_ argument: String, in app: AppModel) -> String {
        #if HERMES_PUSH
        guard argument.hasPrefix("gateway ") else { return "stopnotifications needs gateway <name>" }
        let name = String(argument.dropFirst("gateway ".count))
        guard let bot = app.bots.first(where: { $0.name == name }) else { return "no gateway named that" }
        guard let host = bot.baseURL.host(), ["127.0.0.1", "localhost", "::1"].contains(host) else {
            return "refused: not a gateway on this Mac"
        }
        guard let workspace = app.workspaces[bot.id] else { return "no workspace" }
        PushCenter.shared.stopNotifications(from: workspace)
        return "stopped"
        #else
        return "no push in this build"
        #endif
    }

    /// `select group:<id>` or `select bot:<name>`: what a click on that sidebar row does, so a chat
    /// can be left and opened again in one launch. `select bots` goes back to the Bots home and its
    /// tiles, as `-HERMES_OPEN bots` opens it.
    private static func select(_ target: String, in workspace: BotWorkspace?) -> String {
        guard let workspace else { return "no workspace" }
        if target == "bots" {
            workspace.selection = nil
        } else if target.hasPrefix("group:") {
            workspace.selection = .group(String(target.dropFirst(6)))
        } else if target.hasPrefix("bot:") {
            workspace.selection = .bot(String(target.dropFirst(4)))
        } else {
            return "unknown target"
        }
        workspace.sidebarMode = .bots
        return "selected"
    }

    private static func mode(_ name: String, in workspace: BotWorkspace?) -> String {
        guard let workspace else { return "no workspace" }
        guard let mode = SidebarMode(rawValue: name) else { return "unknown mode" }
        workspace.sidebarMode = mode
        return name
    }

    /// `scroll sidebar 2000 3`: the sidebar's list at that speed, top to bottom and back, that many times.
    private static func scroll(_ argument: String) async -> String {
        let words = argument.split(separator: " ")
        guard words.first == "sidebar", let window = mainWindow else { return "scroll sidebar needs the chats window" }
        let speed = words.count > 1 ? Double(words[1]) ?? 2000 : 2000
        let rounds = words.count > 2 ? Int(words[2]) ?? 3 : 3
        await ScrollRun.shared.scrollSidebar(in: window, speed: speed, rounds: rounds)
        return "scrolled"
    }

    /// `cycle 3 chat:#0,bot:#1,group:#0`: what a click on each row does, in turn, staying 4 s on each,
    /// with the hang log marked as each opens and as it's left.
    private static func cycle(_ argument: String, in workspace: BotWorkspace?) async -> String {
        guard let workspace else { return "no workspace" }
        let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
        guard words.count == 2, let rounds = Int(words[0]) else { return "cycle needs rounds and targets" }
        let targets = words[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var missed: [String] = []
        for round in 1...max(rounds, 1) {
            for target in targets {
                guard open(target, in: workspace) else {
                    if round == 1 { missed.append(target) }
                    continue
                }
                HangLog.shared.mark("cycle \(round): open \(target)")
                try? await Task.sleep(for: .seconds(4))
                HangLog.shared.mark("cycle \(round): settled \(target)")
            }
        }
        return missed.isEmpty ? "cycled" : "cycled, not found: \(missed.joined(separator: ","))"
    }

    private static func open(_ target: String, in workspace: BotWorkspace) -> Bool {
        let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        // `#<n>` picks by place in the list, so a scenario needs no ids from the mock.
        let place = parts[1].hasPrefix("#") ? Int(parts[1].dropFirst()) : nil
        switch parts[0] {
        case "chat":
            let session: HermesSession?
            if let place {
                session = workspace.sessions.indices.contains(place) ? workspace.sessions[place] : nil
            } else {
                session = workspace.session(forKey: parts[1]) ?? .opened(id: parts[1])
            }
            guard let session else { return false }
            workspace.sidebarMode = .chats
            workspace.open(session)
        case "bot":
            let bots = workspace.roster?.visibleBots ?? []
            let name = place.map { bots.indices.contains($0) ? bots[$0].name : "" } ?? parts[1]
            guard !name.isEmpty else { return false }
            workspace.sidebarMode = .bots
            workspace.selection = .bot(name)
        case "group":
            let rooms = workspace.roster?.groupRooms.rooms ?? []
            let id = place.map { rooms.indices.contains($0) ? rooms[$0].id : "" } ?? parts[1]
            guard !id.isEmpty else { return false }
            workspace.sidebarMode = .bots
            workspace.selection = .group(id)
        default:
            return false
        }
        return true
    }

    /// `burst 50 5`: the mock backend sends 50 messages across chats within 5 s.
    private static func burst(_ argument: String) async -> String {
        let numbers = argument.split(separator: " ").compactMap { Double($0) }
        let count = numbers.first ?? 50
        let seconds = numbers.count > 1 ? numbers[1] : 5
        HangLog.shared.mark("burst: \(Int(count)) messages in \(Int(seconds)) s")
        let answer = await mock("/api/mock/burst", ["count": count, "seconds": seconds])
        // The mock answers at once; the messages arrive over the next `seconds`.
        try? await Task.sleep(for: .seconds(seconds + 1))
        HangLog.shared.mark("burst: sent")
        return answer
    }

    /// `sleepwake 30`: the notices `AppModel.watchSleep` hears around a real sleep, posted where it
    /// listens, with the mock's sockets cut in between, as a sleeping Mac's are.
    private static func sleepWake(_ argument: String) async -> String {
        let seconds = Double(argument) ?? 30
        let center = NSWorkspace.shared.notificationCenter
        HangLog.shared.mark("sleepwake: going to sleep")
        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        let answer = await mock("/api/mock/drop-sockets", ["outage": seconds])
        try? await Task.sleep(for: .seconds(seconds))
        HangLog.shared.mark("sleepwake: woke")
        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        try? await Task.sleep(for: .seconds(10))
        HangLog.shared.mark("sleepwake: 10 s after waking")
        return answer
    }

    /// A mock backend's control call. Only a backend on this Mac: these steps never reach a real one.
    private static func mock(_ path: String, _ body: [String: Double]) async -> String {
        guard let base = UserDefaults.standard.string(forKey: "HERMES_BOOTSTRAP_BACKEND").flatMap(URL.init(string:)),
              base.host() == "127.0.0.1", let token = UserDefaults.standard.string(forKey: "HERMES_MOCK_TOKEN")
        else { return "needs -HERMES_BOOTSTRAP_BACKEND on 127.0.0.1 and -HERMES_MOCK_TOKEN" }
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return "mock \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"
        } catch let error as NSError {
            return "mock failed (\(error.domain) \(error.code))"
        }
    }

    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
    }

    /// Toolbar items (the Settings tabs) are in the window's accessibility tree. SwiftUI builds
    /// its content's tree only for an assistive client, so in-page controls use `tap` or `click`.
    /// A tab's press reports "refused" while it switches.
    private static func press(_ label: String) -> String {
        for window in NSApp.windows where window.isVisible {
            if let element = find(label, in: window, depth: 0), element.accessibilityRole() == .button {
                return element.accessibilityPerformPress() ? "pressed" : "refused"
            }
        }
        return "not found"
    }

    /// `click top-button`: the topmost AppKit button in the Settings window's content, clicked
    /// as the mouse would (`performClick`). A page's in-page back button is the topmost one.
    private static func clickTopButton() -> String {
        guard let content = settingsWindow?.contentView else { return "no Settings window" }
        var buttons: [NSControl] = []
        func collect(_ view: NSView) {
            if let control = view as? NSControl, !(view is NSScroller) { buttons.append(control) }
            view.subviews.forEach(collect)
        }
        collect(content)
        guard let top = buttons.max(by: { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY }) else {
            return "no buttons"
        }
        top.performClick(nil)
        return "clicked \(type(of: top)) at \(top.convert(top.bounds, to: nil))"
    }

    /// `tap <x> <y>`: a click at that point of the Settings window, in points from its top left
    /// (a screenshot's pixels halved), sent to the window as the mouse would.
    private static func tap(_ point: String) -> String {
        tap(point, in: settingsWindow)
    }

    /// The largest visible window that isn't Settings: the chats.
    private static var mainWindow: NSWindow? {
        NSApp.windows.filter { $0.isVisible && $0 !== settingsWindow && $0.frame.width >= 480 }.max { $0.frame.width < $1.frame.width }
    }

    private static func tap(_ point: String, in window: NSWindow?) -> String {
        let numbers = point.split(separator: " ").compactMap { Double($0) }
        guard numbers.count == 2, let window else { return "tap needs x y and a window" }
        let location = NSPoint(x: numbers[0], y: window.frame.height - numbers[1])
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { return "no event" }
            window.sendEvent(event)
        }
        return "tapped \(location)"
    }

    private static func frame(_ size: String) -> String {
        let numbers = size.split(separator: " ").compactMap { Double($0) }
        guard numbers.count == 2, let window = mainWindow else { return "frame needs width height and a window" }
        var frame = window.frame
        frame.origin.y += frame.height - numbers[1]
        frame.size = NSSize(width: numbers[0], height: numbers[1])
        window.setFrame(frame, display: true)
        return "frame \(window.frame.size)"
    }

    private static func find(_ label: String, in element: any NSAccessibilityProtocol, depth: Int) -> (any NSAccessibilityProtocol)? {
        guard depth < 40 else { return nil }
        // A toolbar item's group carries its button's label too; only the button is pressed.
        if let own = element.accessibilityLabel(), own == label || own.hasPrefix(label + ","),
           element.accessibilityRole() == .button {
            return element
        }
        for child in element.accessibilityChildren() ?? [] {
            if let child = child as? any NSAccessibilityProtocol, let found = find(label, in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// Every element's role, label and title, indented by depth: what `press` can find.
    private static func dump(_ element: any NSAccessibilityProtocol, depth: Int) {
        guard depth < 40 else { return }
        let role = element.accessibilityRole()?.rawValue ?? "?"
        log(String(repeating: "  ", count: depth) + "\(role) label=\(element.accessibilityLabel() ?? "") title=\(element.accessibilityTitle() ?? "")")
        for child in element.accessibilityChildren() ?? [] {
            if let child = child as? any NSAccessibilityProtocol { dump(child, depth: depth + 1) }
        }
    }

    /// The view tree, with each view's own accessibility children counted.
    private static func dumpViews(_ view: NSView, depth: Int) {
        guard depth < 40 else { return }
        let children = view.accessibilityChildren() ?? []
        let labels = children.compactMap { ($0 as? any NSAccessibilityProtocol)?.accessibilityLabel() }.prefix(6)
        let own = view is NSControl ? " control frame=\(view.convert(view.bounds, to: nil))" : ""
        log(String(repeating: "  ", count: depth) + "\(type(of: view)) ax=\(children.count)\(own) \(labels.joined(separator: " | "))")
        for subview in view.subviews { dumpViews(subview, depth: depth + 1) }
    }

    /// The window frame's views outside the content: the toolbar, its items and their labels.
    private static func dumpToolbar(_ view: NSView, depth: Int) {
        guard depth < 12, view !== settingsWindow?.contentView else { return }
        let text = (view as? NSTextField).map { " \"\($0.stringValue)\" font=\($0.font?.pointSize ?? 0) \($0.font?.fontName ?? "")" } ?? ""
        log(String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.convert(view.bounds, to: nil))\(text)")
        for subview in view.subviews { dumpToolbar(subview, depth: depth + 1) }
    }

    /// `menu View`: each item of a menu bar menu with its shortcut, one level of submenus indented.
    private static func menu(_ title: String) -> String {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu else { return "no \(title) menu" }
        menu.update()
        func list(_ menu: NSMenu, depth: Int) {
            for item in menu.items {
                guard !item.isSeparatorItem else { log(String(repeating: "  ", count: depth) + "—"); continue }
                let shortcut = item.keyEquivalent.isEmpty ? "" : " " + shortcutText(item)
                log(String(repeating: "  ", count: depth) + item.title + shortcut + (item.isEnabled ? "" : " (disabled)"))
                if depth == 0, let submenu = item.submenu { list(submenu, depth: 1) }
            }
        }
        list(menu, depth: 0)
        return "\(menu.items.count) items"
    }

    private static func shortcutText(_ item: NSMenuItem) -> String {
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let names: [Character: String] = [
            Character(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", Character(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            Character(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", Character(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
            "\t": "⇥", "\r": "↩", " ": "Space",
        ]
        return text + item.keyEquivalent.map { names[$0] ?? String($0).uppercased() }.joined()
    }

    /// `tabs`: how many Settings tabs show, of how many, at what window width; none should be in
    /// the » overflow.
    private static func tabs() -> String {
        guard let window = settingsWindow, let toolbar = window.toolbar else { return "no Settings toolbar" }
        let visible = toolbar.visibleItems ?? []
        let clipped = toolbar.items.filter { item in !visible.contains { $0 === item } }.map(\.label)
        return "\(visible.count) of \(toolbar.items.count) tabs at \(Int(window.frame.width)) pt"
            + (clipped.isEmpty ? "" : ", clipped: " + clipped.joined(separator: ", "))
    }

    /// `maintabs`: the chats window's toolbar items by identifier and label, and which of them
    /// went into the » overflow.
    private static func mainToolbarItems() -> String {
        guard let window = mainWindow, let toolbar = window.toolbar else { return "no chats toolbar" }
        let visible = toolbar.visibleItems ?? []
        for item in toolbar.items {
            let shown = visible.contains { $0 === item } ? "shown" : "clipped"
            let label = item.label.isEmpty ? (item.view?.accessibilityLabel() ?? "") : item.label
            log("  \(item.itemIdentifier.rawValue) \"\(label)\" \(shown)")
        }
        return "\(visible.count) of \(toolbar.items.count) items at \(Int(window.frame.width)) pt"
    }

    /// `item View > Show Sidebar`: the item whose title starts with the words given, chosen as
    /// a click would, so its title can change with the state ("Show Sidebar", "Hide Sidebar").
    private static func item(_ path: String) -> String {
        let names = path.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        guard names.count == 2,
              let menu = NSApp.mainMenu?.items.first(where: { $0.title == names[0] })?.submenu
        else { return "item needs <menu> > <item>" }
        menu.update()
        guard let index = menu.items.firstIndex(where: { $0.title.hasPrefix(names[1]) }) else { return "no \(names[1])" }
        guard menu.items[index].isEnabled else { return "\(menu.items[index].title) is disabled" }
        let title = menu.items[index].title
        menu.performActionForItem(at: index)
        return "chose \(title)"
    }

    /// `mainkey esc`: Esc handed to the chats window, which a locked screen can't send.
    /// `mainkey cmd+r`: ⌘R routed as the app routes it, to the window's key equivalents, then the
    /// menus, which answer from the key window's focused values.
    private static func mainKey(_ combo: String) -> String {
        // Tab, the arrows and Return go to the first responder as typed keys do, so `.onKeyPress`
        // and the key view loop see them (the project home's lanes, `docs/projects.md` §2).
        if let (characters, code) = typedKeys[combo] {
            guard let window = mainWindow else { return "no chats window" }
            var flags: NSEvent.ModifierFlags = []
            if code >= 123 { flags.formUnion([.function, .numericPad]) }
            guard let event = keyEvent(characters, code: code, flags: flags, in: window) else { return "no event" }
            window.sendEvent(event)
            return "sent"
        }
        guard combo == "esc" || combo == "cmd+r" else { return "only esc, cmd+r, tab, up, down, left, right and return are supported" }
        let (flags, characters, code): (NSEvent.ModifierFlags, String, UInt16) =
            combo == "esc" ? ([], "\u{1b}", 53) : (.command, "r", 15)
        guard let window = mainWindow, let event = keyEvent(characters, code: code, flags: flags, in: window) else {
            return "no chats window"
        }
        if window.performKeyEquivalent(with: event) { return "handled" }
        guard combo == "cmd+r" else { return "not handled" }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? "handled by the menu" : "not handled"
    }

    private static let typedKeys: [String: (String, UInt16)] = [
        "tab": ("\t", 48), "return": ("\r", 36),
        "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
        "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
    ]

    private static func key(_ combo: String) -> String {
        if combo == "cmd+r" { return settingsCommandR() }
        guard combo == "cmd+[" || combo == "return" else { return "only cmd+[, cmd+r and return are supported" }
        // Return goes to a sheet over Settings when there is one: its default button.
        guard let settings = settingsWindow else { return "no Settings window" }
        let window = combo == "return" ? (settings.attachedSheet ?? settings) : settings
        let (flags, characters, code): (NSEvent.ModifierFlags, String, UInt16) = combo == "return" ? ([], "\r", 36) : (.command, "[", 33)
        guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
              )
        else { return "no event" }
        return window.performKeyEquivalent(with: event) ? "handled" : "not handled"
    }

    /// ⌘R with the Settings window in front: its key equivalents, then the menus, which answer
    /// from the Settings scene's focused values (Setup's Check Again, `docs/setup.md` §3).
    private static func settingsCommandR() -> String {
        guard let settings = settingsWindow, let event = keyEvent("r", code: 15, flags: .command, in: settings) else {
            return "no Settings window"
        }
        if settings.performKeyEquivalent(with: event) { return "handled by the Settings window" }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? "handled by the menu" : "not handled"
    }

    // MARK: The ⌘K palette

    /// The palette's field, found by its placeholder in any window, so it's found whether or not
    /// it's being edited.
    private static var paletteField: NSTextField? {
        let prompt = String(localized: "Search chats, projects and actions")
        func find(_ view: NSView) -> NSTextField? {
            // SwiftUI's own field may name its prompt to accessibility only.
            if let field = view as? NSTextField,
               field.placeholderString == prompt || field.placeholderAttributedString?.string == prompt
                || field.accessibilityPlaceholderValue() == prompt {
                return field
            }
            for subview in view.subviews {
                if let field = find(subview) { return field }
            }
            return nil
        }
        for window in NSApp.windows {
            if let content = window.contentView, let field = find(content) { return field }
        }
        return nil
    }

    /// The chats windows, by their window group's identifier. A copy launched in the background
    /// never shows its windows on the person's Space, where AppKit counts them as not visible.
    private static var chatsWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("\(HermesApp.mainWindow)-") == true && $0.windowNumber > 0 }
    }

    /// A key sent the way the app routes one: a ⌘ key to the window's key equivalents, then the
    /// menus, then as a keyDown to the first responder (the field editor) like every other key.
    private static func paletteKey(_ combo: String) -> String {
        guard let window = paletteField?.window else { return "no palette" }
        let named: [String: (String, UInt16)] = [
            "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126), "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125),
            "return": ("\r", 36), "esc": ("\u{1b}", 53), "space": (" ", 49),
        ]
        let digitCodes: [Character: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25]
        let command = combo.hasPrefix("cmd+")
        let name = command ? String(combo.dropFirst(4)) : combo
        guard let (characters, code) = named[name] ?? name.first.flatMap({ digit in digitCodes[digit].map { (name, $0) } }) else {
            return "unknown key"
        }
        var flags: NSEvent.ModifierFlags = command ? .command : []
        if name == "up" || name == "down" { flags.formUnion([.function, .numericPad]) }
        guard let event = keyEvent(characters, code: code, flags: flags, in: window) else { return "no event" }
        if command {
            if window.performKeyEquivalent(with: event) { return "handled by the window" }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return "handled by the menu" }
        }
        window.sendEvent(event)
        return "sent"
    }

    /// One keyDown per character, so the text goes through the field editor as typing does.
    private static func paletteType(_ text: String) -> String {
        guard let window = paletteField?.window else { return "no palette" }
        for character in text {
            guard let event = keyEvent(String(character), code: character == " " ? 49 : 0, flags: [], in: window) else { return "no event" }
            window.sendEvent(event)
        }
        return "typed \(text.count) keys"
    }

    private static func keyEvent(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )
    }

    /// `palette`: the field's text, whether it's being edited, its field editor's corrections, and
    /// the chats windows with their titles, which name what each one shows. The palette's rows
    /// aren't listed: SwiftUI doesn't hand them to the app's own accessibility walk.
    private static func paletteDump() -> String {
        let windows = chatsWindows.map { "\"\($0.title)\"" }
        let chats = "chats windows: \(windows.count) (\(windows.joined(separator: ", ")))"
        guard let field = paletteField, let window = field.window else {
            return "palette closed · \(chats)"
        }
        let editor = (field.currentEditor() ?? window.fieldEditor(false, for: field)) as? NSTextView
        let corrections = editor.map {
            "replacement \($0.isAutomaticTextReplacementEnabled), spelling correction \($0.isAutomaticSpellingCorrectionEnabled), "
                + "spell checking \($0.isContinuousSpellCheckingEnabled)"
        } ?? "no field editor"
        return "field \"\(field.stringValue)\" (\(field.currentEditor() == nil ? "not editing" : "editing")) · \(corrections) · \(chats)"
    }

    /// The sidebar's lists in the chats window: scroll views over tables, narrower than half the
    /// window and starting in its left half. On the Mac each mode keeps a list of its own.
    private static func sidebarScrollViews(in window: NSWindow) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTableView {
                let frame = scroll.convert(scroll.bounds, to: nil)
                if frame.width < window.frame.width / 2, frame.minX < window.frame.width / 2 { found.append(scroll) }
            }
            view.subviews.forEach(visit)
        }
        window.contentView.map(visit)
        return found
    }

    /// `sidebarlists`: per list, hidden or shown, rows, scroll position, and whether the key view
    /// loop (what Tab walks), a click at its middle, or the window's accessibility tree reaches it.
    private static func sidebarLists() -> String {
        guard let window = mainWindow else { return "no chats window" }
        let lists = sidebarScrollViews(in: window)
        guard !lists.isEmpty else { return "no sidebar list" }
        // Every view Tab can reach from the window's first view, the way AppKit walks it.
        var keyViews: [NSView] = []
        var next = window.contentView?.nextValidKeyView
        while let view = next, keyViews.count < 2000, !keyViews.contains(where: { $0 === view }) {
            keyViews.append(view)
            next = view.nextValidKeyView
        }
        var axElements: [NSObject] = []
        func walkAX(_ element: Any, depth: Int) {
            guard depth < 40, let object = element as? NSObject else { return }
            axElements.append(object)
            for child in (element as? any NSAccessibilityProtocol)?.accessibilityChildren() ?? [] {
                walkAX(child, depth: depth + 1)
            }
        }
        walkAX(window, depth: 0)
        return lists.enumerated().map { index, scroll in
            let table = scroll.documentView as? NSTableView
            let clip = scroll.contentView
            let inside = { (view: NSView) in view === scroll || view.isDescendant(of: scroll) }
            let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
            // hitTest takes a point in the receiver's superview, as a click's does.
            let hit = window.contentView.flatMap { content in content.hitTest(content.superview?.convert(center, from: nil) ?? center) }
            let tabbable = keyViews.filter(inside).count
            let inAX = axElements.contains { element in (element as? NSView).map(inside) ?? false }
            let state = scroll.isHiddenOrHasHiddenAncestor ? "hidden" : "shown"
            return "list \(index) \(state) alpha \(String(format: "%.2f", scroll.alphaValue)) rows \(table?.numberOfRows ?? -1) "
                + "at \(Int(clip.bounds.minY)) of \(Int(scroll.documentView?.frame.height ?? 0)) (inset \(Int(scroll.contentInsets.top))) "
                + "keyViews \(tabbable) tableTakesKey \(table?.canBecomeKeyView ?? false) "
                + "click \(hit.map(inside) ?? false ? "lands" : "misses") ax \(inAX ? "listed" : "absent")"
        }.joined(separator: " | ")
    }

    /// `sidebarat 600`: the shown sidebar list scrolled to 600 points from its top.
    private static func sidebarAt(_ argument: String) -> String {
        guard let window = mainWindow else { return "no chats window" }
        guard let top = Double(argument) else { return "sidebarat needs points" }
        guard let scroll = sidebarScrollViews(in: window).first(where: { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 }) else {
            return "no shown sidebar list"
        }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scroll.reflectScrolledClipView(clip)
        return "at \(Int(clip.bounds.minY))"
    }

    private static func log(_ line: String) {
        print("HERMES_MAC_DRIVE \(line)")
        fflush(stdout)
        guard let path = UserDefaults.standard.string(forKey: "HERMES_MAC_DRIVE_LOG"),
              let data = "HERMES_MAC_DRIVE \(line)\n".data(using: .utf8)
        else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
#endif
