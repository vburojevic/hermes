import Foundation
import HermesKit
import OSLog
import PDFKit
import UniformTypeIdentifiers

/// A document going with the next message (`composerFiles`): a PDF, a log, source, anything.
/// Over the gateway protocol it's uploaded (`file.attach` / `pdf.attach`); the API server has
/// no upload, so its text goes inline.
nonisolated struct FileAttachment: Identifiable, Equatable, Sendable {
    let id = UUID()
    var name: String
    var data: Data

    /// The app takes files up to this size (`FileUpload.appLimit`).
    static let maximumSize = FileUpload.appLimit

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
        case notDownloaded(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name): String(localized: "“\(name)” is too large to send. Files can be up to 20 MB.")
            case .unreadable(let name): String(localized: "“\(name)” couldn't be read.")
            case .notDownloaded(let name): String(localized: "“\(name)” couldn't be downloaded. Check your connection and attach it again.")
            }
        }
    }

    private static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "composer")

    /// Reads a file the person picked, inside its security scope.
    static func load(_ url: URL) throws -> FileAttachment {
        let read = try read(url, limit: maximumSize)
        return FileAttachment(name: read.name, data: read.data)
    }

    /// A picked file's name and contents, up to `limit` bytes when there is one.
    ///
    /// The read is coordinated: a file in iCloud Drive or another provider's folder may not be on
    /// the device yet, and only a coordinated read downloads it first (`Data(contentsOf:)` on it
    /// fails). A package or folder (a Pages document) is read as a zip of it.
    static func read(_ url: URL, limit: Int? = nil) throws -> (name: String, data: Data) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .fileSizeKey])
        let isFolder = values?.isDirectory == true
        let name = FileUpload.uploadName(url.lastPathComponent, isFolder: isFolder)
        if FileUpload.isOver(values?.fileSize, limit: limit) { throw LoadError.tooLarge(name) }

        var outcome: Result<Data, LoadError> = .failure(.unreadable(name))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: isFolder ? .forUploading : [], error: &coordinationError) { readable in
            if FileUpload.isOver(try? readable.resourceValues(forKeys: [.fileSizeKey]).fileSize, limit: limit) {
                outcome = .failure(.tooLarge(name))
                return
            }
            guard let data = try? Data(contentsOf: readable) else { return }
            if FileUpload.isOver(data.count, limit: limit) {
                outcome = .failure(.tooLarge(name))
            } else {
                outcome = .success(data)
            }
        }
        if let coordinationError {
            // Logged as domain and code: the description carries the file's path.
            logger.error("attach: a picked file couldn't be read (\(coordinationError.domain, privacy: .public) \(coordinationError.code, privacy: .public))")
            throw values?.isUbiquitousItem == true ? LoadError.notDownloaded(name) : LoadError.unreadable(name)
        }
        return (name, try outcome.get())
    }
}
