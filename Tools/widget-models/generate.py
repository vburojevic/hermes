#!/usr/bin/env python3
"""Writes HermesKit's widget models (`WidgetModels.swift`) from the widget JSON Schemas.

The schemas in Packages/HermesKit/Sources/HermesKit/Widgets/Spec/schemas are copied verbatim
from the design project (docs/widgets/schemas). Run this after copying new ones:

    python3 -I Tools/widget-models/generate.py

Every primitive becomes a `Decodable` struct with its own fields (the envelope's are in
`WidgetEnvelope`), nested types for nested objects and string enums, and defaults applied while
decoding. The app decodes only payloads that already passed validation, so the models can be
strict. Unions the schemas allow are mapped to the hand-written types in `WidgetValues.swift`.
"""

import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCHEMAS = os.path.join(ROOT, "Packages/HermesKit/Sources/HermesKit/Widgets/Spec/schemas")
CATALOG = os.path.join(ROOT, "Packages/HermesKit/Sources/HermesKit/Widgets/Spec/catalog.json")
OUT = os.path.join(ROOT, "Packages/HermesKit/Sources/HermesKit/Widgets/WidgetModels.swift")

# Shared types from common.schema.json.
COMMON = {
    "State": "WidgetItemState",
    "WidgetState": "WidgetState",
    "Text": "String",
    "Label": "String",
    "RichText": "String",
    "Symbol": "String",
    "Time": "String",
    "Date": "String",
    "Url": "String",
    "Id": "String",
    "Seconds": "Double",
    "Quantity": "WidgetQuantity",
    "Delta": "WidgetDelta",
    "Tag": "WidgetTag",
    "Media": "WidgetMedia",
    "Leading": "WidgetLeading",
    "Person": "WidgetPerson",
    "Action": "WidgetAction",
    "Source": "WidgetSource",
    "Refresh": "WidgetRefresh",
    "Evidence": "WidgetEvidence",
    "Resolution": "WidgetResolution",
}
STRING_DEFS = {"Text", "Label", "RichText", "Symbol", "Time", "Date", "Url", "Id"}

SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
    "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static",
    "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do",
    "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while",
    "as", "catch", "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try",
}
# Nested type names that would shadow something the generated code or callers need.
TYPE_RENAMES = {"Type": "Kind", "Self": "Own", "Protocol": "Protocols", "Error": "Failure", "Result": "Outcome", "Task": "Job"}
IRREGULAR = {"children": "Child", "criteria": "Criterion", "series": "Series", "people": "Member",
             "news": "News", "status": "Status", "progress": "Progress", "address": "Address"}

ENVELOPE_FIELDS = None  # filled from envelope.schema.json
SKIPPED_FIELDS = {"type", "v", "fallback_text"}


def camel(name, upper=False):
    parts = [p for p in re.split(r"[_\-\s.]+", name) if p]
    if not parts:
        return name
    head = parts[0] if not upper else parts[0][:1].upper() + parts[0][1:]
    out = head + "".join(p[:1].upper() + p[1:] for p in parts[1:])
    if out[0].isdigit():
        out = "n" + out
    return out


def field_name(name):
    out = camel(name)
    return f"`{out}`" if out in SWIFT_KEYWORDS else out


def bare(name):
    return name.strip("`")


def type_name(name):
    out = camel(name, upper=True)
    return TYPE_RENAMES.get(out, out)


def singular(name):
    if name in IRREGULAR:
        return IRREGULAR[name]
    if name.endswith("ies"):
        return type_name(name[:-3] + "y")
    if name.endswith("ches") or name.endswith("shes") or name.endswith("sses") or name.endswith("xes"):
        return type_name(name[:-2])
    if name.endswith("s") and not name.endswith("ss"):
        return type_name(name[:-1])
    return type_name(name) + "Item"


def strip_docs(node):
    if isinstance(node, dict):
        return {k: strip_docs(v) for k, v in node.items() if k not in ("description", "examples", "default", "title")}
    if isinstance(node, list):
        return [strip_docs(x) for x in node]
    return node


class Struct:
    def __init__(self, name, path):
        self.name = name
        self.path = path
        self.fields = []  # (json key, swift name, swift type, required, default literal, doc)
        self.nested = []  # Struct or Enum
        self.doc = None


class Enum:
    def __init__(self, name, values, doc=None):
        self.name = name
        self.values = values
        self.doc = doc


def merged_object(schema):
    """Properties and required of an object schema, with properties from its applicators."""
    props = dict(schema.get("properties", {}))
    for key in ("allOf", "anyOf", "oneOf"):
        for branch in schema.get(key, []):
            if "$ref" in branch:
                continue
            for name, sub in branch.get("properties", {}).items():
                props.setdefault(name, sub)
    for key in ("then", "else"):
        branch = schema.get(key)
        if isinstance(branch, dict):
            for name, sub in branch.get("properties", {}).items():
                props.setdefault(name, sub)
    return props, list(schema.get("required", []))


def is_object(schema):
    return schema.get("type") == "object" or ("properties" in schema and "type" not in schema)


def first_line(text):
    lines = (text or "").strip().splitlines()
    return lines[0] if lines else None


def enum_literal(value):
    return "." + enum_case(value)


def enum_case(value):
    out = camel(str(value))
    if not out:
        out = "empty"
    return f"`{out}`" if out in SWIFT_KEYWORDS else out


class Generator:
    def __init__(self):
        self.common = json.load(open(os.path.join(SCHEMAS, "common.schema.json")))["$defs"]

    # Resolves one property schema to a Swift type, adding nested declarations to `owner`.
    def resolve(self, schema, prop, owner, local_defs, ancestors):
        if "$ref" in schema:
            ref = schema["$ref"]
            if ref.startswith("common.schema.json#/$defs/"):
                return COMMON[ref.split("/")[-1]], False
            if ref.startswith("#/$defs/"):
                name = ref.split("/")[-1]
                if name not in local_defs and name in COMMON:
                    return COMMON[name], False  # a reference inside common.schema.json
                return type_name(name), False
            raise SystemExit(f"unhandled $ref {ref} at {owner.path}/{prop}")

        if "allOf" in schema and "type" not in schema:
            refs = [branch for branch in schema["allOf"] if "$ref" in branch]
            # A shared type, maybe narrowed (a Quantity whose value must be a number): the type.
            if len(refs) == 1:
                return self.resolve(refs[0], prop, owner, local_defs, ancestors)

        if "enum" in schema:
            values = schema["enum"]
            if all(isinstance(v, str) for v in values):
                common = self.common_enum(values)
                if common:
                    return common, False
                name = self.unique(owner, type_name(prop))
                owner.nested.append(Enum(name, values))
                return name, False
            return "JSONValue", False

        if "const" in schema:
            value = schema["const"]
            return ("Bool" if isinstance(value, bool) else "Int" if isinstance(value, int) else
                    "Double" if isinstance(value, float) else "String"), False

        for key in ("anyOf", "oneOf"):
            if key in schema and "type" not in schema and "properties" not in schema:
                return self.union(schema[key], prop, owner, local_defs, ancestors)

        kind = schema.get("type")
        if isinstance(kind, list):
            nullable = "null" in kind
            rest = [k for k in kind if k != "null"]
            if len(rest) == 1:
                swift, _ = self.resolve({**schema, "type": rest[0]}, prop, owner, local_defs, ancestors)
                return swift, nullable
            return "WidgetValue", nullable

        if kind == "string":
            return "String", False
        if kind == "integer":
            return "Int", False
        if kind == "number":
            return "Double", False
        if kind == "boolean":
            return "Bool", False
        if kind == "null":
            return "JSONValue", True
        if kind == "array":
            items = schema.get("items")
            if items is None:
                return "[JSONValue]", False
            if owner.path.endswith("stack") and prop == "children":
                return "[WidgetStackChild]", False
            return f"[{self.resolve_element(items, prop, owner, local_defs, ancestors)}]", False
        if is_object(schema):
            props, _ = merged_object(schema)
            if props:
                return self.struct_for(schema, type_name(prop), owner, local_defs, ancestors), False
            extra = schema.get("additionalProperties")
            if isinstance(extra, dict):
                value, nullable = self.resolve(extra, prop + "_value", owner, local_defs, ancestors)
                return f"[String: {value}]", False
            return "JSONValue", False
        if kind is None and "allOf" in schema:
            return "JSONValue", False
        raise SystemExit(f"unhandled schema at {owner.path}/{prop}: {json.dumps(schema)[:200]}")

    def resolve_element(self, items, prop, owner, local_defs, ancestors):
        name = singular(prop)
        if is_object(items) and merged_object(items)[0]:
            return self.struct_for(items, name, owner, local_defs, ancestors)
        if "enum" in items and all(isinstance(v, str) for v in items["enum"]):
            common = self.common_enum(items["enum"])
            if common:
                return common
            enum_name = self.unique(owner, name)
            owner.nested.append(Enum(enum_name, items["enum"]))
            return enum_name
        swift, nullable = self.resolve(items, prop, owner, local_defs, ancestors)
        return swift + ("?" if nullable else "")

    def union(self, branches, prop, owner, local_defs, ancestors):
        shapes = [b for b in branches if set(b.keys()) - {"required", "description"}]
        if not shapes:
            return None, False  # only `required` constraints: the shape is elsewhere
        nullable = any(b.get("type") == "null" for b in shapes)
        rest = [b for b in shapes if b.get("type") != "null"]
        refs = [b.get("$ref", "").split("/")[-1] for b in rest]
        if all(r in STRING_DEFS for r in refs if r) and all("$ref" in b or b.get("type") == "string" for b in rest):
            return "String", nullable
        if set(refs) == {"Quantity", ""} and all(b.get("type") == "string" for b in rest if "$ref" not in b):
            return "WidgetFieldValue", nullable
        if any(b.get("type") == "object" for b in rest) and any(b.get("type") == "number" for b in rest):
            return "WidgetCell", nullable
        raise SystemExit(f"unhandled union at {owner.path}/{prop}: {json.dumps(branches)[:300]}")

    def common_enum(self, values):
        for name in ("State", "WidgetState"):
            if values == self.common[name]["enum"]:
                return COMMON[name]
        return None

    def unique(self, owner, name):
        taken = {n.name for n in owner.nested} | {owner.name}
        if name not in taken:
            return name
        index = 2
        while f"{name}{index}" in taken:
            index += 1
        return f"{name}{index}"

    def struct_for(self, schema, name, owner, local_defs, ancestors):
        props, _ = merged_object(schema)
        signature = json.dumps(strip_docs({k: v for k, v in props.items() if k != "children"}), sort_keys=True)
        # A tree spelled out level by level (outline) is one recursive type.
        for ancestor_name, ancestor_signature in ancestors:
            if ancestor_signature == signature:
                return ancestor_name
        name = self.unique(owner, name)
        struct = Struct(name, f"{owner.path}.{name}")
        owner.nested.append(struct)
        self.fill(struct, schema, local_defs, ancestors + [(name, signature)])
        return name

    def fill(self, struct, schema, local_defs, ancestors, skip=()):
        props, required = merged_object(schema)
        for key, sub in props.items():
            if key in skip:
                continue
            resolved = self.resolve(sub, key, struct, local_defs, ancestors)
            swift, nullable = resolved
            if swift is None:
                continue
            default = sub.get("default")
            literal = None
            if default is not None and not nullable:
                if isinstance(default, bool):
                    literal = "true" if default else "false"
                elif isinstance(default, (int, float)) and swift in ("Int", "Double"):
                    literal = str(default)
                elif isinstance(default, str):
                    literal = enum_literal(default) if swift not in ("String",) else json.dumps(default)
            struct.fields.append((key, field_name(key), swift, key in required and not nullable, literal,
                                  sub.get("description")))

    # Emission

    def emit_struct(self, struct, indent, out, conformance="Decodable, Hashable, Sendable"):
        pad = "    " * indent
        if struct.doc:
            out.append(f"{pad}/// {struct.doc}")
        out.append(f"{pad}public struct {struct.name}: {conformance} {{")
        inner = pad + "    "
        for key, name, swift, required, default, doc in struct.fields:
            if first_line(doc):
                out.append(f"{inner}/// {first_line(doc)}")
            optional = "" if required or default else "?"
            out.append(f"{inner}public var {name}: {swift}{optional}")
        if struct.fields:
            out.append("")
            out.append(f"{inner}enum CodingKeys: String, CodingKey {{")
            for key, name, *_ in struct.fields:
                if bare(name) == key:
                    out.append(f"{inner}    case {name}")
                else:
                    out.append(f"{inner}    case {name} = \"{key}\"")
            out.append(f"{inner}}}")
            out.append("")
            out.append(f"{inner}public init(from decoder: any Decoder) throws {{")
            out.append(f"{inner}    let container = try decoder.container(keyedBy: CodingKeys.self)")
            for key, name, swift, required, default, _ in struct.fields:
                if required:
                    out.append(f"{inner}    {name} = try container.decode({swift}.self, forKey: .{bare(name)})")
                elif default:
                    out.append(f"{inner}    {name} = try container.decodeIfPresent({swift}.self, forKey: .{bare(name)}) ?? {default}")
                else:
                    out.append(f"{inner}    {name} = try container.decodeIfPresent({swift}.self, forKey: .{bare(name)})")
            out.append(f"{inner}}}")
        for nested in struct.nested:
            out.append("")
            if isinstance(nested, Enum):
                self.emit_enum(nested, indent + 1, out)
            else:
                self.emit_struct(nested, indent + 1, out)
        out.append(f"{pad}}}")

    def emit_enum(self, enum, indent, out):
        pad = "    " * indent
        out.append(f"{pad}public enum {enum.name}: String, Decodable, Hashable, Sendable, CaseIterable {{")
        for value in enum.values:
            case = enum_case(value)
            if bare(case) == value:
                out.append(f"{pad}    case {case}")
            else:
                out.append(f"{pad}    case {case} = \"{value}\"")
        out.append(f"{pad}}}")

    def run(self):
        out = [
            "// Generated by Tools/widget-models/generate.py from the schemas in Widgets/Spec/schemas.",
            "// Don't edit: change the generator or the schemas, then run it again.",
            "",
            "import Foundation",
            "",
        ]
        # Common types.
        for name, swift in COMMON.items():
            schema = self.common[name]
            if name in STRING_DEFS or swift in ("String", "Double"):
                continue
            if "enum" in schema:
                enum = Enum(swift, schema["enum"])
                if first_line(schema.get("description")):
                    out.append(f"/// {first_line(schema.get('description'))}")
                self.emit_enum(enum, 0, out)
            else:
                struct = Struct(swift, swift)
                struct.doc = first_line(schema.get("description"))
                self.fill(struct, schema, {}, [])
                self.emit_struct(struct, 0, out)
            out.append("")

        envelope = json.load(open(os.path.join(SCHEMAS, "envelope.schema.json")))
        global ENVELOPE_FIELDS
        ENVELOPE_FIELDS = set(envelope["properties"].keys())
        struct = Struct("WidgetEnvelope", "envelope")
        struct.doc = "Fields every widget payload has (envelope.schema.json)."
        self.fill(struct, envelope, {}, [])
        self.emit_struct(struct, 0, out)
        out.append("")

        catalog = json.load(open(CATALOG))["types"]
        types = [entry["type"] for entry in catalog]
        for kind in types:
            schema = json.load(open(os.path.join(SCHEMAS, f"{kind}.schema.json")))
            struct = Struct(f"{type_name(kind)}Widget", kind)
            struct.doc = first_line(schema.get("description"))
            local_defs = schema.get("$defs", {})
            for def_name, def_schema in local_defs.items():
                nested = Struct(type_name(def_name), f"{kind}.{def_name}")
                struct.nested.append(nested)
                self.fill(nested, def_schema, local_defs, [])
            self.fill(struct, schema, local_defs, [], skip=ENVELOPE_FIELDS | SKIPPED_FIELDS)
            self.emit_struct(struct, 0, out)
            out.append("")

        out.append("/// The primitives this app draws (catalog.json).")
        out.append("public enum WidgetType: String, CaseIterable, Sendable {")
        for kind in types:
            out.append(f"    case {enum_case(kind)}")
        out.append("}")
        out.append("")
        out.append("/// A payload's own fields, by its type.")
        out.append("public enum WidgetContent: Hashable, Sendable {")
        for kind in types:
            out.append(f"    case {enum_case(kind)}({type_name(kind)}Widget)")
        out.append("")
        out.append("    public var type: WidgetType {")
        out.append("        switch self {")
        for kind in types:
            out.append(f"        case .{enum_case(kind)}: .{enum_case(kind)}")
        out.append("        }")
        out.append("    }")
        out.append("")
        out.append("    static func decode(_ type: WidgetType, from decoder: any Decoder) throws -> WidgetContent {")
        out.append("        switch type {")
        for kind in types:
            out.append(f"        case .{enum_case(kind)}: .{enum_case(kind)}(try {type_name(kind)}Widget(from: decoder))")
        out.append("        }")
        out.append("    }")
        out.append("}")
        out.append("")

        text = "\n".join(line for line in out)
        text = re.sub(r"\n{3,}", "\n\n", text).replace("\n\n}", "\n}")
        with open(OUT, "w") as handle:
            handle.write(text.rstrip() + "\n")
        print(f"wrote {os.path.relpath(OUT, ROOT)} ({len(types)} types)")


if __name__ == "__main__":
    Generator().run()
