import Foundation
import Testing
@testable import HermesKit

/// MetricKit's hang and CPU reports, kept in the app's log for the next freeze
/// (docs/development.md, Hangs): the blocked stack survives, nothing a person wrote does.
@Suite("Hang reports: the stack and length kept, nothing personal")
struct HangReportTests {
    /// Shaped like `MXHangDiagnostic.jsonRepresentation()`: the main thread blamed, blocked in
    /// SwiftUI under the app, and a second thread idle.
    static let hang = """
    {
      "version": "1.0.0",
      "diagnosticMetaData": {
        "appVersion": "1.0",
        "appBuildVersion": "2611190410",
        "osVersion": "macOS 27.2 (27C54)",
        "platformArchitecture": "arm64",
        "regionFormat": "HR",
        "bundleIdentifier": "co.caffeinatedcode.hermes",
        "deviceType": "Mac15,9",
        "hangDuration": "2,500 ms"
      },
      "callStackTree": {
        "callStackPerThread": true,
        "callStacks": [
          {
            "threadAttributed": false,
            "callStackRootFrames": [
              {"binaryName": "libsystem_kernel.dylib", "binaryUUID": "AAAA-1111", "offsetIntoBinaryTextSegment": 4096,
               "sampleCount": 25, "address": 7000000000}
            ]
          },
          {
            "threadAttributed": true,
            "callStackRootFrames": [
              {"binaryName": "Hermes", "binaryUUID": "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", "offsetIntoBinaryTextSegment": 74565,
               "sampleCount": 25, "address": 4300000000,
               "subFrames": [
                 {"binaryName": "SwiftUI", "binaryUUID": "BBBB-2222", "offsetIntoBinaryTextSegment": 255, "sampleCount": 24,
                  "subFrames": [
                    {"binaryName": "AttributeGraph", "binaryUUID": "CCCC-3333", "offsetIntoBinaryTextSegment": 16, "sampleCount": 24}
                  ]}
               ]}
            ]
          }
        ]
      }
    }
    """

    @Test func keepsTheLengthTheBuildAndTheBlamedStackFirst() throws {
        let report = try #require(HangReport(json: Data(Self.hang.utf8), kind: .hang))
        #expect(report.seconds == 2.5)
        #expect(report.appVersion == "1.0")
        #expect(report.build == "2611190410")
        #expect(report.os == "macOS 27.2 (27C54)")
        #expect(report.threads.first?.attributed == true)
        #expect(report.threads.first?.frames.map(\.binary) == ["Hermes", "SwiftUI", "AttributeGraph"])
        #expect(report.threads.first?.frames.map(\.depth) == [0, 1, 2])
        #expect(report.threads.first?.frames.first?.offset == 74565)
        #expect(report.lines.first == "hang 2.50 s · app 1.0 (2611190410) · macOS 27.2 (27C54) · arm64")
        #expect(report.lines.contains("    #0 Hermes 0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0 +0x12345 ×25"))
        #expect(report.lines.contains("        #2 AttributeGraph CCCC-3333 +0x10 ×24"))
    }

    @Test func leavesOutTheRegionTheBundleTheDeviceAndAddresses() throws {
        let text = try #require(HangReport(json: Data(Self.hang.utf8), kind: .hang)).lines.joined(separator: "\n")
        for left in ["HR", "co.caffeinatedcode", "Mac15", "7000000000", "4300000000"] {
            #expect(!text.contains(left), "\(left) stayed in the report")
        }
    }

    @Test func aStringCarryingWordsComesThroughCutToTheSafeAlphabet() throws {
        let json = """
        {"diagnosticMetaData": {"hangDuration": "1 sec", "appVersion": "1.0/../\\u201cHi Ana\\u201d <a@b.c> https://x.y/z?k=v"},
         "callStackTree": {"callStacks": [{"threadAttributed": true, "callStackRootFrames": [
           {"binaryName": "Hermes\\nsecret: abc", "binaryUUID": "U", "offsetIntoBinaryTextSegment": 1, "sampleCount": 1}]}]}}
        """
        let report = try #require(HangReport(json: Data(json.utf8), kind: .hang))
        let text = report.lines.joined(separator: "\n")
        // "?" stands in for what was missing, so the URL's query shows by its "=" instead.
        for left in ["/", "\u{201C}", "<", "@", ":", "="] {
            #expect(!text.contains(left), "\(left) stayed in the report")
        }
        #expect(report.threads[0].frames[0].binary == "Hermessecret abc")
        #expect(text.split(separator: "\n").count == 3)
    }

    @Test func aCPUExceptionReadsItsCPUTime() throws {
        let json = """
        {"diagnosticMetaData": {"totalCPUTime": "1.5 min", "totalSampledTime": "3 min"},
         "callStackTree": {"callStacks": [{"threadAttributed": true, "callStackRootFrames": []}]}}
        """
        let report = try #require(HangReport(json: Data(json.utf8), kind: .cpu))
        #expect(report.seconds == 90)
        #expect(report.lines.first?.hasPrefix("cpu exception 90.00 s") == true)
    }

    @Test func refusesWhatIsNotADiagnostic() {
        #expect(HangReport(json: Data("[]".utf8), kind: .hang) == nil)
        #expect(HangReport(json: Data("{\"diagnosticMetaData\": {}}".utf8), kind: .hang) == nil)
        #expect(HangReport(json: Data("not json".utf8), kind: .hang) == nil)
    }

    @Test func aDeepTreeKeepsItsFirstFramesOnly() throws {
        // Written out as text, as MetricKit hands it over: 500 frames deep, the leaf last.
        let depth = HangReport.frameLimit + 100
        let open = #"{"binaryName": "Hermes", "binaryUUID": "U", "offsetIntoBinaryTextSegment": 2, "sampleCount": 1, "subFrames": ["#
        let leaf = #"{"binaryName": "Leaf", "binaryUUID": "U", "offsetIntoBinaryTextSegment": 1, "sampleCount": 1}"#
        let tree = String(repeating: open, count: depth) + leaf + String(repeating: "]}", count: depth)
        let json = #"{"callStackTree": {"callStacks": [{"threadAttributed": true, "callStackRootFrames": ["# + tree + "]}]}}"
        let report = try #require(HangReport(json: Data(json.utf8), kind: .hang))
        #expect(report.threads[0].frames.count == HangReport.frameLimit)
        #expect(report.threads[0].frames.allSatisfy { $0.binary == "Hermes" })
    }

    @Test func theReaderTakesWhatJSONAllowsAndRefusesTheRest() throws {
        let value = try #require(DeepJSON.parse(Data(#" {"a": [1, -2.5, true, false, null, "x\"\u00e9\ud83d\ude00"], "b": {}, "c": []} "#.utf8)) as? [String: Any])
        let list = try #require(value["a"] as? [Any])
        #expect((list[0] as? NSNumber)?.intValue == 1)
        #expect((list[1] as? NSNumber)?.doubleValue == -2.5)
        #expect(list[2] as? Bool == true)
        #expect(list[3] as? Bool == false)
        #expect(list[4] is NSNull)
        #expect(list[5] as? String == "x\"é😀")
        #expect((value["b"] as? [String: Any])?.isEmpty == true)
        #expect((value["c"] as? [Any])?.isEmpty == true)
        for broken in ["", "{", "{\"a\" 1}", "[1,]", "[1] 2", "{\"a\": tru}", "\"open"] {
            #expect(DeepJSON.parse(Data(broken.utf8)) == nil, "\(broken) was read")
        }
    }

    @Test func durationsInMetricKitsUnits() {
        #expect(HangReport.seconds(in: "250 ms") == 0.25)
        #expect(HangReport.seconds(in: "3 sec") == 3)
        #expect(HangReport.seconds(in: "2 min") == 120)
        #expect(HangReport.seconds(in: "soon") == nil)
    }

    @Test func theLogKeepsTheNewestReportsWhole() {
        var log = ""
        for index in 0..<10 {
            log = HangReport.appending("report \(index)\n" + String(repeating: "x", count: 40), to: log, limit: 200)
        }
        #expect(log.utf8.count <= 200)
        #expect(log.hasSuffix("report 9\n" + String(repeating: "x", count: 40) + "\n\n"))
        #expect(!log.contains("report 5"))
        #expect(log.hasPrefix("report "))
        #expect(HangReport.appending(String(repeating: "y", count: 500), to: log, limit: 200).utf8.count == 200)
    }

    @Test func theWatchdogWritesBlocksFromTheThresholdUp() {
        #expect(HangReport.watchdogLine(startMilliseconds: 1000, duration: .milliseconds(249)) == nil)
        #expect(HangReport.watchdogLine(startMilliseconds: 12345.4, duration: .milliseconds(250)) == "HANG start=12345ms duration=250ms")
        #expect(HangReport.watchdogLine(startMilliseconds: 0, duration: .seconds(2.5)) == "HANG start=0ms duration=2500ms")
        #expect(HangReport.watchdogLine(startMilliseconds: 10, duration: .seconds(2), mainCPU: .milliseconds(40))
                == "HANG start=10ms duration=2000ms main-cpu=40ms")
    }
}
