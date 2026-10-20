import Foundation
import HermesKit
import PDFKit
import UniformTypeIdentifiers

/// A document going with the next message (`composerFiles`): a PDF, a log, source, anything.
/// Over the gateway protocol it's uploaded (`file.attach` / `pdf.attach`); the API server has
/// no upload, so its text goes inline.
nonisolated struct FileAttachment: Identifiable, Equatable, Sendable {
    let id = UUID()
    var name: String
    var data: Data

    /// Hermes takes files up to this size.
    static let maximumSize = 20 * 1024 * 1024

    var isPDF: Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .pdf) ?? false
    }

    var symbol: String {
        isPDF ? "doc.richtext.fill" : "doc.text"
    }

    var mimeType: String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    /// The file as text for the API server, or `nil` when it isn't text (or a PDF with a text layer).
    var inlineText: String? {
        if isPDF {
            guard let text = PDFDocument(data: data)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") else { return nil }
        return text
    }

    enum LoadError: LocalizedError {
        case tooLarge(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name): String(localized: "“\(name)” is too large to send. Files can be up to 20 MB.")
            case .unreadable(let name): String(localized: "“\(name)” couldn't be read.")
            }
        }
    }

    /// Reads a file the person picked, inside its security scope.
    static func load(_ url: URL) throws -> FileAttachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumSize {
            throw LoadError.tooLarge(name)
        }
        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(name) }
        guard data.count <= maximumSize else { throw LoadError.tooLarge(name) }
        return FileAttachment(name: name, data: data)
    }
}
