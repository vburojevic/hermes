import HermesKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformView = NSView
#endif

// The composer's text (`docs/commands-and-references.md` §2). SwiftUI's `TextField` and
// `TextEditor` can't hold views inline (the iOS/macOS 27 SDK's `AttributedString` editing has
// formatting and selection, no attachment views), so this wraps a TextKit 2 `UITextView` /
// `NSTextView`. Each pill is one `NSTextAttachment` character whose view comes from an
// `NSTextAttachmentViewProvider`: the caret moves around it, one Delete removes it, a
// selection covers it whole. Copy gives the plain form (`@writer`, `@file:path`); pasting a
// roster `@handle` makes a pill.

/// What's being typed after a trigger (`queryToken`): drawn in a grey capsule while the menu
/// for it is open.
struct ComposerQuery: Equatable {
    var trigger: Character
    /// What follows the trigger.
    var text: String
    /// Where the token sits in the field's text storage.
    var range: NSRange
}

/// A key the composer handles before the text does.
enum ComposerKey {
    /// Return. On the Mac ⌥Return is `sendNext` and ⌘Return `redirect` (docs/follow-ups.md §1);
    /// an iPad's hardware keyboard has ⌥Return open the mode menu (`modeMenu`) and ⌘Return send
    /// as Send Next (§4a). With no turn running they're a new line and Send.
    case send, newline, sendNext, redirect, modeMenu, up, down, tab, escape
    /// ⌘Return on an iPad's keyboard with no turn running: Send, whether or not Return sends.
    case commandSend
}

/// A pill the person long-pressed (hovered on the Mac): what it is and where, in the field's
/// own coordinates.
struct PillPeek: Identifiable, Equatable {
    var item: PreviewItem
    var rect: CGRect
    var id: String { "\(item)" }
}

/// Talks to the field: inserts pills, replaces the query, reports the token being typed.
@MainActor
@Observable
final class PillTextController {
    private(set) var query: ComposerQuery?
    /// The menu for the query is open, so its capsule shows.
    var showsCapsule = false {
        didSet { if showsCapsule != oldValue { coordinator?.updateCapsule() } }
    }
    @ObservationIgnored fileprivate weak var coordinator: PillTextView.Coordinator?

    fileprivate func setQuery(_ query: ComposerQuery?) {
        if query != self.query { self.query = query }
    }

    /// Replaces the query with a pill and a space.
    func insert(_ reference: MessageReference) {
        coordinator?.replaceQuery(with: .reference(reference))
    }

    /// Replaces the query with text (a folder's path to keep completing; nothing for a skill).
    func replaceQuery(with text: String) {
        coordinator?.replaceQuery(with: .text(text))
    }

    func remove(_ reference: MessageReference) {
        coordinator?.remove(reference)
    }

    func focus() {
        coordinator?.focus()
    }

    #if DEBUG
    /// Types as the keyboard would (`-HERMES_TYPE`): focus, then the query and menu follow.
    func typeForTesting(_ text: String) {
        coordinator?.typeForTesting(text)
    }
    #endif

    // MARK: Dictation (`docs/voice.md` §5)

    /// Dictated words go where the caret is (over the selection); typing carries on around them.
    func beginDictation() {
        coordinator?.beginDictation()
    }

    /// The words so far: settled ones in ink, the ones still being heard lighter.
    func updateDictation(settled: String, volatile: String) {
        coordinator?.updateDictation(settled: settled, volatile: volatile)
    }

    /// Done: the words stay, as ordinary text.
    func endDictation(_ words: String) {
        coordinator?.endDictation(words)
    }

    /// Cancel: the dictated words go.
    func cancelDictation() {
        coordinator?.endDictation("")
    }
}

extension NSAttributedString.Key {
    /// Marks the words dictation is filling in, so typing elsewhere leaves them alone.
    static let dictation = NSAttributedString.Key("HermesDictation")
}

/// One pill in the field. TextKit calls these on the main thread; the class itself isn't
/// main-actor isolated because `NSTextAttachment` isn't.
nonisolated final class PillAttachment: NSTextAttachment {
    enum Content: Equatable {
        case reference(MessageReference)
        case command(String)
    }

    let content: Content
    let size: CGSize
    /// Makes the pill's view, and whatever has to stay alive with it (the hosting controller).
    let makeView: @MainActor () -> (view: PlatformView, owner: AnyObject?)
    /// The view on screen now, for anchoring its preview.
    weak var liveView: PlatformView?

    init(content: Content, size: CGSize, makeView: @escaping @MainActor () -> (view: PlatformView, owner: AnyObject?)) {
        self.content = content
        self.size = size
        self.makeView = makeView
        super.init(data: nil, ofType: nil)
        // On iOS/macOS 27 neither UITextView nor NSTextView (TextKit 2) loaded the view of an
        // `NSTextAttachmentViewProvider` (UIKit drew the generic document glyph, AppKit left the
        // space empty), so the attachment only reserves the pill's space and the field places
        // the pill's view itself (`Coordinator.layoutPills`).
        allowsTextAttachmentView = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The pill's view draws it; the attachment itself draws nothing.
    #if os(iOS)
    override func image(for imageBounds: CGRect, attributes: [NSAttributedString.Key: Any] = [:], location: any NSTextLocation, textContainer: NSTextContainer?) -> UIImage? {
        UIGraphicsImageRenderer(size: CGSize(width: max(imageBounds.width, 1), height: max(imageBounds.height, 1))).image { _ in }
    }
    #else
    override func image(for imageBounds: CGRect, attributes: [NSAttributedString.Key: Any] = [:], location: any NSTextLocation, textContainer: NSTextContainer?) -> NSImage? {
        NSImage(size: imageBounds.size)
    }
    #endif

    /// Centred on the text's cap height, but never below its descender (TextKit 2 grows the line
    /// above the baseline, not below), so the pill sits on the line like a word and the line
    /// grows by a few points.
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        PillAttachment.bounds(size: size, font: attributes[.font] as? PlatformFont)
    }

    static func bounds(size: CGSize, font: PlatformFont?) -> CGRect {
        let capHeight = font?.capHeight ?? 12
        let descender = font?.descender ?? -4
        let y = max((capHeight - size.height) / 2, descender).rounded(.down)
        return CGRect(x: 0, y: y, width: size.width, height: size.height)
    }
}

/// A pill's size without its view, for measuring the text off screen.
nonisolated final class PillStandIn: NSTextAttachment {
    let size: CGSize

    init(size: CGSize) {
        self.size = size
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        PillAttachment.bounds(size: size, font: attributes[.font] as? PlatformFont)
    }
}

#if os(iOS)
/// The field itself: hardware keys, plain-form copy and pill-making paste, the query capsule
/// and the placeholder.
final class PillUITextView: UITextView {
    var onKey: ((ComposerKey) -> Bool)?
    var menuOpen = false
    var sendWithReturn = true
    var plainText: ((NSAttributedString) -> String)?
    var pasteHandler: ((String) -> Void)?
    var pasteImages: (([UIImage]) -> Void)?
    var pasteFiles: (([URL]) async -> Void)?
    var spokenText: (() -> String)?
    var onLayout: (() -> Void)?
    let capsule = UIView()
    let emptyTextLabel = UILabel()

    override func layoutSubviews() {
        super.layoutSubviews()
        // UITextView adds its own text views as it lays out: keep the capsule under the text and
        // the placeholder over it.
        if subviews.first !== capsule { sendSubviewToBack(capsule) }
        if subviews.last !== emptyTextLabel { bringSubviewToFront(emptyTextLabel) }
        onLayout?()
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnKey)),
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(newlineKey)),
            // iPad (docs/follow-ups.md §4a): ⌥Return opens the mode menu, ⌘Return sends next.
            UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(modeMenuKey)),
            UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commandReturnKey)),
        ]
        if menuOpen {
            commands += [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(upKey)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(downKey)),
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabKey)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey)),
            ]
        }
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func returnKey() {
        if onKey?(.send) != true { insertText("\n") }
    }

    @objc private func newlineKey() {
        if onKey?(.newline) != true { insertText("\n") }
    }

    @objc private func modeMenuKey() {
        if onKey?(.modeMenu) != true { insertText("\n") }
    }

    /// ⌘Return: Send Next while a turn runs, otherwise Send.
    @objc private func commandReturnKey() {
        if onKey?(.sendNext) != true { _ = onKey?(.commandSend) }
    }

    @objc private func upKey() { _ = onKey?(.up) }
    @objc private func downKey() { _ = onKey?(.down) }
    @objc private func tabKey() { if onKey?(.tab) != true { insertText("\t") } }
    @objc private func escapeKey() { _ = onKey?(.escape) }

    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0, let plainText else { return super.copy(sender) }
        UIPasteboard.general.string = plainText(attributedText.attributedSubstring(from: selectedRange))
    }

    override func cut(_ sender: Any?) {
        guard selectedRange.length > 0 else { return super.cut(sender) }
        copy(sender)
        let range = selectedRange
        textStorage.replaceCharacters(in: range, with: "")
        selectedRange = NSRange(location: range.location, length: 0)
        delegate?.textViewDidChange?(self)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        let files = pasteFiles == nil ? [] : PastedFiles.providers(on: board)
        let string = board.hasStrings ? board.string : nil
        switch PastePlan.plan(hasFiles: !files.isEmpty, hasImages: pasteImages != nil && board.hasImages, text: string) {
        case .files:
            Task { [pasteFiles] in
                let pasted = await PastedFiles.copy(files)
                await pasteFiles?(pasted.urls)
                pasted.remove()
            }
        case .images:
            if let images = board.images { pasteImages?(images) }
        case .text:
            if let string, let pasteHandler { pasteHandler(string) } else { super.paste(sender) }
        case .system:
            super.paste(sender)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Pictures and files paste as attachments; text keeps UITextView's own answer. Only the
        // clipboard's types are read here: its contents wait for the paste itself.
        if action == #selector(paste(_:)), isEditable {
            let board = UIPasteboard.general
            if pasteImages != nil, board.hasImages { return true }
            if pasteFiles != nil, !board.hasStrings, board.numberOfItems > 0 { return true }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override var accessibilityValue: String? {
        get { spokenText?() ?? super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }
}

/// Files copied in the Files app, read off the clipboard into a folder of their own: the
/// system's copy of each only lives while it's being read.
nonisolated enum PastedFiles {
    struct Copies: Sendable {
        let urls: [URL]
        let folder: URL

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Items with a file's name and contents, as the Files app copies them. Text and pictures
    /// copied in other apps carry no name.
    @MainActor static func providers(on board: UIPasteboard) -> [NSItemProvider] {
        board.itemProviders.filter { $0.suggestedName?.isEmpty == false && fileType(of: $0) != nil }
    }

    static func copy(_ providers: [NSItemProvider]) async -> Copies {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Pasted-\(UUID().uuidString)", directoryHint: .isDirectory)
        var urls: [URL] = []
        for (index, provider) in providers.enumerated() {
            // A folder each: two copied files can share a name.
            if let url = await copy(provider, into: folder.appending(path: String(index), directoryHint: .isDirectory)) {
                urls.append(url)
            }
        }
        return Copies(urls: urls, folder: folder)
    }

    /// The richest file type the item offers (types come richest first).
    private static func fileType(of provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers.lazy.compactMap(UTType.init).first { $0.conforms(to: .data) || $0.conforms(to: .package) }
    }

    private static func copy(_ provider: NSItemProvider, into folder: URL) async -> URL? {
        guard let type = fileType(of: provider) else { return nil }
        var name = (provider.suggestedName ?? "Pasted").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if URL(filePath: name).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += ".\(ext)" }
        let destination = folder.appending(path: name, directoryHint: .notDirectory)
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type) { url, _, _ in
                guard let url else { return continuation.resume(returning: nil) }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
#else
final class PillNSTextView: NSTextView {
    var onKey: ((ComposerKey) -> Bool)?
    var plainText: ((NSAttributedString) -> String)?
    var pasteHandler: ((String) -> Void)?
    var pasteImages: (([NSImage]) -> Void)?
    var pasteFiles: (([URL]) async -> Void)?
    var spokenText: (() -> String)?
    var onFocusChange: ((Bool) -> Void)?
    var onLayout: (() -> Void)?
    let capsule = NSView()
    let emptyTextLabel = NSTextField(labelWithString: "")

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let plainText, let storage = textStorage else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText(storage.attributedSubstring(from: range)), forType: .string)
    }

    override func cut(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return super.cut(sender) }
        copy(sender)
        insertText("", replacementRange: range)
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        let urls = pasteFiles == nil ? [] : board.readObjects(forClasses: [NSURL.self], options: Self.fileURLsOnly) as? [URL] ?? []
        let images = pasteImages == nil ? [] : board.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []
        let string = board.string(forType: .string)
        switch PastePlan.plan(hasFiles: !urls.isEmpty, hasImages: !images.isEmpty, text: string) {
        case .files:
            Task { [pasteFiles] in await pasteFiles?(urls) }
        case .images:
            pasteImages?(images)
        case .text:
            if let string, let pasteHandler { pasteHandler(string) } else { super.paste(sender) }
        case .system:
            super.paste(sender)
        }
    }

    /// Edit ▸ Paste (and ⌘V) for pictures and files too: the text view itself only offers it
    /// for what it can read as text.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable {
            let board = NSPasteboard.general
            if pasteFiles != nil, board.canReadObject(forClasses: [NSURL.self], options: Self.fileURLsOnly) { return true }
            if pasteImages != nil, board.canReadObject(forClasses: [NSImage.self]) { return true }
        }
        return super.validateUserInterfaceItem(item)
    }

    private static let fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    override func layout() {
        super.layout()
        onLayout?()
    }

    /// ⌘Return while a turn runs redirects it (docs/follow-ups.md §1).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.charactersIgnoringModifiers == "\r",
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           onKey?(.redirect) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

/// Keeps the text view as wide as the field and at least as tall: TextKit 2 only draws inside
/// the text view's frame.
final class PillScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        let size = contentSize
        if abs(textView.frame.width - size.width) > 0.5 { textView.frame.size.width = size.width }
        if textView.frame.height < size.height { textView.frame.size.height = size.height }
        (textView as? PillNSTextView)?.onLayout?()
    }
}
#endif

/// The composer's field: text with Bots and gateway files as pills, and a command waiting for its
/// argument as a pill at the start.
struct PillTextView {
    @Binding var text: String
    @Binding var references: [MessageReference]
    @Binding var command: String?
    @Binding var isFocused: Bool
    var placeholder: String
    let controller: PillTextController
    var context: ReferenceContext
    var maxHeight: CGFloat = 240
    var menuOpen = false
    var sendWithReturn = true
    var isEnabled = true
    var onKey: (ComposerKey) -> Bool = { _ in false }
    var onPeek: (PillPeek) -> Void = { _ in }
    var onPasteImages: ([PlatformImage]) -> Void = { _ in }
    /// Files copied in the Finder or the Files app. On iPhone and iPad they're copies that are
    /// removed once this returns.
    var onPasteFiles: ([URL]) async -> Void = { _ in }

    static var font: PlatformFont {
        #if os(iOS)
        UIFont.preferredFont(forTextStyle: .body)
        #else
        macFont
        #endif
    }

    #if os(macOS)
    /// Looked up once: the field is measured on every layout pass of the window.
    private static let macFont = NSFont.systemFont(ofSize: 15)
    #endif

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PillTextView
        #if os(iOS)
        weak var textView: PillUITextView?
        #else
        weak var textView: PillNSTextView?
        weak var scrollView: NSScrollView?
        #endif
        /// Set while the field is changed from code, so the change isn't echoed back.
        private var isApplying = false
        private var hoverTask: Task<Void, Never>?

        init(parent: PillTextView) {
            self.parent = parent
        }

        // MARK: Attributes

        var textAttributes: [NSAttributedString.Key: Any] {
            #if os(iOS)
            [.font: PillTextView.font, .foregroundColor: UIColor.label]
            #else
            [.font: PillTextView.font, .foregroundColor: NSColor.labelColor]
            #endif
        }

        private var storage: NSTextStorage? {
            #if os(iOS)
            textView?.textStorage
            #else
            textView?.textStorage
            #endif
        }

        private var selection: NSRange {
            get {
                #if os(iOS)
                textView?.selectedRange ?? NSRange(location: 0, length: 0)
                #else
                textView?.selectedRange() ?? NSRange(location: 0, length: 0)
                #endif
            }
            set {
                #if os(iOS)
                textView?.selectedRange = newValue
                #else
                textView?.setSelectedRange(newValue)
                #endif
            }
        }

        // MARK: Pills

        func makeAttachment(_ content: PillAttachment.Content) -> PillAttachment {
            let context = parent.context
            let make: @MainActor () -> (view: PlatformView, owner: AnyObject?) = { [weak self] in
                let pill: AnyView = switch content {
                case .reference(let reference):
                    // Long-press is a UIKit recognizer on the pill (`layoutPills`): the text
                    // view's own gestures would beat a SwiftUI one.
                    AnyView(ReferencePillView(reference: reference, size: .message)
                        .onHover { inside in self?.hover(content, inside: inside) })
                case .command(let name):
                    AnyView(CommandPill(info: SlashCommands.info(name)).padding(.trailing, 6).accessibilityHidden(true))
                }
                let root = pill.environment(\.references, context)
                #if os(iOS)
                let host = UIHostingController(rootView: root)
                host.view.backgroundColor = .clear
                host.sizingOptions = [.intrinsicContentSize]
                host.view.accessibilityElementsHidden = true
                return (host.view, host)
                #else
                let host = NSHostingView(rootView: root)
                host.setAccessibilityElement(false)
                return (host, nil)
                #endif
            }
            // Measure once; every view made later is the same size.
            let sample = make()
            #if os(iOS)
            let size = sample.view.sizeThatFits(CGSize(width: 600, height: 60))
            #else
            let size = sample.view.fittingSize
            #endif
            return PillAttachment(content: content, size: size, makeView: make)
        }

        private func pillString(_ content: PillAttachment.Content) -> NSAttributedString {
            let string = NSMutableAttributedString(attachment: makeAttachment(content))
            string.addAttributes(textAttributes, range: NSRange(location: 0, length: string.length))
            return string
        }

        /// The field's contents for the model's draft.
        func attributedString(text: String, references: [MessageReference], command: String?) -> NSAttributedString {
            let result = NSMutableAttributedString()
            if let command { result.append(pillString(.command(command))) }
            for segment in MessageParts(body: text, references: references).segments {
                switch segment {
                case .text(let run): result.append(NSAttributedString(string: run, attributes: textAttributes))
                case .reference(let reference): result.append(pillString(.reference(reference)))
                }
            }
            return result
        }

        /// The model's draft for the field's contents: pills become their plain form.
        func decode(_ string: NSAttributedString) -> (text: String, references: [MessageReference], command: String?) {
            var text = ""
            var references: [MessageReference] = []
            var command: String?
            let source = string.string as NSString
            string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, range, _ in
                guard let value else {
                    text += source.substring(with: range)
                    return
                }
                guard let attachment = value as? PillAttachment else { return }
                switch attachment.content {
                case .command(let name) where range.location == 0:
                    command = name
                case .command:
                    break
                case .reference(var reference):
                    reference.location = text.utf16.count
                    references.append(reference)
                    text += reference.plainText
                }
            }
            return (text, references, command)
        }

        func plainText(_ string: NSAttributedString) -> String {
            let decoded = decode(string)
            if let command = decoded.command { return "/\(command) " + decoded.text }
            return decoded.text
        }

        func spokenText() -> String {
            guard let storage else { return "" }
            var spoken = ""
            let source = storage.string as NSString
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let attachment = value as? PillAttachment else {
                    if value == nil { spoken += source.substring(with: range) }
                    return
                }
                switch attachment.content {
                case .command(let name): spoken += CommandMode.pillTitle(SlashCommands.info(name)) + ", " + String(localized: "command") + ". "
                case .reference(let reference):
                    spoken += reference.spokenLabel(bot: reference.kind == .bot ? parent.context.bot(handle: reference.value) : nil)
                }
            }
            return spoken
        }

        // MARK: Model ↔ field

        /// Puts the model's draft in the field when it changed from elsewhere (sent, dictated,
        /// Edit and Resend).
        func apply(text: String, references: [MessageReference], command: String?) {
            guard let storage else { return }
            let current = decode(storage)
            guard current.text != text || current.references != references || current.command != command else { return }
            isApplying = true
            let caretAtEnd = selection.location >= storage.length
            storage.setAttributedString(attributedString(text: text, references: references, command: command))
            if caretAtEnd || selection.location > storage.length {
                selection = NSRange(location: storage.length, length: 0)
            }
            resetTypingAttributes()
            isApplying = false
            textChanged(fromUser: false)
        }

        func resetTypingAttributes() {
            #if os(iOS)
            textView?.typingAttributes = textAttributes
            #else
            textView?.typingAttributes = textAttributes
            #endif
        }

        /// The field changed: tell the model, upgrade a typed `/goal ` into command mode, find
        /// the query.
        func textChanged(fromUser: Bool) {
            guard let storage, !isApplying else { return }
            // Typing isn't hovering: a pill that lands under the pointer doesn't preview.
            hoverTask?.cancel()
            var decoded = decode(storage)
            if fromUser, decoded.command == nil, decoded.references.isEmpty, storage.length == (storage.string as NSString).length,
               let command = typedCommand(decoded.text) {
                isApplying = true
                storage.setAttributedString(attributedString(text: "", references: [], command: command))
                selection = NSRange(location: storage.length, length: 0)
                resetTypingAttributes()
                isApplying = false
                decoded = (text: "", references: [], command: command)
            }
            if parent.references != decoded.references { parent.references = decoded.references }
            if parent.text != decoded.text { parent.text = decoded.text }
            if parent.command != decoded.command { parent.command = decoded.command }
            updatePlaceholder()
            updateQuery()
            invalidateSize()
            #if os(iOS)
            layoutPills()
            #endif
            #if os(macOS)
            // VoiceOver reads pills by kind and name ("Bot, Ada, @writer").
            textView?.setAccessibilityValueDescription(spokenText())
            fitTextViewHeight()
            layoutPills()
            #endif
        }

        /// "/goal " typed by hand: the same command mode as picking it from the menu.
        private func typedCommand(_ text: String) -> String? {
            guard text.hasPrefix("/"), text.hasSuffix(" "), !text.dropLast().contains(where: \.isWhitespace) else { return nil }
            let name = String(text.dropFirst().dropLast())
            guard let info = SlashCommands.known(name), CommandMode.takesArgument(info) else { return nil }
            return info.name
        }

        func selectionChanged() {
            guard let storage, !isApplying else { return }
            // Typing next to dictated words is typing, not dictation: it never takes their mark.
            if dictationStart != nil || (dictationRange?.length ?? 0) > 0 { resetTypingAttributes() }
            // The caret never goes before the command pill.
            if let first = storage.length > 0 ? storage.attribute(.attachment, at: 0, effectiveRange: nil) as? PillAttachment : nil,
               case .command = first.content, selection.location == 0 {
                selection = NSRange(location: 1, length: max(0, selection.length - 1))
            }
            updateQuery()
        }

        /// The `/…` at the start of the field, or the `@…` right before the caret.
        func updateQuery() {
            guard let storage, selection.length == 0 else {
                parent.controller.setQuery(nil)
                updateCapsule()
                return
            }
            let source = storage.string as NSString
            let caret = min(selection.location, source.length)
            var start = caret
            while start > 0 {
                let character = source.character(at: start - 1)
                if character == 0xFFFC || CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(character) ?? " ") { break }
                start -= 1
            }
            var query: ComposerQuery?
            if start < caret {
                let token = source.substring(with: NSRange(location: start, length: caret - start))
                if token.hasPrefix("@") {
                    query = ComposerQuery(trigger: "@", text: String(token.dropFirst()), range: NSRange(location: start, length: caret - start))
                } else if token.hasPrefix("/"), start == 0, !token.dropFirst().contains("/") {
                    query = ComposerQuery(trigger: "/", text: String(token.dropFirst()), range: NSRange(location: start, length: caret - start))
                }
            }
            parent.controller.setQuery(query)
            updateCapsule()
        }

        // MARK: Dictation

        /// Where dictation started, while nothing has been heard yet.
        private var dictationStart: Int?

        func beginDictation() {
            guard let storage else { return }
            let range = selection
            if range.length > 0 { replace(range, with: NSAttributedString()) }
            dictationStart = min(selection.location, storage.length)
        }

        /// The span the dictated words fill: their marked runs, else where dictation started.
        private var dictationRange: NSRange? {
            guard let storage else { return nil }
            var lower: Int?
            var upper = 0
            storage.enumerateAttribute(.dictation, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard value != nil else { return }
                lower = min(lower ?? range.location, range.location)
                upper = max(upper, NSMaxRange(range))
            }
            if let lower { return NSRange(location: lower, length: upper - lower) }
            return dictationStart.map { NSRange(location: min($0, storage.length), length: 0) }
        }

        func updateDictation(settled: String, volatile: String) {
            guard let storage, let range = dictationRange else { return }
            let words = NSMutableAttributedString()
            let source = storage.string as NSString
            let before = range.location > 0 ? source.character(at: range.location - 1) : nil
            let spoken = (settled + (settled.isEmpty || volatile.isEmpty ? "" : " ") + volatile).trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty else { return }
            // A space between what was there and the words.
            let needsSpace = before.map { !(CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar($0) ?? " ")) } ?? false
            var marked = textAttributes
            marked[.dictation] = true
            if needsSpace { words.append(NSAttributedString(string: " ", attributes: marked)) }
            let settledText = settled.trimmingCharacters(in: .whitespaces)
            if !settledText.isEmpty { words.append(NSAttributedString(string: settledText, attributes: marked)) }
            let volatileText = volatile.trimmingCharacters(in: .whitespaces)
            if !volatileText.isEmpty {
                var lighter = marked
                #if os(iOS)
                lighter[.foregroundColor] = UIColor.tertiaryLabel
                #else
                lighter[.foregroundColor] = NSColor.tertiaryLabelColor
                #endif
                if !settledText.isEmpty { words.append(NSAttributedString(string: " ", attributes: marked)) }
                words.append(NSAttributedString(string: volatileText, attributes: lighter))
            }
            let caretAfter = selection.location >= NSMaxRange(range)
            let caret = selection
            isApplying = true
            storage.replaceCharacters(in: range, with: words)
            let delta = words.length - range.length
            // The caret stays where the person left it; after the words, it follows them.
            selection = caretAfter ? NSRange(location: caret.location + delta, length: caret.length) : caret
            resetTypingAttributes()
            isApplying = false
            dictationStart = nil
            textChanged(fromUser: false)
        }

        func endDictation(_ words: String) {
            defer { dictationStart = nil }
            guard let storage, let range = dictationRange, range.length > 0 || !words.isEmpty else { return }
            if !words.isEmpty {
                updateDictation(settled: words, volatile: "")
            } else {
                isApplying = true
                storage.replaceCharacters(in: range, with: NSAttributedString())
                selection = NSRange(location: min(range.location, storage.length), length: 0)
                isApplying = false
            }
            // Ordinary text now: ink, unmarked.
            if let final = dictationRange, final.length > 0 {
                isApplying = true
                storage.removeAttribute(.dictation, range: final)
                storage.addAttributes(textAttributes, range: final)
                isApplying = false
            }
            textChanged(fromUser: false)
        }

        // MARK: Editing from the menu

        enum Replacement {
            case text(String)
            case reference(MessageReference)
        }

        func replaceQuery(with replacement: Replacement) {
            guard let storage, let query = parent.controller.query, NSMaxRange(query.range) <= storage.length else { return }
            let insert: NSAttributedString = switch replacement {
            case .text(let text): NSAttributedString(string: text, attributes: textAttributes)
            case .reference(let reference): {
                let pill = NSMutableAttributedString(attributedString: pillString(.reference(reference)))
                pill.append(NSAttributedString(string: " ", attributes: textAttributes))
                return pill
            }()
            }
            replace(query.range, with: insert)
        }

        func remove(_ reference: MessageReference) {
            guard let storage else { return }
            var found: NSRange?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                guard let attachment = value as? PillAttachment, case .reference(let candidate) = attachment.content,
                      candidate.kind == reference.kind, candidate.value == reference.value else { return }
                found = range
                stop.pointee = true
            }
            guard let range = found else { return }
            replace(range, with: NSAttributedString())
        }

        /// A paste: `@handle`s on the roster and `@file:` paths become pills.
        func paste(_ string: String) {
            let references = parent.context.vocabulary.references(in: string)
            let insert = attributedString(text: string, references: references, command: nil)
            replace(selection, with: insert)
        }

        private func replace(_ range: NSRange, with insert: NSAttributedString) {
            guard let storage else { return }
            #if os(macOS)
            guard textView?.shouldChangeText(in: range, replacementString: insert.string) != false else { return }
            #endif
            storage.replaceCharacters(in: range, with: insert)
            selection = NSRange(location: range.location + insert.length, length: 0)
            resetTypingAttributes()
            #if os(macOS)
            textView?.didChangeText()
            #endif
            textChanged(fromUser: true)
        }

        // MARK: Preview

        private func rect(of content: PillAttachment.Content) -> CGRect? {
            guard let storage else { return nil }
            var view: PlatformView?
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                guard let attachment = value as? PillAttachment, attachment.content == content else { return }
                view = attachment.liveView
                stop.pointee = true
            }
            guard let view, let textView else { return nil }
            #if os(iOS)
            return textView.convert(view.bounds, from: view).offsetBy(dx: -textView.contentOffset.x, dy: -textView.contentOffset.y)
            #else
            guard let scrollView else { return nil }
            let inScroll = scrollView.convert(view.bounds, from: view)
            return scrollView.isFlipped ? inScroll : CGRect(x: inScroll.minX, y: scrollView.bounds.height - inScroll.maxY, width: inScroll.width, height: inScroll.height)
            #endif
        }

        func peek(_ content: PillAttachment.Content) {
            guard case .reference(let reference) = content, let rect = rect(of: content) else { return }
            parent.onPeek(PillPeek(item: .reference(reference), rect: rect))
        }

        func hover(_ content: PillAttachment.Content, inside: Bool) {
            #if os(macOS)
            hoverTask?.cancel()
            guard inside else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, let self, self.parent.controller.query == nil else { return }
                self.peek(content)
            }
            #endif
        }

        // MARK: Chrome

        /// The grey capsule behind the query token (`queryToken`: control fill, radius 6,
        /// padding 1 × 5).
        func updateCapsule() {
            guard let textView else { return }
            let capsule = textView.capsule
            guard parent.controller.showsCapsule, let query = parent.controller.query, let frame = frame(of: query.range) else {
                capsule.isHidden = true
                return
            }
            capsule.isHidden = false
            capsule.frame = frame.insetBy(dx: -5, dy: -1)
        }

        /// Where a range of the text is drawn, in the text view's coordinates.
        private func frame(of range: NSRange) -> CGRect? {
            #if os(iOS)
            guard let textView, let manager = textView.textLayoutManager, let content = manager.textContentManager else { return nil }
            let inset = textView.textContainerInset
            let padding = textView.textContainer.lineFragmentPadding
            #else
            guard let textView, let manager = textView.textLayoutManager, let content = manager.textContentManager else { return nil }
            let inset = NSEdgeInsets(top: textView.textContainerInset.height, left: textView.textContainerInset.width, bottom: 0, right: 0)
            let padding: CGFloat = 0
            #endif
            guard let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return nil }
            manager.ensureLayout(for: textRange)
            var union: CGRect?
            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
                union = union.map { $0.union(segment) } ?? segment
                return true
            }
            guard let frame = union else { return nil }
            #if os(iOS)
            return frame.offsetBy(dx: inset.left + padding - padding, dy: inset.top)
            #else
            return frame.offsetBy(dx: inset.left + padding, dy: inset.top)
            #endif
        }

        func updatePlaceholder() {
            guard let textView, let storage else { return }
            let decoded = decode(storage)
            let label = textView.emptyTextLabel
            let info = decoded.command.map { SlashCommands.info($0) }
            let placeholder = info.map(CommandMode.placeholder) ?? parent.placeholder
            let commandWidth: CGFloat = {
                guard storage.length > 0, let attachment = storage.attribute(.attachment, at: 0, effectiveRange: nil) as? PillAttachment,
                      case .command = attachment.content else { return 0 }
                return attachment.size.width
            }()
            let empty = decoded.text.isEmpty
            #if os(iOS)
            label.text = placeholder
            label.isHidden = !empty
            let inset = textView.textContainerInset
            let padding = textView.textContainer.lineFragmentPadding
            let width = max(0, textView.bounds.width - inset.left - inset.right - padding * 2 - commandWidth)
            let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            label.frame = CGRect(x: inset.left + padding + commandWidth, y: inset.top, width: width, height: min(height, PillTextView.font.lineHeight))
            #else
            label.stringValue = placeholder
            label.isHidden = !empty
            let inset = textView.textContainerInset
            let padding = textView.textContainer?.lineFragmentPadding ?? 0
            label.sizeToFit()
            label.frame.origin = CGPoint(x: inset.width + padding + commandWidth, y: inset.height)
            label.frame.size.width = max(0, min(label.frame.width, textView.bounds.width - label.frame.minX - inset.width))
            #endif
        }

        #if os(macOS)
        /// A second TextKit 2 stack that measures the text at any width, so sizing the field
        /// doesn't resize the text view while SwiftUI probes sizes.
        private lazy var measuring: (content: NSTextContentStorage, manager: NSTextLayoutManager, container: NSTextContainer) = {
            let content = NSTextContentStorage()
            let manager = NSTextLayoutManager()
            content.addTextLayoutManager(manager)
            let container = NSTextContainer(size: .zero)
            container.lineFragmentPadding = 0
            manager.textContainer = container
            return (content, manager, container)
        }()

        /// The last measurement. The window lays the field out on every pass, once for each word
        /// of a streaming reply, and laying the text out again each time showed in profiles.
        private var lastMeasure: (width: CGFloat, text: NSAttributedString, height: CGFloat)?

        func measuredHeight(width: CGFloat) -> CGFloat {
            guard let storage, width > 0 else { return 0 }
            if let last = lastMeasure, last.width == width, last.text.isEqual(to: storage) { return last.height }
            let height = measureHeight(of: storage, width: width)
            lastMeasure = (width, NSAttributedString(attributedString: storage), height)
            return height
        }

        private func measureHeight(of storage: NSTextStorage, width: CGFloat) -> CGFloat {
            let stack = measuring
            stack.container.size = CGSize(width: width, height: 0)
            // Stand-ins of the same size: the pills' views belong to the field, and a second
            // layout asking for them would take them out of it.
            let copy = NSMutableAttributedString(attributedString: storage)
            copy.enumerateAttribute(.attachment, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
                guard let pill = value as? PillAttachment else { return }
                copy.addAttribute(.attachment, value: PillStandIn(size: pill.size), range: range)
            }
            stack.content.attributedString = copy
            stack.manager.ensureLayout(for: stack.manager.documentRange)
            return ceil(stack.manager.usageBoundsForTextContainer.height)
        }

        func fitTextViewHeight() {
            guard let textView, let scrollView, let manager = textView.textLayoutManager else { return }
            manager.ensureLayout(for: manager.documentRange)
            let height = max(ceil(manager.usageBoundsForTextContainer.height), scrollView.contentSize.height)
            if abs(textView.frame.height - height) > 0.5 { textView.frame.size.height = height }
        }
        #endif

        /// Each pill's view sits on its attachment's frame; views for pills that are gone go too.
        private var pillViews: [ObjectIdentifier: (view: PlatformView, owner: AnyObject?)] = [:]

        func layoutPills() {
            guard let textView, let storage, let manager = textView.textLayoutManager, let content = manager.textContentManager else { return }
            manager.ensureLayout(for: manager.documentRange)
            #if os(iOS)
            let origin = CGPoint(x: textView.textContainerInset.left + textView.textContainer.lineFragmentPadding, y: textView.textContainerInset.top)
            #else
            let origin = textView.textContainerOrigin
            #endif
            var seen = Set<ObjectIdentifier>()
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let pill = value as? PillAttachment,
                      let location = content.location(content.documentRange.location, offsetBy: range.location),
                      let fragment = manager.textLayoutFragment(for: location) else { return }
                let inFragment = fragment.frameForTextAttachment(at: location)
                guard !inFragment.isEmpty else { return }
                let fragmentOrigin = fragment.layoutFragmentFrame.origin
                let frame = inFragment.offsetBy(dx: fragmentOrigin.x + origin.x, dy: fragmentOrigin.y + origin.y)
                let id = ObjectIdentifier(pill)
                seen.insert(id)
                let view: PlatformView
                if let existing = pillViews[id] {
                    view = existing.view
                } else {
                    let made = pill.makeView()
                    view = made.view
                    textView.addSubview(view)
                    pillViews[id] = made
                    pill.liveView = view
                    #if os(iOS)
                    if case .reference = pill.content {
                        let press = UILongPressGestureRecognizer(target: self, action: #selector(pillPressed(_:)))
                        press.minimumPressDuration = 0.35
                        press.delegate = self
                        view.addGestureRecognizer(press)
                        pressedContent[ObjectIdentifier(view)] = pill.content
                    }
                    #endif
                }
                if view.frame != frame { view.frame = frame }
            }
            for (id, entry) in pillViews where !seen.contains(id) {
                entry.view.removeFromSuperview()
                pillViews[id] = nil
                #if os(iOS)
                pressedContent[ObjectIdentifier(entry.view)] = nil
                #endif
            }
        }

        #if os(iOS)
        /// What each pill view shows, for its long-press.
        private var pressedContent: [ObjectIdentifier: PillAttachment.Content] = [:]

        @objc func pillPressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view, let content = pressedContent[ObjectIdentifier(view)] else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            peek(content)
        }
        #endif

        private func invalidateSize() {
            #if os(iOS)
            textView?.invalidateIntrinsicContentSize()
            #else
            scrollView?.invalidateIntrinsicContentSize()
            #endif
        }

        func focus() {
            #if os(iOS)
            textView?.becomeFirstResponder()
            #else
            if let textView { textView.window?.makeFirstResponder(textView) }
            #endif
        }

        #if DEBUG
        func typeForTesting(_ text: String) {
            focus()
            #if os(iOS)
            textView?.insertText(text)
            #else
            if let textView { textView.insertText(text, replacementRange: textView.selectedRange()) }
            #endif
        }
        #endif
    }
}

#if os(iOS)
extension PillTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> PillUITextView {
        // The designated initializer: `init(usingTextLayoutManager:)` is a class factory that
        // skips this subclass's stored properties. UITextView uses TextKit 2 by default.
        let view = PillUITextView(frame: .zero, textContainer: nil)
        let coordinator = context.coordinator
        coordinator.textView = view
        controller.coordinator = coordinator
        view.delegate = coordinator
        view.backgroundColor = .clear
        view.font = Self.font
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.allowsEditingTextAttributes = false
        view.typingAttributes = coordinator.textAttributes
        view.accessibilityLabel = String(localized: "Message")

        view.capsule.backgroundColor = UIColor(Theme.controlFill)
        view.capsule.layer.cornerRadius = 6
        view.capsule.layer.cornerCurve = .continuous
        view.capsule.isUserInteractionEnabled = false
        view.capsule.isHidden = true
        view.insertSubview(view.capsule, at: 0)

        view.emptyTextLabel.font = Self.font
        view.emptyTextLabel.adjustsFontForContentSizeCategory = true
        view.emptyTextLabel.textColor = UIColor(Theme.placeholderText)
        view.emptyTextLabel.isAccessibilityElement = false
        view.addSubview(view.emptyTextLabel)

        view.plainText = { [weak coordinator] in coordinator?.plainText($0) ?? $0.string }
        view.pasteHandler = { [weak coordinator] in coordinator?.paste($0) }
        // Through the coordinator's latest `parent`: the field outlives a switch to another chat,
        // and what's pasted belongs to the chat on screen.
        view.pasteImages = { [weak coordinator] in coordinator?.parent.onPasteImages($0) }
        view.pasteFiles = { [weak coordinator] in await coordinator?.parent.onPasteFiles($0) }
        view.spokenText = { [weak coordinator] in coordinator?.spokenText() ?? "" }
        view.onLayout = { [weak coordinator] in
            coordinator?.updatePlaceholder()
            coordinator?.updateCapsule()
            coordinator?.layoutPills()
        }
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: PillUITextView, _) in
            // Pills are sized for the text; rebuild them at the new size.
            guard let coordinator = view.delegate as? Coordinator, let storage = Optional(view.textStorage) else { return }
            let decoded = coordinator.decode(storage)
            storage.setAttributedString(coordinator.attributedString(text: decoded.text, references: decoded.references, command: decoded.command))
            coordinator.updatePlaceholder()
        }
        coordinator.apply(text: text, references: references, command: command)
        return view
    }

    func updateUIView(_ view: PillUITextView, context: Context) {
        context.coordinator.parent = self
        controller.coordinator = context.coordinator
        view.onKey = onKey
        view.menuOpen = menuOpen
        view.isEditable = isEnabled
        context.coordinator.apply(text: text, references: references, command: command)
        context.coordinator.updatePlaceholder()
        context.coordinator.updateCapsule()
        if isFocused, !view.isFirstResponder, view.window != nil {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PillUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = max(Self.font.lineHeight, min(fitting.height, maxHeight))
        let scrolls = fitting.height > maxHeight
        if view.isScrollEnabled != scrolls {
            DispatchQueue.main.async { view.isScrollEnabled = scrolls }
        }
        return CGSize(width: width, height: ceil(height))
    }
}

extension PillTextView.Coordinator: UIGestureRecognizerDelegate {
    /// The text view's own presses (loupe, selection) wait for a pill's long-press to fail.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view === textView
    }
}

extension PillTextView.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        textChanged(fromUser: true)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        selectionChanged()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if !parent.isFocused { parent.isFocused = true }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if parent.isFocused { parent.isFocused = false }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // "@writer " typed out in full becomes the pill it names.
        guard text == " ", range.length == 0, let query = parent.controller.query, query.trigger == "@",
              NSMaxRange(query.range) == range.location, let bot = parent.context.bot(handle: query.text) else { return true }
        let handle = parent.context.vocabulary.handles.contains(query.text.lowercased()) ? query.text : bot.mentionTag
        replaceQuery(with: .reference(MessageReference(kind: .bot, value: handle)))
        return false
    }
}
#else
extension PillTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let textView = PillNSTextView(usingTextLayoutManager: true)
        let coordinator = context.coordinator
        coordinator.textView = textView
        controller.coordinator = coordinator
        textView.delegate = coordinator
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = Self.font
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 22)
        textView.minSize = NSSize(width: 0, height: 22)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = coordinator.textAttributes
        textView.setAccessibilityLabel(String(localized: "Message"))

        textView.capsule.wantsLayer = true
        textView.capsule.layer?.backgroundColor = NSColor(Theme.controlFill).cgColor
        textView.capsule.layer?.cornerRadius = 6
        textView.capsule.layer?.cornerCurve = .continuous
        textView.capsule.isHidden = true
        textView.addSubview(textView.capsule, positioned: .below, relativeTo: nil)

        textView.emptyTextLabel.font = Self.font
        textView.emptyTextLabel.textColor = NSColor(Theme.placeholderText)
        textView.emptyTextLabel.setAccessibilityElement(false)
        textView.addSubview(textView.emptyTextLabel)

        textView.plainText = { [weak coordinator] in coordinator?.plainText($0) ?? $0.string }
        textView.pasteHandler = { [weak coordinator] in coordinator?.paste($0) }
        // Through the coordinator's latest `parent`: the field outlives a switch to another chat,
        // and what's pasted belongs to the chat on screen.
        textView.pasteImages = { [weak coordinator] in coordinator?.parent.onPasteImages($0) }
        textView.pasteFiles = { [weak coordinator] in await coordinator?.parent.onPasteFiles($0) }
        textView.spokenText = { [weak coordinator] in coordinator?.spokenText() ?? "" }
        textView.onLayout = { [weak coordinator] in coordinator?.layoutPills() }
        textView.onFocusChange = { [weak coordinator] focused in
            guard let coordinator, coordinator.parent.isFocused != focused else { return }
            DispatchQueue.main.async { coordinator.parent.isFocused = focused }
        }

        let scrollView = PillScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        coordinator.scrollView = scrollView
        coordinator.apply(text: text, references: references, command: command)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        controller.coordinator = context.coordinator
        guard let textView = context.coordinator.textView else { return }
        textView.onKey = onKey
        textView.isEditable = isEnabled
        context.coordinator.apply(text: text, references: references, command: command)
        context.coordinator.updatePlaceholder()
        context.coordinator.updateCapsule()
        let isFirstResponder = textView.window?.firstResponder === textView
        if isFocused, !isFirstResponder, let window = textView.window {
            DispatchQueue.main.async { window.makeFirstResponder(textView) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        let used = context.coordinator.measuredHeight(width: width)
        return CGSize(width: width, height: ceil(min(max(used, lineHeight), maxHeight)))
    }
}

extension PillTextView.Coordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        textChanged(fromUser: true)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionChanged()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return parent.onKey(shift ? .newline : .send)
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            return parent.onKey(.sendNext) // ⌥Return

        case #selector(NSResponder.moveUp(_:)):
            return parent.menuOpen && parent.onKey(.up)
        case #selector(NSResponder.moveDown(_:)):
            return parent.menuOpen && parent.onKey(.down)
        case #selector(NSResponder.insertTab(_:)):
            return parent.menuOpen && parent.onKey(.tab)
        case #selector(NSResponder.cancelOperation(_:)):
            return parent.onKey(.escape)
        default:
            return false
        }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        // "@writer " typed out in full becomes the pill it names.
        guard text == " ", range.length == 0, let query = parent.controller.query, query.trigger == "@",
              NSMaxRange(query.range) == range.location, let bot = parent.context.bot(handle: query.text) else { return true }
        let handle = parent.context.vocabulary.handles.contains(query.text.lowercased()) ? query.text : bot.mentionTag
        DispatchQueue.main.async { [weak self] in
            self?.replaceQuery(with: .reference(MessageReference(kind: .bot, value: handle)))
        }
        return false
    }
}
#endif
