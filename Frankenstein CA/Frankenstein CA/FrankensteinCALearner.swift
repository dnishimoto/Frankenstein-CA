
import Foundation
import simd


// MARK: - Learner (object / goal Q-values owned by the CA layer)

/// Q-value store keyed by a CA-perceived state string. Replaces the
/// `objectQValues` dictionary that used to live in the Coordinator.
final class FrankensteinCALearner {
    private var table: [String: [String: Float]] = [:]

    let learningRate: Float = 0.20
    let discountFactor: Float = 0.90

    var stateCount: Int { table.count }

    func reset() {
        table.removeAll()
    }

    func values(for key: String) -> [String: Float] {
        table[key] ?? [:]
    }

    func ensure(key: String, actions: [String]) {
        for action in actions where table[key]?[action] == nil {
            table[key, default: [:]][action] = 0
        }
    }

    func reinforce(
        key: String,
        action: String,
        reward: Float,
        nextKey: String? = nil
    ) {
        let current = table[key]?[action] ?? 0

        var maxNext: Float = 0
        if let nextKey {
            maxNext = table[nextKey]?.values.max() ?? 0
        }

        let target = reward + discountFactor * maxNext
        table[key, default: [:]][action] =
            current + learningRate * (target - current)
    }
}

// MARK: - Path Field (distance paths computed by a cellular automaton)

/// Egocentric, world-aligned grid. Each cell holds an identified object cost.
/// A wavefront CA rule (each cell = min over 8 neighbours of neighbour
/// distance + own traversal cost) relaxes to a distance field from the goal.
/// Following the field's gradient gives obstacle-aware movement.
final class FrankensteinCAPathField {

    struct Obstacle {
        var center: SIMD2<Float>
        var halfExtent: SIMD2<Float>
        var className: String
    }

    private struct RememberedObstacle {
        var obstacle: Obstacle
        var lastSeen: TimeInterval
    }

    private enum Kind: UInt8 {
        case free, obstacle, goal
    }

    static let dimension = 31
    static let cellSize: Float = 0.5

    private let dimension = FrankensteinCAPathField.dimension
    private let cellSize = FrankensteinCAPathField.cellSize
    private var half: Int { dimension / 2 }

    private var kinds: [Kind]
    private var costs: [Float]
    private var distances: [Float]

    private var origin = SIMD2<Float>(0, 0)
    private var goalDirection = SIMD2<Float>(0, 0)
    private var goalRemainderMeters: Float = 0

    private(set) var generation = 0

    private let obstacleInflation: Float = 0.3
    private let relaxationSweeps = 45
    private let memoryDuration: TimeInterval = 10

    private var remembered: [String: RememberedObstacle] = [:]

    /// Traversal cost per identified object class. Adapted by outcomes.
    private(set) var classCost: [String: Float] = [
        "door": 3,
        "table": 6,
        "crate": 6,
        "movable": 6,
        "object": 12
    ]

    init() {
        let count = FrankensteinCAPathField.dimension *
            FrankensteinCAPathField.dimension

        kinds = Array(repeating: .free, count: count)
        costs = Array(repeating: 1, count: count)
        distances = Array(repeating: .infinity, count: count)
    }

    func reset() {
        remembered.removeAll()
        generation = 0

        classCost = [
            "door": 3,
            "table": 6,
            "crate": 6,
            "movable": 6,
            "object": 12
        ]

        for index in kinds.indices {
            kinds[index] = .free
            costs[index] = 1
            distances[index] = .infinity
        }
    }

    // MARK: Learning

    /// Raise a class's traversal cost when it blocked progress, lower it
    /// when the character made progress next to it.
    func learnClassOutcome(className: String, blocked: Bool) {
        guard className != "rechargeStation" else { return }

        let current = classCost[className] ?? 12
        let updated = blocked ? current + 1.0 : current - 0.25

        classCost[className] = min(40, max(1.5, updated))
    }

    // MARK: Object memory

    func observe(_ obstacles: [Obstacle], time: TimeInterval) {
        for obstacle in obstacles {
            let key = "\(obstacle.className)|" +
                "\(Int((obstacle.center.x * 2).rounded()))|" +
                "\(Int((obstacle.center.y * 2).rounded()))"

            remembered[key] = RememberedObstacle(
                obstacle: obstacle,
                lastSeen: time
            )
        }

        remembered = remembered.filter {
            time - $0.value.lastSeen <= memoryDuration
        }
    }

    // MARK: Rebuild + relax

    private func index(col: Int, row: Int) -> Int {
        row * dimension + col
    }

    private func cellCoordinates(for world: SIMD2<Float>) -> (col: Int, row: Int) {
        let col = Int(((world.x - origin.x) / cellSize).rounded()) + half
        let row = Int(((world.y - origin.y) / cellSize).rounded()) + half

        return (col, row)
    }

    private func inside(_ col: Int, _ row: Int) -> Bool {
        col >= 0 && col < dimension && row >= 0 && row < dimension
    }

    func rebuild(
        character: SIMD2<Float>,
        goal: SIMD2<Float>?
    ) {
        origin = character

        for index in kinds.indices {
            kinds[index] = .free
            costs[index] = 1
            distances[index] = .infinity
        }

        // Rasterize identified objects.
        for item in remembered.values {
            let obstacle = item.obstacle
            let cost = classCost[obstacle.className] ?? 12

            let minWorld = obstacle.center - obstacle.halfExtent -
                SIMD2<Float>(repeating: obstacleInflation)
            let maxWorld = obstacle.center + obstacle.halfExtent +
                SIMD2<Float>(repeating: obstacleInflation)

            let lower = cellCoordinates(for: minWorld)
            let upper = cellCoordinates(for: maxWorld)

            for row in max(0, lower.row)...min(dimension - 1, max(lower.row, upper.row)) {
                for col in max(0, lower.col)...min(dimension - 1, max(lower.col, upper.col)) {
                    guard inside(col, row) else { continue }

                    let i = index(col: col, row: row)

                    kinds[i] = .obstacle
                    costs[i] = max(costs[i], cost)
                }
            }
        }

        // The character's own cell is always traversable.
        let centerIndex = index(col: half, row: half)
        kinds[centerIndex] = .free
        costs[centerIndex] = 1

        // Goal cell (projected to the grid border when out of range).
        goalRemainderMeters = 0
        goalDirection = SIMD2<Float>(0, 0)

        guard let goal else {
            generation += 1
            return
        }

        let delta = goal - character
        let length = simd_length(delta)

        goalDirection = length > 0.0001 ? delta / length : SIMD2<Float>(0, 0)

        let limit = Float(half - 1) * cellSize
        var goalWorld = goal

        if max(abs(delta.x), abs(delta.y)) > limit {
            let scale = limit / max(abs(delta.x), abs(delta.y))
            goalWorld = character + delta * scale
            goalRemainderMeters = length * (1 - scale)
        }

        let goalCell = cellCoordinates(for: goalWorld)

        guard inside(goalCell.col, goalCell.row) else {
            generation += 1
            return
        }

        let goalIndex = index(col: goalCell.col, row: goalCell.row)

        kinds[goalIndex] = .goal
        costs[goalIndex] = 1
        distances[goalIndex] = 0

        relax()
        generation += 1
    }

    /// CA rule: distance(cell) = min over 8 neighbours of
    /// distance(neighbour) + step * cost(cell). Iterated to a fixed point.
    private func relax() {
        let neighbours: [(dc: Int, dr: Int, step: Float)] = [
            (-1, 0, 1), (1, 0, 1), (0, -1, 1), (0, 1, 1),
            (-1, -1, 1.4142), (1, -1, 1.4142),
            (-1, 1, 1.4142), (1, 1, 1.4142)
        ]

        for _ in 0..<relaxationSweeps {
            var next = distances
            var changed = false

            for row in 0..<dimension {
                for col in 0..<dimension {
                    let i = index(col: col, row: row)

                    if kinds[i] == .goal { continue }

                    var best = distances[i]

                    for n in neighbours {
                        let nc = col + n.dc
                        let nr = row + n.dr

                        guard inside(nc, nr) else { continue }

                        let candidate =
                            distances[index(col: nc, row: nr)] +
                            n.step * costs[i]

                        if candidate < best {
                            best = candidate
                        }
                    }

                    if best < next[i] {
                        next[i] = best
                        changed = true
                    }
                }
            }

            distances = next

            if !changed { break }
        }
    }

    // MARK: Steering

    func steering() -> CAPathSteering? {
        let center = index(col: half, row: half)

        guard distances[center].isFinite else {
            return nil
        }

        var bestDistance = distances[center]
        var bestStep: (dc: Int, dr: Int)?

        for dr in -1...1 {
            for dc in -1...1 {
                if dc == 0 && dr == 0 { continue }

                let nc = half + dc
                let nr = half + dr

                guard inside(nc, nr) else { continue }

                let value = distances[index(col: nc, row: nr)]

                if value < bestDistance {
                    bestDistance = value
                    bestStep = (dc, dr)
                }
            }
        }

        guard let step = bestStep else {
            return nil
        }

        // Column maps to world x, row maps to world z.
        let dx = Float(step.dc)
        let dz = Float(step.dr)

        let heading = atan2(-dx, -dz)

        var isDetouring = false

        if simd_length(goalDirection) > 0.001 {
            let stepDirection = simd_normalize(SIMD2<Float>(dx, dz))
            let alignment = simd_dot(stepDirection, goalDirection)

            isDetouring = alignment < 0.92
        }

        return CAPathSteering(
            heading: heading,
            pathDistance: distances[center] * cellSize + goalRemainderMeters,
            isDetouring: isDetouring,
            generation: generation
        )
    }
}

// MARK: - Executive (learning + path control under one CA owner)

final class FrankensteinCAExecutive {
    let learner = FrankensteinCALearner()
    let field = FrankensteinCAPathField()

    func reset() {
        learner.reset()
        field.reset()
    }
}
