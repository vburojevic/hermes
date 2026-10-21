import HermesKit
import SwiftUI

extension DebugFlags {
    /// `-HERMES_PASSWORDS YES|add:login|add:payment|add:address|unlock:<source>|item:<id>` opens
    /// Passwords, and in it an Add sheet, an Unlock sheet or an item (`docs/development.md`).
    static var passwords: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "HERMES_PASSWORDS")
        #else
        nil
        #endif
    }
}

/// `-HERMES_PASSWORDS …`: Passwords with a model of its own (screenshots).
struct DebugPasswordsPage: View {
    @State private var model: PasswordsModel

    init(workspace: BotWorkspace) {
        _model = State(initialValue: PasswordsModel(workspace: workspace))
    }

    var body: some View {
        PasswordsView(model: model)
    }
}

/// What `-HERMES_PASSWORDS` asks the page to open once it has loaded.
enum PasswordsDebugRoute {
    case add(VaultItem.Kind)
    case unlock(String)
    case item(String)

    static var current: PasswordsDebugRoute? {
        guard let route = DebugFlags.passwords else { return nil }
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "add": return VaultItem.Kind(rawValue: parts[1]).map(PasswordsDebugRoute.add)
        case "unlock": return .unlock(parts[1])
        case "item": return .item(parts[1])
        default: return nil
        }
    }
}
