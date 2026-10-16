import Foundation

// Artifacts (`docs/inspector.md` §2, §4): a fenced block in Hermes's reply that is substantial,
// self-contained content (an HTML page, a large SVG, a long piece of code) opens in the Inspector
// instead of sitting inline. Ported from the Hermes desktop app's `lib/artifact-detect.ts` so both
// apps agree on what counts. The gateway has no artifact store: versions are the same slug in later
// replies of the chat, found again from the transcript.

public enum ArtifactKind: String, Sendable, Hashable, Codable {
    case html, svg, code
}

/// What a fence is, when it's an artifact.
public struct ArtifactDetection: Sendable, Hashable {
    public var kind: ArtifactKind
    /// The fence's language, cleaned ("" for HTML/SVG found by shape).
    public var language: String
    /// From `<title>`/`<h1>`, a filename comment, or a named declaration; else the kind.
    public var title: String

    /// One artifact across versions: the same kind, language and title in a chat.
    public var slug: String {
        let lowered = title.lowercased()
        var cleaned = ""
        var lastDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                cleaned.append("-")
                lastDash = true
            }
        }
        let trimmed = String(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
        return "\(kind.rawValue):\(language):\(trimmed.isEmpty ? "untitled" : trimmed)"
    }
}

/// One fenced block of a reply that is an artifact.
public struct ArtifactBlock: Sendable, Hashable {
    public var detection: ArtifactDetection
    public var content: String

    /// A short content fingerprint (FNV-1a), so a reply repeating the same content isn't a version.
    public var contentHash: String { ArtifactDetector.hash(content) }
}

public enum ArtifactDetector {
    static let htmlDocumentMinimum = 160
    static let htmlFragmentMinimum = 1200
    static let svgMinimum = 2000
    static let codeMinimumLines = 48
    static let codeMinimumCharacters = 3000

    static let htmlLanguages: Set<String> = ["html", "htm", "xhtml"]
    /// Prose, terminal output, and fences richer renderers own: never artifacts.
    static let nonArtifactLanguages: Set<String> = [
        "", "console", "diff", "listing", "log", "logs", "markdown", "md", "mermaid", "output", "patch",
        "plain", "plaintext", "shell-session", "stdout", "text", "txt",
    ]

    /// The cleaned fence language: its first word, if it looks like a language tag.
    public static func language(_ tag: String) -> String {
        let first = tag.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let valid = !first.isEmpty && first.count <= 16
            && first.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "+#._-".unicodeScalars.contains($0) }
        return valid ? first.lowercased() : ""
    }

    /// Whether a fence is an artifact, and what kind.
    public static func detect(language tag: String, code: String) -> ArtifactDetection? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let language = language(tag)
        if htmlLanguages.contains(language) {
            let isDocument = trimmed.range(of: #"<!doctype\s+html|<html[\s>]|<head[\s>]|<body[\s>]"#, options: [.regularExpression, .caseInsensitive]) != nil
            let hasTag = trimmed.range(of: #"<[a-z][a-z0-9-]*(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) != nil
            guard (isDocument && trimmed.count >= htmlDocumentMinimum) || (!isDocument && trimmed.count >= htmlFragmentMinimum && hasTag) else { return nil }
            let title = titleFromTag(trimmed, "title") ?? titleFromTag(trimmed, "h1") ?? "HTML"
            return ArtifactDetection(kind: .html, language: language, title: title)
        }
        if language == "svg" {
            guard trimmed.count >= svgMinimum, trimmed.range(of: #"<svg[\s>]"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
            return ArtifactDetection(kind: .svg, language: language, title: titleFromTag(trimmed, "title") ?? "SVG")
        }
        if nonArtifactLanguages.contains(language) { return nil }
        guard trimmed.count >= codeMinimumCharacters || lineCount(trimmed) >= codeMinimumLines else { return nil }
        guard !looksLikeProse(trimmed) else { return nil }
        return ArtifactDetection(kind: .code, language: language, title: codeTitle(language: language, code: trimmed))
    }

    /// Every artifact in a reply's text, in order. Fences that aren't artifacts are left out.
    public static func artifacts(in text: String) -> [ArtifactBlock] {
        fences(in: text).compactMap { fence in
            detect(language: fence.language, code: fence.body).map { ArtifactBlock(detection: $0, content: fence.body.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    /// Fenced blocks (``` or ~~~, three or more) with their info string.
    static func fences(in text: String) -> [(language: String, body: String)] {
        var result: [(String, String)] = []
        var open: (marker: Character, length: Int, info: String, lines: [Substring])?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = line.drop { $0 == " " }
            if var current = open {
                let run = stripped.prefix { $0 == current.marker }
                if run.count >= current.length, stripped.dropFirst(run.count).allSatisfy(\.isWhitespace) {
                    result.append((current.info, current.lines.joined(separator: "\n")))
                    open = nil
                } else {
                    current.lines.append(line)
                    open = current
                }
                continue
            }
            guard let first = stripped.first, first == "`" || first == "~" else { continue }
            let run = stripped.prefix { $0 == first }
            guard run.count >= 3 else { continue }
            let info = String(stripped.dropFirst(run.count)).trimmingCharacters(in: .whitespaces)
            if first == "`", info.contains("`") { continue }
            open = (first, run.count, info, [])
        }
        return result
    }

    static func lineCount(_ text: String) -> Int {
        text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    static func titleFromTag(_ content: String, _ tag: String) -> String? {
        guard let match = content.range(of: "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = String(content[match])
            .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let title = String(inner.prefix(80))
        return title.isEmpty ? nil : title
    }

    static func codeTitle(language: String, code: String) -> String {
        let head = String(code.prefix(2000))
        // `// app.py`, `# server.ts`, `<!-- index.html -->` on the first meaningful line.
        if let firstLine = head.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           let range = firstLine.range(of: #"^\s*(?://|#|--|<!--|/\*)\s*([\w./-]+\.[a-zA-Z0-9]{1,8})\b"#, options: .regularExpression) {
            let match = String(firstLine[range])
            if let name = match.range(of: #"[\w./-]+\.[a-zA-Z0-9]{1,8}$"#, options: .regularExpression) {
                return String(match[name])
            }
        }
        if let range = head.range(of: #"(?:^|\n)\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?(?:function|class|struct|interface|enum|trait|impl|def|fn)\s+([A-Za-z_$][\w$]*)"#, options: .regularExpression) {
            let declaration = String(head[range])
            if let name = declaration.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "$" }).last {
                return String(name)
            }
        }
        return language.isEmpty ? "Code" : language
    }

    /// Long fences of plain sentences (a model wrapping prose in a code block) aren't code.
    static func looksLikeProse(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let codeLike = lines.filter { line in
            line.range(of: #"[{};=<>()\[\]]|^\s*(import|from|let|var|const|func|def|class|return|if|for|while)\b|->|=>|::"#, options: .regularExpression) != nil
        }.count
        let sentences = lines.filter { $0.range(of: #"^[A-Z][^{};=]{30,}[.!?]$"#, options: .regularExpression) != nil }.count
        return codeLike * 4 < lines.count && sentences * 2 >= lines.count
    }

    /// FNV-1a, base 36: the desktop's `artifactContentHash`.
    public static func hash(_ content: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for unit in content.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        return String(hash, radix: 36)
    }

    /// A file name for Save, from the title ("pricing-card.html").
    public static func fileName(for detection: ArtifactDetection) -> String {
        let base = detection.title
            .replacingOccurrences(of: #"[^\p{L}\p{N}._ -]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        let name = String(base.prefix(60)).lowercased()
        let stem = name.isEmpty ? "artifact" : name
        if stem.range(of: #"\.[a-z0-9]{1,8}$"#, options: .regularExpression) != nil { return stem }
        let extensions = ["bash": ".sh", "c": ".c", "cpp": ".cpp", "csharp": ".cs", "css": ".css", "go": ".go", "java": ".java",
                          "javascript": ".js", "js": ".js", "json": ".json", "jsx": ".jsx", "kotlin": ".kt", "php": ".php",
                          "py": ".py", "python": ".py", "rb": ".rb", "ruby": ".rb", "rs": ".rs", "rust": ".rs", "sh": ".sh",
                          "sql": ".sql", "swift": ".swift", "toml": ".toml", "ts": ".ts", "tsx": ".tsx", "typescript": ".ts",
                          "xml": ".xml", "yaml": ".yaml", "yml": ".yaml"]
        let ext = switch detection.kind {
        case .html: ".html"
        case .svg: ".svg"
        case .code: extensions[detection.language] ?? ".txt"
        }
        return stem + ext
    }
}

/// An artifact with its versions in a chat: each later reply with the same slug (and new content)
/// adds one.
public struct Artifact: Sendable, Hashable, Identifiable {
    public struct Version: Sendable, Hashable {
        public var content: String
        /// The reply it came from.
        public var turnID: String
        public var at: Date?
    }

    public var slug: String
    public var detection: ArtifactDetection
    public var versions: [Version]
    public var id: String { slug }

    public var latest: Version { versions[versions.count - 1] }

    /// Every artifact in a chat's replies, versions in reply order. `replies` are (turn id, text,
    /// date) oldest first.
    public static func collect(from replies: [(turnID: String, text: String, at: Date?)]) -> [Artifact] {
        var order: [String] = []
        var bySlug: [String: Artifact] = [:]
        for reply in replies {
            for block in ArtifactDetector.artifacts(in: reply.text) {
                let slug = block.detection.slug
                let version = Version(content: block.content, turnID: reply.turnID, at: reply.at)
                if var existing = bySlug[slug] {
                    guard ArtifactDetector.hash(existing.latest.content) != block.contentHash else { continue }
                    existing.versions.append(version)
                    existing.detection = block.detection
                    bySlug[slug] = existing
                } else {
                    order.append(slug)
                    bySlug[slug] = Artifact(slug: slug, detection: block.detection, versions: [version])
                }
            }
        }
        return order.compactMap { bySlug[$0] }
    }
}
