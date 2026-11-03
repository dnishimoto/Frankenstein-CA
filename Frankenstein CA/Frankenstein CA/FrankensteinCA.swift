
import Foundation
import Combine
import SceneKit
import UIKit

final class FrankensteinCA: ObservableObject {
     private var previousRouteHeadings: [Float] = []
    private let routeChangeThreshold: Float = 0.50
    private let planHorizon = 5
        private let planActionSeconds: Float = 0.35
        private let planTurnPerAction: Float = 0.9 * 0.35
        private let planCellLength: Float = 0.5
        private let planGain: Float = 1.5
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
    /// Actions queued for the current sub-goal (plain state, see
    /// FrankensteinPlanBuffer).
    var planBuffer = FrankensteinPlanBuffer()

    /// The overall goal and where he is within it. Survives replanning.
    @Published var goalContext = FrankensteinGoalContext()

    /// Set when the goal or sub-goal changed; the next decision drops the old
    /// plan and searches again for the new sub-goal.
    private var pendingGoalChange: String?

    /// How much worse than the best-scoring action the buffered head may be
    /// before the CA's own scoring vetoes the plan.
    private let planCommitmentMargin: Float = 0.75

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
    private(set) var plannedSequence: [FrankensteinAction] = []

    private var noveltyScale: Float {
        max(0.08, 0.5 * powf(0.9997, Float(totalDecisions)))
    }

    private var randomExploration: Float {
        max(0.01, 0.06 * powf(0.9995, Float(totalDecisions)))
    }

    private(set) var lastScoreBreakdown: [FrankensteinAction: String] = [:]

    func receivePerception(_ newPerception: FrankensteinCAPerception, allowedActions: [FrankensteinAction]) {
            perception = newPerception
            lastTimestamp = max(lastTimestamp, newPerception.timestamp)

            let sub = newPerception.subGoal.isEmpty ? nil : newPerception.subGoal
            if let change = goalContext.observe(
                goal: newPerception.goal,
                subGoal: sub,
                goalReached: newPerception.atGoal
            ) {
                pendingGoalChange = change
            }
            
            // Mark Q-values dirty for all currently permitted actions
            markVisionQValuesDirty(perception: newPerception, allowedActions: allowedActions)
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
        }

        // The plan advances only when the action has really run.
        planBuffer.recordExecuted(action: action, blocked: blocked)
        
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
        for y in 0..<size {
            for x in 0..<size {
                let liveNeighbors = countLiveNeighbors(x: x, y: y)
                let isAlive = grid[y][x]
                
                if isAlive {
                    nextGrid[y][x] = liveNeighbors == 2 || liveNeighbors == 3
                } else {
                    nextGrid[y][x] = liveNeighbors == 3
                }
            }
        }
        
        cells = nextGrid
        generation += 1
        liveCellCount = countLiveCells()
    }

   

 
    func isActive(x: Int, y: Int) -> Bool {
        guard x >= 0, x < size, y >= 0, y < size else {
            return false
        }
        return grid[y][x]
    }

    func reset() {
        generation = 0
        isRunning = false
        totalDecisions = 0
        stuckSeconds = 0
        outcomesObserved = 0
        consecutiveJumpCount = 0
        lastDecisionDescription = "Simulation reset"
        goalSeekingStatus = "No goal outcome yet"
        
        planBuffer = FrankensteinPlanBuffer()
        goalContext = FrankensteinGoalContext()
        pendingGoalChange = nil
        plannedSequence.removeAll()
        visitCounts.removeAll()
        effectModel.removeAll()
        recentPositions.removeAll()
        lastPositionSampleTime = 0
        lastLoopPenaltyTime = 0
        
        networkQGrid = Array(repeating: Array(repeating: 0.0, count: size), count: size)
        dirtyQCells = Array(repeating: Array(repeating: true, count: size), count: size)
        
        randomize()
        liveCellCount = countLiveCells()
    }

    private func markVisionQValuesDirty(perception p: FrankensteinCAPerception, allowedActions: [FrankensteinAction]) {
        for y in 0..<size {
            for x in 0..<size {
                dirtyQCells[y][x] = false
            }
        }

        // Mark Q-cells for all currently permitted actions
        for action in allowedActions {
            if let pos = actionNeuronPosition(for: action) {
                dirtyQCells[pos.y][pos.x] = true
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

    func qValue(atX x: Int, y: Int) -> Float {
        guard (0..<size).contains(x), (0..<size).contains(y) else { return 0 }
        return networkQGrid[y][x]
    }

    func qValue(for action: FrankensteinAction) -> Float {
        guard let position = actionNeuronPosition(for: action) else { return 0 }
        return networkQGrid[position.y][position.x]
    }

    func setQValues(_ qValues: [FrankensteinAction: Float]) {
        for (action, value) in qValues {
            guard let position = actionNeuronPosition(for: action) else {
                continue
            }

            if dirtyQCells[position.y][position.x] {
                networkQGrid[position.y][position.x] = value
            }
        }
    }

    // FrankensteinCA_6.swift

    private func predictedGoalScore(
        for action: FrankensteinAction,
        perception p: FrankensteinCAPerception
    ) -> Float {
        var score: Float = 0
        let alignment = max(0, cosf(p.headingError))
        let objectName = p.nearestObjectName.lowercased()
        
        // ---> LETTER DELIVERY OVERRIDE <---
        // When carrying a letter block, strongly prioritize walking toward the slot
        // and executing the place action so scoring doesn't override the delivery plan.
        if p.carryingLetterBlock {
            if action == .placeObject {
                score += 12.0 // Massive boost to prevent local overrides during delivery
                return score
            } else if action == .walk || action == .run || action == .stepForward {
                score += 4.0 * alignment
            } else if action == .turnLeft || action == .turnRight {
                score += 1.0 * (1.0 - alignment) // Help him line up precisely with the slot
            } else {
                score -= 2.0 // Discourage unrelated actions while carrying a letter
            }
        }
        // ---------------------------------

        // ---> HAZARD EVASION OVERRIDE <---
        if p.clearanceAhead < 0.8 {
            if action == .backward {
                score += 6.0
            } else if action == .turnLeft || action == .turnRight {
                score += 3.0
            } else if action == .walk || action == .run || action == .pushObject || action == .kickObject {
                score -= 5.0
            }
        }

        let isTargetLetter = objectName.contains("letterblock") || objectName.contains("floatingletter")
        
        switch action {
        case .pushObject:
            if p.nearestObjectMovable, p.nearestObjectDistance <= 2.0 {
                score += 6.0
            } else {
                score -= 0.5
            }

        case .kickObject:
            if p.nearestObjectMovable, p.nearestObjectDistance <= 1.8 {
                score += 5.5
            } else {
                score -= 0.5
            }
            
        case .throwObject:
            if p.nearestObjectMovable || objectName.contains("block") {
                score += 4.5
            } else {
                score -= 0.2
            }
            
        case .liftObject:
            if p.nearestObjectPickupable && (isTargetLetter || p.nearestObjectDistance <= 1.25) {
                score += 8.0
            }
        case .backward:
            if p.carryingLetterBlock {
                score += 6.0
            } else {
                score += 0.1
            }
        case .walk, .run:
            score += (isTargetLetter ? 1.5 : 0.4) * alignment
            
        default:
            break
        }

        return score
    }

    private struct Rollout {
        var heading: Float = 0
        var progress: Float = 0
        var used: Float = 0
        var wasted: Int = 0
        var qSum: Float = 0
        var discount: Float = 1
    }

    private let planQWeight: Float = 0.5
    private let planQScale: Float = 2.0
    private let planDiscount: Float = 0.9
    private let planGoalBonus: Float = 1.0
    private let planGoalTolerance: Float = 0.3

    private var planQValues: [FrankensteinAction: Float] = [:]

    private func goalQTerm(_ action: FrankensteinAction) -> Float {
        let q = planQValues[action, default: 0]
        guard q.isFinite else { return 0 }
        return planQWeight * tanhf(q / planQScale)
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
        case .kickObject:  return (2.5, false)
        default:           return nil
        }
    }

    private func routeHeading(
            atProgress progress: Float,
            perception p: FrankensteinCAPerception
        ) -> Float {
            let route = p.routeRelativeHeadings.isEmpty ? [p.headingError] : p.routeRelativeHeadings
            let cell = max(0, Int(progress / planCellLength))
            return route[min(cell, route.count - 1)]
        }

        private func planValues(
            for actions: [FrankensteinAction],
            perception p: FrankensteinCAPerception
        ) -> [FrankensteinAction: Float] {
            // Fallback to heading error if path field headings are temporarily empty
            let activeHeadings = p.routeRelativeHeadings.isEmpty ? [p.headingError] : p.routeRelativeHeadings

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
        var next = physicalStep(action, from: state, perception: p)
        next.qSum = state.qSum + state.discount * goalQTerm(action)
        next.discount = state.discount * planDiscount
        return next
    }

    private func physicalStep(
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
        var value = state.progress + 0.4 * alignment - 0.5 * Float(state.wasted)

        value += state.qSum

        if p.pathDistance.isFinite,
           state.progress >= p.pathDistance - planGoalTolerance {
            value += planGoalBonus
        }

        return value
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

        // Expanded rollout action set including backward movement for retreat maneuvers
        for action in [
            FrankensteinAction.walk,
            .run,
            .turnLeft,
            .turnRight,
            .stepForward,
            .backward,
            .pushObject,
            .kickObject
        ] {
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
   
    private struct PositionSample {
        let x: Float
        let z: Float
        let time: TimeInterval
        let action: FrankensteinAction
    }

    private var recentPositions: [PositionSample] = []
    private var lastPositionSampleTime: TimeInterval = 0
    private var lastLoopPenaltyTime: TimeInterval = 0

    private let positionSampleInterval: TimeInterval = 0.25
    private let loopMinimumAge: TimeInterval = 2.0
    private let loopDistanceThreshold: Float = 0.45
    private let maximumPositionSamples = 40

   
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

        var total: Float {
            q + advisory + steering + clearance + terrain + goal + plan + novelty + activity
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

    /// Within this distance (m) of an obstruction the plan clears it.
    private let obstructionReach: Float = 1.4
    /// How far above the best rollout the clearing action is valued.
    private let obstructionPlanBonus: Float = 3.0

    /// An obstruction (the table, a letterless block) on the route becomes a
    /// planned action: the plan walks up to it, then kicks it out of the way
    /// (or lifts a block), then carries on to the goal.
    private func applyObstructionToPlan(
            _ plan: inout [FrankensteinAction: Float],
            allowed: [FrankensteinAction],
            perception p: FrankensteinCAPerception
        ) {
            let reach = p.obstructionBlocked ? obstructionReach + 0.4 : obstructionReach
            guard let action = p.obstructionAction,
                  p.obstructionDistance <= reach,
                  allowed.contains(action) else { return }

            let top = plan.values.max() ?? 0
            plan[action] = top + (p.obstructionBlocked ? 2 * obstructionPlanBonus : obstructionPlanBonus)
            plannedSequence = [action] + plannedSequence.filter { $0 != action }
        }

    private func updatePlanBuffer(
            plan: [FrankensteinAction: Float],
            allowed: [FrankensteinAction],
            perception p: FrankensteinCAPerception?
        ) {
            if let change = pendingGoalChange {
                planBuffer.invalidate(reason: change)
                pendingGoalChange = nil
            }

            let fresh: [PlanStep] = plannedSequence.map { action in
                guard let p, !p.obstructionName.isEmpty else {
                    return PlanStep(action: action, description: "\(action)")
                }
                if action == p.obstructionAction {
                    return PlanStep(
                        action: action,
                        description: "\(action): clear \(p.obstructionName) out of the path"
                    )
                }
                return PlanStep(
                    action: action,
                    description: "\(action): toward \(p.obstructionName) (in the way)"
                )
            }

            var headRegret: Float = 0
            if let head = planBuffer.currentStep,
               let bestValue = plan.values.max(),
               let headValue = plan[head.action] {
                headRegret = max(0, bestValue - headValue)
            }

            planBuffer.reconcile(
                fresh: fresh,
                headRegret: headRegret,
                allowed: allowed,
                regretMargin: planCommitmentMargin
            )
        }

 
    func decideAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        allowedActions: [FrankensteinAction],
        qValues: [FrankensteinAction: Float],
        exploration: Float = 0,
        isDeliveringLetter: Bool = false
    ) -> FrankensteinAction {

        guard !allowedActions.isEmpty else {
            lastDecisionDescription = "No permitted action"
            return .walk
        }

        setQValues(qValues)
        planQValues = qValues

        let p = currentPerception()

        // MARK: - Preserve the delivery route

        // A changed path-field heading does not automatically cancel
        // the delivery plan. The path can adapt around obstacles while
        // the mission destination remains the letter slot.
        if let p,
           routeHasChanged(p.routeRelativeHeadings),
           !isDeliveringLetter {

            planBuffer.invalidate(
                reason: "Pathfield changed: reconsidering route around obstruction"
            )

            plannedSequence.removeAll()
        }

        let stateKey = p?.stateKey ?? "none"

        var plan: [FrankensteinAction: Float]

        if let p {
            plan = planValues(
                for: allowedActions,
                perception: p
            )
        } else {
            plannedSequence = []
            plan = [:]
        }

        // Obstruction planning remains available during delivery.
        if let p {
            applyObstructionToPlan(
                &plan,
                allowed: allowedActions,
                perception: p
            )
        }

        // During delivery, do not continuously replace the plan.
        // Only initialize it if empty or replace an unsafe/disallowed head.
        if isDeliveringLetter {
            if planBuffer.currentStep == nil {
                updatePlanBuffer(
                    plan: plan,
                    allowed: allowedActions,
                    perception: p
                )
            }
        } else {
            updatePlanBuffer(
                plan: plan,
                allowed: allowedActions,
                perception: p
            )
        }

        // MARK: - Score permitted actions

        var best = allowedActions[0]

        var bestParts = scoreParts(
            for: best,
            perception: p,
            terrain: terrain,
            plan: plan
        )

        var allParts: [FrankensteinAction: ScoreParts] = [
            best: bestParts
        ]

        lastScoreBreakdown.removeAll()

        lastScoreBreakdown[best] = String(
            format: "Q:%.2f | Pred:%.2f | Steer:%.2f | Clear:%.2f | Terr:%.2f | Plan:%.2f | Nov:%.2f | Act:%.2f  -> Total:%.2f",
            bestParts.q,
            bestParts.goal,
            bestParts.steering,
            bestParts.clearance,
            bestParts.terrain,
            bestParts.plan,
            bestParts.novelty,
            bestParts.activity,
            bestParts.total
        )

        for action in allowedActions.dropFirst() {

            let parts = scoreParts(
                for: action,
                perception: p,
                terrain: terrain,
                plan: plan
            )

            allParts[action] = parts

            lastScoreBreakdown[action] = String(
                format: "Q:%.2f | Pred:%.2f | Steer:%.2f | Clear:%.2f | Terr:%.2f | Plan:%.2f | Nov:%.2f | Act:%.2f  -> Total:%.2f",
                parts.q,
                parts.goal,
                parts.steering,
                parts.clearance,
                parts.terrain,
                parts.plan,
                parts.novelty,
                parts.activity,
                parts.total
            )

            if parts.total > bestParts.total {
                best = action
                bestParts = parts
            }
        }

        // MARK: - Select action

        var selected = best

        if let head = planBuffer.currentStep {

            if allowedActions.contains(head.action) {

                if isDeliveringLetter {
                    // Letter delivery commitment:
                    // keep executing the current planned action.
                    selected = head.action

                } else if let headParts = allParts[head.action] {

                    if head.action == best ||
                        bestParts.total - headParts.total <= planCommitmentMargin {

                        selected = head.action

                    } else {

                        planBuffer.overrideHead(
                            with: PlanStep(
                                action: best,
                                description: "\(best)"
                            ),
                            reason: "scoring overrode \(head.action) with \(best)"
                        )

                        selected = best
                    }

                } else {
                    selected = best
                }

            } else {
                // The current step is no longer permitted.
                // Safety constraints take priority over commitment.
                planBuffer.overrideHead(
                    with: PlanStep(
                        action: best,
                        description: "\(best)"
                    ),
                    reason: isDeliveringLetter
                        ? "delivery step no longer permitted; safe replan"
                        : "current step no longer permitted"
                )

                selected = best
            }

        } else {

            planBuffer.overrideHead(
                with: PlanStep(
                    action: best,
                    description: "\(best)"
                ),
                reason: "no plan; chose \(best)"
            )

            selected = best
        }

        // MARK: - Exploration

        let epsilon: Float

        if isDeliveringLetter {
            // No random action substitutions while delivering.
            epsilon = 0

        } else if exploration >= 1 {
            epsilon = 1

        } else if exploration <= 0 {
            epsilon = 0

        } else {
            epsilon = min(
                0.25,
                max(exploration, randomExploration)
            )
        }

        var explored = false

        if Float.random(in: 0..<1) < epsilon,
           let random = allowedActions
            .filter({ $0 != .recover && $0 != selected })
            .randomElement() {

            selected = random
            explored = true

            planBuffer.overrideHead(
                with: PlanStep(
                    action: random,
                    description: "\(random) (exploring)"
                ),
                reason: "exploring \(random)"
            )
        }

        // MARK: - Record decision

        recordVisit(
            action: selected,
            stateKey: stateKey
        )

        rememberDecision(
            selected,
            stateKey: stateKey,
            perception: p
        )

        let queue = planBuffer.pendingActions
            .prefix(4)
            .map { String(describing: $0) }
            .joined(separator: " > ")

        let missionLabel = isDeliveringLetter
            ? "LETTER DELIVERY COMMITTED"
            : "Normal planning"

        lastDecisionDescription =
            "\(missionLabel) | " +
            "\(explored ? "Exploring" : "Executing") \(selected) | " +
            "\(goalContext.summary) | " +
            "Queue: \(queue.isEmpty ? "empty" : queue) | " +
            "Plan: \(planBuffer.lastReplanReason) " +
            "(\(planBuffer.replanCount)) | " +
            "State: \(stateKey)"

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
        case .kickObject:  return (10, 10) // Fixed: Added grid coordinates for kickObject
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


    private func routeHasChanged(
        _ headings: [Float]
    ) -> Bool {
        guard !previousRouteHeadings.isEmpty,
              !headings.isEmpty else {
            previousRouteHeadings = headings
            return false
        }

        let count = min(
            headings.count,
            previousRouteHeadings.count
        )

        var maximumChange: Float = 0

        for index in 0..<count {
            let difference = abs(
                wrapped(headings[index] - previousRouteHeadings[index])
            )

            maximumChange = max(maximumChange, difference)
        }

        let changed =
            maximumChange >= routeChangeThreshold ||
            headings.count != previousRouteHeadings.count

        previousRouteHeadings = headings

        return changed
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
    
 
}
