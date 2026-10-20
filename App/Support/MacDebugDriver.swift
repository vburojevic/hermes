#if DEBUG && os(macOS)
import AppKit

/// Drives the Mac app from inside for checks, without touching the person's screen: a window on
/// another Space can't take input from outside (cua-driver refuses it), but the app can press its
/// own controls through its accessibility tree, as VoiceOver does, and hand a window a key
/// equivalent.
///
/// `-HERMES_MAC_DRIVE "wait 9; press Developer; wait 3; tap 150 190; wait 3; click top-button"`.
/// Steps: `wait <seconds>`; `press <label>` (a toolbar item); `tap <x> <y>` (points from the
/// Settings window's top left: a screenshot's pixels halved); `click top-button` (the topmost
/// AppKit button, which on a pushed page is its back button); `key cmd+[`; `tabs` (Settings tabs
/// shown and clipped); `dump`, `views` and `toolbar` (the accessibility, content and toolbar view
/// trees, with frames). Each step logs `HERMES_MAC_DRIVE` with
/// its result and the Settings window's title, which is the page it shows.
@MainActor
enum MacDebugDriver {
    static func runIfAsked() async {
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
            case "tabs":
                result = tabs()
            case "toolbar":
                if let frame = settingsWindow?.contentView?.superview { dumpToolbar(frame, depth: 0) }
            case "views":
                if let view = settingsWindow?.contentView { dumpViews(view, depth: 0) }
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
        let numbers = point.split(separator: " ").compactMap { Double($0) }
        guard numbers.count == 2, let window = settingsWindow else { return "tap needs x y and a Settings window" }
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

    private static func find(_ label: String, in element: any NSAccessibilityProtocol, depth: Int) -> (any NSAccessibilityProtocol)? {
        guard depth < 40 else { return nil }
        if let own = element.accessibilityLabel(), own == label || own.hasPrefix(label + ",") {
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

    /// `tabs`: how many Settings tabs show, of how many, at what window width; none should be in
    /// the » overflow.
    private static func tabs() -> String {
        guard let window = settingsWindow, let toolbar = window.toolbar else { return "no Settings toolbar" }
        let visible = toolbar.visibleItems ?? []
        let clipped = toolbar.items.filter { item in !visible.contains { $0 === item } }.map(\.label)
        return "\(visible.count) of \(toolbar.items.count) tabs at \(Int(window.frame.width)) pt"
            + (clipped.isEmpty ? "" : ", clipped: " + clipped.joined(separator: ", "))
    }

    private static func key(_ combo: String) -> String {
        guard combo == "cmd+[" else { return "only cmd+[ is supported" }
        guard let window = settingsWindow,
              let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "[", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33
              )
        else { return "no Settings window" }
        return window.performKeyEquivalent(with: event) ? "handled" : "not handled"
    }

    private static func log(_ line: String) {
        print("HERMES_MAC_DRIVE \(line)")
        fflush(stdout)
    }
}
#endif
