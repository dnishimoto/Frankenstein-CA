
import Foundation
import Combine

/// 18 x 18 cellular automaton and executive action controller.
///
/// Learned Q-values are stored in dedicated action-neuron cells.
/// The CA selects actions using values read back from those cells.
final class FrankensteinCA: ObservableObject {

    let size = 18

    @Published private(set) var generation: Int = 0
    @Published private(set) var isRunning = false
    @Published private(set) var liveCellCount: Int = 0
    @Published private(set) var lastDecisionDescription =
        "Waiting for perception"

    private var grid: [[Bool]]
    private var nextGrid: [[Bool]]

    /// Q-values stored at action-neuron coordinates: [y][x].
    @Published  var networkQGrid: [[Float]]

    private let qTieBreakWeight: Float = 0.02

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
        case .walk:      return (8, 8)
        case .run:       return (8, 4)
        case .turnLeft:  return (4, 8)
        case .turnRight: return (12, 8)
        case .jump:      return (8, 2)
        case .crouch:    return (4, 4)
        case .recover:   return (12, 4)
        case .stepUp:    return (4, 12)
        case .stepDown:  return (12, 12)
        case .crawl:     return (6, 14)
        case .roll:      return (10, 14)
        case .backward:  return (8, 6)
        case .stepForward: return (14, 6)
        case .liftObject: return (2, 8)
        case .placeObject: return (2, 4)
        case .throwObject: return (2, 12)
        default:         return nil
        }
    }

    // MARK: - Q-value network API

    /// Reads the Q-value at an individual network cell.
    func qValue(atX x: Int, y: Int) -> Float {
        guard (0..<size).contains(x),
              (0..<size).contains(y) else {
            return 0
        }

        return networkQGrid[y][x]
    }

    /// Returns the stored Q-value associated with an action.
    func qValue(for action: FrankensteinAction) -> Float {
        guard let position = actionNeuronPosition(for: action) else {
            return 0
        }

        return networkQGrid[position.y][position.x]
    }

    /// Loads learned values into the network without selecting an action.
    ///
    /// Call this with the latest values obtained from the learning system.
    func setQValues(
        _ qValues: [FrankensteinAction: Float]
    ) {
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

    /// Returns the currently stored values, keyed by action.
    func networkQValues() -> [FrankensteinAction: Float] {
        var values: [FrankensteinAction: Float] = [:]

        for action in supportedActions {
            values[action] = qValue(for: action)
        }

        return values
    }

    /// Actions with assigned network cells.
    private var supportedActions: [FrankensteinAction] {
        [
            .walk, .run, .turnLeft, .turnRight,
            .jump, .crouch, .recover, .stepUp,
            .stepDown, .crawl, .roll,
            .backward, .stepForward, .liftObject,
            .placeObject, .throwObject
        ]
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
        qValue(for: action) + networkActivitySignal(for: action)
    }

    // MARK: - Executive action decision

    /// Selects the highest-scoring action from the permitted candidates.
    ///
    /// `qValues` should contain the latest learned values.
    /// `allowedActions` must already reflect runtime constraints.
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

        // The CA owns exploration; the Q-policy only supplies values.
        if exploration > 0,
           Float.random(in: 0..<1) < exploration,
           let random = allowedActions.randomElement() {
            setQValues(qValues)
            lastDecisionDescription = "Action=\(random) | exploring"
            return random
        }

        // Load the supplied Q-values into their CA network cells.
        setQValues(qValues)

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
        let position = actionNeuronPosition(for: selected)

        let cellDescription: String
        if let position {
            cellDescription = "cell=(\(position.x),\(position.y))"
        } else {
            cellDescription = "cell=unmapped"
        }

        lastDecisionDescription =
            "Action=\(selected) | Q-cell=\(selectedQ) | " +
            "CA-signal=\(selectedActivity) | score=\(bestScore) | " +
            "\(cellDescription) | terrain=\(terrain.terrain) | " +
            "fallen=\(body.fallen)"

        print("[CA] Executive selected: \(selected)")
        print("[CA] Q-value from network cell: \(selectedQ)")
        print("[CA] CA activity signal: \(selectedActivity)")
        print("[CA] Combined score: \(bestScore)")
        print("[CA] Network cell: \(cellDescription)")
        print("[CA] Permitted actions: \(allowedActions)")
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
