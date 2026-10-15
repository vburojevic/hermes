import HermesKit
import SwiftUI

/// The card for a request other than an approval (`docs/quick-actions.md` §2). Each answers in
/// the shape Hermes expects and leaves a one-line receipt; no secret ever reaches the receipt.
struct RequestCard: View {
    let request: HermesRequest
    let conversation: ConversationModel

    var body: some View {
        Group {
            switch request.kind {
            case .clarify(let questions):
                ClarifyCard(request: request, questions: questions, conversation: conversation)
            case .secret(let envVar, let prompt):
                SecretCard(request: request, envVar: envVar, prompt: prompt, conversation: conversation)
            case .sudo(let command):
                SudoCard(request: request, command: command, conversation: conversation)
            case .vaultUnlock(let backend, let name):
                VaultUnlockCard(request: request, name: name ?? backend ?? String(localized: "password manager"), conversation: conversation)
            case .vaultSaveLogin(let origin, let site):
                SaveLoginCard(request: request, origin: origin, site: site ?? origin ?? String(localized: "this site"), conversation: conversation)
            case .vaultCode(let site, let hint):
                CodeCard(request: request, site: site, hint: hint, conversation: conversation)
            case .choose(let choice):
                ChooseCard(request: request, choice: choice, conversation: conversation)
            case .connection(let connection):
                ConnectionCard(request: request, connection: connection, conversation: conversation)
            }
        }
        .requestCard()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Clarify

/// `clarifySingle`, `clarifyMulti`, `clarifySteps`, `clarifyFree`.
private struct ClarifyCard: View {
    let request: HermesRequest
    let questions: [HermesRequest.Question]
    let conversation: ConversationModel

    @State private var step = 0
    @State private var answers: [String: String] = [:]
    @State private var picked: [String: Set<String>] = [:]
    @State private var other = ""
    @State private var editingOther = false
    @State private var freeText = ""

    private var question: HermesRequest.Question { questions[min(step, questions.count - 1)] }
    private var isSteps: Bool { questions.count > 1 }
    private var isLast: Bool { step >= questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(
                symbol: question.multiSelect ? "checklist" : "questionmark.circle.fill",
                title: title,
                subtitle: conversation.askerName,
                deadline: request.deadline
            )
            if isSteps {
                progress
                let earlier = questions.prefix(step).compactMap { question in answers[question.id].map { (question, $0) } }
                if !earlier.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(earlier, id: \.0.id) { item in
                            Button {
                                step = questions.firstIndex(of: item.0) ?? 0
                            } label: {
                                TagLabel(title: "\(Self.short(item.0.question)): \(item.1)", symbol: "checkmark")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Text(question.question)
                .font(.body)
                .foregroundStyle(Theme.primaryText)
            if question.choices.isEmpty {
                TextField("Your answer", text: $freeText, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
            } else {
                VStack(spacing: 8) {
                    ForEach(question.choices, id: \.self) { choice in
                        let parts = Self.split(choice)
                        ChoiceRow(
                            label: parts.label,
                            detail: parts.detail,
                            style: question.multiSelect ? .check : .radio,
                            isSelected: question.multiSelect ? picked[question.id, default: []].contains(choice) : answers[question.id] == choice
                        ) {
                            choose(choice)
                        }
                    }
                    if !question.multiSelect {
                        // What's typed here is the answer, sent like a pick (Return sends too).
                        OtherAnswerRow(text: $other, isEditing: $editingOther) {
                            if hasAnswer { advance() }
                        }
                    }
                }
            }
            footer
        }
        .onChange(of: step) {
            freeText = answers[question.id] ?? ""
            // Back to a question answered in words: the words, in their field.
            let earlier = answers[question.id].flatMap { question.choices.contains($0) ? nil : $0 }
            other = earlier ?? ""
            editingOther = earlier != nil && !question.choices.isEmpty
        }
        .onChange(of: other) { _, text in
            guard editingOther, !question.multiSelect, !question.choices.isEmpty else { return }
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            answers[question.id] = said.isEmpty ? nil : said
        }
        .onChange(of: editingOther) { _, editing in
            // Writing an answer of your own sets the picks aside.
            guard editing, !question.multiSelect, !question.choices.isEmpty else { return }
            let said = other.trimmingCharacters(in: .whitespacesAndNewlines)
            answers[question.id] = said.isEmpty ? nil : said
        }
    }

    /// The current question has an answer to send (a pick, or words of your own).
    private var hasAnswer: Bool {
        !(answers[question.id] ?? "").isEmpty
    }

    private var title: String {
        if isSteps { return String(localized: "Question \(step + 1) of \(questions.count)") }
        return question.multiSelect ? String(localized: "Pick what to include") : String(localized: "\(conversation.askerName) has a question")
    }

    private var progress: some View {
        HStack(spacing: 4) {
            ForEach(questions.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Theme.primaryText : Theme.controlFill)
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var footer: some View {
        if question.multiSelect {
            let count = picked[question.id, default: []].count
            CardFooter(
                secondary: isSteps && step > 0 ? String(localized: "Back") : String(localized: "Skip"),
                onSecondary: { isSteps && step > 0 ? (step -= 1) : skipQuestion() },
                primary: isLast ? (count > 0 ? String(localized: "Submit \(count)") : String(localized: "Submit")) : String(localized: "Next"),
                primaryEnabled: count > 0
            ) {
                record(question.choices.filter { picked[question.id, default: []].contains($0) }.joined(separator: ", "))
            }
        } else if question.choices.isEmpty {
            CardFooter(
                secondary: isSteps && step > 0 ? String(localized: "Back") : String(localized: "Skip"),
                onSecondary: { isSteps && step > 0 ? (step -= 1) : skipQuestion() },
                primary: isLast ? String(localized: "Send") : String(localized: "Next"),
                primaryEnabled: !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                record(freeText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            // A pick is a choice, not a send: it's confirmed here (Return too, on a keyboard).
            CardFooter(
                secondary: isSteps && step > 0 ? String(localized: "Back") : String(localized: "Skip"),
                onSecondary: { isSteps && step > 0 ? (step -= 1) : skipQuestion() },
                primary: isLast ? String(localized: "Send") : String(localized: "Next"),
                primaryEnabled: hasAnswer
            ) {
                advance()
            }
        }
    }

    private func choose(_ choice: String) {
        if question.multiSelect {
            var set = picked[question.id, default: []]
            if set.contains(choice) { set.remove(choice) } else { set.insert(choice) }
            picked[question.id] = set
        } else {
            // Picked, not sent: Send (or Next) confirms. Picking sets aside words of your own.
            answers[question.id] = choice
            editingOther = false
            other = ""
        }
    }

    /// Records the current question's answer and moves on, or sends everything.
    private func record(_ answer: String) {
        answers[question.id] = answer
        advance()
    }

    private func advance() {
        if isLast { send() } else { step += 1 }
    }

    private func skipQuestion() {
        answers[question.id] = nil
        if isLast { send(skippingCurrent: true) } else { step += 1 }
    }

    private func send(skippingCurrent: Bool = false) {
        var result: [String: JSONValue] = [:]
        for question in questions {
            result[question.id] = answers[question.id].map(JSONValue.string) ?? .null
        }
        let given = questions.compactMap { answers[$0.id].map { Self.split($0).label } }
        let receipt = given.isEmpty
            ? String(localized: "Skipped · \(Self.short(questions[0].question))")
            : String(localized: "Answered · \(given.joined(separator: " · "))")
        conversation.answer(request, with: .object(["answers": .object(result)]), receipt: receipt)
    }

    /// "Staging — Safe to reset" → label and detail.
    static func split(_ choice: String) -> (label: String, detail: String?) {
        for separator in [" — ", " – ", ": ", "\n"] {
            if let range = choice.range(of: separator) {
                return (String(choice[..<range.lowerBound]), String(choice[range.upperBound...]))
            }
        }
        return (choice, nil)
    }

    static func short(_ question: String) -> String {
        let words = question.split(separator: " ")
        return words.count <= 4 ? question : words.prefix(4).joined(separator: " ") + "…"
    }
}

// MARK: - Values

/// `secretAsk`: a skill needs a value for a named variable. Masked; saved on the gateway.
private struct SecretCard: View {
    let request: HermesRequest
    let envVar: String
    let prompt: String?
    let conversation: ConversationModel
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(
                symbol: "key.fill",
                title: String(localized: "\(conversation.askerName) needs \(envVar)"),
                subtitle: String(localized: "\(conversation.askerName) · skill setup"),
                deadline: request.deadline
            )
            if let prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
            }
            TagLabel(title: envVar)
                .font(.caption2.monospaced())
            MaskedField(placeholder: String(localized: "Paste or type the key"), text: $value, onSubmit: save)
            FinePrint(text: String(localized: "Saved to the gateway's .env. Never shown in chat or sent to the model."))
            CardFooter(secondary: String(localized: "Skip"), onSecondary: { conversation.skip(request) }, primary: String(localized: "Save Key"), primaryEnabled: !value.isEmpty, onPrimary: save)
        }
    }

    private func save() {
        guard !value.isEmpty else { return }
        conversation.answer(request, with: .object(["value": .string(value)]), receipt: String(localized: "Saved \(envVar) to the gateway"), symbol: "key")
        value = ""
    }
}

/// `sudoAsk`: the admin password for one command. Used once, never stored.
private struct SudoCard: View {
    let request: HermesRequest
    let command: String
    let conversation: ConversationModel
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(symbol: "lock.fill", title: String(localized: "Administrator password"), subtitle: conversation.askerName, deadline: request.deadline)
            if !command.isEmpty { CodeBox(text: command) }
            MaskedField(placeholder: String(localized: "Password"), text: $password, symbol: "lock", isPassword: true, allowsPaste: false, onSubmit: run)
            FinePrint(text: String(localized: "Used for this command only. Hermes doesn't keep it."))
            CardFooter(secondary: String(localized: "Cancel"), onSecondary: { conversation.skip(request) }, primary: String(localized: "Run"), primaryEnabled: !password.isEmpty, onPrimary: run)
        }
    }

    private func run() {
        guard !password.isEmpty else { return }
        conversation.answer(request, with: .object(["value": .string(password)]), receipt: String(localized: "Ran with your administrator password"), symbol: "lock")
        password = ""
    }
}

/// `vaultUnlock`: unlock the password manager for this session.
private struct VaultUnlockCard: View {
    let request: HermesRequest
    let name: String
    let conversation: ConversationModel
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(symbol: "lock.shield.fill", title: String(localized: "Unlock \(name)"), subtitle: String(localized: "\(conversation.askerName) · signing in"), deadline: request.deadline)
            Text("\(conversation.askerName) needs your password manager to fill a login.")
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
            MaskedField(placeholder: String(localized: "Master password"), text: $password, symbol: "lock", isPassword: true, allowsPaste: false, onSubmit: unlock)
            FinePrint(text: String(localized: "Goes straight to \(name). Only a session token stays in memory, until this chat ends."))
            CardFooter(secondary: String(localized: "Cancel"), onSecondary: { conversation.skip(request) }, primary: String(localized: "Unlock"), primaryEnabled: !password.isEmpty, onPrimary: unlock)
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        conversation.answer(request, with: .object(["value": .string(password)]), receipt: String(localized: "Unlocked \(name) for this chat"), symbol: "lock.open")
        password = ""
    }
}

/// `vaultSaveLogin`: the agent is about to fill a site it has no login for.
private struct SaveLoginCard: View {
    let request: HermesRequest
    let origin: String?
    let site: String
    let conversation: ConversationModel
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RequestHeader(symbol: "person.badge.key.fill", title: String(localized: "Save a login for \(site)"), subtitle: String(localized: "\(conversation.askerName) · browser"), deadline: request.deadline)
            if let origin {
                Label(origin, systemImage: "globe")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            PlainField(placeholder: String(localized: "Email or username"), text: $username, symbol: "person", contentType: .username)
            MaskedField(placeholder: String(localized: "Password"), text: $password, symbol: "lock", isPassword: true, allowsPaste: false)
            FinePrint(text: String(localized: "Saved to your password manager, not to Hermes."))
            CardFooter(secondary: String(localized: "Not Now"), onSecondary: { conversation.skip(request) }, primary: String(localized: "Save & Fill"), primaryEnabled: !username.isEmpty && !password.isEmpty) {
                let login: JSONValue = .object(["identifier": .string(username), "password": .string(password)])
                let json = (try? JSONEncoder().encode(login)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                conversation.answer(request, with: .object(["value": .string(json)]), receipt: String(localized: "Saved a login for \(site)"), symbol: "person.badge.key")
                password = ""
            }
        }
    }
}

/// `codeAsk`: six digit boxes; Paste Code; one-time-code AutoFill.
private struct CodeCard: View {
    let request: HermesRequest
    let site: String?
    let hint: String?
    let conversation: ConversationModel
    @State private var code = ""
    @FocusState private var focused: Bool

    private let length = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(symbol: "number.square.fill", title: String(localized: "Enter the 2FA code"), subtitle: [conversation.askerName, site].compactMap { $0 }.joined(separator: " · "), deadline: request.deadline)
            Text(hint ?? String(localized: "Open your authenticator app and type the code for \(site ?? "this sign-in")."))
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
            ZStack {
                TextField("", text: $code)
                    .focused($focused)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    #endif
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .opacity(0.02)
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(length))
                        if digits != new { code = digits }
                        if digits.count == length { submit() }
                    }
                HStack(spacing: 8) {
                    ForEach(0..<length, id: \.self) { index in
                        let characters = Array(code)
                        Text(index < characters.count ? String(characters[index]) : "")
                            .font(.title2.weight(.medium).monospacedDigit())
                            .foregroundStyle(Theme.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(index == characters.count && focused ? Theme.primaryText : Theme.hairline, lineWidth: index == characters.count && focused ? 2 : 1)
                            }
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .accessibilityElement()
            .accessibilityLabel("Code")
            .accessibilityValue(Text(code.isEmpty ? String(localized: "Empty") : code.map(String.init).joined(separator: " ")))
            Group {
                #if os(iOS)
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first { code = String(text.filter(\.isNumber).prefix(length)) }
                }
                .buttonBorderShape(.capsule)
                .tint(Theme.controlFill)
                .foregroundStyle(Theme.primaryText)
                #else
                Button {
                    if let text = Pasteboard.string() { code = String(text.filter(\.isNumber).prefix(length)) }
                } label: {
                    Label("Paste Code", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Theme.controlFill, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                #endif
            }
            .frame(maxWidth: .infinity)
            CardFooter(secondary: String(localized: "Cancel"), onSecondary: { conversation.skip(request) }, primary: String(localized: "Continue"), primaryEnabled: code.count == length, onPrimary: submit)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard code.count == length else { return }
        conversation.answer(request, with: .object(["value": .string(code)]), receipt: String(localized: "Sent the code for \(site ?? "sign-in")"), symbol: "number.square")
        code = ""
    }
}

// MARK: - Setup choices

/// `chooseAccent`, `chooseTheme`, `chooseOptions`.
private struct ChooseCard: View {
    let request: HermesRequest
    let choice: HermesRequest.Choice
    let conversation: ConversationModel

    @State private var selected: Set<String> = []
    @State private var other = ""
    @State private var editingOther = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(symbol: symbol, tint: Theme.warning, title: title, subtitle: String(localized: "\(conversation.askerName) · setup"), deadline: request.deadline)
            if !choice.question.isEmpty {
                Text(choice.question)
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
            }
            switch choice.kind {
            case "accent": swatches
            case "theme": themePicker
            default: options
            }
            CardFooter(
                secondary: String(localized: "Skip"),
                onSecondary: { conversation.skip(request) },
                primary: choice.multiSelect && selected.count > 0 ? String(localized: "Continue with \(selected.count)") : String(localized: "Continue"),
                primaryEnabled: !selected.isEmpty || !said.isEmpty
            ) {
                send()
            }
        }
        .onAppear {
            selected = Set(choice.preselected)
            if choice.kind == "theme", selected.isEmpty, let first = choice.options.first { selected = [first.id] }
        }
        .onChange(of: editingOther) { _, editing in
            // Writing an answer of your own sets the picks aside.
            if editing { selected = [] }
        }
    }

    /// An answer in your own words ("Something else…"), while it's being given.
    private var said: String {
        editingOther ? other.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private var title: String {
        switch choice.kind {
        case "accent": String(localized: "Pick an accent")
        case "theme": String(localized: "Choose an appearance")
        case "connectors": String(localized: "Connect your apps")
        case "plugins": String(localized: "Add plugins")
        default: String(localized: "\(conversation.askerName) has a question")
        }
    }

    private var symbol: String {
        switch choice.kind {
        case "accent": "sparkles"
        case "theme": "circle.lefthalf.filled"
        case "connectors": "app.connected.to.app.below.fill"
        default: "questionmark.circle.fill"
        }
    }

    private var swatches: some View {
        HStack(spacing: 10) {
            ForEach(choice.options) { option in
                let isSelected = selected.contains(option.id)
                Button {
                    selected = [option.id]
                } label: {
                    Circle()
                        .fill(Self.color(for: option))
                        .frame(width: 30, height: 30)
                        .padding(3)
                        .overlay(Circle().strokeBorder(isSelected ? Theme.primaryText : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var themePicker: some View {
        Picker("Appearance", selection: Binding(get: { selected.first ?? "" }, set: { selected = [$0] })) {
            ForEach(choice.options) { option in
                Text(option.label).tag(option.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var options: some View {
        VStack(spacing: 8) {
            ForEach(choice.options) { option in
                ChoiceRow(label: option.label, detail: option.detail, style: choice.multiSelect ? .check : .radio, isSelected: selected.contains(option.id)) {
                    if choice.multiSelect {
                        if selected.contains(option.id) { selected.remove(option.id) } else { selected.insert(option.id) }
                    } else {
                        selected = [option.id]
                    }
                    editingOther = false
                    other = ""
                }
            }
            OtherAnswerRow(text: $other, isEditing: $editingOther) {
                if !said.isEmpty { send() }
            }
        }
    }

    private func send() {
        if !said.isEmpty {
            conversation.answer(request, with: .object(["picked": .null, "said": .string(said)]), receipt: String(localized: "Answered · \(said)"))
            return
        }
        let picked = choice.options.filter { selected.contains($0.id) }
        guard !picked.isEmpty else { return }
        let label = picked.map(\.label).joined(separator: ", ")
        let value: JSONValue = choice.multiSelect ? .array(picked.map { .string($0.id) }) : .string(picked[0].id)
        conversation.answer(request, with: .object(["picked": value, "label": .string(label)]), receipt: String(localized: "Chose \(label)"))
    }

    /// Accent ids are colour names or hex; fall back to the Bot accent palette.
    static func color(for option: HermesRequest.Option) -> Color {
        let key = option.id.lowercased()
        if let accent = BotAccent.allCases.first(where: { $0.rawValue.lowercased() == key || $0.name.lowercased() == option.label.lowercased() }) {
            return accent.color
        }
        let named: [String: Color] = ["graphite": .gray, "black": Theme.primaryText, "red": .red, "orange": .orange, "yellow": .yellow, "green": .green, "mint": .mint, "teal": .teal, "cyan": .cyan, "blue": .blue, "indigo": .indigo, "purple": .purple, "pink": .pink]
        return named[key] ?? Theme.secondaryText
    }
}

// MARK: - Connections

/// `connectCredentials`, `connectSignIn` → `connectWaiting` → `connectDone`, `installAsk`.
private struct ConnectionCard: View {
    let request: HermesRequest
    let connection: HermesRequest.Connection
    let conversation: ConversationModel

    @Environment(\.openURL) private var openURL
    @State private var values: [String: String] = [:]
    @State private var enabled: Set<String> = []
    @State private var signingIn = false

    private var states: [String: String] { conversation.connectionStates[request.id] ?? [:] }
    private var credentialTarget: HermesRequest.Target? { connection.targets.first { !$0.requiredEnv.isEmpty } }
    private var signInTarget: HermesRequest.Target? { connection.targets.first { $0.needsSignIn } }
    private var addOns: [HermesRequest.Target] { connection.targets.filter(\.isAddOn) }

    var body: some View {
        Group {
            if let target = credentialTarget {
                credentials(target)
            } else if let target = signInTarget {
                signIn(target)
            } else if !addOns.isEmpty {
                install
            } else {
                generic
            }
        }
        .onAppear {
            enabled = Set(addOns.filter { $0.scan != "warnings" && $0.scan != "failed" }.map(\.name))
            for target in connection.targets {
                for field in target.requiredEnv where values[field.name] == nil {
                    values[field.name] = field.defaultValue ?? ""
                }
            }
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func kindLabel(_ target: HermesRequest.Target) -> String {
        switch target.kind {
        case "mcp": String(localized: "MCP server")
        case "plugin": String(localized: "Plugin")
        case "skill": String(localized: "Skill")
        default: String(localized: "App")
        }
    }

    // MARK: Credentials

    private func credentials(_ target: HermesRequest.Target) -> some View {
        let missing = target.requiredEnv.contains { $0.required && (values[$0.name] ?? "").isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            RequestHeader(
                symbol: "app.connected.to.app.below.fill",
                title: String(localized: "Connect \(target.name.capitalized)"),
                subtitle: String(localized: "\(kindLabel(target)) · \(conversation.askerName) wants its tools"),
                deadline: request.deadline
            )
            if let detail = target.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
            }
            badges(origin: target.origin, scan: target.scan)
            ForEach(target.requiredEnv) { field in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(field.name) · \(field.required ? String(localized: "required") : String(localized: "optional"))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                    if field.secret {
                        MaskedField(placeholder: field.prompt ?? String(localized: "Paste or type the key"), text: binding(field.name))
                    } else {
                        PlainField(placeholder: field.prompt ?? field.name, text: binding(field.name))
                    }
                }
            }
            CardFooter(secondary: String(localized: "Skip"), onSecondary: skipAll, primary: String(localized: "Connect"), primaryEnabled: !missing) {
                var env: [String: JSONValue] = [:]
                for field in target.requiredEnv {
                    let value = values[field.name] ?? ""
                    if !value.isEmpty { env[field.name] = .string(value) }
                }
                respond([target.name: ("approved", env)], receipt: String(localized: "Connected · \(target.name.capitalized)"))
            }
        }
    }

    @ViewBuilder
    private func badges(origin: String?, scan: String?) -> some View {
        if origin != nil || scan != nil {
            HStack(spacing: 6) {
                if let origin { TagLabel(title: origin.capitalized) }
                if let scan {
                    TagLabel(title: scan == "passed" ? String(localized: "Scan passed") : String(localized: "Scan \(scan)"), symbol: scan == "passed" ? "checkmark.shield.fill" : "exclamationmark.triangle.fill", style: scan == "passed" ? .success : .warning)
                }
            }
        }
    }

    // MARK: OAuth

    private func signIn(_ target: HermesRequest.Target) -> some View {
        let state = states[target.name] ?? target.state
        let connected = state == "connected" || state == "authorized" || state == "done"
        let name = target.name.capitalized
        return VStack(alignment: .leading, spacing: 12) {
            if connected {
                RequestHeader(symbol: "checkmark.shield.fill", tint: Theme.success, tileFill: Theme.successTint, title: String(localized: "\(name) connected"), subtitle: String(localized: "\(conversation.askerName) is continuing"))
                if let detail = target.detail {
                    Label(detail, systemImage: "person.crop.circle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.primaryText)
                }
            } else {
                RequestHeader(symbol: "link", title: String(localized: "Sign in to \(name)"), subtitle: String(localized: "Needed by \(conversation.askerName)"), deadline: request.deadline)
                if signingIn {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to finish in the browser…")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    CardFooter(secondary: String(localized: "Cancel"), onSecondary: skipAll, primary: String(localized: "Open Again")) {
                        if let url = target.connectURL { openURL(url) }
                    }
                } else {
                    if let detail = target.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Theme.primaryText)
                    }
                    Button {
                        if let url = target.connectURL { openURL(url) }
                        signingIn = true
                        approveSignIn(target)
                    } label: {
                        Label("Sign In with \(name)", systemImage: "arrow.up.forward.square")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.inkForeground)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Theme.ink, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    FinePrint(text: String(localized: "Opens \(target.connectURL?.host() ?? name) in your browser. Hermes never sees your password."))
                }
            }
        }
        .animation(Theme.spring, value: signingIn)
        .animation(Theme.spring, value: connected)
    }

    /// Tells Hermes to go ahead and wait for the sign-in; the card follows `connection.update`.
    private func approveSignIn(_ target: HermesRequest.Target) {
        Task {
            await conversation.respondToConnection(request, targets: [target.name: ("approved", [:])])
        }
    }

    // MARK: Add-ons

    private var install: some View {
        VStack(alignment: .leading, spacing: 12) {
            RequestHeader(symbol: "puzzlepiece.extension.fill", title: String(localized: "Install \(addOns.count) add-ons?"), subtitle: conversation.askerName, deadline: request.deadline)
            ForEach(addOns) { target in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                        if let detail = target.detail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        HStack(spacing: 6) {
                            Text([kindLabel(target), target.origin?.capitalized].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                            badges(origin: nil, scan: target.scan)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(target.name, isOn: Binding(
                        get: { enabled.contains(target.name) },
                        set: { if $0 { enabled.insert(target.name) } else { enabled.remove(target.name) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.success)
                }
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            CardFooter(secondary: String(localized: "Skip All"), onSecondary: skipAll, primary: String(localized: "Install \(enabled.count)"), primaryEnabled: !enabled.isEmpty) {
                var answers: [String: (String, [String: JSONValue])] = [:]
                for target in addOns { answers[target.name] = (enabled.contains(target.name) ? "approved" : "skipped", [:]) }
                respond(answers, receipt: String(localized: "Installed \(addOns.filter { enabled.contains($0.name) }.map(\.name).formatted(.list(type: .and)))"))
            }
        }
    }

    private var generic: some View {
        VStack(alignment: .leading, spacing: 12) {
            RequestHeader(symbol: "app.connected.to.app.below.fill", title: String(localized: "Connect \(connection.targets.map(\.name).formatted(.list(type: .and)))?"), subtitle: conversation.askerName, deadline: request.deadline)
            CardFooter(secondary: String(localized: "Skip"), onSecondary: skipAll, primary: String(localized: "Connect")) {
                var answers: [String: (String, [String: JSONValue])] = [:]
                for target in connection.targets { answers[target.name] = ("approved", [:]) }
                respond(answers, receipt: String(localized: "Connected · \(connection.targets.map(\.name).formatted(.list(type: .and)))"))
            }
        }
    }

    private func skipAll() {
        var answers: [String: (String, [String: JSONValue])] = [:]
        for target in connection.targets { answers[target.name] = ("skipped", [:]) }
        respond(answers, receipt: String(localized: "Skipped · \(connection.targets.map(\.name).formatted(.list(type: .and)))"))
    }

    private func respond(_ answers: [String: (String, [String: JSONValue])], receipt: String) {
        conversation.answer(request, with: ConversationModel.connectionResult(answers), receipt: receipt, symbol: "app.connected.to.app.below")
        values = [:]
    }
}
