#if DEBUG
import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Debug only (`-HERMES_SCROLL_RUN <rounds>`): `-HERMES_SCROLL_AFTER` seconds after launch (10 by
/// default), scrolls the open chat from its end to its top and back (`-HERMES_SCROLL_LEGS up`:
/// only up), `-HERMES_SCROLL_SPEED` points a second (2000 by default), a step each frame as a
/// finger would. The chat takes it as a drag
/// (`drags`), so pages come in at the top and go below as they would under a finger. Each leg is
/// marked (`SCROLLRUN`, and in the frame log on iOS): scroll hitches and the window's changes are
/// read without a tapping tool, whose accessibility queries cost more than the scrolling.
@MainActor
final class ScrollRun {
    static let shared = ScrollRun()
    /// Posted as a run starts moving the chat (`true`) and stops (`false`).
    static let drags = Notification.Name("HermesScrollRunDrags")
    /// Posted `-HERMES_SCROLL_THEN_JUMP` seconds after an up-only run: the chat jumps to its end,
    /// as ⌘↓ or the pill would.
    static let jumpToEnd = Notification.Name("HermesScrollRunJumpToEnd")

    private var timer: Timer?
    private var last: CFTimeInterval = 0
    private var glide: Glide?
    private var started = false
    private let logsSteps = UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG")
    /// While the run moves the chat itself (`HERMES_SCROLL_WHO` counts only the chat's moves).
    private var setting = false

    private struct Glide {
        let scroll: Scrolled
        let up: Bool
        let speed: CGFloat
        let until: CFTimeInterval
        let done: CheckedContinuation<Void, Never>
        /// When it reached the edge, waiting there for more rows.
        var reachedEdge: CFTimeInterval?
    }

    func startIfRequested() {
        let defaults = UserDefaults.standard
        let rounds = defaults.integer(forKey: "HERMES_SCROLL_RUN")
        guard rounds > 0, !started else { return }
        started = true
        let after = defaults.double(forKey: "HERMES_SCROLL_AFTER")
        let speed = defaults.double(forKey: "HERMES_SCROLL_SPEED")
        // `-HERMES_SCROLL_LEGS up`: only up, left far back in the chat (to send, jump or let a
        // turn end from there).
        let upOnly = defaults.string(forKey: "HERMES_SCROLL_LEGS") == "up"
        Task {
            try? await Task.sleep(for: .seconds(after > 0 ? after : 10))
            await run(rounds: rounds, speed: speed > 0 ? speed : 2000, upOnly: upOnly)
        }
    }

    private func run(rounds: Int, speed: CGFloat, upOnly: Bool) async {
        guard let scroll = Scrolled.transcript() else {
            mark("scroll: no chat to scroll")
            return
        }
        #if os(macOS)
        // A covered Mac window gets no frames, so a run in one measures the cover, not the chat:
        // each mark says whether the window is on screen, and a change mid-leg is marked too.
        let covering = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: scroll.view.window, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                ScrollRun.shared.mark("window \(window.occlusionState.contains(.visible) ? "on screen" : "covered")")
            }
        }
        defer { NotificationCenter.default.removeObserver(covering) }
        // With `-HERMES_SCROLL_WHO`: each move of the chat the run didn't make, with who made it.
        var moves: (any NSObjectProtocol)?
        if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_WHO") {
            let clip = scroll.view.contentView
            clip.postsBoundsChangedNotifications = true
            seenTop = clip.bounds.minY
            moves = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
            ) { note in
                guard let clip = note.object as? NSClipView else { return }
                MainActor.assumeIsolated { ScrollRun.shared.noteMove(of: clip) }
            }
        }
        defer { moves.map(NotificationCenter.default.removeObserver) }
        #endif
        for round in 1...rounds {
            mark(String(format: "scroll %d: up from the end (content %.0f pt)", round, scroll.contentHeight)
                + scroll.windowNote)
            await move(scroll, up: true, speed: speed)
            mark(String(format: "scroll %d: top, back down (content %.0f pt)", round, scroll.contentHeight)
                + scroll.windowNote)
            if upOnly {
                let jumpAfter = UserDefaults.standard.double(forKey: "HERMES_SCROLL_THEN_JUMP")
                guard jumpAfter > 0 else { return }
                try? await Task.sleep(for: .seconds(jumpAfter))
                mark("scroll: jump to the end")
                NotificationCenter.default.post(name: Self.jumpToEnd, object: nil)
                return
            }
            await move(scroll, up: false, speed: speed)
            mark(String(format: "scroll %d: end (content %.0f pt)", round, scroll.contentHeight) + scroll.windowNote)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    #if os(macOS)
    /// Where the chat's clip view was last seen (`HERMES_SCROLL_WHO`).
    private var seenTop: CGFloat = 0

    private func noteMove(of clip: NSClipView) {
        let now = clip.bounds.minY
        defer { seenTop = now }
        guard !setting, abs(now - seenTop) > 0.01 else { return }
        // Each frame without its index; deep enough to reach the layout pass that moved it.
        let callers = Thread.callStackSymbols.dropFirst(2).prefix(48).map { frame in
            let words = frame.split(separator: " ", omittingEmptySubsequences: true).dropFirst()
            return String(words.joined(separator: " ").prefix(120))
        }
        print(String(format: "SCROLLRUN chat moved %.2f -> %.2f by ", Double(seenTop), Double(now))
            + callers.joined(separator: " < "))
    }
    #endif

    private func mark(_ event: String) {
        print("SCROLLRUN \(Int(CACurrentMediaTime() * 1000) % 100_000)ms \(event)")
        HangLog.shared.mark(event)
        #if os(iOS)
        FrameMonitor.shared.mark(event)
        #endif
    }

    #if os(macOS)
    /// Scrolls the main window's sidebar from its top to its end and back, `rounds` times, at
    /// `speed` points a second (the Mac driver's `scroll sidebar` step). The chat list isn't a
    /// drag the transcript should hear of, so nothing is posted.
    func scrollSidebar(in window: NSWindow, speed: CGFloat, rounds: Int) async {
        guard let scroll = Scrolled.sidebar(in: window) else {
            mark("scroll sidebar: no sidebar list to scroll")
            return
        }
        scroll.offset = scroll.top
        for round in 1...max(rounds, 1) {
            mark(String(format: "scroll sidebar %d: down from the top (content %.0f pt)", round, scroll.contentHeight)
                + scroll.windowNote)
            await move(scroll, up: false, speed: speed, drags: false)
            mark(String(format: "scroll sidebar %d: end, back up (content %.0f pt)", round, scroll.contentHeight)
                + scroll.windowNote)
            await move(scroll, up: true, speed: speed, drags: false)
            mark(String(format: "scroll sidebar %d: top", round) + scroll.windowNote)
        }
    }
    #endif

    /// Moves `scroll` to its top or end, at most 150 s (a 300-turn chat at 3000 pt/s takes about
    /// 100): pages coming in and going on the way change its length.
    private func move(_ scroll: Scrolled, up: Bool, speed: CGFloat, drags: Bool = true) async {
        if drags { NotificationCenter.default.post(name: Self.drags, object: true) }
        await withCheckedContinuation { done in
            glide = Glide(scroll: scroll, up: up, speed: speed, until: CACurrentMediaTime() + 150, done: done)
            last = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        timer?.invalidate()
        timer = nil
        if drags { NotificationCenter.default.post(name: Self.drags, object: false) }
    }

    private func tick() {
        guard let glide else { return }
        let now = CACurrentMediaTime()
        let frame = now - last
        last = now
        let scroll = glide.scroll
        let step = glide.speed * frame * (glide.up ? -1 : 1)
        let from = scroll.offset
        let y = min(max(from + step, scroll.top), scroll.end)
        setting = true
        scroll.offset = y
        setting = false
        // With the scroll log: what the run set and where it found the chat, so a check can tell
        // its moves from the chat's (with the rows' tops, `SCROLLLOG row`, what moved on screen).
        if logsSteps { print(String(format: "SCROLLRUN set %.0f from %.0f", Double(y), Double(from))) }
        // At an edge, more rows may be on their way, as when a finger stops there: rows that
        // come in give the run room, and it carries on.
        let reached = glide.up ? y <= scroll.top : y >= scroll.end
        if reached, now < glide.until {
            // Marked, so a check can tell how long the run waited at the edge for rows.
            if glide.reachedEdge == nil, logsSteps { mark("waiting at the edge") }
            let since = glide.reachedEdge ?? now
            self.glide?.reachedEdge = since
            if now - since < 4 { return }
        } else if !reached {
            if glide.reachedEdge != nil, logsSteps { mark("moving again") }
            self.glide?.reachedEdge = nil
        }
        if reached || now >= glide.until {
            self.glide = nil
            glide.done.resume()
        }
    }
}

/// The open chat's scroll view, on either platform: the one showing the most of the window, with
/// more to show than fits (the sidebar's list is narrower).
@MainActor
private struct Scrolled {
    #if os(iOS)
    let view: UIScrollView

    var contentHeight: CGFloat { view.contentSize.height }
    var windowNote: String { "" }
    var top: CGFloat { -view.adjustedContentInset.top }
    var end: CGFloat { max(top, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom) }
    var offset: CGFloat {
        get { view.contentOffset.y }
        nonmutating set { view.contentOffset.y = newValue }
    }

    static func transcript() -> Scrolled? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter(\.isKeyWindow)
        var best: (view: UIScrollView, area: CGFloat)?
        func visit(_ view: UIView, in window: UIWindow) {
            if let scroll = view as? UIScrollView, !scroll.isHidden, scroll.contentSize.height > scroll.bounds.height {
                let shown = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
                let area = shown.isNull ? 0 : shown.width * shown.height
                if area > best?.area ?? 0 { best = (scroll, area) }
            }
            view.subviews.forEach { visit($0, in: window) }
        }
        windows.forEach { visit($0, in: $0) }
        return best.map { Scrolled(view: $0.view) }
    }
    #else
    let view: NSScrollView

    private var clip: NSClipView { view.contentView }
    var contentHeight: CGFloat { view.documentView?.frame.height ?? 0 }
    var windowNote: String {
        ", window " + (view.window?.occlusionState.contains(.visible) == true ? "on screen" : "covered")
    }
    var top: CGFloat { -view.contentInsets.top }
    var end: CGFloat { max(top, contentHeight - clip.bounds.height + view.contentInsets.bottom) }
    /// From the content's top, whichever way the document view runs.
    var offset: CGFloat {
        get { view.documentView?.isFlipped == false ? contentHeight - clip.bounds.maxY : clip.bounds.minY }
        nonmutating set {
            let y = view.documentView?.isFlipped == false ? contentHeight - newValue - clip.bounds.height : newValue
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            view.reflectScrolledClipView(clip)
        }
    }

    static func transcript() -> Scrolled? {
        var best: (view: NSScrollView, area: CGFloat)?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHidden,
               (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height {
                let area = scroll.visibleRect.width * scroll.visibleRect.height
                if area > best?.area ?? 0 { best = (scroll, area) }
            }
            view.subviews.forEach(visit)
        }
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView { visit(content) }
        }
        return best.map { Scrolled(view: $0.view) }
    }

    /// The sidebar's list: the leftmost scroll view in `window` with more to show than fits,
    /// narrower than half the window.
    static func sidebar(in window: NSWindow) -> Scrolled? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHidden,
               (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height {
                let frame = scroll.convert(scroll.bounds, to: nil)
                if frame.width < window.frame.width / 2, frame.minX < (best.map { $0.convert($0.bounds, to: nil).minX } ?? .infinity) {
                    best = scroll
                }
            }
            view.subviews.forEach(visit)
        }
        window.contentView.map(visit)
        return best.map { Scrolled(view: $0) }
    }
    #endif
}
#endif
