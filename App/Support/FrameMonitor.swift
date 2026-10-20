#if DEBUG && os(iOS)
import QuartzCore
import UIKit

/// Debug only (`-HERMES_FRAME_LOG YES`): logs every frame that took longer than its budget, so a
/// hitch during an animation (opening a chat, the drawer) shows as a line with its length. Times
/// count from the process's start, so a launch reads straight off the log.
@MainActor
final class FrameMonitor: NSObject {
    static let shared = FrameMonitor()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var start: CFTimeInterval = 0
    private var lastCPU: Double = 0
    /// Main-thread CPU time since the last mark: unlike wall time, a busy machine doesn't inflate it.
    private var cpuSinceMark: Double = 0

    private static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }

    /// When the process started, on the display link's clock.
    private static func processStart() -> CFTimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return CACurrentMediaTime() }
        let started = info.kp_proc.p_starttime
        let wall = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return CACurrentMediaTime() - (Date.now.timeIntervalSince1970 - wall)
    }

    func startIfRequested() {
        guard UserDefaults.standard.bool(forKey: "HERMES_FRAME_LOG"), link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        start = Self.processStart()
        mark("launch: root view appears")
    }

    /// Marks an event in the log (a tap, a chat opening) so long frames can be read against it.
    func mark(_ event: String) {
        guard link != nil else { return }
        print(String(format: "FRAMELOG %8.1fms %@ (main cpu since last mark %.1fms, in all %.1fms)", (CACurrentMediaTime() - start) * 1000, event, cpuSinceMark, Self.threadCPU()))
        cpuSinceMark = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let cpu = Self.threadCPU()
        defer { last = now; lastCPU = cpu }
        guard last > 0 else {
            mark("launch: first frame")
            return
        }
        let frame = now - last
        let work = cpu - lastCPU
        cpuSinceMark += work
        if work > 8 {
            print(String(format: "FRAMELOG %8.1fms busy frame: main cpu %.1fms (wall %.1fms)", (now - start) * 1000, work, frame * 1000))
        }
    }
}
#endif
