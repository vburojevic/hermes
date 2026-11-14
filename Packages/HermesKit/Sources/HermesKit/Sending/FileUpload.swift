import Foundation

/// How large a file may go to Hermes, and under what name (`docs/composer.md` §2).
public enum FileUpload {
    /// The app takes files up to 20 MB, well under Hermes's own 256 MB cap.
    public static let appLimit = 20 * 1024 * 1024

    /// A file goes whole in one socket frame, as base64 (4 bytes for every 3). Before Hermes 0.23.1
    /// the backend's socket took frames of up to 16 MiB (uvicorn's default) and closed on a larger
    /// one, so the file never arrived; 12 MB leaves room for the frame's JSON around it. 0.23.1 raised
    /// the frame to 384 MiB (hermes-agent `hermes_cli/web_server_boundary.py`,
    /// `_DESKTOP_ATTACHMENT_WS_MAX_BYTES`).
    public static let olderHermesLimit = 12 * 1000 * 1000
    /// `olderHermesLimit` as the person reads it.
    public static let olderHermesLimitText = "12 MB"
    static let largeFramesSince = [0, 23, 1]

    /// The largest file the Hermes at `hermesVersion` takes. One whose version isn't known yet is
    /// taken to be older: a frame it can't read closes the socket, and the message never arrives.
    public static func limit(hermesVersion: String?) -> Int {
        takesLargeFrames(hermesVersion: hermesVersion) ? appLimit : olderHermesLimit
    }

    /// Whether this Hermes reads frames large enough for any file the app sends.
    public static func takesLargeFrames(hermesVersion: String?) -> Bool {
        guard let parts = versionParts(hermesVersion) else { return false }
        return parts.lexicographicallyPrecedes(largeFramesSince) == false
    }

    /// "0.23.1", "v0.24.0" or "0.23.1rc3" → [0, 23, 1]; nil when it doesn't start with a number.
    static func versionParts(_ version: String?) -> [Int]? {
        guard var text = version?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        var parts: [Int] = []
        for component in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(component.prefix { $0.isASCII && $0.isNumber }) else { break }
            parts.append(number)
        }
        guard !parts.isEmpty else { return nil }
        // Compared as major.minor.patch: a missing part is 0.
        return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
    }

    /// The name a picked file goes under: a package or folder (a Pages document, a folder from
    /// Files) goes as a zip of it, named for it.
    public static func uploadName(_ name: String, isFolder: Bool) -> String {
        isFolder ? name + ".zip" : name
    }

    /// Whether a file of `size` bytes is over `limit`. A size the system didn't give is never over:
    /// the read itself checks again.
    public static func isOver(_ size: Int?, limit: Int?) -> Bool {
        guard let size, let limit else { return false }
        return size > limit
    }
}
