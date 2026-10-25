
import Foundation



final class FrankensteinCA {
    let rows = 18
    let columns = 18

    private var cells: [[Bool]]
    private var generation = 0
    private var time: Float = 0

    private(set) var motion = FrankensteinMotion()

    // Reinforcement learning parameters.
    private var memories: [String: FrankensteinLearningMemory] = [:]
    private var lastStateKey: String?
    private var lastAction: FrankensteinLearningAction?
    private var explorationRate: Float = 0.25
    private let learningRate: Float = 0.25
    private let discountFactor: Float = 0.80

    private var objectVisits: [String: Int] = [:]

    private(set) var currentAction: FrankensteinLearningAction = .explore
    private(set) var lastReward: Float = 0
    private(set) var learnedExperienceCount = 0

    init() {
        cells = Array(
            repeating: Array(repeating: false, count: 18),
            count: 18
        )
        seedPattern()
    }

    // MARK: Cellular automaton

    private func seedPattern() {
        let pattern: [(Int, Int)] = [
            (1, 0), (2, 1), (0, 2), (1, 2), (2, 2)
        ]

        for (x, y) in pattern {
            cells[y + 2][x + 2] = true
        }

        for x in 0..<3 {
            cells[6][7 + x] = true
            cells[10][11 + x] = true
        }

        for y in 0..<rows {
            for x in 0..<columns {
                let value = (x * 17 + y * 31 + x * y * 3) % 23

                if value == 0 || value == 7 {
                    cells[y][x] = true
                }
            }
        }
    }

    func step(deltaTime: Float) -> FrankensteinMotion {
        let dt = min(max(deltaTime, 0), 0.05)
        time += dt

        updateCells()

        let alive = liveCellCount
        let activity = Float(alive) / Float(rows * columns)
        let intensity = min(max(activity * 3.0, 0.15), 1.0)

        motion.walkPhase += dt * (1.4 + intensity * 2.2)
        motion.armLift = sin(time * 1.2) * 0.20 + intensity * 0.18
        motion.headTurn = sin(time * 0.75) * 0.28

        let speechPulse = max(0, sin(time * 4.0))
        motion.mouthOpen = speechPulse * 0.35 * intensity

        return motion
    }

    private func updateCells() {
        var next = cells

        for y in 0..<rows {
            for x in 0..<columns {
                var neighbors = 0

                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 {
                            continue
                        }

                        let nx = x + dx
                        let ny = y + dy

                        if nx >= 0 && nx < columns &&
                            ny >= 0 && ny < rows &&
                            cells[ny][nx] {
                            neighbors += 1
                        }
                    }
                }

                if cells[y][x] {
                    next[y][x] = neighbors == 2 || neighbors == 3
                } else {
                    next[y][x] = neighbors == 3
                }
            }
        }

        cells = next
        generation += 1

        if generation % 80 == 0 {
            let x = (generation * 7) % columns
            let y = (generation * 11) % rows
            cells[y][x] = true
        }
    }

    // MARK: Action selection

    func chooseAction(
        for observation: FrankensteinObservation
    ) -> FrankensteinLearningAction {
        let state = observation.stateKey
        var memory = memories[state] ?? FrankensteinLearningMemory()

        // Track how often Frankenstein encounters each object.
        if observation.objectNearby && !observation.objectID.isEmpty {
            objectVisits[observation.objectID, default: 0] += 1
        }

        let legalActions = availableActions(for: observation)

        guard !legalActions.isEmpty else {
            currentAction = .stop
            return .stop
        }

        // Explore occasionally; otherwise choose the best learned action.
        if Float.random(in: 0...1) < explorationRate {
            currentAction = legalActions.randomElement() ?? .stop
        } else {
            currentAction = legalActions.max {
                memory.value(for: $0) < memory.value(for: $1)
            } ?? .stop
        }

        lastStateKey = state
        lastAction = currentAction

        memory.attempts[currentAction, default: 0] += 1
        memories[state] = memory

        return currentAction
    }

    private func availableActions(
        for observation: FrankensteinObservation
    ) -> [FrankensteinLearningAction] {
        // Never intentionally move forward without supporting ground.
        guard observation.groundSupported else {
            if observation.dropAhead {
                return [.stop, .jumpDown, .explore]
            }
            return [.stop]
        }

        // An opening or door can be interacted with only when detected.
        if observation.objectNearby && observation.objectCanOpen {
            return [.stop, .open, .explore]
        }

        // Low ceilings favor crouched movement or rolling.
        if observation.lowCeiling {
            return [.roll, .walk, .stop]
        }

        // A gap requires a specific jump decision or stopping.
        if observation.gapAhead {
            return [.stop, .jump]
        }

        if observation.dropAhead {
            return [.stop, .jumpDown, .explore]
        }

        if observation.stepAhead {
            return [.stop, .stepUp, .jump]
        }

        if observation.obstacleAhead || !observation.pathClear {
            return [.stop, .jump, .roll, .explore]
        }

        if observation.objectNearby {
            return [.explore, .walk, .stop]
        }

        return [.walk, .run, .explore, .stop]
    }

    // MARK: Learning from outcomes

    /// Call after an action has actually completed.
    /// Positive reward means success; negative reward means failure.
    func recordOutcome(
        reward: Float,
        nextObservation: FrankensteinObservation,
        succeeded: Bool
    ) {
        guard let state = lastStateKey,
              let action = lastAction else {
            return
        }

        var memory = memories[state] ?? FrankensteinLearningMemory()
        let oldValue = memory.value(for: action)

        let nextActions = availableActions(for: nextObservation)
        let nextMemory = memories[nextObservation.stateKey]

        let bestFutureValue: Float

        if nextActions.isEmpty {
            bestFutureValue = 0
        } else {
            bestFutureValue = nextActions
                .map { nextMemory?.value(for: $0) ?? 0 }
                .max() ?? 0
        }

        let target = reward + discountFactor * bestFutureValue
        let updatedValue = oldValue + learningRate * (target - oldValue)

        memory.actionValues[action] = updatedValue

        if succeeded {
            memory.successes[action, default: 0] += 1
        }

        memories[state] = memory

        lastReward = reward
        learnedExperienceCount += 1

        // Reduce random exploration gradually, but never eliminate it.
        explorationRate = max(0.05, explorationRate * 0.999)

        lastStateKey = nil
        lastAction = nil
    }

    /// Convenience method for a successful action.
    func recordSuccess(
        nextObservation: FrankensteinObservation
    ) {
        recordOutcome(
            reward: 1.0,
            nextObservation: nextObservation,
            succeeded: true
        )
    }

    /// Convenience method for a failed or unsafe action.
    func recordFailure(
        nextObservation: FrankensteinObservation
    ) {
        recordOutcome(
            reward: -1.0,
            nextObservation: nextObservation,
            succeeded: false
        )
    }

    // MARK: Learning statistics

    func learnedValue(
        for action: FrankensteinLearningAction,
        in observation: FrankensteinObservation
    ) -> Float {
        memories[observation.stateKey]?.value(for: action) ?? 0
    }

    func attemptCount(
        for action: FrankensteinLearningAction,
        in observation: FrankensteinObservation
    ) -> Int {
        memories[observation.stateKey]?.attempts[action, default: 0] ?? 0
    }

    func successCount(
        for action: FrankensteinLearningAction,
        in observation: FrankensteinObservation
    ) -> Int {
        memories[observation.stateKey]?.successes[action, default: 0] ?? 0
    }

    func visits(to objectID: String) -> Int {
        objectVisits[objectID, default: 0]
    }

    // MARK: Reset

    func reset() {
        generation = 0
        time = 0
        motion = FrankensteinMotion()

        cells = Array(
            repeating: Array(repeating: false, count: columns),
            count: rows
        )
        seedPattern()

        memories.removeAll()
        objectVisits.removeAll()

        lastStateKey = nil
        lastAction = nil
        currentAction = .explore
        lastReward = 0
        learnedExperienceCount = 0
        explorationRate = 0.25
    }

    var liveCellCount: Int {
        cells.reduce(0) { total, row in
            total + row.filter { $0 }.count
        }
    }

    var generationCount: Int {
        generation
    }
}
