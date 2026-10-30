
import Combine
import SceneKit
import UIKit

final class FrankensteinCA: ObservableObject {

    let size = 18

    @Published private(set) var generation: Int = 0
    @Published private(set) var isRunning = false
    @Published private(set) var liveCellCount: Int = 0
    @Published private(set) var lastDecisionDescription = "Waiting for perception"

    @Published var networkQGrid: [[Float]]
    @Published var planBuffer = FrankensteinPlanBuffer()

    // MARK: - Tapestry Pattern Coordinates & Movable Blocks Setup
    @Published private(set) var currentTapestrySlotIndex = 0
    private weak var cachedRootNode: SCNNode?
    
    /// Converts active CA grid cells into 3D world targets for tapestry placement.
    var tapestryTargetCoordinates: [SIMD2<Float>] {
        var targets: [SIMD2<Float>] = []
        let spacing: Float = 0.4
        let originX: Float = -2.0
        let originZ: Float = -2.0
        
        for y in 0..<size {
            for x in 0..<size {
                if grid[y][x] {
                    let worldX = originX + Float(x) * spacing
                    let worldZ = originZ + Float(y) * spacing
                    targets.append(SIMD2<Float>(worldX, worldZ))
                }
            }
        }
        
        if targets.isEmpty {
            targets.append(SIMD2<Float>(0, -2.0))
        }
        return targets
    }

    var currentTapestryTargetSlot: SIMD2<Float> {
        let targets = tapestryTargetCoordinates
        guard !targets.isEmpty else { return SIMD2<Float>(0, -2.0) }
        let index = min(currentTapestrySlotIndex, targets.count - 1)
        return targets[index]
    }

    func advanceToNextTapestrySlot() {
        let total = tapestryTargetCoordinates.count
        if currentTapestrySlotIndex < total - 1 {
            currentTapestrySlotIndex += 1
        } else {
            // Completed pattern layer; reset index and evolve CA state for next pattern
            currentTapestrySlotIndex = 0
            update()
        }
    }

    /// Spawns compact movable blocks for tapestry construction.
    func setupSpellingBlocks(in rootNode: SCNNode) {
        self.cachedRootNode = rootNode
        let blockSideLength: CGFloat = 0.35
        let cornerRadius: CGFloat = 0.04
        let startX: Float = -2.2
        let startZ: Float = 3.0
        let spacing: Float = 0.55
        let totalBlocks = 16
        let columns = 4
        
        for index in 0..<totalBlocks {
            let blockGeometry = SCNBox(
                width: blockSideLength,
                height: blockSideLength,
                length: blockSideLength,
                chamferRadius: cornerRadius
            )
            
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemOrange
            material.roughness.contents = 0.4
            blockGeometry.materials = [material]
            
            let blockNode = SCNNode(geometry: blockGeometry)
            blockNode.name = "MovableBlock_\(index)"
            
            let row = index / columns
            let col = index % columns
            
            let posX = startX + Float(col) * spacing
            let posY = Float(blockSideLength / 2.0)
            let posZ = startZ + Float(row) * spacing
            
            blockNode.position = SCNVector3(posX, posY, posZ)
            
            let physicsShape = SCNPhysicsShape(geometry: blockGeometry, options: nil)
            let physicsBody = SCNPhysicsBody(type: .dynamic, shape: physicsShape)
            physicsBody.mass = 1.5
            physicsBody.friction = 0.6
            physicsBody.rollingFriction = 0.1
            physicsBody.damping = 0.4
            
            blockNode.physicsBody = physicsBody
            rootNode.addChildNode(blockNode)
        }
    }

    /// Scans the scene graph for available movable blocks to build the tapestry.
    func findNextTargetBlock(from robotPosition: SIMD2<Float>) -> (position: SIMD2<Float>, name: String)? {
        guard let root = cachedRootNode else { return nil }
        
        var closestBlockPos: SIMD2<Float>? = nil
        var closestName: String = ""
        var minDistance: Float = .infinity
        
        for child in root.childNodes {
            guard let name = child.name, name.hasPrefix("MovableBlock_") else { continue }
            let pos = SIMD2<Float>(Float(child.position.x), Float(child.position.z))
            let dist = simd_distance(robotPosition, pos)
            if dist < minDistance {
                minDistance = dist
                closestBlockPos = pos
                closestName = name
            }
        }
        
        if let pos = closestBlockPos {
            return (pos, closestName)
        }
        return nil
    }

    private var grid: [[Bool]]
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
    }

    private struct EffectStat {
        var mean: Float = 0
        var count: Int = 0
    }

    private var effectModel: [String: [Int: EffectStat]] = [:]
    private var decisionStateKey = "none"
    private var decisionHeadingError: Float = 0
    private var decisionAction: FrankensteinAction?

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

    // MARK: - Q-Path Search and Goal Queue Routing
    
    /// Evaluates queued goals, tracks available blocks, and searches Q-paths to route toward tapestry slots.
    func evaluateGoalQueuePath(
        currentPosition: SIMD2<Float>,
        qValues: [FrankensteinAction: Float],
        pathField: FrankensteinCAPathField
    ) -> Float? {
        let targetGoalPosition: SIMD2<Float>
        if let blockInfo = findNextTargetBlock(from: currentPosition) {
            targetGoalPosition = blockInfo.position
            
            let slotPosition = currentTapestryTargetSlot
            if simd_distance(blockInfo.position, slotPosition) < 0.35 {
                advanceToNextTapestrySlot()
            }
        } else {
            targetGoalPosition = currentTapestryTargetSlot
        }
        
        return pathField.searchOptimalQPath(
            currentPosition: currentPosition,
            goalPosition: targetGoalPosition,
            qValues: qValues
        )
    }

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

        if p.atGoal {
            switch action {
            case .walk, .run, .stepForward, .jump, .backward, .roll, .pushObject:
                score -= 1.0
            case .turnLeft, .turnRight:
                score += 0.3
            default:
                break
            }
        }

        if stuckSeconds > stuckThreshold, !p.atGoal {
            let pressure = min(2.0, 0.5 * stuckSeconds)

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

        if !p.pathDistance.isFinite {
            switch action {
            case .turnLeft, .turnRight: score += 0.2
            case .run: score -= 0.4
            default: break
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

        for (action, value) in values {
            values[action] = planGain * (value - bestValue)
        }

        return values
    }

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
        currentTapestrySlotIndex = 0

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
        planBuffer.clear()

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
        case .pushObject:  return (14, 10)
        default:           return nil
        }
    }

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
            .throwObject, .pushObject
        ]
    }

    func observeMovementForFutility(
        action: FrankensteinAction,
        x: Float,
        z: Float,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
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

        guard timestamp - lastLoopPenaltyTime >= loopMinimumAge else {
            return
        }

        lastLoopPenaltyTime = timestamp
        futilityCount += 1

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
    }

    private var lastFutilityDecayTime: TimeInterval = 0
    private let futilityHalfLife: TimeInterval = 15

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

    func forgiveFutility(for action: FrankensteinAction, amount: Float = 0.5) {
        guard let penalty = futilityPenalties[action] else { return }

        let reduced = penalty - amount

        futilityPenalties[action] = reduced > 0.05 ? reduced : nil
    }

    func futilityPenalty(for action: FrankensteinAction) -> Float {
        futilityPenalties[action, default: 0]
    }

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

    private func currentPerception() -> FrankensteinCAPerception? {
        guard let perception else { return nil }

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

        case .walk, .stepForward, .stepUp, .jump, .pushObject:
            if abs(error) < alignedHeadingTolerance { return 0.35 }
            return -0.6 * magnitude

        case .run:
            if abs(error) < alignedHeadingTolerance { return 0.15 }
            return -0.8 * magnitude

        case .backward:
            return abs(error) > 2.6 ? 0.1 : -0.3

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

    // MARK: - Extended Plan Buffer Logic
    private func updatePlanBuffer(
        perception p: FrankensteinCAPerception?,
        terrain: FrankensteinTerrainSample
    ) {
        guard let p else { return }

        let newSteps = plannedSequence.map { action in
            PlanStep(
                action: action,
                description: "Execute action \(action)"
            )
        }

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

        // MARK: 1. Validate permitted actions

        let candidates = allowedActions.filter {
            qValues[$0]?.isFinite != false
        }

        guard !candidates.isEmpty else {
            lastDecisionDescription = "No permitted action"
            return .walk
        }

        setQValues(qValues)

        let p = currentPerception()
        let stateKey = p?.stateKey ?? "none"

        // MARK: 2. Evaluate action sequences

        let plan: [FrankensteinAction: Float]

        if let perception = p {
            plan = planValues(
                for: candidates,
                perception: perception
            )
        } else {
            plannedSequence = []
            plan = [:]
        }

        // Update the plan only after generating the new sequence.
        updatePlanBuffer(
            perception: p,
            terrain: terrain
        )

        // MARK: 3. Score all permitted actions

        var scores: [FrankensteinAction: ScoreParts] = [:]

        for action in candidates {
            var parts = scoreParts(
                for: action,
                perception: p,
                terrain: terrain,
                plan: plan
            )

            // Explicitly incorporate the Q-value supplied by locomotion.
            parts.q = qValues[action] ?? 0

            // Never favor pushing an object that cannot be moved.
            if action == .pushObject {
                let canPush =
                    terrain.objectMovable &&
                    terrain.distance.isFinite &&
                    terrain.distance <= 1.0 &&
                    (p?.nearestObjectMovable ?? false)

                if !canPush {
                    parts.goal -= 3.0
                    parts.terrain -= 2.0
                }
            }

            // Prefer manipulation only when it is relevant to the goal.
            if action == .liftObject {
                if !(p?.nearestObjectPickupable ?? false) {
                    parts.goal -= 2.0
                }
            }

            // Prevent unsafe running near obstacles.
            if action == .run,
               terrain.distance.isFinite,
               terrain.distance < 1.0 {
                parts.clearance -= 2.0
            }

            // Include actual body stability in action evaluation.
            // These are conservative penalties, not physical validation.
            if body.isFallen {
                switch action {
                case .recover:
                    parts.goal += 4.0
                case .run, .jump, .pushObject:
                    parts.goal -= 2.0
                default:
                    break
                }
            }

            scores[action] = parts
        }

        // MARK: 4. Select the best permitted action

        guard let best = scores.max(by: {
            $0.value.total < $1.value.total
        }) else {
            lastDecisionDescription = "Unable to score actions"
            return .walk
        }

        var selected = best.key

        // MARK: 5. Controlled exploration

        let epsilon: Float = exploration >= 1
            ? 1
            : max(0, min(0.25, max(exploration, randomExploration)))

        if Float.random(in: 0..<1) < epsilon {
            let alternatives = candidates.filter {
                $0 != selected &&
                $0 != .recover &&
                ($0 != .pushObject ||
                 (terrain.objectMovable &&
                  terrain.distance.isFinite &&
                  terrain.distance <= 1.0))
            }

            if let alternative = alternatives.randomElement() {
                let alternativeScore = scores[alternative]?.total ?? -.infinity

                // Ordinary exploration only tries alternatives that are
                // reasonably competitive. Full exploration (exploration >= 1,
                // as in tests or a deliberate exploration phase) samples
                // from every permitted candidate, however low its score.
                let forcedExploration = exploration >= 1

                if forcedExploration || alternativeScore >= best.value.total - 0.75 {
                    selected = alternative
                }
            }
        }

        // MARK: 6. Record decision

        recordVisit(
            action: selected,
            stateKey: stateKey
        )

        rememberDecision(
            selected,
            stateKey: stateKey,
            perception: p
        )

        // MARK: 7. Preserve scoring diagnostics

        lastScoreBreakdown = [:]

        for (action, parts) in scores {
            lastScoreBreakdown[action] = String(
                format:
                    "Total %.2f | Q %.2f | Goal %.2f | Plan %.2f | Terrain %.2f | Steering %.2f | Clearance %.2f | Futility %.2f",
                parts.total,
                parts.q,
                parts.goal,
                parts.plan,
                parts.terrain,
                parts.steering,
                parts.clearance,
                parts.futility
            )
        }

        lastDecisionDescription =
            "Selected \(selected) | State: \(stateKey) | " +
            "Score: \(String(format: "%.2f", scores[selected]?.total ?? 0))"

        return selected
    }

    
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

// MARK: - Q-Path Field Extension Helper
extension FrankensteinCAPathField {
    func searchOptimalQPath(
        currentPosition: SIMD2<Float>,
        goalPosition: SIMD2<Float>?,
        qValues: [FrankensteinAction: Float]
    ) -> Float? {
        let directions: [Float] = [0, .pi/4, .pi/2, 3.0 * .pi/4, .pi, -3.0 * .pi/4, -.pi/2, -.pi/4]
        var bestHeading: Float? = nil
        var maxScore: Float = -.infinity
        
        for heading in directions {
            let stepLength: Float = 1.0
            let targetX = currentPosition.x - sin(heading) * stepLength
            let targetZ = currentPosition.y - cos(heading) * stepLength
            let candidatePoint = SIMD2<Float>(targetX, targetZ)
            
            var goalAlignmentScore: Float = 0
            if let goal = goalPosition {
                let currentDist = simd_distance(currentPosition, goal)
                let candidateDist = simd_distance(candidatePoint, goal)
                goalAlignmentScore = (currentDist - candidateDist) * 2.0
            }
            
            let baseQ = qValues[.walk] ?? 0
            let forwardQ = qValues[.stepForward] ?? 0
            let combinedQ = max(baseQ, forwardQ)
            
            let totalScore = combinedQ + goalAlignmentScore
            
            if totalScore > maxScore {
                maxScore = totalScore
                bestHeading = heading
            }
        }
        
        return bestHeading
    }
}
