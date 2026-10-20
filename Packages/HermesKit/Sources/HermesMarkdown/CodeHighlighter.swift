import Foundation

/// A lightweight, dependency-free lexer that tints common languages.
///
/// It favours being fast and never wrong in a jarring way over completeness:
/// unknown languages come back as one plain token.
public enum CodeHighlighter {
    public struct Token: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case plain, keyword, type, string, number, comment, function, property, meta, inserted, deleted
        }

        public var kind: Kind
        public var text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public static func tokenize(_ code: String, language: String?) -> [Token] {
        guard let grammar = Grammar(language: language) else {
            return code.isEmpty ? [] : [Token(.plain, code)]
        }
        if grammar.isDiff {
            return tokenizeDiff(code)
        }
        var lexer = Lexer(characters: Array(code), grammar: grammar)
        return lexer.run()
    }

    /// Normalised display name for a fence's info string, e.g. `"py"` → `"Python"`.
    public static func displayName(for language: String?) -> String? {
        guard let language = language?.lowercased(), !language.isEmpty else { return nil }
        let names: [String: String] = [
            "swift": "Swift", "py": "Python", "python": "Python", "python3": "Python",
            "js": "JavaScript", "javascript": "JavaScript", "jsx": "JSX", "mjs": "JavaScript",
            "ts": "TypeScript", "typescript": "TypeScript", "tsx": "TSX",
            "sh": "Shell", "bash": "Bash", "zsh": "Zsh", "shell": "Shell", "console": "Console", "fish": "Fish",
            "json": "JSON", "jsonc": "JSON", "yaml": "YAML", "yml": "YAML", "toml": "TOML",
            "rs": "Rust", "rust": "Rust", "go": "Go", "golang": "Go", "rb": "Ruby", "ruby": "Ruby",
            "java": "Java", "kt": "Kotlin", "kotlin": "Kotlin", "c": "C", "h": "C", "cpp": "C++", "c++": "C++",
            "cs": "C#", "csharp": "C#", "objc": "Objective-C", "m": "Objective-C", "php": "PHP",
            "sql": "SQL", "html": "HTML", "xml": "XML", "css": "CSS", "scss": "SCSS",
            "md": "Markdown", "markdown": "Markdown", "diff": "Diff", "patch": "Diff",
            "dockerfile": "Dockerfile", "docker": "Dockerfile", "makefile": "Makefile", "make": "Makefile",
            "lua": "Lua", "dart": "Dart", "scala": "Scala", "r": "R", "text": "Text", "txt": "Text", "plaintext": "Text",
        ]
        return names[language] ?? language.capitalized
    }

    private static func tokenizeDiff(_ code: String) -> [Token] {
        var tokens: [Token] = []
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let text = String(line) + (index < lines.count - 1 ? "\n" : "")
            let kind: Token.Kind = if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                .meta
            } else if line.hasPrefix("+") {
                .inserted
            } else if line.hasPrefix("-") {
                .deleted
            } else {
                .plain
            }
            tokens.append(Token(kind, text))
        }
        return tokens
    }
}

// MARK: - Grammar

private struct Grammar {
    var keywords: Set<String>
    var literals: Set<String> = ["true", "false", "nil", "null", "None", "True", "False", "undefined", "self", "this", "super"]
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)?
    var stringDelimiters: Set<Character> = ["\"", "'"]
    var tripleQuotedStrings = false
    var capitalizedAreTypes = true
    var caseInsensitiveKeywords = false
    var jsonKeys = false
    var isDiff = false
    var hashMeta = false // `#include`, `#if` …
    var atMeta = false // `@MainActor`, `@decorator`

    init?(language: String?) {
        guard let raw = language?.lowercased().split(separator: " ").first.map(String.init), !raw.isEmpty else { return nil }
        switch raw {
        case "swift":
            keywords = Self.swift
            lineComments = ["//"]; blockComment = ("/*", "*/"); stringDelimiters = ["\""]; tripleQuotedStrings = true; atMeta = true
        case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx":
            keywords = Self.javascript
            lineComments = ["//"]; blockComment = ("/*", "*/"); stringDelimiters = ["\"", "'", "`"]; atMeta = true
        case "py", "python", "python3":
            keywords = Self.python
            lineComments = ["#"]; tripleQuotedStrings = true; atMeta = true
        case "rb", "ruby":
            keywords = Self.ruby
            lineComments = ["#"]
        case "sh", "bash", "zsh", "shell", "console", "fish", "dockerfile", "docker", "makefile", "make":
            keywords = Self.shell
            lineComments = ["#"]; capitalizedAreTypes = false
        case "go", "golang":
            keywords = Self.go
            lineComments = ["//"]; blockComment = ("/*", "*/"); stringDelimiters = ["\"", "'", "`"]
        case "rs", "rust":
            keywords = Self.rust
            lineComments = ["//"]; blockComment = ("/*", "*/"); stringDelimiters = ["\""]; hashMeta = true
        case "java", "kt", "kotlin", "scala", "dart", "cs", "csharp":
            keywords = Self.jvm
            lineComments = ["//"]; blockComment = ("/*", "*/"); atMeta = true; tripleQuotedStrings = true
        case "c", "h", "cpp", "c++", "cc", "hpp", "objc", "m", "mm":
            keywords = Self.cFamily
            lineComments = ["//"]; blockComment = ("/*", "*/"); hashMeta = true; atMeta = true
        case "php":
            keywords = Self.php
            lineComments = ["//", "#"]; blockComment = ("/*", "*/")
        case "lua":
            keywords = ["and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or", "repeat", "return", "then", "until", "while"]
            lineComments = ["--"]; capitalizedAreTypes = false
        case "sql", "psql", "mysql", "sqlite":
            keywords = Self.sql
            lineComments = ["--"]; blockComment = ("/*", "*/"); stringDelimiters = ["'"]; capitalizedAreTypes = false; caseInsensitiveKeywords = true
        case "json", "jsonc", "json5":
            keywords = []
            lineComments = ["//"]; blockComment = ("/*", "*/"); stringDelimiters = ["\""]; capitalizedAreTypes = false; jsonKeys = true
        case "yaml", "yml", "toml", "ini", "conf", "env", "dotenv", "r":
            keywords = []
            lineComments = ["#"]; capitalizedAreTypes = false
        case "css", "scss", "less":
            keywords = ["important", "media", "import", "from", "to"]
            blockComment = ("/*", "*/"); capitalizedAreTypes = false
        case "html", "xml", "svg", "plist":
            keywords = []
            blockComment = ("<!--", "-->"); capitalizedAreTypes = false
        case "diff", "patch":
            keywords = []
            isDiff = true
        default:
            return nil
        }
    }

    static let swift: Set<String> = ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "mutating", "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat", "rethrows", "return", "some", "static", "struct", "subscript", "switch", "throw", "throws", "try", "typealias", "var", "where", "while", "consume", "borrowing", "consuming", "sending", "package", "macro", "weak", "unowned", "lazy", "get", "set", "willSet", "didSet"]
    static let javascript: Set<String> = ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "of", "private", "protected", "public", "readonly", "return", "set", "static", "switch", "throw", "try", "type", "typeof", "var", "void", "while", "with", "yield", "declare", "namespace", "keyof", "satisfies"]
    static let python: Set<String> = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "case", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"]
    static let ruby: Set<String> = ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "then", "undef", "unless", "until", "when", "while", "yield", "require", "attr_reader", "attr_accessor"]
    static let shell: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "export", "local", "readonly", "source", "alias", "unset", "set", "echo", "cd", "exit", "sudo", "FROM", "RUN", "CMD", "COPY", "ADD", "ENV", "WORKDIR", "EXPOSE", "ENTRYPOINT", "ARG", "LABEL", "USER", "VOLUME"]
    static let go: Set<String> = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"]
    static let rust: Set<String> = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "static", "struct", "trait", "type", "unsafe", "use", "where", "while", "Self"]
    static let jvm: Set<String> = ["abstract", "break", "case", "catch", "class", "const", "continue", "data", "default", "do", "else", "enum", "extends", "final", "finally", "for", "fun", "if", "implements", "import", "in", "instanceof", "interface", "is", "lateinit", "namespace", "new", "object", "override", "package", "private", "protected", "public", "return", "sealed", "static", "switch", "synchronized", "throw", "throws", "try", "using", "val", "var", "void", "when", "while", "async", "await", "def", "trait"]
    static let cFamily: Set<String> = ["auto", "break", "case", "char", "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "namespace", "new", "private", "protected", "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while", "interface", "implementation", "end", "property", "nonatomic", "strong", "weak"]
    static let php: Set<String> = ["abstract", "array", "as", "break", "case", "catch", "class", "const", "continue", "default", "do", "echo", "else", "elseif", "extends", "final", "fn", "for", "foreach", "function", "if", "implements", "interface", "match", "namespace", "new", "private", "protected", "public", "readonly", "return", "static", "switch", "throw", "trait", "try", "use", "while", "yield"]
    static let sql: Set<String> = ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "view", "drop", "alter", "add", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "distinct", "union", "all", "case", "when", "then", "else", "end", "is", "null", "in", "exists", "primary", "key", "foreign", "references", "default", "with", "returning", "begin", "commit", "rollback", "asc", "desc", "count", "sum", "avg", "min", "max", "like", "between"]
}

// MARK: - Lexer

private struct Lexer {
    let characters: [Character]
    let grammar: Grammar
    var index = 0
    var tokens: [CodeHighlighter.Token] = []
    var plain = ""

    init(characters: [Character], grammar: Grammar) {
        self.characters = characters
        self.grammar = grammar
    }

    mutating func run() -> [CodeHighlighter.Token] {
        while index < characters.count {
            let character = characters[index]
            if let comment = grammar.lineComments.first(where: { matches($0) }), !(comment == "#" && isShebangLikeVariable()) {
                emit(.comment, readUntilLineEnd())
            } else if let block = grammar.blockComment, matches(block.open) {
                emit(.comment, readBlock(open: block.open, close: block.close))
            } else if grammar.tripleQuotedStrings, character == "\"" || character == "'", matches(String(repeating: character, count: 3)) {
                let fence = String(repeating: character, count: 3)
                emit(.string, readBlock(open: fence, close: fence))
            } else if grammar.stringDelimiters.contains(character) {
                let literal = readString(delimiter: character)
                if grammar.jsonKeys, nextNonSpaceCharacter() == ":" {
                    emit(.property, literal)
                } else {
                    emit(.string, literal)
                }
            } else if character.isNumber, !previousIsIdentifier() {
                emit(.number, readNumber())
            } else if grammar.hashMeta, character == "#", isAtLineStartIgnoringSpaces() {
                emit(.meta, readUntilLineEnd())
            } else if grammar.atMeta, character == "@", index + 1 < characters.count, characters[index + 1].isLetter {
                index += 1
                emit(.meta, "@" + readIdentifier())
            } else if character.isLetter || character == "_" || character == "$" {
                let word = readIdentifier()
                emit(classify(word), word)
            } else {
                plain.append(character)
                index += 1
            }
        }
        flushPlain()
        return tokens
    }

    // MARK: Classification

    func classify(_ word: String) -> CodeHighlighter.Token.Kind {
        let lookup = grammar.caseInsensitiveKeywords ? word.lowercased() : word
        if grammar.keywords.contains(lookup) { return .keyword }
        if grammar.literals.contains(word) { return .keyword }
        if nextNonSpaceCharacter() == "(" { return .function }
        if grammar.capitalizedAreTypes, let first = word.first, first.isUppercase, word.count > 1 { return .type }
        return .plain
    }

    // MARK: Readers

    func matches(_ string: String) -> Bool {
        var cursor = index
        for character in string {
            guard cursor < characters.count, characters[cursor] == character else { return false }
            cursor += 1
        }
        return true
    }

    mutating func readUntilLineEnd() -> String {
        var result = ""
        while index < characters.count, characters[index] != "\n" {
            result.append(characters[index])
            index += 1
        }
        return result
    }

    mutating func readBlock(open: String, close: String) -> String {
        var result = open
        index += open.count
        while index < characters.count {
            if matches(close) {
                result += close
                index += close.count
                return result
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    mutating func readString(delimiter: Character) -> String {
        var result = String(delimiter)
        index += 1
        while index < characters.count {
            let character = characters[index]
            result.append(character)
            index += 1
            if character == "\\", index < characters.count {
                result.append(characters[index])
                index += 1
            } else if character == delimiter {
                break
            } else if character == "\n", delimiter != "`" {
                break // unterminated single-line string; stop tinting at the line end
            }
        }
        return result
    }

    mutating func readNumber() -> String {
        var result = ""
        let isHex = matches("0x") || matches("0X")
        if isHex {
            result = String(characters[index...index + 1])
            index += 2
        }
        while index < characters.count {
            let character = characters[index]
            let isDigit = isHex ? character.isHexDigit : character.isNumber
            if isDigit || character == "_" {
                result.append(character)
                index += 1
            } else if !isHex, character == ".", index + 1 < characters.count, characters[index + 1].isNumber, !result.contains(".") {
                result.append(character)
                index += 1
            } else {
                break
            }
        }
        return result
    }

    mutating func readIdentifier() -> String {
        var result = ""
        while index < characters.count {
            let character = characters[index]
            guard character.isLetter || character.isNumber || character == "_" || character == "$" else { break }
            result.append(character)
            index += 1
        }
        if grammar.keywords.contains("defined?"), index < characters.count, characters[index] == "?" {
            result.append("?")
            index += 1
        }
        return result
    }

    // MARK: Context

    func nextNonSpaceCharacter() -> Character? {
        var cursor = index
        while cursor < characters.count {
            let character = characters[cursor]
            if character != " " && character != "\t" { return character }
            cursor += 1
        }
        return nil
    }

    func previousIsIdentifier() -> Bool {
        guard let last = plain.last ?? tokens.last?.text.last else { return false }
        return last.isLetter || last == "_" || last.isNumber
    }

    func isAtLineStartIgnoringSpaces() -> Bool {
        var cursor = index - 1
        while cursor >= 0 {
            let character = characters[cursor]
            if character == "\n" { return true }
            if character != " " && character != "\t" { return false }
            cursor -= 1
        }
        return true
    }

    /// `$#` and `${#array}` in shell are not comments.
    func isShebangLikeVariable() -> Bool {
        guard index > 0 else { return false }
        let previous = characters[index - 1]
        return previous == "$" || previous == "{"
    }

    // MARK: Output

    mutating func emit(_ kind: CodeHighlighter.Token.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        if kind == .plain {
            plain += text
            return
        }
        flushPlain()
        tokens.append(CodeHighlighter.Token(kind, text))
    }

    mutating func flushPlain() {
        guard !plain.isEmpty else { return }
        tokens.append(CodeHighlighter.Token(.plain, plain))
        plain = ""
    }
}
