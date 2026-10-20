import Foundation

/// The widget contract this app was built against, bundled from the design project's
/// `docs/widgets/` (`docs/widgets.md` §3): the JSON Schemas, the catalogue and the examples.
public final class WidgetSpec: Sendable {
    public static let shared = WidgetSpec()

    /// One primitive in `catalog.json`.
    public struct Entry: Decodable, Hashable, Sendable {
        public var type: String
        public var v: Int
        public var family: String
        public var cue: String
        public var summary: String
        public var examples: [String]
        public var design: Design
        public var skeleton: String
        public var fallback: String

        public struct Design: Decodable, Hashable, Sendable {
            public var file: String
            public var exports: [String]
        }
    }

    public static let schemaBase = "https://hermesapp.dev/schemas/widgets/"
    /// The major version of every primitive this app knows.
    public static let knownVersion = 1

    public let catalog: [Entry]
    let validator: JSONSchemaValidator
    /// Every property name a type's schema knows, at any depth (with the envelope's and the
    /// shared types'): a field by one of these names in the wrong place isn't an unknown field.
    let knownProperties: [String: Set<String>]
    private let folder: URL?

    private init() {
        let folder = Bundle.module.url(forResource: "Spec", withExtension: nil)
        self.folder = folder
        var documents: [JSONValue] = []
        if let schemas = folder?.appendingPathComponent("schemas"),
           let files = try? FileManager.default.contentsOfDirectory(at: schemas, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file), let schema = JSONValue.parse(data) { documents.append(schema) }
            }
        }
        validator = JSONSchemaValidator(documents: documents)
        var names: [String: Set<String>] = [:]
        for document in documents {
            guard let id = document["$id"]?.stringValue, let file = id.split(separator: "/").last else { continue }
            var found: Set<String> = []
            Self.collectPropertyNames(document, into: &found)
            names[String(file.split(separator: ".").first ?? "")] = found
        }
        let shared = names["envelope", default: []].union(names["common", default: []])
        knownProperties = names.mapValues { $0.union(shared) }
        struct Catalog: Decodable { var types: [Entry] }
        if let url = folder?.appendingPathComponent("catalog.json"), let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
            self.catalog = catalog.types
        } else {
            self.catalog = []
        }
    }

    public func entry(_ type: WidgetType) -> Entry? {
        catalog.first { $0.type == type.rawValue }
    }

    /// The example payloads (`examples/<type>-<n>.json`), in catalogue order: the gallery's
    /// content and the mock's.
    public func examples(for type: WidgetType? = nil) -> [(name: String, json: JSONValue)] {
        guard let folder else { return [] }
        let entries = type.map { type in catalog.filter { $0.type == type.rawValue } } ?? catalog
        return entries.flatMap(\.examples).compactMap { path in
            let url = folder.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url), let json = JSONValue.parse(data) else { return nil }
            return (url.deletingPathExtension().lastPathComponent, json)
        }
    }

    private static func collectPropertyNames(_ node: JSONValue, into found: inout Set<String>) {
        switch node {
        case .object(let object):
            if case .object(let properties)? = object["properties"] { found.formUnion(properties.keys) }
            for value in object.values { collectPropertyNames(value, into: &found) }
        case .array(let array):
            for value in array { collectPropertyNames(value, into: &found) }
        default:
            break
        }
    }

    static func schemaID(_ type: String) -> String {
        schemaBase + "\(type).schema.json"
    }
}
