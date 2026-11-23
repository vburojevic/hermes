#if DEBUG
import Foundation
import HermesKit
import QuartzCore
import os

/// Debug only (`-HERMES_HANG_LOG /path/hangs.txt`): a watchdog thread pings the main queue every
/// 20 ms and writes one line for each block of the main thread of 250 ms or more, with when it
/// started, how long it lasted and the main thread's CPU time meanwhile, which tells a busy main
/// thread from a starved one (docs/development.md, Hangs). `mark` writes a scenario's steps
/// into the same file, so a block reads against what was happening. Times count from the
/// process's start, like the frame log's.
nonisolated final class HangLog: Sendable {
    static let shared = HangLog()
    private struct State {
        var file: FileHandle?
        var start: CFTimeInterval = 0
        var mainThread: thread_act_t = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private static let interval: TimeInterval = 0.02

    func startIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "HERMES_HANG_LOG"), !path.isEmpty else { return }
        let started = state.withLock { state -> Bool in
            guard state.file == nil else { return false }
            FileManager.default.createFile(atPath: path, contents: nil)
            state.file = FileHandle(forWritingAtPath: path)
            state.start = Self.processStart()
            // Called on the main thread, so this is the thread the watchdog times.
            state.mainThread = pthread_mach_thread_np(pthread_self())
            return state.file != nil
        }
        guard started else { return }
        mark("hang log: watching the main thread")
        let thread = Thread { [self] in watch() }
        thread.name = "HangLog watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Writes a step of a scenario (a scroll leg, a burst, a sleep) into the log.
    func mark(_ event: String) {
        write(String(format: "MARK at=%.0fms %@", milliseconds(at: CACurrentMediaTime()), event))
    }

    private func watch() {
        let answered = DispatchSemaphore(value: 0)
        let main = state.withLock(\.mainThread)
        while true {
            let sent = CACurrentMediaTime()
            let cpuBefore = Self.cpuTime(of: main)
            DispatchQueue.main.async { answered.signal() }
            answered.wait()
            let late = CACurrentMediaTime() - sent
            var used: Duration?
            if let cpuBefore, let cpuAfter = Self.cpuTime(of: main) { used = .seconds(cpuAfter - cpuBefore) }
            if let line = HangReport.watchdogLine(startMilliseconds: milliseconds(at: sent), duration: .seconds(late),
                                                  mainCPU: used) {
                write(line)
            }
            Thread.sleep(forTimeInterval: Self.interval)
        }
    }

    private func milliseconds(at time: CFTimeInterval) -> Double {
        (time - state.withLock(\.start)) * 1000
    }

    private func write(_ line: String) {
        state.withLock { state in
            state.file?.write(Data((line + "\n").utf8))
        }
    }

    /// The user and system time a thread has used, in seconds.
    private static func cpuTime(of thread: thread_act_t) -> Double? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        func seconds(_ time: time_value_t) -> Double { Double(time.seconds) + Double(time.microseconds) / 1_000_000 }
        return seconds(info.user_time) + seconds(info.system_time)
    }

    /// When the process started, on `CACurrentMediaTime`'s clock (the frame log does the same).
    private static func processStart() -> CFTimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return CACurrentMediaTime() }
        let started = info.kp_proc.p_starttime
        let wall = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return CACurrentMediaTime() - (Date.now.timeIntervalSince1970 - wall)
    }
}
#endif
