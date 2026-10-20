import Foundation
@testable import HermesKit
import Testing

/// The fast paths read the same results as the slow ones they replace.
@Suite("Performance paths")
struct PerformanceTests {
    /// `JSONValue.parse` (one pass over JSONSerialization) agrees with the Codable decoder.
    @Test func oneJSONPassMatchesTheDecoder() throws {
        let samples = [
            #"{"method":"event","params":{"type":"message.delta","session_id":"s1","seq":42,"payload":{"text":"Hé 👋 \n\"quoted\""}}}"#,
            #"{"a":true,"b":false,"c":0,"d":1,"e":-3.5,"f":1e21,"g":null,"h":[1,"two",false,null,{"x":[]}],"i":{}}"#,
            #"[{"nested":{"deep":[[1,2],[3]]}},"",0.1]"#,
            #""just a string""#,
            #"12345"#,
            #"true"#,
        ]
        for sample in samples {
            let fast = try #require(JSONValue.parse(sample))
            let slow = try JSONDecoder().decode(JSONValue.self, from: Data(sample.utf8))
            #expect(fast == slow, "\(sample)")
        }
    }

    @Test func booleansStayBooleansAndNumbersStayNumbers() throws {
        let json = try #require(JSONValue.parse(#"{"yes":true,"one":1,"zero":0,"no":false}"#))
        #expect(json["yes"] == .bool(true))
        #expect(json["no"] == .bool(false))
        #expect(json["one"] == .number(1))
        #expect(json["zero"] == .number(0))
    }

    @Test func notJSONIsNil() {
        #expect(JSONValue.parse("{oops") == nil)
        #expect(JSONValue.parse("") == nil)
        #expect(throws: DecodingError.self) { try JSONValue.decode(Data("nope".utf8)) }
    }

    @Test func gatewayFramesStillParse() throws {
        let frame = try #require(GatewayFrame.parse(#"{"jsonrpc":"2.0","id":"7","result":{"ok":true}}"#))
        guard case .response(let id, let result, let error) = frame else { Issue.record("not a response"); return }
        #expect(id == "7" && result?["ok"] == .bool(true) && error == nil)
    }
}
