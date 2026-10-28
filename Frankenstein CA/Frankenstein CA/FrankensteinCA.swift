
import Foundation
import Combine

/// 18 x 18 cellular automaton and executive action controller.
/// Learned Q-values are stored in dedicated action-neuron cells.
/// Futility detection discourages actions associated with repetitive paths.
final class FrankensteinCA: ObservableObject {

    let size = 18

    @Published private(set) var generation: Int = 0
    @Published private(set) var isRunning = false
    @Published private(set) var liveCellCount: Int = 0
    @Published private(set) var lastDecisionDescription =
        "Waiting for perception"

    @Published var networkQGrid: [[Float]]

    // MARK: - Cellular automaton storage

    private var grid: [[Bool]]
    private var nextGrid: [[Bool]]
    private let qTieBreakWeight: Float = 0.02

    // MARK: - Futility learning

    @Published private(set) var futilityCount: Int = 0
    @Published private(set) var futilityStatus = "No loop detected"

    private struct PositionSample {
        let x: Float
        let z: Float
        let time: TimeInterval
        let action: FrankensteinAction
    }

    private var recentPositions: [PositionSample] = []
    private var lastPositionSampleTime: TimeInterval = 0
    private var lastLoopPenaltyTime: TimeInterval = 0

    private var futilityPenalties: [FrankensteinAction: Float] = [:]

    private let positionSampleInterval: TimeInterval = 0.25
    private let loopMinimumAge: TimeInterval = 2.0
    private let loopDistanceThreshold: Float = 0.45
    private let maximumPositionSamples = 40
    private let maximumFutilityPenalty: Float = 8.0
    private let futilityPenaltyIncrement: Float = 1.5

    init() {
        grid = Array(
            repeating: Array(repeating: false, count: size),
            count: size
        )

        nextGrid = grid

        networkQGrid = Array(
            repeating: Array(repeating: 0.0, count: size),
            count: size
        )

        randomize()
        liveCellCount = countLiveCells()
    }

    // MARK: - Cellular automaton

    func isActive(_ x: Int, _ y: Int) -> Bool {
        guard (0..<size).contains(x),
              (0..<size).contains(y) else {
            return false
        }

        return grid[y][x]
    }

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func tick() {
        guard isRunning else { return }
        update()
    }

    func step() {
        update()
    }

    func reset() {
        generation = 0
        randomize()
        liveCellCount = countLiveCells()

        for y in 0..<size {
            for x in 0..<size {
                networkQGrid[y][x] = 0
            }
        }

        recentPositions.removeAll()
        futilityPenalties.removeAll()
        lastPositionSampleTime = 0
        lastLoopPenaltyTime = 0
        futilityCount = 0
        futilityStatus = "No loop detected"

        lastDecisionDescription = "Reset"
    }

    func update() {
        for y in 0..<size {
            for x in 0..<size {
                let neighbors = countLiveNeighbors(x: x, y: y)

                nextGrid[y][x] =
                    (grid[y][x] &&
                     (neighbors == 2 || neighbors == 3)) ||
                    (!grid[y][x] && neighbors == 3)
            }
        }

        swap(&grid, &nextGrid)
        generation += 1
        liveCellCount = countLiveCells()
    }

    // MARK: - Action-neuron layout

    private func actionNeuronPosition(
        for action: FrankensteinAction
    ) -> (x: Int, y: Int)? {
        switch action {
        case .walk:        return (8, 8)
        case .run:         return (8, 4)
        case .turnLeft:    return (4, 8)
        case .turnRight:   return (12, 8)
        case .jump:        return (8, 2)
        case .crouch:      return (4, 4)
        case .recover:     return (12, 4)
        case .stepUp:      return (4, 12)
        case .stepDown:    return (12, 12)
        case .crawl:       return (6, 14)
        case .roll:        return (10, 14)
        case .backward:    return (8, 6)
        case .stepForward: return (14, 6)
        case .liftObject:  return (2, 8)
        case .placeObject: return (2, 4)
        case .throwObject: return (2, 12)
        default:           return nil
        }
    }

    // MARK: - Q-value network API

    func qValue(atX x: Int, y: Int) -> Float {
        guard (0..<size).contains(x),
              (0..<size).contains(y) else {
            return 0
        }

        return networkQGrid[y][x]
    }

    func qValue(for action: FrankensteinAction) -> Float {
        guard let position = actionNeuronPosition(for: action) else {
            return 0
        }

        return networkQGrid[position.y][position.x]
    }

    /// Loads policy Q-values into their corresponding CA cells.
    func setQValues(_ qValues: [FrankensteinAction: Float]) {
        for y in 0..<size {
            for x in 0..<size {
                networkQGrid[y][x] = 0
            }
        }

        for (action, value) in qValues {
            guard let position = actionNeuronPosition(for: action) else {
                continue
            }

            networkQGrid[position.y][position.x] = value
        }
    }

    func networkQValues() -> [FrankensteinAction: Float] {
        var values: [FrankensteinAction: Float] = [:]

        for action in supportedActions {
            values[action] = qValue(for: action)
        }

        return values
    }

    private var supportedActions: [FrankensteinAction] {
        [
            .walk, .run, .turnLeft, .turnRight,
            .jump, .crouch, .recover, .stepUp,
            .stepDown, .crawl, .roll, .backward,
            .stepForward, .liftObject, .placeObject,
            .throwObject
        ]
    }

    // MARK: - Futility observation

    /// Call using the action actually executed and the character's
    /// actual scene position, not merely the requested action.
    ///
    /// Position samples must be supplied regularly by Coordinator.
    func observeMovementForFutility(
        action: FrankensteinAction,
        x: Float,
        z: Float,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        guard timestamp - lastPositionSampleTime >=
                positionSampleInterval else {
            return
        }

        lastPositionSampleTime = timestamp

        let current = PositionSample(
            x: x,
            z: z,
            time: timestamp,
            action: action
        )

        // Look for a return to a previous position after enough time
        // and several intervening samples.
        var matchingSample: PositionSample?

        if recentPositions.count >= 8 {
            for old in recentPositions.dropLast(4) {
                let dx = current.x - old.x
                let dz = current.z - old.z
                let distance = sqrt(dx * dx + dz * dz)
                let age = timestamp - old.time

                if distance < loopDistanceThreshold,
                   age >= loopMinimumAge {
                    matchingSample = old
                    break
                }
            }
        }

        recentPositions.append(current)

        if recentPositions.count > maximumPositionSamples {
            recentPositions.removeFirst(
                recentPositions.count - maximumPositionSamples
            )
        }

        guard let match = matchingSample else {
            return
        }

        // Prevent the same short loop from being penalized repeatedly
        // on every sample.
        guard timestamp - lastLoopPenaltyTime >= loopMinimumAge else {
            return
        }

        lastLoopPenaltyTime = timestamp
        futilityCount += 1

        // Penalize the current action and actions recorded along the
        // repeated segment. This helps when turning actions alternate.
        var actionsToPenalize: Set<FrankensteinAction> = [action]

        for sample in recentPositions
        where sample.time >= match.time {
            actionsToPenalize.insert(sample.action)
        }

        for failedAction in actionsToPenalize {
            let oldPenalty = futilityPenalties[failedAction, default: 0]

            futilityPenalties[failedAction] = min(
                oldPenalty + futilityPenaltyIncrement,
                maximumFutilityPenalty
            )
        }

        futilityStatus =
            "Loop detected #\(futilityCount); reconsidering actions"

        print("[CA Futility] Repeated position detected.")
        print("[CA Futility] Actions penalized: \(actionsToPenalize)")
        print("[CA Futility] Penalties: \(futilityPenalties)")
    }

    /// Diagnostic access to the current penalty for an action.
    func futilityPenalty(for action: FrankensteinAction) -> Float {
        futilityPenalties[action, default: 0]
    }

    // MARK: - Network scoring

    private func networkActivitySignal(
        for action: FrankensteinAction
    ) -> Float {
        guard let position = actionNeuronPosition(for: action) else {
            return 0
        }

        let neighbors = countLiveNeighbors(
            x: position.x,
            y: position.y
        )

        return Float(neighbors) / 8.0 * qTieBreakWeight
    }

    private func networkScore(
        for action: FrankensteinAction
    ) -> Float {
        qValue(for: action)
            + networkActivitySignal(for: action)
            - futilityPenalties[action, default: 0]
    }

    // MARK: - Executive action decision

    /// Selects the highest-scoring permitted action.
    /// Q-values come from the learning policy.
    /// Futility penalties discourage actions associated with loops.
    func decideAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        allowedActions: [FrankensteinAction],
        qValues: [FrankensteinAction: Float],
        exploration: Float = 0
    ) -> FrankensteinAction {
        guard !allowedActions.isEmpty else {
            lastDecisionDescription = "No permitted action"
            return .walk
        }

        // Load current policy values before scoring.
        setQValues(qValues)

        // Exploration chooses among permitted actions.
        if exploration > 0,
           Float.random(in: 0..<1) < exploration,
           let random = allowedActions.randomElement() {
            lastDecisionDescription =
                "Action=\(random) | exploring | futility-aware"

            return random
        }

        var selected = allowedActions[0]
        var bestScore = networkScore(for: selected)

        for action in allowedActions.dropFirst() {
            let score = networkScore(for: action)

            if score > bestScore {
                selected = action
                bestScore = score
            }
        }

        let selectedQ = qValue(for: selected)
        let selectedActivity = networkActivitySignal(for: selected)
        let penalty = futilityPenalties[selected, default: 0]

        let cellDescription: String

        if let position = actionNeuronPosition(for: selected) {
            cellDescription = "cell=(\(position.x),\(position.y))"
        } else {
            cellDescription = "cell=unmapped"
        }

        lastDecisionDescription =
            "Action=\(selected) | Q=\(selectedQ) | " +
            "CA-signal=\(selectedActivity) | " +
            "futility-penalty=\(penalty) | score=\(bestScore) | " +
            "\(cellDescription) | terrain=\(terrain.terrain) | " +
            "fallen=\(body.fallen)"

        print("[CA] Executive selected: \(selected)")
        print("[CA] Q-value: \(selectedQ)")
        print("[CA] Futility penalty: \(penalty)")
        print("[CA] Combined score: \(bestScore)")
        print("[CA] Network cell: \(cellDescription)")
        print("[CA] Permitted actions: \(allowedActions)")
        print("[CA] Futility count: \(futilityCount)")
        print("[CA] Generation=\(generation), live cells=\(liveCellCount)")

        return selected
    }

    // MARK: - Cellular activity

    private func countLiveNeighbors(x: Int, y: Int) -> Int {
        var count = 0

        for dy in -1...1 {
            for dx in -1...1 {
                if dx == 0 && dy == 0 {
                    continue
                }

                let nx = (x + dx + size) % size
                let ny = (y + dy + size) % size

                if grid[ny][nx] {
                    count += 1
                }
            }
        }

        return count
    }

    private func countLiveCells() -> Int {
        grid.reduce(0) { total, row in
            total + row.filter { $0 }.count
        }
    }

    private func randomize() {
        for y in 0..<size {
            for x in 0..<size {
                grid[y][x] = Bool.random()
            }
        }
    }
}
