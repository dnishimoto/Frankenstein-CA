import Foundation
import Combine
import SceneKit
import UIKit

final class FrankensteinCA: ObservableObject {

    let size = 18
    // MARK: - Dirty Q-Values Field of Vision Tracking
    @Published private(set) var dirtyQCells: [[Bool]]

    private var grid: [[Bool]] {
            get { cells }
            set { cells = newValue }
        }
    
    @Published private(set) var generation: Int = 0
    @Published private(set) var isRunning = false
    @Published private(set) var liveCellCount: Int = 0
    @Published private(set) var lastDecisionDescription = "Waiting for perception"

    @Published var networkQGrid: [[Float]]
    @Published var planBuffer = FrankensteinPlanBuffer()

    // MARK: - Tapestry Blueprint Coordinates & Movable Blocks Setup
    private var currentTapestrySlotIndex = 0
    private weak var cachedRootNode: SCNNode?

    private var cells: [[Bool]]
    private var nextGrid: [[Bool]]
    private let qTieBreakWeight: Float = 0.04

    private var perception: FrankensteinCAPerception?
    private var perceptionMaxAge: TimeInterval = 0.6
    private var lastTimestamp: TimeInterval = 0

    private var visitCounts: [String: [Int: Int]] = [:]
    private(set) var totalDecisions = 0

    private let steeringGain: Float = 1.2
    private let alignedHeadingTolerance: Float = 0.2
    private let steeringDeadband: Float = 0.12

    private var noveltyScale: Float {
        max(0.08, 0.5 * powf(0.9997, Float(totalDecisions)))
    }

    private var randomExploration: Float {
        max(0.01, 0.06 * powf(0.9995, Float(totalDecisions)))
    }

    private(set) var lastScoreBreakdown: [FrankensteinAction: String] = [:]

    func receivePerception(_ newPerception: FrankensteinCAPerception) {
        perception = newPerception
        lastTimestamp = max(lastTimestamp, newPerception.timestamp)
        decayFutility(to: newPerception.timestamp)
        
        // Mark Q-values dirty within Frankenstein's field of vision based on perception
        markVisionQValuesDirty(perception: newPerception)
    }

    private struct EffectStat {
        var mean: Float = 0
        var count: Int = 0
    }

    private var effectModel: [String: [Int: EffectStat]] = [:]
    private var decisionStateKey = "none"
    private var decisionHeadingError: Float = 0
    private var decisionAction: FrankensteinAction?
    private var consecutiveJumpCount: Int = 0 // Tracks repetitive hopping

    @Published private(set) var stuckSeconds: Float = 0
    @Published private(set) var goalSeekingStatus = "No goal outcome yet"
    private(set) var outcomesObserved = 0

    private let goalProgressGain: Float = 1.6
    private let stuckThreshold: Float = 1.5

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

        let currentError = perception?.headingError ?? decisionHeadingError
        let alignmentGain = (abs(decisionHeadingError) - abs(currentError)) / windowDuration

        var measured = goalProgressRate + 0.8 * alignmentGain
        if blocked {
            measured -= 0.3
            planBuffer.markCurrentStepFailed()
        }
        
        // Anti-hop penalty: if jumping produced no forward progress, penalize heavily
        if action == .jump && measured < 0.05 {
            measured -= 1.0
            consecutiveJumpCount += 1
        } else if action == .jump {
            consecutiveJumpCount += 1
        } else {
            consecutiveJumpCount = 0
        }

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
            stuckSeconds = max(0, stuckSeconds - 2.0 * windowDuration)
        }

        decisionHeadingError = currentError

        goalSeekingStatus =
            "last \(action): progress \(String(format: "%.2f", measured)) m/s | " +
            "stuck \(String(format: "%.1f", stuckSeconds)) s | outcomes \(outcomesObserved)"
    }
    /// Advances the cellular automaton state and updates live cell counts.
        func step() {
            // Run one generation/step of the cellular automaton
            for y in 0..<size {
                for x in 0..<size {
                    let liveNeighbors = countLiveNeighbors(x: x, y: y)
                    let isAlive = grid[y][x]
                    
                    // Conway-style or custom CA rule application
                    if isAlive {
                        nextGrid[y][x] = liveNeighbors == 2 || liveNeighbors == 3
                    } else {
                        nextGrid[y][x] = liveNeighbors == 3
                    }
                }
            }
            
            // Swap grids
            cells = nextGrid
            generation += 1
            liveCellCount = countLiveCells()
        }

        /// Observes movement to track and penalize repetitive futile loops.
        func observeMovementForFutility(
            action: FrankensteinAction,
            x: Float,
            z: Float,
            timestamp: TimeInterval
        ) {
            // Track action position/futility to discourage getting stuck in loops
            let currentPenalty = futilityPenalties[action, default: 0]
            if currentPenalty < maximumFutilityPenalty {
                futilityPenalties[action] = currentPenalty + (futilityPenaltyIncrement * 0.1)
            }
        }

        /// Forgives or reduces the futility penalty for an action when steady progress is made.
        func forgiveFutility(for action: FrankensteinAction, amount: Float) {
            let currentPenalty = futilityPenalties[action, default: 0]
            futilityPenalties[action] = max(0, currentPenalty - amount)
        }
    /// Evaluates whether a given cell or entity is currently active within the grid bounds.
        /// - Parameters:
        ///   - x: The x-coordinate index.
        ///   - y: The y-coordinate index.
        /// - Returns: A boolean indicating if the cell is active (alive) and within valid bounds.
        func isActive(x: Int, y: Int) -> Bool {
            guard x >= 0, x < size, y >= 0, y < size else {
                return false
            }
            return grid[y][x]
        }
    /// Resets the cellular automaton state, generation counter, Q-grids, and planning buffers.
        func reset() {
            generation = 0
            isRunning = false
            totalDecisions = 0
            stuckSeconds = 0
            outcomesObserved = 0
            consecutiveJumpCount = 0
            lastDecisionDescription = "Simulation reset"
            goalSeekingStatus = "No goal outcome yet"
            
            // Reset planning and memory structures
            planBuffer = FrankensteinPlanBuffer()
            plannedSequence.removeAll()
            visitCounts.removeAll()
            effectModel.removeAll()
            futilityPenalties.removeAll()
            
            // Reset network Q-grid and field-of-vision dirty flags
            networkQGrid = Array(repeating: Array(repeating: 0.0, count: size), count: size)
            dirtyQCells = Array(repeating: Array(repeating: true, count: size), count: size)
            
            // Re-randomize CA grid and update live cell count
            randomize()
            liveCellCount = countLiveCells()
        }
    // MARK: - Dirty Q-Values Field of Vision Logic
    private func markVisionQValuesDirty(perception p: FrankensteinCAPerception) {
        // Clear dirty flags
        for y in 0..<size {
            for x in 0..<size {
                dirtyQCells[y][x] = false
            }
        }

        // Mark action neurons visible/relevant in field of vision as dirty
        let visibleActions: [FrankensteinAction] = p.nearestObjectMovable ? [.pushObject, .liftObject, .walk] : [.walk, .run, .turnLeft, .turnRight, .jump]
        
        for action in visibleActions {
            if let pos = actionNeuronPosition(for: action) {
                dirtyQCells[pos.y][pos.x] = true
                // Mark local neighborhood in CA grid as dirty for spatial propagation
                for dy in -1...1 {
                    for dx in -1...1 {
                        let ny = max(0, min(size - 1, pos.y + dy))
                        let nx = max(0, min(size - 1, pos.x + dx))
                        dirtyQCells[ny][nx] = true
                    }
                }
            }
        }
    }

    func setQValues(_ qValues: [FrankensteinAction: Float]) {
        // Only update Q-values where the corresponding cells are marked dirty in Frankenstein's field of vision
        for (action, value) in qValues {
            guard let position = actionNeuronPosition(for: action) else {
                continue
            }

            if dirtyQCells[position.y][position.x] {
                networkQGrid[position.y][position.x] = value
            }
        }
    }

    // MARK: - Predicted Goal Score (Fixed: Removed blind jump preference)
    private func predictedGoalScore(
        for action: FrankensteinAction,
        perception p: FrankensteinCAPerception
    ) -> Float {
        var score: Float = 0

        let alignment = max(0, cosf(p.headingError))
        let nearGoal = p.pathDistance.isFinite && p.pathDistance < 1.2

        switch action {
        case .walk:
            score += 0.25 * 1.0 * alignment
        case .run:
            score += 0.25 * 2.2 * alignment
            if nearGoal { score -= 0.8 }
            if p.clearanceAhead < 2.0 { score -= 0.4 }
        case .stepForward:
            score += 0.25 * 0.5 * alignment
        case .jump:
            // FIXED: Removed automatic blind preference when stuck.
            // Jump is only rewarded if an obstacle requires it or clearance demands it.
            if p.clearanceAhead < 0.8 {
                score += 0.2
            } else {
                score -= 0.5 // Penalize unnecessary jumping
            }
            if consecutiveJumpCount > 2 {
                score -= 2.0 // Heavy penalty for repeat hopping loops
            }
        default:
            break
        }

        if action == .pushObject {
            if p.nearestObjectMovable, p.nearestObjectDistance <= 1.2 {
                score += alignment > 0.5 ? 1.5 : 0.35
                if stuckSeconds > stuckThreshold {
                    score += 0.8
                }
            } else {
                score -= 0.5
            }
        }

        return score
    }

    private let planHorizon = 3
    private let planActionSeconds: Float = 0.35
    private let planTurnPerAction: Float = 0.9 * 0.35
    private let planCellLength: Float = 0.5
    private let planGain: Float = 1.5

    private(set) var plannedSequence: [FrankensteinAction] = []

    private struct Rollout {
        var heading: Float = 0
        var progress: Float = 0
        var used: Float = 0
        var wasted: Int = 0
    }

    private func wrapped(_ angle: Float) -> Float {
        var value = angle
        while value > .pi { value -= 2.0 * .pi }
        while value < -.pi { value += 2.0 * .pi }
        return value
    }

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
        case .pushObject:  return (0.5, false)
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

        for action in [FrankensteinAction.walk, .run, .turnLeft, .turnRight, .pushObject] {
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

    private func planValues(
        for actions: [FrankensteinAction],
        perception p: FrankensteinCAPerception
    ) -> [FrankensteinAction: Float] {
        guard !p.routeRelativeHeadings.isEmpty else {
            plannedSequence = []
            return [:]
        }

        var values: [FrankensteinAction: Float] = [:]
        var bestValue: Float = -.infinity
        var bestSequence: [FrankensteinAction] = []

        for action in actions {
            let first = planStep(action, from: Rollout(), perception: p)
            let rest = bestContinuation(from: first, depth: planHorizon - 1, perception: p)
            values[action] = rest.value

            if rest.value > bestValue {
                bestValue = rest.value
                bestSequence = [action] + rest.sequence
            }
        }

        plannedSequence = bestSequence

        for (action, value) in values {
            values[action] = planGain * (value - bestValue)
        }

        return values
    }

    private var futilityPenalties: [FrankensteinAction: Float] = [:]
    private let maximumFutilityPenalty: Float = 8.0
    private let futilityPenaltyIncrement: Float = 1.5

    func futilityPenalty(for action: FrankensteinAction) -> Float {
        futilityPenalties[action, default: 0]
    }

    private func networkActivitySignal(
        for action: FrankensteinAction
    ) -> Float {
        guard let position = actionNeuronPosition(for: action) else {
            return 0
        }

        let neighbors = countLiveNeighbors(x: position.x, y: position.y)
        return Float(neighbors) / 8.0 * qTieBreakWeight
    }

    private func currentPerception() -> FrankensteinCAPerception? {
        guard let perception else { return nil }
        guard lastTimestamp - perception.timestamp <= perceptionMaxAge else { return nil }
        return perception
    }

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

        case .walk, .stepForward, .stepUp, .pushObject:
            if abs(error) < alignedHeadingTolerance { return 0.35 }
            return -0.6 * magnitude

        case .run:
            if abs(error) < alignedHeadingTolerance { return 0.15 }
            return -0.8 * magnitude

        default:
            return 0
        }
    }

    private func clearanceScore(
        for action: FrankensteinAction,
        perception p: FrankensteinCAPerception
    ) -> Float {
        let ahead = p.clearanceAhead

        switch action {
        case .walk, .stepForward, .pushObject:
            return ahead < 0.9 ? -(0.9 - ahead) * 2.0 : 0
        case .run:
            if ahead < 2.0 { return -(2.0 - ahead) * 1.5 }
            return 0.2
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
            case .jump:
                if t.canLandOnObject { return 0.6 }
                return t.isLandingAreaClear ? 0.45 : -0.5
            case .pushObject: return t.objectMovable ? 0.8 : -1.0
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
        parts.q = networkQGrid[actionNeuronPosition(for: action)?.y ?? 0][actionNeuronPosition(for: action)?.x ?? 0]
        parts.activity = networkActivitySignal(for: action)
        parts.futility = futilityPenalties[action, default: 0]

        if let p {
            parts.advisory = p.advisoryValues[action, default: 0]
            parts.steering = steeringScore(for: action, perception: p)
            parts.clearance = clearanceScore(for: action, perception: p)
            parts.terrain = terrainScore(for: action, terrain: terrain)
            parts.plan = plan[action, default: 0]
            parts.goal = learnedGoalValue(for: action, stateKey: p.stateKey) + predictedGoalScore(for: action, perception: p)
            parts.novelty = explorationBonus(for: action, stateKey: p.stateKey)
        }

        return parts
    }

    private func learnedGoalValue(for action: FrankensteinAction, stateKey: String) -> Float {
        guard let stat = effectModel[stateKey]?[action.rawValue], stat.count >= 2 else { return 0 }
        return goalProgressGain * tanhf(stat.mean / 0.6)
    }

    private func updatePlanBuffer(perception p: FrankensteinCAPerception?, terrain: FrankensteinTerrainSample) {
        guard let p else { return }
        let newSteps = plannedSequence.map { PlanStep(action: $0, description: "Execute action \($0)") }
        if planBuffer.isEmpty {
            planBuffer.setPlan(newSteps)
        } else {
            planBuffer.adaptPlan(with: newSteps)
        }
    }

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

        setQValues(qValues)

        let p = currentPerception()
        let stateKey = p?.stateKey ?? "none"

        updatePlanBuffer(perception: p, terrain: terrain)

        let epsilon = max(exploration, randomExploration)

        if Float.random(in: 0..<1) < epsilon,
           let random = allowedActions.filter({ $0 != .recover }).randomElement() {
            recordVisit(action: random, stateKey: stateKey)
            rememberDecision(random, stateKey: stateKey, perception: p)
            planBuffer.insertImmediateStep(PlanStep(action: random, description: "Exploration step"))
            planBuffer.markCurrentStepCompleted()
            lastDecisionDescription = "Decided to explore \(random) (State: \(stateKey))"
            return random
        }

        let plan: [FrankensteinAction: Float] = p.map { planValues(for: allowedActions, perception: $0) } ?? [:]

        let selected: FrankensteinAction
        if let step = planBuffer.currentStep, allowedActions.contains(step.action) {
            selected = step.action
            planBuffer.markCurrentStepCompleted()
        } else {
            var candidate = allowedActions[0]
            var bestParts = scoreParts(for: candidate, perception: p, terrain: terrain, plan: plan)

            for action in allowedActions.dropFirst() {
                let parts = scoreParts(for: action, perception: p, terrain: terrain, plan: plan)
                if parts.total > bestParts.total {
                    candidate = action
                    bestParts = parts
                }
            }
            selected = candidate
            planBuffer.insertImmediateStep(PlanStep(action: selected, description: "Action step"))
            planBuffer.markCurrentStepCompleted()
        }

        recordVisit(action: selected, stateKey: stateKey)
        rememberDecision(selected, stateKey: stateKey, perception: p)
        lastDecisionDescription = "Decided to execute \(selected) (State: \(stateKey))"
        return selected
    }

    init() {
        cells = Array(repeating: Array(repeating: false, count: size), count: size)
        nextGrid = cells
        networkQGrid = Array(repeating: Array(repeating: 0.0, count: size), count: size)
        dirtyQCells = Array(repeating: Array(repeating: true, count: size), count: size)
        randomize()
        liveCellCount = countLiveCells()
    }

    private func actionNeuronPosition(for action: FrankensteinAction) -> (x: Int, y: Int)? {
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
        case .pushObject:  return (14, 10)
        default:           return nil
        }
    }

    private func countLiveNeighbors(x: Int, y: Int) -> Int {
        var count = 0
        for dy in -1...1 {
            for dx in -1...1 {
                if dx == 0 && dy == 0 { continue }
                let nx = (x + dx + size) % size
                let ny = (y + dy + size) % size
                if grid[ny][nx] { count += 1 }
            }
        }
        return count
    }

    private func countLiveCells() -> Int {
        grid.reduce(0) { $0 + $1.filter { $0 }.count }
    }

    private func randomize() {
        for y in 0..<size {
            for x in 0..<size {
                grid[y][x] = Bool.random()
            }
        }
    }
    
    private func decayFutility(to timestamp: TimeInterval) {}
}
