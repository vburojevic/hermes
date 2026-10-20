import Foundation

/// Where each node of the learning map sits (`docs/learned.md` §2): clusters by category, a force
/// layout inside and between them, and every start position seeded by the node's id, so the map
/// looks the same each visit and only shifts where something new arrives.
public enum LearningLayout {
    public struct Point: Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Positions in the unit square (0…1 on both axes, with a margin), by node id. `aspect` is
    /// width / height of the space it will be drawn in.
    public static func positions(for graph: LearningGraph, aspect: Double = 1, iterations: Int = 240) -> [String: Point] {
        let nodes = graph.nodes
        guard !nodes.isEmpty else { return [:] }
        let aspect = max(0.4, min(aspect, 3))

        // Cluster centres: skill categories biggest first around an ellipse, memories in the middle
        // of their skills (they attach by edges).
        let categories = graph.clusters.map(\.category).filter { $0 != "memory" }
        var centres: [String: Point] = [:]
        for (index, category) in categories.enumerated() {
            if categories.count == 1 {
                centres[category] = Point(x: 0, y: 0)
                continue
            }
            let angle = Double(index) / Double(categories.count) * 2 * .pi + seed(category) * 0.4
            centres[category] = Point(x: cos(angle) * 0.55 * aspect, y: sin(angle) * 0.55)
        }

        var position: [Point] = nodes.map { node in
            let centre = centres[node.category] ?? Point(x: 0, y: 0)
            let a = seed(node.id) * 2 * .pi
            let r = 0.08 + seed(node.id + "#r") * 0.18
            return Point(x: centre.x + cos(a) * r, y: centre.y + sin(a) * r)
        }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        let links = graph.edges.compactMap { edge -> (Int, Int)? in
            guard let a = index[edge.source], let b = index[edge.target] else { return nil }
            return (a, b)
        }
        let weight = nodes.map { $0.isSkill ? 1.0 + min(Double($0.useCount), 20) / 10 : 0.4 }

        var temperature = 0.06
        for _ in 0..<max(1, iterations) {
            var force = [Point](repeating: Point(x: 0, y: 0), count: nodes.count)
            // Every pair pushes apart (heavier skills push harder).
            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    var dx = position[i].x - position[j].x
                    var dy = position[i].y - position[j].y
                    var distance2 = dx * dx + dy * dy
                    if distance2 < 1e-6 {
                        dx = seed("\(i)-\(j)") - 0.5
                        dy = seed("\(j)-\(i)") - 0.5
                        distance2 = 1e-4
                    }
                    let push = 0.0009 * (weight[i] + weight[j]) / distance2
                    let distance = sqrt(distance2)
                    force[i].x += dx / distance * push
                    force[i].y += dy / distance * push
                    force[j].x -= dx / distance * push
                    force[j].y -= dy / distance * push
                }
            }
            // Edges pull together, toward a short rest length.
            for (a, b) in links {
                let dx = position[b].x - position[a].x
                let dy = position[b].y - position[a].y
                let distance = max(sqrt(dx * dx + dy * dy), 1e-4)
                let rest = nodes[a].isSkill && nodes[b].isSkill ? 0.2 : 0.12
                let pull = (distance - rest) * 0.08
                force[a].x += dx / distance * pull
                force[a].y += dy / distance * pull
                force[b].x -= dx / distance * pull
                force[b].y -= dy / distance * pull
            }
            // Skills drift to their category's centre; everything stays near the middle.
            for i in 0..<nodes.count {
                if nodes[i].isSkill, let centre = centres[nodes[i].category] {
                    force[i].x += (centre.x - position[i].x) * 0.03
                    force[i].y += (centre.y - position[i].y) * 0.03
                }
                force[i].x -= position[i].x * 0.006
                force[i].y -= position[i].y * 0.006
            }
            for i in 0..<nodes.count {
                let length = sqrt(force[i].x * force[i].x + force[i].y * force[i].y)
                let scale = length > temperature ? temperature / length : 1
                position[i].x += force[i].x * scale
                position[i].y += force[i].y * scale
            }
            temperature = max(temperature * 0.985, 0.002)
        }

        // Fit into the unit square, keeping the aspect: x spans the width, y the height.
        let xs = position.map(\.x), ys = position.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let spanX = max(maxX - minX, 1e-3), spanY = max(maxY - minY, 1e-3)
        let margin = 0.1
        let scale = min((1 - 2 * margin) / spanX * aspect, (1 - 2 * margin) / spanY)
        let offsetX = (1 - spanX * scale / aspect) / 2
        let offsetY = (1 - spanY * scale) / 2
        var result: [String: Point] = [:]
        for (i, node) in nodes.enumerated() {
            result[node.id] = Point(x: offsetX + (position[i].x - minX) * scale / aspect, y: offsetY + (position[i].y - minY) * scale)
        }
        return result
    }

    /// A stable number in 0..<1 from text (FNV-1a), the same on every device and run.
    static func seed(_ text: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Double(hash % 1_000_003) / 1_000_003
    }
}
