import Foundation
import HermesKit

/// Words the transcriber should spell right (`docs/voice.md` §2): Bot names, projects and
/// skills, as `AnalysisContext.contextualStrings` (up to 100).
@MainActor
enum SpeechVocabulary {
    static func words(workspace: BotWorkspace, conversation: ConversationModel?) -> [String] {
        var words: Set<String> = ["Hermes"]
        if let roster = workspace.roster {
            words.formUnion(roster.visibleBots.prefix(30).map(\.displayName))
        }
        if let projects = workspace.projects {
            words.formUnion(projects.projects.values.prefix(30).map(\.name))
        }
        if let skills = conversation?.slashCatalog?.skillNames {
            // "pdf-tools" is said "PDF tools".
            words.formUnion(skills.prefix(40).map { $0.replacingOccurrences(of: "-", with: " ") })
        }
        return Array(words.filter { !$0.isEmpty }.sorted().prefix(100))
    }
}
