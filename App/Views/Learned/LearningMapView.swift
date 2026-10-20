import HermesKit
import SwiftUI

/// The map of what was learned (`learningMap`, `learningMapCompact`): skills as circles sized by
/// use, ink when used 6+ times and grey otherwise, memories as small dots, lines from the graph's
/// edges. Ink, grey and size, never colour alone. Drawn in a Canvas; VoiceOver reads the skills by
/// cluster instead, with their connections as actions.
struct LearningMapView: View {
    let model: LearnedModel
    /// The preview card: no gestures, fewer labels.
    var isPreview = false
    /// Starts loose and settles into place (the welcome tour's `welcomeLearns`).
    var settles = false
    var onOpenMemory: ((LearningNode) -> Void)?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var appeared = false
    /// When the settling began; nil once it's done or for a map that doesn't settle.
    @State private var settleStart: Date?
    /// 0 = loose, 1 = in place.
    private static let settleDuration = 1.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var graph: LearningGraph? { model.graph }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let positions = model.positions(aspect: size.height > 0 ? size.width / size.height : 1)
            TimelineView(.animation(paused: settleStart == nil)) { timeline in
                let progress = settleStart.map { min(1, timeline.date.timeIntervalSince($0) / Self.settleDuration) } ?? 1
                Canvas { context, canvasSize in
                    draw(in: &context, size: canvasSize, positions: progress < 1 ? loosened(positions, progress: progress) : positions)
                } symbols: {
                    // Each skill's label, plain and selected, rendered once and reused every frame
                    // (panning and pinching redraw the map 60–120 times a second).
                    ForEach(labelNodes) { node in
                        labelText(node, selected: false).tag(node.id)
                        labelText(node, selected: true).tag(node.id + Self.selectedTag)
                    }
                }
            }
            .opacity(appeared || reduceMotion ? 1 : 0)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
            .contentShape(Rectangle())
            .gesture(isPreview ? nil : tap(size: size, positions: positions))
            .simultaneousGesture(isPreview ? nil : pinch)
            .simultaneousGesture(isPreview ? nil : pan)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Map of what \(model.learnerName) learned"))
            .accessibilityChildren { accessibleList }
        }
        .clipped()
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            }
        }
        .task(id: settles && !reduceMotion) {
            guard settles, !reduceMotion else { return }
            settleStart = .now
            try? await Task.sleep(for: .seconds(Self.settleDuration))
            settleStart = nil
        }
    }

    /// The layout pushed out from its centre and nudged per node (by id, so it's the same every
    /// time), easing back in as `progress` reaches 1.
    private func loosened(_ positions: [String: LearningLayout.Point], progress: Double) -> [String: LearningLayout.Point] {
        let eased = 1 - pow(1 - progress, 3)
        let slack = 1 - eased
        return positions.reduce(into: [:]) { result, entry in
            let angle = Double(BotAppearance.stringHash(entry.key) % 360) * .pi / 180
            let push = 0.06 * slack
            let x = 0.5 + (entry.value.x - 0.5) * (1 + 0.18 * slack) + cos(angle) * push
            let y = 0.5 + (entry.value.y - 0.5) * (1 + 0.18 * slack) + sin(angle) * push
            result[entry.key] = LearningLayout.Point(x: x, y: y)
        }
    }

    // MARK: Drawing

    private func point(_ id: String, positions: [String: LearningLayout.Point], size: CGSize) -> CGPoint? {
        guard let p = positions[id] else { return nil }
        let x = p.x * size.width, y = p.y * size.height
        let cx = size.width / 2, cy = size.height / 2
        return CGPoint(x: cx + (x - cx) * scale + offset.width, y: cy + (y - cy) * scale + offset.height)
    }

    /// A skill's radius by use; memories are dots.
    private func radius(_ node: LearningNode) -> CGFloat {
        guard node.isSkill else { return isPreview ? 2.5 : 3.2 }
        let base: CGFloat = isPreview ? 4 : 6
        return base + min(CGFloat(node.useCount), 16) * (isPreview ? 0.45 : 0.62)
    }

    private func fill(_ node: LearningNode) -> Color {
        if !node.isSkill { return Theme.tertiaryText }
        return node.isWellUsed ? Theme.ink : Theme.secondaryText
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, positions: [String: LearningLayout.Point]) {
        guard let graph else { return }
        let shown = Set(graph.nodes.filter(model.isShown).map(\.id))
        let selected = model.selectedID
        let lit: Set<String> = selected.map { id in Set([id] + graph.connections(of: id).map(\.id)) } ?? shown
        func alpha(_ id: String) -> Double { selected == nil || lit.contains(id) ? 1 : 0.3 }

        // Lines first, under the circles.
        for edge in graph.edges where shown.contains(edge.source) && shown.contains(edge.target) {
            guard let a = point(edge.source, positions: positions, size: size), let b = point(edge.target, positions: positions, size: size) else { continue }
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            let strong = selected != nil && (edge.source == selected || edge.target == selected)
            context.stroke(path, with: .color(Theme.separator.opacity(strong ? 1 : (selected == nil ? 0.9 : 0.3))), lineWidth: strong ? 1.6 : 1)
        }

        // Memories under skills, small skills under big ones.
        let ordered = graph.nodes.filter { shown.contains($0.id) }.sorted { radius($0) < radius($1) }
        for node in ordered {
            guard let center = point(node.id, positions: positions, size: size) else { continue }
            let r = radius(node)
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            if node.id == selected {
                // The ring: a halo of the canvas colour, then a hairline.
                let halo = rect.insetBy(dx: -5, dy: -5)
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: Theme.shadow.opacity(0.35), radius: 6, y: 2))
                    layer.fill(Path(ellipseIn: halo), with: .color(Theme.groupedCell))
                }
                context.stroke(Path(ellipseIn: halo), with: .color(Theme.separator), lineWidth: 1)
            }
            context.opacity = alpha(node.id)
            context.fill(Path(ellipseIn: rect), with: .color(fill(node)))
            if node.state == .stale {
                // Stale: a gap in the middle (shape, not colour).
                context.fill(Path(ellipseIn: rect.insetBy(dx: r * 0.45, dy: r * 0.45)), with: .color(Theme.groupedCell))
            }
            context.opacity = 1
        }

        // Labels for skills (the preview names only the biggest few).
        let labelled: [LearningNode] = {
            let skills = ordered.filter(\.isSkill)
            if isPreview { return Array(skills.sorted { $0.useCount > $1.useCount }.prefix(4)) }
            return skills
        }()
        // The selection's label first, then the most used: a label that would overlap one
        // already drawn (or a circle or dot) is left out rather than drawn over it.
        let priority = labelled.sorted {
            if ($0.id == selected) != ($1.id == selected) { return $0.id == selected }
            return $0.useCount > $1.useCount
        }
        var taken: [CGRect] = ordered.compactMap { node in
            guard let center = point(node.id, positions: positions, size: size) else { return nil }
            let r = radius(node)
            return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        }
        let bounds = CGRect(origin: .zero, size: size)
        for node in priority {
            guard let center = point(node.id, positions: positions, size: size) else { continue }
            let isSelected = node.id == selected
            guard let resolved = context.resolveSymbol(id: isSelected ? node.id + Self.selectedTag : node.id) else { continue }
            let measured = resolved.size
            func collides(_ frame: CGRect) -> Bool {
                !bounds.contains(frame) || taken.contains { $0.intersects(frame) && !$0.contains(center) }
            }
            var origin = CGPoint(x: center.x + radius(node) + 5, y: center.y - measured.height / 2)
            var frame = CGRect(origin: origin, size: measured).insetBy(dx: -2, dy: -1)
            if collides(frame) {
                // Try the other side of the circle.
                origin.x = center.x - radius(node) - 5 - measured.width
                frame = CGRect(origin: origin, size: measured).insetBy(dx: -2, dy: -1)
                if !isSelected, collides(frame) { continue }
            }
            taken.append(frame)
            context.opacity = alpha(node.id)
            context.draw(resolved, at: CGPoint(x: origin.x, y: center.y), anchor: .leading)
            context.opacity = 1
        }
    }

    private static let selectedTag = "#selected"

    /// The skills that can carry a label (the preview names only the biggest few).
    private var labelNodes: [LearningNode] {
        guard let graph else { return [] }
        let skills = graph.skills
        return isPreview ? Array(skills.sorted { $0.useCount > $1.useCount }.prefix(4)) : skills
    }

    private func labelText(_ node: LearningNode, selected: Bool) -> some View {
        Text(node.label)
            .font(isPreview ? .system(size: 10) : .caption)
            .fontWeight(selected ? .semibold : .regular)
            .foregroundStyle(selected ? Theme.primaryText : Theme.secondaryText)
            .fixedSize()
    }

    // MARK: Gestures

    private func tap(size: CGSize, positions: [String: LearningLayout.Point]) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            guard let graph else { return }
            let hit = graph.nodes.filter(model.isShown).compactMap { node -> (LearningNode, CGFloat)? in
                guard let center = point(node.id, positions: positions, size: size) else { return nil }
                let distance = hypot(center.x - value.location.x, center.y - value.location.y)
                return distance <= radius(node) + 12 ? (node, distance) : nil
            }.min { $0.1 < $1.1 }?.0
            guard let hit else {
                withAnimation(reduceMotion ? nil : Theme.snappy) { model.selectedID = nil }
                return
            }
            if hit.isSkill {
                withAnimation(reduceMotion ? nil : Theme.snappy) { model.selectedID = model.selectedID == hit.id ? nil : hit.id }
            } else {
                onOpenMemory?(hit)
            }
        }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in scale = min(max(lastScale * value.magnification, 0.6), 4) }
            .onEnded { _ in lastScale = scale }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    /// Back to the whole map.
    func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    // MARK: VoiceOver's list

    @ViewBuilder
    private var accessibleList: some View {
        if let graph {
            ForEach(graph.skillCategories, id: \.self) { category in
                let skills = graph.skills.filter { $0.category == category && model.isShown($0) }
                ForEach(skills) { skill in
                    let connections = graph.connections(of: skill.id)
                    Text("\(skill.label), \(Self.categoryName(category)), \(skill.useCount == 1 ? String(localized: "used once") : String(localized: "used \(skill.useCount) times")), \(connections.count == 1 ? String(localized: "1 connection") : String(localized: "\(connections.count) connections"))")
                        .accessibilityAddTraits(model.selectedID == skill.id ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { model.selectedID = skill.id }
                        .accessibilityActions {
                            ForEach(connections.prefix(8)) { other in
                                Button(other.isSkill ? String(localized: "Go to \(other.label)") : String(localized: "Memory: \(other.label)")) {
                                    if other.isSkill { model.selectedID = other.id } else { onOpenMemory?(other) }
                                }
                            }
                        }
                }
            }
            if model.filter != .skills {
                let memories = graph.memories
                if !memories.isEmpty {
                    Text(memories.count == 1 ? String(localized: "1 memory") : String(localized: "\(memories.count) memories"))
                }
            }
        }
    }

    /// "ios" → "iOS"-ish: categories as people read them.
    static func categoryName(_ category: String) -> String {
        let known = ["ios": "iOS", "macos": "macOS", "ai": "AI", "devops": "DevOps", "ml": "ML", "ui": "UI"]
        if let name = known[category.lowercased()] { return name }
        return category.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }
}
