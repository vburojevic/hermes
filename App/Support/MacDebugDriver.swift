#if DEBUG && os(macOS)
import AppKit

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
/// `mainkey esc` (Esc in the chats window); `sidebar` (the sidebar button's action); `dump`,
/// `views` and `toolbar` (the accessibility, content and toolbar view trees, with frames). The ⌘K
/// palette: `paletteopen`, `palettekey up|down|return|esc|space|cmd+return|cmd+<digit>`,
/// `palettetype <text>` (typed into its field as keys, one per character), `paletteblur` (takes
/// the field out of editing) and `palette` (the field's text, the field editor's corrections and
/// the chats windows' titles). Each step logs `HERMES_MAC_DRIVE` with its result and the Settings
/// window's title, which is the page it shows, to `-HERMES_MAC_DRIVE_LOG <file>` too when it's given.
@MainActor
enum MacDebugDriver {
    static func runIfAsked(router: WindowRouter) async {
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
            default:
                result = "unknown step"
            }
            log("\(step) → \(result) · window: \(settingsWindow?.title ?? "none")")
        }
        log("done")
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
    private static func mainKey(_ combo: String) -> String {
        guard combo == "esc" else { return "only esc is supported" }
        guard let window = mainWindow,
              let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
              )
        else { return "no chats window" }
        return window.performKeyEquivalent(with: event) ? "handled" : "not handled"
    }

    private static func key(_ combo: String) -> String {
        guard combo == "cmd+[" || combo == "return" else { return "only cmd+[ and return are supported" }
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
