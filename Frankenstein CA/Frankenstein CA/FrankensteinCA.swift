
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
    var nearestObjectPickupable = false

    /// Heading of each successive 0.5 m cell along the routed path, relative
    /// to the current heading (positive: reached by .turnRight). The CA
    /// plans a short sequence of actions against this preview.
    var routeRelativeHeadings: [Float] = []

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

    // MARK: - Goal-directed learning
    //
    // The CA learns what each action actually does for the goal: a running
    // average of measured goal progress (metres/second along the routed path,
    // plus heading-alignment gain) per perception state and action. Actions
    // that moved the character toward the goal are sought; actions that did
    // nothing are dropped, and a stuck character is pushed to try something else.

    private struct EffectStat {
        var mean: Float = 0
        var count: Int = 0
    }

    private var effectModel: [String: [Int: EffectStat]] = [:]
    private var decisionStateKey = "none"
    private var decisionHeadingError: Float = 0
    private var decisionAction: FrankensteinAction?

    /// Seconds of (almost) no goal progress; decays quickly once progressing.
    @Published private(set) var stuckSeconds: Float = 0
    @Published private(set) var goalSeekingStatus = "No goal outcome yet"
    private(set) var outcomesObserved = 0

    private let goalProgressGain: Float = 1.6
    private let stuckThreshold: Float = 1.5

    /// Report what the last executed action achieved. Call once per
    /// outcome window (about 4 Hz) from the Coordinator.
    ///
    /// - goalProgressRate: reduction of routed goal distance, m/s.
    /// - blocked: the body did not move although it tried to.
    func reportActionOutcome(
        action: FrankensteinAction,
        goalProgressRate: Float,
        windowDuration: Float,
        blocked: Bool
    ) {
        guard windowDuration > 0.01,
              goalProgressRate.isFinite else {
            return
        }

        // Turning toward the route has value even though it moves nowhere.
        let currentError = perception?.headingError ?? decisionHeadingError
        let alignmentGain = (abs(decisionHeadingError) - abs(currentError)) / windowDuration

        var measured = goalProgressRate + 0.8 * alignmentGain
        if blocked { measured -= 0.3 }
        measured = max(-3, min(3, measured))

        var stat = effectModel[decisionStateKey]?[action.rawValue] ?? EffectStat()
        let alpha = max(0.12, 1 / Float(stat.count + 1))
        stat.mean += alpha * (measured - stat.mean)
        stat.count += 1
        effectModel[decisionStateKey, default: [:]][action.rawValue] = stat

        outcomesObserved += 1

        if measured < 0.05 {
            stuckSeconds += windowDuration
        } else {
            stuckSeconds = max(0, stuckSeconds - 2 * windowDuration)
        }

        decisionHeadingError = currentError

        goalSeekingStatus =
            "last \(action): progress \(String(format: "%.2f", measured)) m/s | " +
            "stuck \(String(format: "%.1f", stuckSeconds)) s | outcomes \(outcomesObserved)"
    }

    /// Learned worth of an action in the current perception state.
    private func learnedGoalValue(
        for action: FrankensteinAction,
        stateKey: String
    ) -> Float {
        guard let stat = effectModel[stateKey]?[action.rawValue],
              stat.count >= 2 else {
            return 0
        }

        return goalProgressGain * tanhf(stat.mean / 0.6)
    }

    /// Model-based part: how much goal progress this action should give
    /// right now, from speeds, heading error, clearance and goal proximity.
    private func predictedGoalScore(
        for action: FrankensteinAction,
        perception p: FrankensteinCAPerception
    ) -> Float {
        var score: Float = 0

        let alignment = max(0, cosf(p.headingError))
        let nearGoal = p.pathDistance.isFinite && p.pathDistance < 1.2

        // Expected forward progress per second.
        switch action {
        case .walk:
            score += 0.25 * 1.0 * alignment
        case .run:
            score += 0.25 * 2.2 * alignment
            if nearGoal { score -= 0.8 }              // do not overshoot
            if p.clearanceAhead < 2.0 { score -= 0.4 }
        case .stepForward:
            score += 0.25 * 0.5 * alignment
        default:
            break
        }

        // On the goal: hold still so contact is maintained.
        if p.atGoal {
            switch action {
            case .walk, .run, .stepForward, .jump, .backward, .roll:
                score -= 1.0
            case .turnLeft, .turnRight:
                score += 0.3
            default:
                break
            }
        }

        // Stuck: abandon the repeated action and try alternatives that
        // can clear the obstruction.
        if stuckSeconds > stuckThreshold, !p.atGoal {
            let pressure = min(2, 0.5 * stuckSeconds)

            if action == decisionAction {
                score -= pressure
            }

            switch action {
            case .jump, .stepUp:
                score += 0.4
            case .liftObject:
                score += p.nearestObjectPickupable ? 1.2 : 0
            case .turnLeft:
                if p.clearanceMinus > p.clearancePlus { score += 0.6 }
            case .turnRight:
                if p.clearancePlus > p.clearanceMinus { score += 0.6 }
            case .backward:
                score += 0.3
            default:
                break
            }
        }

        // Goal unknown or unreachable: scan by turning rather than walking blind.
        if !p.pathDistance.isFinite {
            switch action {
            case .turnLeft, .turnRight: score += 0.2
            case .run: score -= 0.4
            default: break
            }
        }

        return score
    }

    // MARK: - Sequence planning
    //
    // The perception layer previews the routed path as a list of headings.
    // The CA rolls a small kinematic model forward over the next few actions
    // (turn, walk, run, ...) and credits each first action with the best
    // route progress reachable by some sequence that starts with it. A turn
    // that sets up a long run therefore beats a walk that will have to turn
    // anyway.

    private let planHorizon = 3
    private let planActionSeconds: Float = 0.35
    private let planTurnPerAction: Float = 0.9 * 0.35   // 0.9 rad/s turn rate
    private let planCellLength: Float = 0.5
    private let planGain: Float = 1.5

    /// Best action sequence found by the last plan, for diagnostics.
    private(set) var plannedSequence: [FrankensteinAction] = []

    private struct Rollout {
        var heading: Float = 0      // relative to the current heading
        var progress: Float = 0     // metres advanced along the route
        var used: Float = 0         // clearance consumed in the current sector
        var wasted: Int = 0         // steps that could not advance
    }

    private func wrapped(_ angle: Float) -> Float {
        var value = angle

        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }

        return value
    }

    /// Forward speed used by the plan model (m/s); nil for non-moving actions.
    private func planSpeed(_ action: FrankensteinAction) -> (speed: Float, blockable: Bool)? {
        switch action {
        case .walk:        return (1.0, true)
        case .run:         return (2.2, true)
        case .stepForward: return (0.5, true)
        case .backward:    return (-0.5, true)
        case .crouch:      return (0.45, true)
        case .crawl:       return (0.35, true)
        case .roll:        return (1.1, true)
        case .jump:        return (1.2, false)
        case .stepUp:      return (0.6, false)
        default:           return nil
        }
    }

    private func routeHeading(
        atProgress progress: Float,
        perception p: FrankensteinCAPerception
    ) -> Float {
        let route = p.routeRelativeHeadings

        guard !route.isEmpty else { return p.headingError }

        let cell = max(0, Int(progress / planCellLength))

        return route[min(cell, route.count - 1)]
    }

    private func clearance(
        forHeading heading: Float,
        perception p: FrankensteinCAPerception
    ) -> Float {
        if heading > 0.5 { return p.clearancePlus }
        if heading < -0.5 { return p.clearanceMinus }

        return p.clearanceAhead
    }

    private func planStep(
        _ action: FrankensteinAction,
        from state: Rollout,
        perception p: FrankensteinCAPerception
    ) -> Rollout {
        var next = state

        switch action {
        case .turnRight:
            next.heading += planTurnPerAction
            next.used = 0
            return next

        case .turnLeft:
            next.heading -= planTurnPerAction
            next.used = 0
            return next

        default:
            break
        }

        guard let motion = planSpeed(action) else {
            // Lift / place / throw / recover: time passes, nothing advances.
            next.wasted += 1
            return next
        }

        let routeNow = routeHeading(atProgress: state.progress, perception: p)
        let error = wrapped(routeNow - state.heading)

        var advance = motion.speed * planActionSeconds * cosf(error)

        if motion.blockable, advance > 0 {
            let room = max(
                0,
                clearance(forHeading: state.heading, perception: p) - 0.3 - state.used
            )

            if advance > room {
                advance = room
            }

            next.used += advance
        }

        if advance <= 0.01 && motion.speed > 0 {
            next.wasted += 1
        }

        next.progress = state.progress + advance

        // Cannot usefully advance past the goal.
        if p.pathDistance.isFinite {
            next.progress = min(next.progress, p.pathDistance)
        }

        return next
    }

    private func terminalPlanValue(
        _ state: Rollout,
        perception p: FrankensteinCAPerception
    ) -> Float {
        let routeNow = routeHeading(atProgress: state.progress, perception: p)
        let alignment = cosf(wrapped(routeNow - state.heading))

        return state.progress + 0.4 * alignment - 0.5 * Float(state.wasted)
    }

    private func bestContinuation(
        from state: Rollout,
        depth: Int,
        perception p: FrankensteinCAPerception
    ) -> (value: Float, sequence: [FrankensteinAction]) {
        guard depth > 0 else {
            return (terminalPlanValue(state, perception: p), [])
        }

        var best: (value: Float, sequence: [FrankensteinAction]) = (-.infinity, [])

        for action in [FrankensteinAction.walk, .run, .turnLeft, .turnRight] {
            let result = bestContinuation(
                from: planStep(action, from: state, perception: p),
                depth: depth - 1,
                perception: p
            )

            if result.value > best.value {
                best = (result.value, [action] + result.sequence)
            }
        }

        return best
    }

    /// Plan value of starting with each permitted action.
    private func planValues(
        for actions: [FrankensteinAction],
        perception p: FrankensteinCAPerception
    ) -> [FrankensteinAction: Float] {
        guard !p.atGoal,
              !p.routeRelativeHeadings.isEmpty else {
            plannedSequence = []
            return [:]
        }

        var values: [FrankensteinAction: Float] = [:]
        var bestValue: Float = -.infinity
        var bestSequence: [FrankensteinAction] = []

        for action in actions {
            let first = planStep(action, from: Rollout(), perception: p)

            let rest = bestContinuation(
                from: first,
                depth: planHorizon - 1,
                perception: p
            )

            values[action] = rest.value

            if rest.value > bestValue {
                bestValue = rest.value
                bestSequence = [action] + rest.sequence
            }
        }

        plannedSequence = bestSequence

        // Relative to the best option so the term ranks actions without
        // shifting every score.
        for (action, value) in values {
            values[action] = planGain * (value - bestValue)
        }

        return values
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
        effectModel.removeAll()
        decisionAction = nil
        decisionStateKey = "none"
        decisionHeadingError = 0
        stuckSeconds = 0
        plannedSequence = []
        outcomesObserved = 0
        goalSeekingStatus = "No goal outcome yet"
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

    /// The outcome of the next window is credited to this decision. A
    /// repeated decision keeps its original heading error so a multi-frame
    /// turn is measured over the whole window.
    private func rememberDecision(
        _ action: FrankensteinAction,
        stateKey: String,
        perception p: FrankensteinCAPerception?
    ) {
        if action != decisionAction || stateKey != decisionStateKey {
            decisionHeadingError = p?.headingError ?? 0
        }

        decisionAction = action
        decisionStateKey = stateKey
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
        var terrain: Float = 0
        var goal: Float = 0
        var plan: Float = 0
        var activity: Float = 0
        var futility: Float = 0

        var total: Float {
            q + advisory + steering + clearance + terrain + goal + plan + novelty + activity - futility
        }
    }

    /// Terrain priors so the CA picks competent maneuvers before Q-values
    /// have been learned. Only used with live perception.
    private func terrainScore(
        for action: FrankensteinAction,
        terrain t: FrankensteinTerrainSample
    ) -> Float {
        let near = t.distance.isFinite && t.distance < 1.0

        switch t.terrain {
        case .hurdle, .raisedStep:
            guard near else { return 0 }

            let low = t.obstacleHeight > 0 && t.obstacleHeight <= 0.55

            switch action {
            case .stepUp: return low ? 0.7 : -0.5
            case .jump:   return t.isLandingAreaClear ? 0.45 : -0.5
            case .walk, .run: return -0.5
            default: return 0
            }

        case .gap:
            switch action {
            case .jump:
                return (t.gapWidth > 0 && t.gapWidth <= 1.8 && t.isLandingAreaClear)
                    ? 0.6 : -1.0
            case .walk, .run, .stepForward: return -1.0
            default: return 0
            }

        case .lowCeiling:
            switch action {
            case .crouch: return 0.35
            case .crawl:  return 0.25
            default: return 0
            }

        default:
            return 0
        }
    }

    private func scoreParts(
        for action: FrankensteinAction,
        perception p: FrankensteinCAPerception?,
        terrain: FrankensteinTerrainSample,
        plan: [FrankensteinAction: Float] = [:]
    ) -> ScoreParts {
        var parts = ScoreParts()

        parts.q = qValue(for: action)
        parts.activity = networkActivitySignal(for: action)
        parts.futility = futilityPenalties[action, default: 0]

        if let p {
            parts.advisory = p.advisoryValues[action, default: 0]
            parts.steering = steeringScore(for: action, perception: p)
            parts.clearance = clearanceScore(for: action, perception: p)
            parts.terrain = terrainScore(for: action, terrain: terrain)
            parts.plan = plan[action, default: 0]
            parts.goal =
                learnedGoalValue(for: action, stateKey: p.stateKey) +
                predictedGoalScore(for: action, perception: p)
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
            rememberDecision(random, stateKey: stateKey, perception: p)

            lastDecisionDescription =
                "Action=\(random) | exploring (eps=\(epsilon)) | futility-aware"

            return random
        }

        let plan: [FrankensteinAction: Float] = p.map {
            planValues(for: allowedActions, perception: $0)
        } ?? [:]

        var selected = allowedActions[0]
        var bestParts = scoreParts(
            for: selected,
            perception: p,
            terrain: terrain,
            plan: plan
        )
        var breakdown: [FrankensteinAction: String] = [:]

        func describe(_ parts: ScoreParts) -> String {
            let head = "Q=\(parts.q) adv=\(parts.advisory) steer=\(parts.steering)"
            let mid = "clear=\(parts.clearance) terr=\(parts.terrain) goal=\(parts.goal) plan=\(parts.plan) nov=\(parts.novelty) act=\(parts.activity)"
            let tail = "fut=-\(parts.futility) => \(parts.total)"

            return "\(head) \(mid) \(tail)"
        }

        breakdown[selected] = describe(bestParts)

        for action in allowedActions.dropFirst() {
            let parts = scoreParts(
                for: action,
                perception: p,
                terrain: terrain,
                plan: plan
            )

            breakdown[action] = describe(parts)

            if parts.total > bestParts.total {
                selected = action
                bestParts = parts
            }
        }

        lastScoreBreakdown = breakdown
        recordVisit(action: selected, stateKey: stateKey)
        rememberDecision(selected, stateKey: stateKey, perception: p)

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
        print("[CA] Planned sequence: \(plannedSequence)")
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
