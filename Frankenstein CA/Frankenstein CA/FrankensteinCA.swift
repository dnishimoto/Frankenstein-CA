
import Foundation
import Combine

// MARK: - Perception handed to the CA by the Coordinator

/// Everything the CA needs to choose an action. The Coordinator builds this
/// every frame; the CA scores each permitted action against it.
///
/// Heading convention: `.turnRight` ADDS to `output.heading` and `.turnLeft`
/// SUBTRACTS (see FrankensteinLocomotion.updateAnimation), so
/// "plus" means "reached by .turnRight" and "minus" means "reached by .turnLeft".
struct FrankensteinCAPerception {
    /// Routed heading minus current heading, wrapped to [-pi, pi].
    /// Positive: .turnRight reduces the error. Negative: .turnLeft does.
    var headingError: Float = 0
    /// Obstacle-aware path distance to the goal (m); .infinity if unknown.
    var pathDistance: Float = .infinity
    var isDetouring = false
    /// Smoothed speed toward the goal along the routed path (m/s).
    var goalProgressRate: Float = 0
    /// True once the character is on or beside the goal; steering is muted.
    var atGoal = false

    /// Free distance (m) in each sector of a horizontal ray fan.
    var clearanceAhead: Float = 4
    var clearancePlus: Float = 4
    var clearanceMinus: Float = 4

    var nearestObjectClass = "none"
    var nearestObjectDistance: Float = .infinity

    /// Learned object/goal Q-values (from FrankensteinCALearner), per action.
    var advisoryValues: [FrankensteinAction: Float] = [:]

    /// Coarse discretisation of this perception, used for visit counts.
    var stateKey = "none"

    var timestamp: TimeInterval = 0
}

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
    private let qTieBreakWeight: Float = 0.04

    // MARK: - Perception-driven control

    private var perception: FrankensteinCAPerception?
    private var perceptionMaxAge: TimeInterval = 0.6
    private var lastTimestamp: TimeInterval = 0

    // Visit counts (perception state -> action id -> n) drive a directed
    // exploration bonus: rarely tried actions in a state get a boost.
    private var visitCounts: [String: [Int: Int]] = [:]
    private(set) var totalDecisions = 0

    private let steeringGain: Float = 1.2
    private let alignedHeadingTolerance: Float = 0.2
    private let steeringDeadband: Float = 0.12

    /// Directed exploration strength; decays as experience accumulates.
    private var noveltyScale: Float {
        max(0.08, 0.5 * powf(0.9997, Float(totalDecisions)))
    }

    /// Random-action probability; small and decaying.
    private var randomExploration: Float {
        max(0.01, 0.06 * powf(0.9995, Float(totalDecisions)))
    }

    /// Per-term breakdown of the most recent decision, for diagnostics.
    private(set) var lastScoreBreakdown: [FrankensteinAction: String] = [:]

    /// Latest perception pushed by the Coordinator. Call every frame.
    func receivePerception(_ newPerception: FrankensteinCAPerception) {
        perception = newPerception
        lastTimestamp = max(lastTimestamp, newPerception.timestamp)
        decayFutility(to: newPerception.timestamp)
    }

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
        perception = nil
        lastFutilityDecayTime = 0
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
        // The Coordinator calls this every frame, so it doubles as the CA's clock.
        lastTimestamp = max(lastTimestamp, timestamp)
        decayFutility(to: timestamp)

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

    private var lastFutilityDecayTime: TimeInterval = 0
    private let futilityHalfLife: TimeInterval = 15

    /// Penalties fade with a 15 s half-life so an action that failed once
    /// in one place is not avoided forever.
    private func decayFutility(to timestamp: TimeInterval) {
        defer { lastFutilityDecayTime = timestamp }

        guard lastFutilityDecayTime > 0,
              timestamp > lastFutilityDecayTime,
              !futilityPenalties.isEmpty else {
            return
        }

        let elapsed = Float(timestamp - lastFutilityDecayTime)
        let factor = powf(0.5, elapsed / Float(futilityHalfLife))

        for (action, penalty) in futilityPenalties {
            let decayed = penalty * factor

            if decayed < 0.05 {
                futilityPenalties[action] = nil
            } else {
                futilityPenalties[action] = decayed
            }
        }
    }

    /// Called when the character is measurably making progress, so the
    /// executed action stops carrying loop penalties.
    func forgiveFutility(for action: FrankensteinAction, amount: Float = 0.5) {
        guard let penalty = futilityPenalties[action] else { return }

        let reduced = penalty - amount

        futilityPenalties[action] = reduced > 0.05 ? reduced : nil
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

    /// Fresh perception, or nil if none has arrived recently.
    private func currentPerception() -> FrankensteinCAPerception? {
        guard let perception else { return nil }

        // Compare against the newest timestamp seen, so a stale context
        // (Coordinator paused or detached) stops steering the CA.
        guard lastTimestamp - perception.timestamp <= perceptionMaxAge else {
            return nil
        }

        return perception
    }

    private func isForwardAction(_ action: FrankensteinAction) -> Bool {
        switch action {
        case .walk, .run, .stepForward, .stepUp, .jump:
            return true
        default:
            return false
        }
    }

    /// Turning toward the routed heading, moving forward only when aligned.
    private func steeringScore(
        for action: FrankensteinAction,
        perception p: FrankensteinCAPerception
    ) -> Float {
        guard !p.atGoal else { return 0 }

        let error = p.headingError
        let magnitude = min(1, abs(error) / 0.8)

        switch action {
        case .turnRight:
            if error > steeringDeadband { return steeringGain * magnitude }
            if error < -steeringDeadband { return -steeringGain * magnitude * 0.8 }
            return -0.2

        case .turnLeft:
            if error < -steeringDeadband { return steeringGain * magnitude }
            if error > steeringDeadband { return -steeringGain * magnitude * 0.8 }
            return -0.2

        case .walk, .stepForward, .stepUp, .jump:
            if abs(error) < alignedHeadingTolerance { return 0.35 }
            return -0.6 * magnitude

        case .run:
            if abs(error) < alignedHeadingTolerance { return 0.15 }
            return -0.8 * magnitude

        case .backward:
            // Only reasonable when the goal is almost directly behind.
            return abs(error) > 2.6 ? 0.1 : -0.3

        default:
            return 0
        }
    }

    /// Free-space reasoning from the ray fan: avoid driving into things,
    /// turn toward the side with more room, run only in open space.
    private func clearanceScore(
        for action: FrankensteinAction,
        perception p: FrankensteinCAPerception
    ) -> Float {
        let ahead = p.clearanceAhead

        switch action {
        case .walk, .stepForward:
            return ahead < 0.9 ? -(0.9 - ahead) * 2.0 : 0

        case .run:
            if ahead < 2.0 { return -(2.0 - ahead) * 1.5 }
            return 0.2

        case .turnRight:
            if ahead < 1.5 {
                if p.clearancePlus > p.clearanceMinus + 0.5 { return 0.5 }
                if p.clearanceMinus > p.clearancePlus + 0.5 { return -0.3 }
            }
            return 0

        case .turnLeft:
            if ahead < 1.5 {
                if p.clearanceMinus > p.clearancePlus + 0.5 { return 0.5 }
                if p.clearancePlus > p.clearanceMinus + 0.5 { return -0.3 }
            }
            return 0

        default:
            return 0
        }
    }

    private func explorationBonus(
        for action: FrankensteinAction,
        stateKey: String
    ) -> Float {
        let count = visitCounts[stateKey]?[action.rawValue] ?? 0

        return noveltyScale / sqrtf(1 + Float(count))
    }

    private func recordVisit(
        action: FrankensteinAction,
        stateKey: String
    ) {
        visitCounts[stateKey, default: [:]][action.rawValue, default: 0] += 1
        totalDecisions += 1
    }

    private struct ScoreParts {
        var q: Float = 0
        var advisory: Float = 0
        var steering: Float = 0
        var clearance: Float = 0
        var novelty: Float = 0
        var activity: Float = 0
        var futility: Float = 0

        var total: Float {
            q + advisory + steering + clearance + novelty + activity - futility
        }
    }

    private func scoreParts(
        for action: FrankensteinAction,
        perception p: FrankensteinCAPerception?
    ) -> ScoreParts {
        var parts = ScoreParts()

        parts.q = qValue(for: action)
        parts.activity = networkActivitySignal(for: action)
        parts.futility = futilityPenalties[action, default: 0]

        if let p {
            parts.advisory = p.advisoryValues[action, default: 0]
            parts.steering = steeringScore(for: action, perception: p)
            parts.clearance = clearanceScore(for: action, perception: p)
            parts.novelty = explorationBonus(for: action, stateKey: p.stateKey)
        }

        return parts
    }

    // MARK: - Executive action decision

    /// Chooses the action. The CA owns the decision: it sums
    ///   learned policy Q  +  learned object/goal advice  +  routed-path
    ///   steering  +  free-space clearance  +  directed-exploration bonus
    ///   +  cellular activity  -  futility penalty
    /// over the permitted actions. Environmental safety stays in the
    /// permitted-action filter and in FrankensteinLocomotion.
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

        let p = currentPerception()
        let stateKey = p?.stateKey ?? "none"

        // Occasional random action among permitted ones. Recovery is never
        // a random choice.
        let epsilon = max(exploration, randomExploration)

        if Float.random(in: 0..<1) < epsilon,
           let random = allowedActions
            .filter({ $0 != .recover })
            .randomElement() {
            recordVisit(action: random, stateKey: stateKey)

            lastDecisionDescription =
                "Action=\(random) | exploring (eps=\(epsilon)) | futility-aware"

            return random
        }

        var selected = allowedActions[0]
        var bestParts = scoreParts(for: selected, perception: p)
        var breakdown: [FrankensteinAction: String] = [:]

        func describe(_ parts: ScoreParts) -> String {
            let head = "Q=\(parts.q) adv=\(parts.advisory) steer=\(parts.steering)"
            let mid = "clear=\(parts.clearance) nov=\(parts.novelty) act=\(parts.activity)"
            let tail = "fut=-\(parts.futility) => \(parts.total)"

            return "\(head) \(mid) \(tail)"
        }

        breakdown[selected] = describe(bestParts)

        for action in allowedActions.dropFirst() {
            let parts = scoreParts(for: action, perception: p)

            breakdown[action] = describe(parts)

            if parts.total > bestParts.total {
                selected = action
                bestParts = parts
            }
        }

        lastScoreBreakdown = breakdown
        recordVisit(action: selected, stateKey: stateKey)

        let cellDescription: String

        if let position = actionNeuronPosition(for: selected) {
            cellDescription = "cell=(\(position.x),\(position.y))"
        } else {
            cellDescription = "cell=unmapped"
        }

        let perceptionStatus = p == nil ? "stale" : "live"
        let terms = describe(bestParts)

        lastDecisionDescription =
            "Action=\(selected) | \(terms) | \(cellDescription) | " +
            "terrain=\(terrain.terrain) | fallen=\(body.fallen) | " +
            "perception=\(perceptionStatus)"

        print("[CA] Executive selected: \(selected)")
        print("[CA] Score terms: \(describe(bestParts))")
        print("[CA] Permitted actions: \(allowedActions)")
        print("[CA] Perception state: \(stateKey)")
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
