import Foundation
import Testing
@testable import HermesKit

/// Hermes refusing a file attached to a message, in plain words with the file's name
/// (`docs/composer.md` §2). The messages are Hermes's own (hermes-agent
/// `tui_gateway/methods_prompt.py`, `tui_gateway/prompt_attachments.py`, `tui_gateway/server.py`).
@Suite("Hermes refusing a file")
struct FileRefusalTests {
    private func refusal(_ code: Int, _ message: String, name: String = "report.zip") -> FileRefusal {
        FileRefusal(name: name, GatewayRPCError(code: code, message: message))
    }

    @Test func aFullDiskSaysSoInsteadOfTheErrno() {
        let refused = refusal(5028, "[Errno 28] No space left on device: 'report.zip'")
        #expect(refused.reason == .diskFull)
        #expect(refused.errorDescription == "Hermes couldn't save “report.zip”: its computer is out of disk space.")
        #expect(refused.errorDescription?.contains("Errno") == false)
    }

    @Test func aFileOverHermesCapNamesTheCap() {
        let refused = refusal(5028, "attachment too large (300000000 bytes; cap is 256 MB)")
        #expect(refused.reason == .tooLarge(cap: "256 MB"))
        #expect(refused.errorDescription == "“report.zip” is larger than Hermes takes. Files can be up to 256 MB.")
    }

    @Test func aCapHermesDoesNotNameIsLeftOut() {
        let refused = refusal(5028, "attachment too large")
        #expect(refused.reason == .tooLarge(cap: nil))
        #expect(refused.errorDescription == "“report.zip” is larger than Hermes takes.")
    }

    @Test func aBrokenOrMissingPayloadAsksToSendAgain() {
        #expect(refusal(5028, "invalid data_url payload").reason == .damaged)
        #expect(refusal(4015, "path or data_url required").reason == .damaged)
        #expect(refusal(4015, "path or data_url required").errorDescription == "“report.zip” didn't reach Hermes whole. Send it again.")
    }

    @Test func aFolderHermesCannotWriteToSaysSo() {
        let refused = refusal(5028, "[Errno 13] Permission denied: '/home/h/.hermes/sessions/x/attachments/report.zip'")
        #expect(refused.reason == .noPermission)
        #expect(refused.errorDescription?.contains("/home") == false)
    }

    @Test func aGatewayWithoutUploadsAsksForAnUpdate() {
        let refused = refusal(-32601, "unknown method: file.attach — not available on this Hermes backend")
        #expect(refused.reason == .notSupported)
        #expect(refused.errorDescription == "This Hermes can't take files. Update Hermes on its computer to send “report.zip”.")
    }

    @Test func anythingElseKeepsHermesOwnFirstLine() {
        let refused = refusal(5028, "pdftoppm failed: bad xref\nTraceback (most recent call last):")
        #expect(refused.reason == .other)
        #expect(refused.errorDescription == "Hermes couldn't take “report.zip”: pdftoppm failed: bad xref")
        #expect(refusal(5028, "").errorDescription == "Hermes couldn't take “report.zip”: it gave no reason.")
    }

    /// Nothing was submitted: the message goes back to the person, never round the gateway.
    @Test func aRefusedFileGoesBackToThePerson() {
        #expect(SendFailure.overSocket(refusal(5028, "[Errno 28] No space left on device: 'x'")) == .refused)
    }

    /// A session Hermes no longer has is the send's to resume, and a retiring socket's to reconnect:
    /// neither is a refusal of the file.
    @Test func aLostSessionOrSocketIsNotAboutTheFile() {
        #expect(FileRefusal(name: "a.pdf", refusing: GatewayRPCError(code: 4001, message: "session not found")) == nil)
        #expect(FileRefusal(name: "a.pdf", refusing: GatewayRPCError(code: 5035, message: "reconnect to continue")) == nil)
        #expect(FileRefusal(name: "a.pdf", refusing: URLError(.networkConnectionLost)) == nil)
        #expect(FileRefusal(name: "a.pdf", refusing: CancellationError()) == nil)
        #expect(FileRefusal(name: "a.pdf", refusing: GatewayRPCError(code: 4018, message: "PDF too large; cap is 50 MB"))?.reason == .tooLarge(cap: "50 MB"))
    }

    @Test func aFileTooLargeForAnOlderHermesSaysToUpdateIt() {
        let refused = FileRefusal.tooLargeForThisHermes(name: "scan.zip")
        #expect(refused.errorDescription == "“scan.zip” is larger than this Hermes takes. Files can be up to 12 MB until Hermes on its computer is updated.")
        #expect(SendFailure.overSocket(refused) == .refused)
    }
}
