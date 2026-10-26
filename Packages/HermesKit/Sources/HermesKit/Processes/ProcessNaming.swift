import Foundation

/// What a background process is called (`docs/background-processes.md` §2). People see a name,
/// not the command; the command still shows, cleaned, with home folders as `~`.
public enum ProcessNaming {
    /// The longest name made from the program and its first argument.
    static let fallbackLimit = 24

    // MARK: Cleaning

    /// The command without what doesn't say what it is: a leading `cd … &&`, `VAR=value` pairs,
    /// `nohup`, `exec` and `env`, redirections (`> log 2>&1`) and a trailing `&`. A JSON argv
    /// (`["npm", "run", "dev"]`) becomes a command line first. Home folders read `~`.
    public static func clean(_ command: String) -> String {
        var words = commandWords(command)
        guard !words.isEmpty else { return shortenPaths(command.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let inner = shellCommandLine(words.map(\.value)) { return clean(inner) }
        // Hermes's delivery of a message to another Bot (`message_agent`) runs a Python script that
        // runs `hermes -p <bot> chat …`: that part says what it is. Cut before it (the list keeps
        // 200 characters), the script and its mode say enough.
        if let script = words.firstIndex(where: { basename($0.value) == "bot_mode_dm.py" }) {
            if let hermes = words.lastIndex(where: { basename($0.value) == "hermes" }), hermes > script {
                words = [Word(value: "hermes", raw: "hermes")] + words[(hermes + 1)...]
            } else {
                let head = words[...min(script + 1, words.count - 1)].map { Word(value: basename($0.value), raw: basename($0.raw)) }
                words = head + (words.count > script + 2 ? [Word(value: "…", raw: "…")] : [])
            }
        }
        return shortenPaths(words.map(\.raw).joined(separator: " "))
    }

    /// `/Users/sam/Code` → `~/Code` (and `/home/…`, `/root`).
    public static func shortenPaths(_ text: String) -> String {
        text.replacingOccurrences(of: #"(^|(?<=[\s'"=:]))(/Users/[^/\s'"]+|/home/[^/\s'"]+|/root)(?=/|\s|$|['"])"#,
                                  with: "~", options: .regularExpression)
    }

    // MARK: Naming

    /// The name of a process from its command. `botName` turns a profile into the Bot's name
    /// ("engineer" → "Engineer"); without one the profile is title-cased.
    public static func name(for command: String, botName: (String) -> String? = { _ in nil }) -> String {
        let words = commandWords(command).map(\.value)
        // A shell running a command line (`bash -lc "cd site && npm run dev"`): named for the line.
        if let inner = shellCommandLine(words) { return name(for: inner, botName: botName) }
        // Of `npm ci && npm run dev`, the last command is the one that keeps running; of a
        // pipeline, the first.
        let last = words.split(whereSeparator: { $0 == "&&" || $0 == ";" || $0 == "||" }).last.map(Array.init) ?? words
        let head = Array(last.prefix { $0 != "|" && $0 != "|&" })
        guard var program = head.first.map(basename) else {
            return String(localized: "Background process")
        }
        var args = Array(head.dropFirst())
        // Runners in front of the real program.
        if ["npx", "bunx", "pnpx"].contains(program), let next = args.first {
            program = basename(next)
            args.removeFirst()
        } else if ["pnpm", "yarn"].contains(program), args.first == "dlx", args.count > 1 {
            program = basename(args[1])
            args.removeFirst(2)
        }
        let lower = args.map { $0.lowercased() }

        // Messages to other Bots: `hermes -p <bot> chat …`, or Hermes' own delivery script.
        if let message = botMessageName(program: program, args: args, botName: botName) { return message }

        switch program {
        case "npm", "pnpm", "yarn", "bun":
            if let name = packageScriptName(manager: program, args: args) { return name }
        case "vite":
            if lower.contains("build") { return String(localized: "Build") }
            return lower.contains("preview") ? String(localized: "Web server") : String(localized: "Dev server")
        case "next", "astro", "nuxt", "remix", "svelte-kit":
            if lower.first == "dev" { return String(localized: "Dev server") }
            if lower.first == "build" { return String(localized: "Build") }
        case "caddy", "serve", "http-server":
            return String(localized: "Web server")
        case "python", "python3":
            if let module = moduleName(args) {
                if module == "http.server" { return String(localized: "Web server") }
                if module == "pytest" || module == "unittest" { return String(localized: "Tests") }
            }
        case "php":
            if lower.contains("-s") { return String(localized: "Web server") }
        case "pytest", "jest", "vitest", "rspec":
            return String(localized: "Tests")
        case "swift":
            if lower.first == "test" { return String(localized: "Tests") }
            if lower.first == "build" {
                return isReleaseConfiguration(lower) ? String(localized: "Release build") : String(localized: "Build")
            }
        case "go":
            if lower.first == "test" { return String(localized: "Tests") }
            if lower.first == "build" { return String(localized: "Build") }
        case "cargo":
            if lower.first == "test" { return String(localized: "Tests") }
            if lower.first == "build" {
                return lower.contains("--release") ? String(localized: "Release build") : String(localized: "Build")
            }
        case "xcodebuild":
            if lower.contains("test") || lower.contains("test-without-building") { return String(localized: "Tests") }
            if lower.contains("archive") { return String(localized: "Release build") }
            return String(localized: "Build")
        case "make", "gmake":
            let targets = lower.filter { !$0.hasPrefix("-") && !$0.contains("=") }
            if targets.contains("release") { return String(localized: "Release build") }
            if targets.contains("test") || targets.contains("check") { return String(localized: "Tests") }
            return String(localized: "Build")
        case "docker":
            if let name = dockerName(args) { return name }
        case "docker-compose":
            if lower.first == "up" { return dockerComposeName(Array(args.dropFirst())) }
        case "tail":
            if lower.contains(where: { $0.hasPrefix("-") && ($0.contains("f") || $0.contains("F")) || $0 == "--follow" }),
               let file = args.last(where: { !$0.hasPrefix("-") && !$0.allSatisfy(\.isNumber) }) {
                return String(localized: "Watching \(basename(file))")
            }
        case "journalctl":
            if lower.contains("-f") || lower.contains("--follow") {
                if let index = lower.firstIndex(where: { $0 == "-u" || $0 == "--unit" }), index + 1 < args.count {
                    return String(localized: "Watching \(args[index + 1])")
                }
                return String(localized: "Watching the journal")
            }
        case "hermes":
            let rest = argumentsSkippingProfile(args)
            if let subcommand = rest.first(where: { !$0.hasPrefix("-") }) {
                return String(localized: "Hermes: \(subcommand)")
            }
        default:
            if program.hasSuffix("release.sh") { return String(localized: "Release build") }
        }
        return fallbackName(program: program, args: args)
    }

    // MARK: Rules

    /// `npm run dev`, `pnpm test`, `yarn build`, `bun run docs:dev`.
    private static func packageScriptName(manager: String, args: [String]) -> String? {
        var rest = args.drop { $0.hasPrefix("-") }
        guard var script = rest.first?.lowercased() else { return nil }
        if script == "run" || script == "run-script" {
            rest = rest.dropFirst().drop { $0.hasPrefix("-") }
            guard let named = rest.first?.lowercased() else { return nil }
            script = named
        }
        let parts = script.split(whereSeparator: { ":-_.".contains($0) }).map(String.init)
        if parts.contains("dev") {
            return parts.contains("docs") ? String(localized: "Docs site") : String(localized: "Dev server")
        }
        if parts.first == "test" || parts.contains("test") { return String(localized: "Tests") }
        if parts.contains("build") || parts.contains("release") {
            return parts.contains("release") ? String(localized: "Release build") : String(localized: "Build")
        }
        return nil
    }

    /// `python -m http.server`: the module after `-m`.
    private static func moduleName(_ args: [String]) -> String? {
        guard let index = args.firstIndex(of: "-m"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func isReleaseConfiguration(_ args: [String]) -> Bool {
        if let index = args.firstIndex(where: { $0 == "-c" || $0 == "--configuration" }), index + 1 < args.count {
            return args[index + 1] == "release"
        }
        return args.contains("--configuration=release") || args.contains("-c=release")
    }

    /// `docker compose up web`, `docker run -p 80:80 nginx:1.27`.
    private static func dockerName(_ args: [String]) -> String? {
        let lower = args.map { $0.lowercased() }
        if lower.first == "compose", lower.dropFirst().first(where: { !$0.hasPrefix("-") }) == "up" {
            let after = args.drop { $0.lowercased() != "up" }.dropFirst()
            return dockerComposeName(Array(after))
        }
        if lower.first == "run" {
            // Options that take a value; anything else starting with "-" is a flag.
            let valued: Set<String> = ["-p", "--publish", "-v", "--volume", "-e", "--env", "--env-file", "--name", "-w",
                                       "--workdir", "--network", "--net", "-u", "--user", "--entrypoint", "-l", "--label",
                                       "--mount", "--platform", "--restart", "-h", "--hostname", "--add-host", "--cpus",
                                       "-m", "--memory", "--gpus", "--device", "--pull", "--log-driver"]
            var index = 1
            while index < args.count {
                let word = args[index]
                if valued.contains(word.lowercased()) {
                    index += 2
                } else if word.hasPrefix("-") {
                    index += 1
                } else {
                    return String(localized: "Docker: \(imageName(word))")
                }
            }
            return String(localized: "Docker")
        }
        return nil
    }

    private static func dockerComposeName(_ args: [String]) -> String {
        if let service = args.first(where: { !$0.hasPrefix("-") }) {
            return String(localized: "Docker: \(service)")
        }
        return String(localized: "Docker: compose")
    }

    /// `ghcr.io/acme/web:1.2` → `web`.
    private static func imageName(_ image: String) -> String {
        let last = image.split(separator: "/").last.map(String.init) ?? image
        return last.split(separator: "@").first.flatMap { $0.split(separator: ":").first }.map(String.init) ?? last
    }

    /// `hermes -p engineer chat -q …` → "Message to Engineer"; Hermes' own delivery script for
    /// `message_agent` names the profile the same way. Its reply waiter waits for that Bot.
    private static func botMessageName(program: String, args: [String], botName: (String) -> String?) -> String? {
        if program == "hermes" {
            let rest = argumentsSkippingProfile(args)
            guard rest.first(where: { !$0.hasPrefix("-") }) == "chat" else { return nil }
            return String(localized: "Message to \(bot(profile(in: args) ?? "default", botName: botName))")
        }
        let script = (["python", "python3"].contains(program) ? args.first.map(basename) : program) ?? ""
        guard script == "bot_mode_dm.py" else { return nil }
        if let index = args.firstIndex(of: "--wait-reply"), index + 2 < args.count {
            return String(localized: "Waiting for \(args[index + 2])")
        }
        if let profile = profile(in: args) {
            return String(localized: "Message to \(bot(profile, botName: botName))")
        }
        return String(localized: "Message to a Bot")
    }

    /// The Bot a message to another Bot went to: the profile of Hermes's delivery
    /// (`bot_mode_dm.py … hermes -p <bot> chat …`). Nil for any other command, or one cut before it.
    public static func messageRecipient(of command: String) -> String? {
        let words = commandWords(command).map(\.value)
        guard words.contains(where: { basename($0) == "bot_mode_dm.py" })
                || (words.first.map(basename) == "hermes" && argumentsSkippingProfile(Array(words.dropFirst())).first(where: { !$0.hasPrefix("-") }) == "chat")
        else { return nil }
        return profile(in: words)
    }

    /// A message to another Bot sent by running Hermes itself, `hermes -p <bot> chat -q <words>`
    /// (`hermes_cli/_parser.py`: `-q`, `--query`): the Bot's profile and the words. Nil for any
    /// other command. `--query-file` carries its words in a file: the message shows none.
    public static func botMessage(in command: String) -> (profile: String, text: String)? {
        var words = commandWords(command).map(\.value)
        if let inner = shellCommandLine(words) { words = commandWords(inner).map(\.value) }
        // Of `cd ~ && hermes …`, the command that sends it.
        words = words.split(whereSeparator: { $0 == "&&" || $0 == ";" || $0 == "||" }).last.map(Array.init) ?? words
        guard words.first.map(basename) == "hermes" else { return nil }
        let args = Array(words.dropFirst())
        guard argumentsSkippingProfile(args).first(where: { !$0.hasPrefix("-") }) == "chat" else { return nil }
        var text = ""
        for (index, word) in args.enumerated() {
            if (word == "-q" || word == "--query"), index + 1 < args.count {
                text = args[index + 1]
                break
            }
            if word.hasPrefix("--query=") {
                text = String(word.dropFirst("--query=".count))
                break
            }
        }
        return (profile(in: args) ?? "default", text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func profile(in args: [String]) -> String? {
        for (index, word) in args.enumerated() {
            if (word == "-p" || word == "--profile"), index + 1 < args.count { return args[index + 1] }
            if word.hasPrefix("--profile=") { return String(word.dropFirst("--profile=".count)) }
        }
        return nil
    }

    private static func argumentsSkippingProfile(_ args: [String]) -> [String] {
        var rest: [String] = []
        var index = 0
        while index < args.count {
            if args[index] == "-p" || args[index] == "--profile" {
                index += 2
                continue
            }
            rest.append(args[index])
            index += 1
        }
        return rest
    }

    /// A profile as the app names its Bot: the display name, else the profile title-cased.
    static func bot(_ profile: String, botName: (String) -> String?) -> String {
        if let name = botName(profile), !name.isEmpty { return name }
        if profile == "default" { return "Hermes" }
        return profile.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The program and its first argument, at most 24 characters: `rsync backups`, `ffmpeg`. A
    /// script run by an interpreter is named for the script.
    private static func fallbackName(program: String, args: [String]) -> String {
        var program = program
        var args = args
        let interpreters: Set<String> = ["python", "python3", "node", "ruby", "bash", "sh", "zsh", "perl", "deno", "bun", "tsx", "ts-node"]
        if interpreters.contains(program), let script = args.first(where: { !$0.hasPrefix("-") }),
           let index = args.firstIndex(of: script), script != "run" {
            program = basename(script)
            args = Array(args[(index + 1)...])
        }
        var name = program
        // Its first argument, unless that's an option (`ffmpeg -i …` is just "ffmpeg").
        if let first = args.first, !first.hasPrefix("-"), !first.contains("=") {
            let shown = first.contains("/") ? basename(first) : first
            if !shown.isEmpty { name += " " + shown }
        }
        if name.count > fallbackLimit { name = String(name.prefix(fallbackLimit - 1)) + "…" }
        return name
    }

    /// The command line a shell runs (`bash -lc "…"`, `sh -c '…'`).
    static func shellCommandLine(_ words: [String]) -> String? {
        guard let shell = words.first.map(basename), ["bash", "sh", "zsh", "dash", "fish"].contains(shell),
              let flag = words.dropFirst().firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }),
              flag + 1 < words.count else { return nil }
        return words[flag + 1]
    }

    static func basename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    // MARK: Words

    /// One word of a command line: what the shell would pass (`value`) and how it was written.
    struct Word: Equatable {
        var value: String
        var raw: String
    }

    /// The words of the command after cleaning (§2).
    static func commandWords(_ command: String) -> [Word] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        var words: [Word]
        if trimmed.hasPrefix("["), case .array(let items)? = JSONValue.parse(trimmed) {
            let values = items.compactMap(\.stringValue)
            words = values.map { Word(value: $0, raw: quoted($0)) }
        } else {
            words = split(trimmed)
        }
        // Leading `cd … &&` (and `cd …;`, `set +m;`, `export X=1 &&`).
        while let first = words.first, ["cd", "set", "export"].contains(first.value),
              let separator = words.firstIndex(where: { $0.value == "&&" || $0.value == ";" }) {
            words.removeSubrange(0...separator)
        }
        // `VAR=value`, `nohup`, `exec`, `env` in front.
        while let first = words.first,
              first.value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
                || ["nohup", "exec", "env"].contains(first.value) {
            words.removeFirst()
        }
        // Redirections anywhere, and a trailing `&`.
        var cleaned: [Word] = []
        var index = 0
        while index < words.count {
            let word = words[index].value
            if word.range(of: #"^(\d*|&)(>>?|<)(&\d+|&-)?$"#, options: .regularExpression) != nil {
                // `>` alone takes the next word as its target; `2>&1` is whole.
                index += word.hasSuffix("&1") || word.hasSuffix("&2") || word.hasSuffix("&-") ? 1 : 2
                continue
            }
            if word.range(of: #"^(\d*|&)(>>?|<)\S+$"#, options: .regularExpression) != nil, words[index].raw == word {
                index += 1
                continue
            }
            cleaned.append(words[index])
            index += 1
        }
        while let last = cleaned.last, last.value == "&" || last.value == ";" {
            cleaned.removeLast()
        }
        return cleaned
    }

    /// Splits a command line into words, keeping each word as written. Operators (`&&`, `;`, `|`,
    /// `&`) are words of their own.
    static func split(_ line: String) -> [Word] {
        var words: [Word] = []
        var value = ""
        var raw = ""
        var quote: Character?
        var inWord = false
        var escaping = false
        func finish() {
            if inWord { words.append(Word(value: value, raw: raw)) }
            value = ""
            raw = ""
            inWord = false
        }
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaping {
                value.append(character)
                raw.append(character)
                escaping = false
            } else if let open = quote {
                raw.append(character)
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    escaping = true
                } else {
                    value.append(character)
                }
            } else if character == "\\" {
                raw.append(character)
                escaping = true
                inWord = true
            } else if character == "'" || character == "\"" {
                raw.append(character)
                quote = character
                inWord = true
            } else if character.isWhitespace {
                finish()
            } else if character == ";" || character == "|" || character == "&" {
                // `2>&1` and `&>` stay inside their redirection word.
                if character == "&", inWord, raw.hasSuffix(">") || raw.hasSuffix("<") {
                    value.append(character)
                    raw.append(character)
                } else if character == "&", !inWord, index + 1 < characters.count, characters[index + 1] == ">" {
                    value.append(character)
                    raw.append(character)
                    inWord = true
                } else {
                    finish()
                    var op = String(character)
                    if index + 1 < characters.count, characters[index + 1] == character || (character == "|" && characters[index + 1] == "&") {
                        op.append(characters[index + 1])
                        index += 1
                    }
                    words.append(Word(value: op, raw: op))
                }
            } else {
                value.append(character)
                raw.append(character)
                inWord = true
            }
            index += 1
        }
        finish()
        return words
    }

    /// A word as a shell would need it written.
    private static func quoted(_ word: String) -> String {
        guard word.isEmpty || word.contains(where: { $0.isWhitespace || "'\"$`\\|&;<>(){}*?!#".contains($0) }) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
