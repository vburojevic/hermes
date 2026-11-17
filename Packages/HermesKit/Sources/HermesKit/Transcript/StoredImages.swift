import Foundation

/// How Hermes stores the photos a message carried, so the bubble shows them again and only the
/// person's words (`docs/chat.md` §1).
///
/// A turn with photos is a list of parts, and the stored row joins them a line each
/// (`agent/session_persistence.py` `_durable_content`): the text part, a `[screenshot]` line per photo
/// (`[screenshot detail=…]` when the photo carried a detail), then any context Hermes appended for the
/// model as further text parts (`agent/turn_context.py` `_append_multimodal_context`): recalled memory,
/// plugins' `pre_llm_call` context, gateway notes. The text part takes one of two forms:
///
/// - When the gateway runs the turn: the words, or the stock question when there are none, a blank
///   line and an `[Image attached at: <path>]` (or `[Image attached: <url>]`) line per photo
///   (`agent/image_routing.py` `build_native_content_parts`).
/// - When the socket runs it in process: the words, then an `@image:<path>` line per photo that still
///   exists, quoted when the path has spaces or brackets (`tui_gateway/session_history.py`
///   `_build_persist_user_message`). The context an `@file:` attached sits between the words and them.
///
/// Newer rows also carry the text part alone (`display_metadata.typed_ask`); older rows don't, so the
/// split is tied to the photos: a run of N markers counts only with exactly N hint lines after a blank
/// line, or up to N `@image:` lines, right before it. Anything looser would eat brackets the person
/// typed, which are theirs whether or not the message had photos.
public enum StoredImages {
    /// The text part's stand-in when the person sent photos without words (`build_native_content_parts`).
    public static let defaultCaption = "What do you see in this image?"

    /// The person's part of a stored user row, and how many photos it carried. `typedAsk` is the
    /// row's `typed_ask`, when Hermes stamped one.
    public static func split(_ text: String, typedAsk: String? = nil) -> (text: String, count: Int) {
        let photos = typedSplit(text, typedAsk: typedAsk) ?? tiedSplit(text) ?? trailingSplit(text)
        // Only the gateway's form stands the stock question in for missing words; on the socket's
        // form it's what the person typed.
        guard photos.form == .hints, photos.text.trimmingCharacters(in: .whitespacesAndNewlines) == defaultCaption
        else { return (photos.text, photos.count) }
        return ("", photos.count)
    }

    /// How the text part names its photos: hint lines (the gateway) or `@image:` lines (the socket).
    enum Form { case hints, references }

    /// The person's words, how many photos follow them, and how the text part named them.
    struct Photos {
        var text: String
        var count: Int
        var form: Form?
    }

    /// The text part Hermes stamped, when the row starts with it and its photos' markers follow:
    /// everything after the markers is context Hermes added for the model.
    static func typedSplit(_ text: String, typedAsk: String?) -> Photos? {
        guard let typedAsk, !typedAsk.isEmpty,
              let range = text.range(of: typedAsk, options: .anchored)
        else { return nil }
        let after = text[range.upperBound...].components(separatedBy: "\n")
        // The text part ends at a line break, then the markers start.
        guard after.first == "" else { return nil }
        let markers = after.dropFirst().prefix(while: isMarker).count
        guard markers > 0 else { return nil }
        let words = withoutPhotoLines(typedAsk.components(separatedBy: "\n"), count: markers)
        return Photos(text: words?.text ?? typedAsk, count: markers, form: words?.form)
    }

    /// The last run of markers that the lines right before it name, photo for photo.
    static func tiedSplit(_ text: String) -> Photos? {
        let lines = text.components(separatedBy: "\n")
        var end = lines.count
        while end > 0 {
            guard isMarker(lines[end - 1]) else {
                end -= 1
                continue
            }
            var start = end - 1
            while start > 0, isMarker(lines[start - 1]) { start -= 1 }
            let count = end - start
            if let words = withoutPhotoLines(Array(lines[..<start]), count: count) {
                return Photos(text: words.text, count: count, form: words.form)
            }
            end = start
        }
        return nil
    }

    /// The text part's lines without the photo lines for `count` photos: exactly `count` hint lines
    /// after a blank line and the words, or one to `count` `@image:` lines (Hermes leaves out a path
    /// that no longer exists). `nil` when they aren't there.
    static func withoutPhotoLines(_ lines: [String], count: Int) -> (text: String, form: Form)? {
        let hints = lines.suffix(count)
        let blank = lines.count - count - 1
        if hints.count == count, hints.allSatisfy(isHint), blank >= 1, lines[blank].isEmpty,
           lines[..<blank].contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return (lines[..<blank].joined(separator: "\n"), .hints)
        }
        let references = lines.reversed().prefix(while: { isReference($0.trimmingCharacters(in: .whitespaces)) }).count
        if (1...count).contains(references) {
            return (lines.dropLast(references).joined(separator: "\n"), .references)
        }
        return nil
    }

    /// Photo lines at the very end, in any order, as rows from before Hermes added context after
    /// the photos end.
    static func trailingSplit(_ text: String) -> Photos {
        var lines = text.components(separatedBy: "\n")
        var references = 0
        var placeholders = 0
        while let last = lines.last {
            let line = last.trimmingCharacters(in: .whitespaces)
            if isMarker(line) {
                placeholders += 1
            } else if isReference(line) {
                references += 1
            } else if !line.isEmpty {
                break
            }
            lines.removeLast()
        }
        guard references + placeholders > 0 else { return Photos(text: text, count: 0) }
        return Photos(text: lines.joined(separator: "\n"), count: max(references, placeholders),
                      form: references > 0 ? .references : nil)
    }

    /// A photo's place in the row: `[screenshot]`, or with the detail it was sent at (`_image_marker`).
    static func isMarker(_ line: String) -> Bool {
        ["[screenshot]", "[screenshot detail=low]", "[screenshot detail=high]", "[screenshot detail=auto]"].contains(line)
    }

    /// `[Image attached at: <path>]` or `[Image attached: <url>]`, a whole line (`_NATIVE_HINT_RE`).
    static func isHint(_ line: String) -> Bool {
        for prefix in ["[Image attached at: ", "[Image attached: "] where line.hasPrefix(prefix) {
            return line.count > prefix.count + 1 && line.hasSuffix("]")
        }
        return false
    }

    /// `@image:` and a path: bare, or in backticks or quotes (`format_reference_value`).
    static func isReference(_ line: String) -> Bool {
        guard line.hasPrefix("@image:") else { return false }
        let value = line.dropFirst("@image:".count)
        guard let first = value.first else { return false }
        if "`\"'".contains(first) {
            let inside = value.dropFirst().dropLast()
            return value.count > 2 && value.last == first && !inside.contains(first)
        }
        return !value.contains(where: \.isWhitespace)
    }

    /// A chat's preview without its first message's photo lines. Hermes builds the preview from the
    /// stored row with line breaks as spaces and cuts it at 60 characters and "..."
    /// (`hermes_state_common.py` `_shape_preview`): the hints' blank line reads as two spaces, an
    /// `@image:` line or a marker as one, and the cut can land anywhere in them. The preview is cut
    /// only where the rest reads as Hermes's photo lines, so `@image:` or brackets the person typed stay.
    public static func preview(_ preview: String) -> String {
        let isCut = preview.hasSuffix("...")
        let body = isCut ? preview.dropLast(3) : Substring(preview)
        let starts = [body.startIndex] + body.indices.filter { body[$0] == " " }
        for start in starts {
            guard let form = photoRun(body[start...], isCut: isCut, atStart: start == body.startIndex) else { continue }
            let words = body[..<start].trimmingCharacters(in: .whitespaces)
            return form == .hints && words == defaultCaption ? "" : words
        }
        return preview
    }

    /// Whether a preview's tail is Hermes's photo lines, as `_shape_preview` flattens them: hints after
    /// a blank line, or `@image:` lines, or markers alone, then the markers and whatever context
    /// follows them. A cut preview may stop anywhere in them, even in the first line's opening.
    static func photoRun(_ tail: Substring, isCut: Bool, atStart: Bool) -> Form? {
        var rest = tail
        let space = atStart ? "" : " "
        // The first line decides the form. A cut must leave enough of its opening to tell it from
        // the person's own spaces: both spaces before a hint, or a space and three characters.
        let first: [(opening: String, form: Form, shortest: Int)] = [
            ("  [Image attached at: ", .hints, 2), ("  [Image attached: ", .hints, 2),
            (space + "@image:", .references, space.count + 3), (space + "[screenshot", .references, space.count + 3),
        ]
        var form: Form?
        var markers = false
        for candidate in first where form == nil {
            switch line(&rest, candidate.opening, isCut: isCut, shortest: candidate.shortest) {
            case .whole:
                form = candidate.form
                markers = candidate.opening.hasSuffix("[screenshot")
            case .cut: return candidate.form
            case .none: continue
            }
        }
        guard let form else { return nil }
        if markers {
            // Markers right after the words aren't tied to photo lines, so they must look like Hermes's
            // run: more markers, then the end or a bracketed note, never more of the person's sentence.
            while line(&rest, " [screenshot", isCut: false, shortest: 1) == .whole {}
            guard rest.isEmpty || rest.hasPrefix(" [") || rest.hasPrefix(" <") || (isCut && rest == " ")
            else { return nil }
        }
        // Then more of the same photo lines, until the markers start.
        let more = form == .hints ? [" [Image attached at: ", " [Image attached: "] : [" @image:"]
        while !markers {
            if rest.isEmpty { return isCut ? form : nil }
            var found = Line.none
            for opening in more + [" [screenshot"] where found == .none {
                found = line(&rest, opening, isCut: isCut, shortest: 1)
                markers = found == .whole && opening == " [screenshot"
            }
            switch found {
            case .whole: continue
            case .cut: return form
            case .none: return nil
            }
        }
        // After the markers comes the context Hermes added for the model.
        return form
    }

    enum Line { case whole, cut, none }

    /// Reads one flattened photo line that starts with `opening` off the front of `rest`: `.cut` when
    /// the preview's cut lands in it (in its opening, when at least `shortest` characters of it are
    /// left). Hints and markers end at "]"; an `@image:` path at a space, or its closing quote.
    static func line(_ rest: inout Substring, _ opening: String, isCut: Bool, shortest: Int) -> Line {
        guard rest.hasPrefix(opening) else {
            return isCut && rest.count >= shortest && opening.hasPrefix(rest) ? .cut : .none
        }
        let value = rest.dropFirst(opening.count)
        let end: Substring.Index?
        if opening.hasSuffix("@image:") {
            if let quote = value.first, "`\"'".contains(quote) {
                end = value.dropFirst().firstIndex(of: quote).map(value.index(after:))
            } else {
                end = value.firstIndex(of: " ") ?? (isCut ? nil : value.endIndex)
            }
        } else {
            end = value.firstIndex(of: "]").map(value.index(after:))
        }
        guard let end else { return isCut ? .cut : .none }
        let token = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        guard opening.hasSuffix("@image:") ? isReference(token)
                : opening.hasSuffix("[screenshot") ? isMarker(token) : isHint(token)
        else { return .none }
        rest = value[end...]
        return .whole
    }
}
