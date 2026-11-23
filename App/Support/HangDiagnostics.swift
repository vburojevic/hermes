import Foundation
import HermesKit
import MetricKit
import os

/// MetricKit's hang and CPU exception reports, kept in the app's own log so the next freeze report
/// has a stack (docs/development.md, Hangs). Every build subscribes; nothing is sent anywhere.
/// Each report goes through `HangReport`, which keeps binaries, UUIDs, offsets and lengths only,
/// to the system log (category `hangs`) and to `Diagnostics/hangs.log` in Application Support,
/// newest last, about 256 KB at most.
nonisolated final class HangDiagnostics: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = HangDiagnostics()
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "co.caffeinatedcode.hermes", category: "hangs")
    /// One writer at a time: MetricKit calls back on a queue of its own.
    private let writing = DispatchQueue(label: "co.caffeinatedcode.hermes.hang-diagnostics")

    @MainActor
    func start() {
        MXMetricManager.shared.add(self)
        #if DEBUG
        // `-HERMES_HANG_REPORT_SAMPLE YES`: one made-up report through the same path, to see the
        // log and the file written without waiting for MetricKit.
        if UserDefaults.standard.bool(forKey: "HERMES_HANG_REPORT_SAMPLE") {
            writing.async { self.keep(Self.sample, kind: .hang) }
        }
        #endif
    }

    /// Where the reports are kept: Application Support (the app's container on a sandboxed Mac).
    static var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Diagnostics/hangs.log")
    }

    // MetricKit calls this off the main thread, once per delivery; nothing here touches the UI.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap { payload in
            (payload.hangDiagnostics ?? []).map { ($0.jsonRepresentation(), HangReport.Kind.hang) }
                + (payload.cpuExceptionDiagnostics ?? []).map { ($0.jsonRepresentation(), HangReport.Kind.cpu) }
        }
        guard !reports.isEmpty else { return }
        writing.async {
            for (json, kind) in reports { self.keep(json, kind: kind) }
        }
    }

    private func keep(_ json: Data, kind: HangReport.Kind) {
        guard let report = HangReport(json: json, kind: kind) else {
            Self.logger.error("hangs: a \(kind.rawValue, privacy: .public) report that didn't read")
            return
        }
        let lines = report.lines
        // The heading and the blamed thread's top frames in the system log; the whole stack in the file.
        Self.logger.notice("hangs: \(lines.prefix(40).joined(separator: "\n"), privacy: .public)")
        guard let file = Self.file else { return }
        let stamp = Date.now.formatted(.iso8601)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let entry = ([stamp] + lines).joined(separator: "\n")
            try HangReport.appending(entry, to: old).write(to: file, atomically: true, encoding: .utf8)
        } catch let error as NSError {
            Self.logger.error("hangs: couldn't keep the report (\(error.domain, privacy: .public) \(error.code))")
        }
    }

    #if DEBUG
    private static let sample = Data("""
    {"diagnosticMetaData": {"appVersion": "0.0", "appBuildVersion": "sample", "osVersion": "sample",
     "platformArchitecture": "arm64", "hangDuration": "1.2 sec"},
     "callStackTree": {"callStackPerThread": true, "callStacks": [{"threadAttributed": true, "callStackRootFrames": [
       {"binaryName": "Hermes", "binaryUUID": "00000000-0000-0000-0000-000000000000", "offsetIntoBinaryTextSegment": 4096,
        "sampleCount": 12, "subFrames": [{"binaryName": "SwiftUI", "binaryUUID": "00000000-0000-0000-0000-000000000001",
        "offsetIntoBinaryTextSegment": 256, "sampleCount": 12}]}]}]}}
    """.utf8)
    #endif
}
