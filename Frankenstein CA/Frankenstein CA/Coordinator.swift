import Foundation
import SceneKit
import simd
import SwiftUI
import UIKit

final class Coordinator: NSObject, SCNSceneRendererDelegate {
    var hasCompletedLetterMission: Bool = false
    private var lastMissionSyncKey = ""
    private var lastOutcomeEvaluationTime: TimeInterval = 0
    var isResetPending = false
    private let pushBlockSpeed: Float = 0.6
    var animationSpeed: Double = 0
    private var blockConnectionStartGeneration: Int?
    private var trackedBlockID: ObjectIdentifier?
    private var movableObjectNodes: [SCNNode] = []
    private var lastSplineIndex: Int = 0
    private var lastSplineSignature = ""
    let energyManager: FrankensteinEnergyManager
    private weak var powerMeterNode: SCNNode?
    private var currentFrameTime: TimeInterval = 0
    private let requiredRechargeContactDuration: TimeInterval = 1.0
    private var hasCompletedRechargeGoal = false

    // CA perception state (the CA, not the Coordinator, turns the character
    // by choosing turnLeft / turnRight; these values are only its inputs).
    private var clearanceAhead: Float = 4
    private var clearancePlus: Float = 4
    private var clearanceMinus: Float = 4    // side reached by .turnLeft
    private var goalProgressRate: Float = 0
    private var lastPathDistance: Float = .infinity
    private var lastPathDistanceTime: TimeInterval = 0
    private let clearanceRange: Float = 3.0

    private var lastGoalDistance: Float = .infinity
    private var lastGoalNodeID: ObjectIdentifier?

    var onCAStats: ((Int, Int) -> Void)?

    private var ca: FrankensteinCA?
    private var lastCATickTime: TimeInterval = 0
    private let caTickInterval: TimeInterval = 0.25

    // MARK: - CA Executive (learning + object identity + distance paths)
    private let executive = FrankensteinCAExecutive()
    private var pathSteering: CAPathSteering?
    private var pathGoalDistance: Float = .infinity

    // MARK: - Callbacks
    var onStats: ((String) -> Void)?
    var onDebugInfo: ((String) -> Void)?
    var onDetectedObject: ((DetectedObjectInfo?) -> Void)?
    var onDetectedObjects: (([DetectedObjectInfo]) -> Void)?
    var onActionChanged: ((String) -> Void)?

    // MARK: - Scene References
    private weak var scene: SCNScene?
    private weak var characterNode: SCNNode?
    private weak var doorNode: SCNNode?
    private weak var tableNode: SCNNode?
    private weak var handNode: SCNNode?
    private weak var rechargeStationNode: SCNNode?

    /// Power below which the recharge station becomes the goal.
    private let rechargeThreshold: Float = 30.0

    /// The recharge station is the goal only when power is below the
    /// threshold. A recharge already under way (he is on the station and
    /// charging) continues until the battery is full, so it is not cut off
    /// when the power rises past the threshold.
    private var needsRecharge: Bool {
        missionDecision.requiresRecharge ||
        hasReportedRecharge
    }

    // MARK: - Hierarchical mission supervision
    private let missionSupervisor = FrankensteinMissionSupervisor()
    private var missionDecision = FrankensteinMissionDecision.initial

    private func updateMissionSupervisor() {
        let hasUnplacedLetter = letterWord.indices.contains { index in
            energyManager.placedLetters[index] == nil &&
            looseLetterBlock(forLetter: letterWord[index], atIndex: index) != nil
        }
        missionDecision = missionSupervisor.update(
            powerLevel: energyManager.powerLevel,
            maximumPower: energyManager.maxPower,
            isRecharging: hasReportedRecharge,
            carryingLetter: carryingLetterBlock,
            hasUnplacedLetter: hasUnplacedLetter,
            dogAvailable: dogTarget?.parent != nil || carryingDog,
            carryingDog: carryingDog
        )
        if missionDecision.phase != lastMissionPhase {
            lastMissionPhase = missionDecision.phase
            publishDebug("Mission phase: \(missionDecision.phase.rawValue) - \(missionDecision.subGoal)")
        }
        locomotion.isDeliveringLetter = missionDecision.phase == .deliverLetter && carryingLetterBlock
        
        switch missionDecision.phase {
        case .emergencyRecharge, .deliverLetter:
            locomotion.explorationRate = 0
        case .recharge, .fetchLetter:
            locomotion.explorationRate = 0.04
        default:
            locomotion.explorationRate = 0.12
        }
    }

    private var lastMissionPhase: FrankensteinMissionPhase?

    private func applyMissionPhaseInfluence(
        to advisory: inout [FrankensteinAction: Float],
        perception p: FrankensteinCAPerception,
        allowedActions: [FrankensteinAction]
    ) {
        func bias(_ action: FrankensteinAction, _ value: Float) {
            guard allowedActions.contains(action) else { return }
            advisory[action, default: 0] += value
        }
        if carryingLetterBlock {
            bias(.jump, -4)
            bias(.roll, -2)
        }
        let aligned = abs(p.headingError) < 0.4
        let openAhead = p.clearanceAhead > 2.0
        let farFromGoal = p.pathDistance.isFinite && p.pathDistance > 2.5
        let nearGoal = p.pathDistance.isFinite && p.pathDistance < 1.3
        let obstructed = !p.obstructionName.isEmpty
        let idleObjectActionPenalty: Float = obstructed ? 0 : -4

        switch missionDecision.phase {
        case .emergencyRecharge, .recharge:
            let urgency: Float = missionDecision.phase == .emergencyRecharge ? 3.0 : 2.0
            if aligned, openAhead { bias(.run, urgency) }
            bias(.liftObject, -6)
            bias(.throwObject, -6)
            bias(.roll, -2)
            bias(.crouch, -1)
            bias(.pushObject, idleObjectActionPenalty)
            bias(.kickObject, idleObjectActionPenalty)

        case .fetchLetter:
            if aligned, openAhead, farFromGoal { bias(.run, 1.5) }
            if nearGoal, aligned { bias(.liftObject, 3.0) }
            bias(.placeObject, -4)
            bias(.throwObject, -3)
            bias(.pushObject, idleObjectActionPenalty)
            bias(.kickObject, idleObjectActionPenalty)

        case .deliverLetter:
            if aligned, openAhead, farFromGoal { bias(.run, 1.5) }
            if nearGoal { bias(.placeObject, 4.0) }
            bias(.liftObject, -5)
            bias(.throwObject, -6)
            bias(.pushObject, -4)
            bias(.kickObject, -4)
            bias(.jump, -1)

        case .dogInteraction:
            if nearGoal, aligned { bias(.liftObject, 3.0) }
            bias(.throwObject, -4)
            bias(.pushObject, idleObjectActionPenalty)
            bias(.kickObject, idleObjectActionPenalty)

        case .lettersComplete, .explore:
            bias(.liftObject, -2)
            bias(.pushObject, -2)
            bias(.kickObject, -2)
        }
    }

    private var effectiveRechargeStationNode: SCNNode? {
        return needsRecharge ? rechargeStationNode : nil
    }

    // MARK: - Letter mission
    private let letterWord = Array("FRANKENSTEIN")
    private let letterSlotTolerance: Float = 0.45
    private let letterPlaceReach: Float = 1.6
    private let letterFetchStandoff: Float = 0.75
    private weak var letterBlockTarget: SCNNode?

    private let objectMemory = FrankensteinObjectMemory()
    private let memoryRefreshRange: Float = 1.5
    private weak var letterSlotTarget: SCNNode?
    private var letterTargetIndex: Int?

    // Dog interaction
    private let dogName = "CarryableDog"
    private let dogDetourRange: Float = 3.0
    private let dogLoveSeconds: Float = 4.0
    private let dogCooldownSeconds: TimeInterval = 25
    private weak var dogTarget: SCNNode?
    private var dogHoldSeconds: Float = 0
    private var dogCooldownUntil: TimeInterval = 0
    private var wasCarryingDog = false
    private var assistTimer: Float = 0
    private weak var loveHeartsNode: SCNNode?

    private var carryingDog: Bool { carriedNode?.name == dogName }

    private var carryingLetterBlock: Bool {
        guard let carriedNode else { return false }
        return letter(ofBlock: carriedNode) != nil
    }

    // MARK: - Simulation
    private let locomotion: FrankensteinLocomotion
    private let qFloorGrid = FrankensteinQFloorGrid()
    private let predictivePerception = FrankensteinPredictivePerception()
    private var pendingPrediction: FrankensteinPredictedOutcome?
    /// Predicted outcome of every permitted action, made before the CA chooses.
    private var latestPredictions: [FrankensteinAction: FrankensteinPredictedOutcome] = [:]
    private var lastRecordedQUpdate = 0
    private var characterVerticalVelocity: Float = 0
    private var hasReportedFall = false
    private var hasReportedRecharge = false
    private let worldGravity: Float = 9.8

    // MARK: - Lifecycle
    private var isRunning = false
    private var lastFrameTime: TimeInterval = 0
    private var lastSensorTime: TimeInterval = 0
    private var lastStatsTime: TimeInterval = 0
    private let sensorInterval: TimeInterval = 1.0 / 30.0
    private let statsInterval: TimeInterval = 0.25

    // MARK: - Movement State
    private var heading: Float = 0
    private var previousCharacterPosition = SCNVector3Zero
    private var hasPreviousCharacterPosition = false
    private var latestTerrainSample = FrankensteinTerrainSample()
    private var latestDetection: DetectedObjectInfo?

    // MARK: - Object Perception
    private struct RaycastObservation {
        let origin: SCNVector3
        let direction: SCNVector3
        let hitNodeName: String
        let resolvedObjectName: String
        let distance: Float
    }

    private struct DetailedObjectDetection {
        let node: SCNNode
        let info: DetectedObjectInfo
    }

    private var latestDetections: [DetectedObjectInfo] = []
    private var latestDetectionNodes: [ObjectIdentifier: DetectedObjectInfo] = [:]
    private var latestRayObservations: [RaycastObservation] = []

    // MARK: - Wide Field of View
    private var wideDetections: [DetectedObjectInfo] = []
    private var visibleObjects: [DetectedObjectInfo] = []
    private var lastWideScanTime: TimeInterval = 0
    private let wideScanInterval: TimeInterval = 1.0 / 6.0
    private let wideScanRange: Float = 16
    private let wideScanHalfAngleDegrees: Float = 85
    private let wideScanStepDegrees: Float = 6
    private let wideScanHeights: [Float] = [0.25, 0.9]
    private let wideScanMaximumExtent: Float = 60

    // MARK: - Pushing Movable Blocks
    private weak var pushTargetNode: SCNNode?
    var planSpline = FrankensteinPlanSpline()
    private var lastStuckSamplePosition: SCNVector3?
    private var stuckSeconds: Float = 0
    private let stuckThreshold: Float = 0.8
    private var spawnedMovableBlocks = false
    private var pushLastNodePosition: SIMD2<Float>?
    private var pushTrackedNodeID: ObjectIdentifier?
    private var pushAccumulatedMeters: Float = 0

    var onPlanText: ((String) -> Void)?
    var onMissionText: ((String) -> Void)?
    var onPerceptionText: ((String) -> Void)?
    var onGoalText: ((String) -> Void)?
    var onCurrentTaskText: ((String) -> Void)?
    var onQGrid: (([FrankensteinQDisplayCell]) -> Void)?
    private var lastQGridPublishTime: TimeInterval = 0

    // MARK: - Ground Verification
    private var verifiedGroundSupport: Bool = false
    private var verifiedLandingSupport: Bool = false

    // MARK: - Goal Tracking
    private var rechargePlatformDistance: Float = .infinity
    private var hasReachedRechargePlatform = false
    private var rechargePlatformContactTime: TimeInterval = 0
    private var lastGoalActionTime: TimeInterval = 0
    private var lastGoalActionPosition = SCNVector3Zero
    private var consecutiveNoProgressCount = 0

    // MARK: - Goal Learning Parameters
    private let noProgressThreshold: Float = 0.015
    private let noProgressPenalty: Float = -0.05
    private let goalProgressRewardScale: Float = 2.0
    private var previousGoalStateKey: String?
    private var previousGoalAction: FrankensteinAction?

    // MARK: - Outcome Window
    private var outcomeWindowElapsedTime: TimeInterval = 0
    private var outcomeWindowDisplacement: Float = 0
    private var outcomeWindowGoalProgress: Float = 0
    private var outcomeWindowPathProgress: Float = 0
    private var lastEvalPathDistance: Float = .infinity
    private let outcomeWindowDuration: TimeInterval = 0.25

    private var lastEvaluatedActionName = ""
    private var lastDisplayedActionName = ""
    private var lastDebugMessage = ""
    private var dtFromLastFrame: Float = 1.0 / 60.0

    // MARK: - Jump State
    private let standingHeight: Float = 1.8
    private var characterFootOffset: Float = 0
    private var jumpBaseY: Float?

    // MARK: - Object Interaction
    private var carriedNode: SCNNode?
    private var carriedOriginalParent: SCNNode?
    private var carriedOriginalPosition = SCNVector3Zero
    private let manipulationDistance: Float = 1.0
    private let minimumManipulationAlignment: Float = 0.7

    private var goalNode: SCNNode? {
        ca?.missionQueue.currentTargetNode
    }

    private var missionPlansWired = false
    
    // MARK: - Heading Control

    // MARK: - Reinforcement Learning


    private func syncMissionQueue() {
        guard let ca else { return }
        let queue = ca.missionQueue

        if !missionPlansWired {
            missionPlansWired = true
            queue.onPlanEvent = { [weak self] message in
                self?.publishDebug("[CA MISSION QUEUE] \(message)")
            }
        }

        queue.beginMission(
            id: "frankenstein-letter-delivery",
            title: "Spell FRANKENSTEIN by placing each letter in its matching slot"
        )

        guard let target = resolveMissionGoal() else {
            if missionDecision.phase == .lettersComplete {
                queue.clearTacticalOverrides(reason: "Mission completed")
                queue.completeGoal(id: "recharge", because: "No longer required")
            }
            return
        }

        let targetID = String(describing: ObjectIdentifier(target))
        let goalID: String
        let title: String
        let tasks: [PlanTask]

        switch missionDecision.phase {
        case .emergencyRecharge, .recharge:
            goalID = "recharge"
            title = missionDecision.subGoal
            tasks = [
                PlanTask(
                    targetNode: target,
                    description: "Approach charging station",
                    completionCondition: { [weak self] _ in
                        guard let self else { return false }
                        return self.hasReachedRechargePlatform
                    }
                ),
                PlanTask(
                    targetNode: target,
                    description: "Recharge until battery is full"
                )
            ]

        case .fetchLetter:
            goalID = "fetch-letter-\(targetID)"
            title = "Retrieve letter: \(target.name ?? "letter block")"
            tasks = [
                PlanTask(
                    targetNode: target,
                    description: "Approach letter block",
                    completionCondition: { [weak self] perception in
                        guard let self, let perception else { return false }
                        return perception.atGoal ||
                            self.planarDistance(to: target) <= self.manipulationDistance + 0.3
                    }
                ),
                PlanTask(
                    actions: [.liftObject],
                    targetNode: target,
                    description: "Pick up matching letter"
                )
            ]

        case .deliverLetter:
            goalID = "deliver-letter-\(targetID)"
            title = "Deliver carried letter to matching slot"
            tasks = [
                PlanTask(
                    targetNode: target,
                    description: "Approach matching letter slot",
                    completionCondition: { [weak self] perception in
                        guard let self, let perception else { return false }
                        return perception.atGoal ||
                            self.planarDistance(to: target) <= self.letterPlaceReach
                    }
                ),
                PlanTask(
                    actions: [.placeObject],
                    targetNode: target,
                    description: "Place letter in matching slot"
                )
            ]

        case .dogInteraction:
            goalID = "dog-interaction-\(targetID)"
            title = "Optional dog interaction"
            tasks = [
                PlanTask(
                    targetNode: target,
                    description: "Approach dog",
                    completionCondition: { [weak self] perception in
                        guard let self, let perception else { return false }
                        return perception.atGoal ||
                            self.planarDistance(to: target) <= self.manipulationDistance
                    }
                ),
                PlanTask(
                    actions: [.liftObject],
                    targetNode: target,
                    description: "Pick up dog"
                )
            ]

        case .lettersComplete, .explore:
            return
        }

        queue.upsertGoal(
            MissionQueueGoal(
                id: goalID,
                title: title,
                targetNode: target,
                subgoals: tasks
            ),
            atFront: true
        )
    }

    private func planarDistance(to node: SCNNode) -> Float {
        guard let character = characterNode else {
            return .infinity
        }

        let characterPosition = character.presentation.worldPosition
        let targetPosition = node.presentation.worldPosition

        let dx = targetPosition.x - characterPosition.x
        let dz = targetPosition.z - characterPosition.z

        return sqrt(dx * dx + dz * dz)
    }

    private func resolveMissionGoal() -> SCNNode? {
        switch missionDecision.phase {
        case .emergencyRecharge, .recharge:
            return rechargeStationNode

        case .deliverLetter:
            guard carryingLetterBlock else { return nil }
            return letterSlotTarget

        case .fetchLetter:
            guard letterTargetIndex != nil else { return nil }
            return letterBlockTarget

        case .dogInteraction:
            return carryingDog ? nil : dogTarget

        case .lettersComplete, .explore:
            return nil
        }
    }

 

        func validateMissionTarget(scene: SCNScene, isBlockInSlot: (SCNNode) -> Bool) {
            let targetName = goalNode?.name ?? "nil"
            let key = "\(missionDecision.phase.rawValue)|\(targetName)|\(carryingLetterBlock)"
            guard key != lastMissionSyncKey else { return }
            lastMissionSyncKey = key
            
            publishDebug(
                "[MISSION SYNC] phase \(missionDecision.phase.rawValue), goal \(targetName), " +
                "carrying letter \(carryingLetterBlock), power \(Int(energyManager.powerLevel))"
            )
            
            if missionDecision.phase == .emergencyRecharge, rechargeStationNode == nil {
                publishDebug("[MISSION SYNC] emergency recharge but no station found: holding, not resuming letters")
            }

            // Check if all letter blocks are successfully delivered into their destination slots
            var allBlocks: [SCNNode] = []
            scene.rootNode.enumerateChildNodes { node, _ in
                let name = (node.name ?? "").lowercased()
                if name.contains("movableblock") || name.contains("letterblock") {
                    allBlocks.append(node)
                }
            }
            
            if !allBlocks.isEmpty, allBlocks.allSatisfy({ isBlockInSlot($0) }) {
                if !hasCompletedLetterMission {
                    hasCompletedLetterMission = true
                    ca?.missionQueue.completeGoal(id: "letter_delivery_mission", because: "All letter blocks are successfully secured in their slots.")
                    
                    // Purge task queue and reset active states
                    purgeMissionQueue()
                    
                    publishDebug("[MISSION SYNC] Mission Complete: All letter blocks are in place!")
                }
            }
        }

        // MARK: - Mission Queue Purge Helper
        func purgeMissionQueue() {
            // Clear all pending or active tasks and goals from the mission queue
            ca?.missionQueue.reset()
            
                 
            publishDebug("[MISSION PURGE] Mission queue and goals purged. Frankenstein is now idle/halted.")
        }
  

    // MARK: - Navigation & Plan Update Loop

        func updateNavigation(time: TimeInterval, deltaTime: TimeInterval) {
            guard let characterNode = characterNode, let ca = ca else { return }
            let characterPos = characterNode.position
            
            // 1. Pull the current task/goal target from CA's missionQueue
            let missionQueue = ca.missionQueue
            let targetNode = missionQueue.currentTargetNode
            let targetPos = targetNode?.worldPosition
            
            // Determine destination or object positions for the spline update
            // If there's an active target node (like a pickup object or goal destination), pass its position.
            let objectPos = targetNode?.worldPosition // Or refine based on whether carrying/approaching an object
            let destinationPos = targetNode?.worldPosition ?? SCNVector3(0, 0, -6.0) // Fallback or goal destination
            
            // Check if we are approaching an object or carrying one to decide approach side
            let carrying = missionQueue.pendingActions.contains(where: { String(describing: $0).contains("lift") || String(describing: $0).contains("place") })
            
            // 2. Update the visual and navigation spline
            planSpline.update(
                time: time,
                character: characterPos,
                object: objectPos,
                destination: destinationPos,
                approachFromCharacterSide: carrying
            )
            
            // 3. Select active steering path (approach vs delivery)
            let activePath = carrying ? planSpline.deliveryPath : planSpline.approachPath
            guard !activePath.isEmpty else { return }
            
            // 4. Look ahead along the path and steer Frankenstein
            if let steeringTarget2D = planSpline.lookAheadPoint(from: characterPos, path: activePath, distance: 0.8) {
                let steeringTarget3D = SCNVector3(steeringTarget2D.x, characterPos.y, steeringTarget2D.y)
                
                // Drive locomotion steering toward the look-ahead point
                locomotion.steer(towards: steeringTarget3D, character: characterNode, deltaTime: deltaTime)
                
                // 5. Check arrival at the end of the current path segment
                if let finalPoint = activePath.last {
                    let distanceToGoal = hypot(characterPos.x - finalPoint.x, characterPos.z - finalPoint.y)
                    if distanceToGoal < 0.35 {
                        // Trigger completion or interaction when arriving at the waypoint/target
                        handleWaypointArrival(missionQueue: missionQueue, targetNode: targetNode)
                    }
                }
            }
        }

        private func handleWaypointArrival(missionQueue: MissionPlanQueue, targetNode: SCNNode?) {
            // Example: notify or complete current task/action when waypoint is reached
            if let currentTask = missionQueue.currentTask {
                if let firstAction = currentTask.actions.first {
                    missionQueue.completeAction(firstAction, target: targetNode, because: "reached waypoint via spline navigation")
                }
            }
        }

    func getFrankensteinPerception() -> String {

        var lines: [String] = []

        // Character position
        if let character = characterNode {
            let p = character.presentation.worldPosition

            lines.append("========== FRANKENSTEIN PERCEPTION ==========")

            lines.append(
                String(
                    format: "Character position: X %.2f | Y %.2f | Z %.2f",
                    Double(p.x),
                    Double(p.y),
                    Double(p.z)
                )
            )
        }

        // Mission information
        lines.append("")
        lines.append("MISSION")

        lines.append("Phase: \(missionDecision.phase)")
        lines.append("Subgoal: \(missionDecision.subGoal)")
        lines.append("Goal: \(goalNode?.name ?? "None")")
        lines.append("Carrying letter: \(carryingLetterBlock)")

        // Terrain perception
        let terrain = latestTerrainSample

        lines.append("")
        lines.append("TERRAIN PERCEPTION")

        lines.append("Terrain: \(terrain.terrain)")
        lines.append("Object: \(terrain.objectName.isEmpty ? "None" : terrain.objectName)")

        lines.append(
            String(
                format: "Distance: %.2f m",
                Double(terrain.distance)
            )
        )

        lines.append(
            String(
                format: "Obstacle height: %.2f m",
                Double(terrain.obstacleHeight)
            )
        )

        lines.append("Object movable: \(terrain.objectMovable)")
        lines.append("Can land on object: \(terrain.canLandOnObject)")

        // Directional clearance
        lines.append("")
        lines.append("DIRECTIONAL CLEARANCE")

        lines.append(
            String(format: "Ahead: %.2f m", Double(clearanceAhead))
        )

        lines.append(
            String(format: "Left: %.2f m", Double(clearanceMinus))
        )

        lines.append(
            String(format: "Right: %.2f m", Double(clearancePlus))
        )

        lines.append(
            String(format: "Heading: %.2f radians", Double(heading))
        )

        // Object detection
        lines.append("")
        lines.append("DETECTED OBJECTS")
        lines.append("Count: \(latestDetections.count)")

        for (index, object) in latestDetections.enumerated() {

            let p = object.worldPosition
            let d = object.dimensions

            lines.append(
                String(
                    format:
                        "%d. %@ | Distance %.2f m | Size %.2f × %.2f × %.2f m | Pickupable: %@",
                    index + 1,
                    object.name,
                    Double(object.distance),
                    Double(d.x),
                    Double(d.y),
                    Double(d.z),
                    object.pickupable ? "YES" : "NO"
                )
            )
        }

        // Field of view
        lines.append("")
        lines.append("VISIBLE OBJECTS")
        lines.append("Count: \(visibleObjects.count)")

        for object in visibleObjects.prefix(12) {
            lines.append(
                String(
                    format: "%@ | %.2f m",
                    object.name,
                    Double(object.distance)
                )
            )
        }

        // Raycast perception
        lines.append("")
        lines.append("RAYCAST OBSERVATIONS")
        lines.append("Count: \(latestRayObservations.count)")

        for ray in latestRayObservations.prefix(12) {
            lines.append(
                String(
                    format: "%@ -> %@ | %.2f m",
                    ray.hitNodeName,
                    ray.resolvedObjectName,
                    Double(ray.distance)
                )
            )
        }

        // Obstruction and movement state
        lines.append("")
        lines.append("OBSTRUCTION STATE")

        lines.append("Push target: \(pushTargetNode?.name ?? "None")")

        lines.append(
            String(
                format: "Stuck duration: %.2f seconds",
                Double(stuckSeconds)
            )
        )

        lines.append(
            String(
                format: "Perceived goal distance: %.2f m",
                Double(pathGoalDistance)
            )
        )

        lines.append("============================================")

        return lines.joined(separator: "\n")
    }
    private func canManipulate(_ target: SCNNode, from character: SCNNode) -> Bool {
        guard target.parent != nil, target !== carriedNode,
              !isCharacterPart(target) else { return false }
        let c = character.presentation.worldPosition
        let n = target.presentation.worldPosition
        let dx = Float(n.x - c.x)
        let dz = Float(n.z - c.z)
        let distance = sqrt(dx * dx + dz * dz)

        let isMovable = isMovableName(target.name ?? "")
        let maxDistance: Float = isMovable ? 1.8 : manipulationDistance
        guard distance.isFinite, distance > 0.001,
              distance < maxDistance else { return false }
        let forward = forwardVector()
        let length = sqrt(forward.x * forward.x + forward.z * forward.z)
        guard length > 0.001 else { return false }
        let ahead = dx * forward.x + dz * forward.z

        let minAlignment: Float = isMovable ? 0.25 : minimumManipulationAlignment
        return ahead >= (isMovable ? -0.2 : 0.05) &&
            ahead / (distance * length) >= minAlignment
    }

    private func setRechargeStationFlashing(_ flashing: Bool) {
        guard let station = rechargeStationNode else { return }

        if flashing {
            guard station.action(forKey: "flashingBlue") == nil else { return }

            let tintBlue = SCNAction.run { node in
                node.geometry?.materials.first?.diffuse.contents = UIColor.systemBlue
            }
            let tintOriginal = SCNAction.run { node in
                node.geometry?.materials.first?.diffuse.contents = UIColor.systemCyan
            }
            let wait = SCNAction.wait(duration: 0.3)

            let flashSequence = SCNAction.sequence([tintBlue, wait, tintOriginal, wait])
            let repeatAction = SCNAction.repeatForever(flashSequence)

            station.runAction(repeatAction, forKey: "flashingBlue")
        } else {
            station.removeAction(forKey: "flashingBlue")
            station.geometry?.materials.first?.diffuse.contents = UIColor.systemCyan
        }
    }

    private func reachablePickupTarget(character: SCNNode, scene: SCNScene) -> SCNNode? {
        guard carriedNode == nil, handNode != nil else { return nil }
        if let hit = nearestPickupNode(from: character, in: scene),
           let target = pickupTarget(for: hit),
           canManipulate(target, from: character),
           isPickupAllowed(target) {
            return target
        }
        let c = character.presentation.worldPosition
        return scene.rootNode.childNodes { node, _ in
            let name = node.name ?? ""
            return name.hasPrefix("LetterBlock_") || name == self.dogName
        }
        .filter { canManipulate($0, from: character) && isPickupAllowed($0) }
        .min { a, b in
            let pa = a.presentation.worldPosition
            let pb = b.presentation.worldPosition
            let da = (pa.x - c.x) * (pa.x - c.x) + (pa.z - c.z) * (pa.z - c.z)
            let db = (pb.x - c.x) * (pb.x - c.x) + (pb.z - c.z) * (pb.z - c.z)
            return da < db
        }
    }

    private func isPickupAllowed(_ node: SCNNode) -> Bool {
        if node.name == dogName {
            return currentFrameTime >= dogCooldownUntil
        }
        return true
    }

    private var canLiftNow: Bool {
        guard let character = characterNode, let scene = scene else { return false }
        return reachablePickupTarget(character: character, scene: scene) != nil
    }

    private let pickupDistance: Float = 1.25
    private let interactionDistance: Float = 1.25

    // MARK: - Initializer
    init(
        scene: SCNScene,
        characterNode: SCNNode,
        locomotion: FrankensteinLocomotion,
        energyManager: FrankensteinEnergyManager
    ) {
        self.scene = scene
        self.characterNode = characterNode
        self.locomotion = locomotion
        self.energyManager = energyManager
        super.init()
        previousCharacterPosition = characterNode.presentation.worldPosition
        hasPreviousCharacterPosition = true
    }
        func getCurrentGoalSummary() -> String {
            guard let ca = ca, let currentGoal = ca.missionQueue.currentGoal else {
                return "No active goal"
            }
            
            let subgoalDescriptions = currentGoal.subgoals.map { task in
                let actions = task.actions.map { "\($0)" }.joined(separator: ", ")
                let actionText = actions.isEmpty ? "" : " [Actions: \(actions)]"
                return "  • \(task.description)\(actionText)"
            }.joined(separator: "\n")
            
            return """
            Goal: \(currentGoal.title)
            Subgoals:
            \(subgoalDescriptions.isEmpty ? "  (No remaining subgoals)" : subgoalDescriptions)
            """
        }
    func getMissionQueuePlanString() -> String {
        guard let ca = ca else {
            return "CA not attached or simulation inactive"
        }
        
        let summary = ca.missionQueue.summary
        let pendingActionsText = ca.missionQueue.pendingActions
            .map { String(describing: $0) }
            .joined(separator: " → ")
        
        return "Mission Queue: \(summary) | Actions: \(pendingActionsText)"
    }

    // MARK: - CA Attachment
    func attachCA(_ ca: FrankensteinCA) {
        self.ca = ca
        locomotion.attachCA(ca)
        publishCAStats()
        ca.missionQueue.upsertGoal(
            MissionQueueGoal(
                id: "find-letter-f-block",
                title: "Find the letter F block",
                targetNode: nil,
                subgoals: [PlanTask(description: "Find the letter F block")]
            ),
            atFront: true
        )
    }
    /// Shows and logs the current task and all its remaining actions from CA's mission queue.
    @discardableResult
        func getCurrentTaskAndActions() -> String {
            guard let missionQueue = ca?.missionQueue else {
                let message = "Mission queue is unavailable."
                publishDebug(message)
                return message
            }

            let details: String
            if let task = missionQueue.currentTask {
                let actionList = task.actions.isEmpty
                    ? "None"
                    : task.actions.map { "\($0)" }.joined(separator: " → ")

                details = "Current Task: '\(task.description)' | Actions: [\(actionList)]"
            } else {
                details = "Current Task: None | Actions: [None]"
            }

            publishDebug(details)
            onPlanText?(details)
            return details
        }
    private func tickCA() {
        guard let ca else { return }
        ca.step()
        publishCAStats()
    }

    private func publishCAStats() {
        guard let ca else { return }
        let generation = ca.generation
        let liveCells = ca.liveCellCount
        DispatchQueue.main.async { [weak self] in
            self?.onCAStats?(generation, liveCells)
        }
    }

    // MARK: - Goal Observation
    private func makeGoalObservation(
        character: SCNNode
    ) -> FrankensteinGoalObservation? {
        let powerPercentage = energyManager.powerLevel / max(energyManager.maxPower, 1) * 100
        guard powerPercentage < 30 else { return nil }
        guard let station = effectiveRechargeStationNode else { return nil }
        let characterPosition = character.presentation.worldPosition
        let stationPosition = station.presentation.worldPosition
        let dx = Float(stationPosition.x - characterPosition.x)
        let dz = Float(stationPosition.z - characterPosition.z)
        let distance = sqrt(dx * dx + dz * dz)
        guard distance > 0.001 else {
            return FrankensteinGoalObservation(
                distance: 0,
                bearingError: 0,
                isMovingTowardGoal: true
            )
        }
        let desiredHeading = atan2(-dx, -dz)
        var bearingError = desiredHeading - heading
        while bearingError > .pi { bearingError -= 2 * .pi }
        while bearingError < -.pi { bearingError += 2 * .pi }
        return FrankensteinGoalObservation(
            distance: distance,
            bearingError: bearingError,
            isMovingTowardGoal: abs(bearingError) < 0.5
        )
    }

    // MARK: - Character Foot Offset
    private func measureCharacterFootOffset(_ character: SCNNode) -> Float {
        let rootWorldY = Float(character.presentation.worldPosition.y)
        var minimumWorldY = Float.infinity
        func visit(_ node: SCNNode) {
            if node.geometry != nil {
                let bounds = node.boundingBox
                let xs = [bounds.min.x, bounds.max.x]
                let ys = [bounds.min.y, bounds.max.y]
                let zs = [bounds.min.z, bounds.max.z]
                for x in xs {
                    for y in ys {
                        for z in zs {
                            let worldPoint = node.presentation.convertPosition(SCNVector3(x, y, z), to: nil)
                            minimumWorldY = min(minimumWorldY, Float(worldPoint.y))
                        }
                    }
                }
            }
            for child in node.childNodes { visit(child) }
        }
        visit(character)
        guard minimumWorldY.isFinite else { return 0 }
        return min(0.25, max(-0.25, minimumWorldY - rootWorldY))
    }

    // MARK: - Scene Attachment
    func attach(
        scene: SCNScene,
        characterNode: SCNNode
    ) {
        self.scene = scene
        self.characterNode = characterNode
        characterFootOffset = measureCharacterFootOffset(characterNode)
        configurePhysicsWorld(in: scene)
        addMovableBlockCourse(to: scene)
        planSpline.attach(to: scene)
        characterVerticalVelocity = 0
        hasReportedFall = false
        hasReportedRecharge = false
        previousCharacterPosition = characterNode.presentation.worldPosition
        hasPreviousCharacterPosition = true
        jumpBaseY = nil
        doorNode = findNode(containing: "door", under: scene.rootNode)
        tableNode = findNode(containing: "table", under: scene.rootNode)
        rechargeStationNode = findNode(containing: "rechargestation", under: scene.rootNode)
        qFloorGrid.attach(to: scene)
        planSpline.attach(to: scene)
        executive.field.learnedPenalty = { [weak self] world in
            self?.qFloorGrid.pathFieldPenalty(atX: world.x, z: world.y) ?? 0
        }
        addLetterPlaceholders(to: scene)
        addLetterBlocks(to: scene)
        addDog(to: scene)
        objectMemory.clear()
        seedMissionMemory(from: scene)

        setupPowerMeter(on: characterNode)
        publishDebug("Coordinator attached to displayed scene.")
    }

    private func updateStuckDuration(position: SCNVector3, deltaTime: Float) {
        guard deltaTime.isFinite, deltaTime > 0 else { return }
        if let previous = lastStuckSamplePosition {
            let dx = Float(position.x - previous.x)
            let dz = Float(position.z - previous.z)
            let moved = sqrt(dx * dx + dz * dz)
            let blocked = clearanceAhead < 0.9 || latestTerrainSample.terrain == .hurdle || latestTerrainSample.terrain == .raisedStep
            if blocked && moved < 0.015 {
                stuckSeconds = min(5, stuckSeconds + deltaTime)
            } else if moved >= 0.04 || !blocked {
                stuckSeconds = max(0, stuckSeconds - deltaTime * 2)
            }
        }
        lastStuckSamplePosition = position
    }

    private func isQGridNode(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node
        while let candidate = current {
            if candidate.name == "FrankensteinQFloorGrid" { return true }
            current = candidate.parent
        }
        return false
    }

    func attachDoor(_ node: SCNNode?) { doorNode = node }

    func attachTable(_ node: SCNNode?) {
        tableNode = node
        guard let node, let scene else { return }
        placeObjectOnSupportSurface(node, in: scene)
        configurePhysicsBody(for: node, forceDynamic: true)
        publishDebug("Table attached.")
    }

    @discardableResult
    private func placeObjectOnSupportSurface(_ node: SCNNode, in scene: SCNScene) -> Bool {
        guard let bottomY = worldBottomY(of: node),
              let surfaceY = supportSurfaceBelow(node, in: scene) else { return false }
        let correction = surfaceY - bottomY
        guard correction.isFinite, abs(correction) > 0.001 else { return true }
        let oldWorldPosition = node.presentation.worldPosition
        let correctedWorldPosition = SCNVector3(oldWorldPosition.x, oldWorldPosition.y + correction, oldWorldPosition.z)
        if let parent = node.parent {
            node.position = parent.convertPosition(correctedWorldPosition, from: nil)
        } else {
            node.position = correctedWorldPosition
        }
        node.physicsBody?.resetTransform()
        return true
    }

    private func supportSurfaceBelow(_ object: SCNNode, in scene: SCNScene) -> Float? {
        guard let bottomY = worldBottomY(of: object) else { return nil }
        let worldPosition = object.presentation.worldPosition
        let start = SCNVector3(worldPosition.x, bottomY - 0.02, worldPosition.z)
        let end = SCNVector3(worldPosition.x, bottomY - 20.0, worldPosition.z)
        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: true
        ]
        let hits = scene.rootNode.hitTestWithSegment(from: start, to: end, options: options)
        for hit in hits {
            let hitNode = hit.node
            var current: SCNNode? = hitNode
            var belongsToObject = false
            while let candidate = current {
                if candidate === object { belongsToObject = true; break }
                current = candidate.parent
            }
            guard !belongsToObject, !isCharacterPart(hitNode), !isQGridNode(hitNode), hit.worldNormal.y > 0.5 else { continue }
            let name = (hitNode.name ?? "").lowercased()
            if name.contains("marker") || name.contains("rechargestation") { continue }
            return Float(hit.worldCoordinates.y)
        }
        return nil
    }

    private func worldBottomY(of node: SCNNode) -> Float? {
        var lowest = Float.infinity
        func inspect(_ current: SCNNode) {
            if current.geometry != nil {
                let (minimum, maximum) = current.boundingBox
                let validBounds = minimum.x.isFinite && minimum.y.isFinite && minimum.z.isFinite &&
                                  maximum.x.isFinite && maximum.y.isFinite && maximum.z.isFinite &&
                                  maximum.x >= minimum.x && maximum.y >= minimum.y && maximum.z >= minimum.z
                if validBounds {
                    for x in [minimum.x, maximum.x] {
                        for y in [minimum.y, maximum.y] {
                            for z in [minimum.z, maximum.z] {
                                let world = current.presentation.convertPosition(SCNVector3(x, y, z), to: nil)
                                lowest = min(lowest, Float(world.y))
                            }
                        }
                    }
                }
            }
            for child in current.childNodes { inspect(child) }
        }
        inspect(node)
        return lowest.isFinite ? lowest : nil
    }

    func attachHand(_ node: SCNNode?) { handNode = node }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastFrameTime = 0
        lastSensorTime = 0
        lastStatsTime = 0
        publishDebug("Simulation started.")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lastFrameTime = 0
        publishDebug("Simulation stopped.")
    }

    func setRunning(_ running: Bool) {
        if running { start() } else { stop() }
    }

    func randomizeSceneObjects() {
        guard let scene = scene else { return }
        ca?.reset()
        let letterBlocks = scene.rootNode.childNodes { node, _ in
            return node.name?.hasPrefix("LetterBlock_") == true
        }
        for block in letterBlocks {
            let randomX = Float.random(in: -4.5...4.5)
            let randomZ = Float.random(in: -4.5...4.5)
            block.position = SCNVector3(randomX, 0.3, randomZ)
            if let body = block.physicsBody {
                body.velocity = SCNVector3Zero
                body.angularVelocity = SCNVector4Zero
                body.resetTransform()
            }
        }
        let movableBlocks = scene.rootNode.childNodes { node, _ in
            let name = node.name?.lowercased() ?? ""
            return name.contains("movableblock_") || name.contains("stackblock_")
        }
        for block in movableBlocks {
            let randomX = Float.random(in: -5.0...5.0)
            let randomZ = Float.random(in: -5.0...5.0)
            let randomY = Float.random(in: 0.4...1.2)
            block.position = SCNVector3(randomX, randomY, randomZ)
            if let body = block.physicsBody {
                body.velocity = SCNVector3Zero
                body.angularVelocity = SCNVector4Zero
                body.resetTransform()
            }
        }
        publishDebug("Scene objects and letter blocks randomly repositioned.")
    }

    func resetObjectLearning() {
        executive.reset()
        pathSteering = nil
        pathGoalDistance = .infinity
        goalProgressRate = 0
        lastPathDistance = .infinity
        lastPathDistanceTime = 0
        clearanceAhead = clearanceRange
        clearancePlus = clearanceRange
        clearanceMinus = clearanceRange
        latestDetections.removeAll()
        latestDetectionNodes.removeAll()
        latestRayObservations.removeAll()
        wideDetections.removeAll()
        visibleObjects.removeAll()
        pushTargetNode = nil
        pushLastNodePosition = nil
        pushAccumulatedMeters = 0
        rechargePlatformDistance = .infinity
        lastGoalDistance = .infinity
        hasReachedRechargePlatform = false
        rechargePlatformContactTime = 0
        consecutiveNoProgressCount = 0
        previousGoalStateKey = nil
        previousGoalAction = nil
        outcomeWindowElapsedTime = 0
        outcomeWindowDisplacement = 0
        outcomeWindowGoalProgress = 0
        outcomeWindowPathProgress = 0
        lastEvalPathDistance = .infinity
        lastEvaluatedActionName = ""
        lastDisplayedActionName = ""

        randomizeSceneObjects()
        energyManager.reset()
        missionSupervisor.reset()
        missionDecision = .initial
    }
    func isBlockInSlot(_ node: SCNNode) -> Bool {
        let pos = node.worldPosition
        // Letter slots are placed along z = -4.2
        let isNearTargetZ = abs(pos.z - (-4.2)) < 0.3
        // Check if it's sitting on or near the slot height (y <= 0.1)
        let isAtSlotHeight = pos.y <= 0.15
        
        return isNearTargetZ && isAtSlotHeight
    }
    func lockBlockInSlotIfReached(_ node: SCNNode) {
        if isBlockInSlot(node), let physicsBody = node.physicsBody, physicsBody.type != .static {
            physicsBody.type = .static
            node.physicsBody = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(node: node, options: nil))
        }
    }
    func executePhysicalAction(_ action: FrankensteinAction, on targetNode: SCNNode, characterNode: SCNNode) {
        guard let physicsBody = targetNode.physicsBody else { return }
        
        let charPos = characterNode.worldPosition
        let targetPos = targetNode.worldPosition
        let dx = targetPos.x - charPos.x
        let dz = targetPos.z - charPos.z
        let length = sqrt(dx * dx + dz * dz)
        
        guard length > 0.001 else { return }
        let dirX = dx / length
        let dirZ = dz / length
        
        switch action {
        case .pushObject:
            // Apply directional force impulse to slide the box out of the way
            let impulse = SCNVector3(dirX * 3.0, 0.2, dirZ * 3.0)
            physicsBody.applyForce(impulse, asImpulse: true)
            
        case .kickObject:
            // Apply a sharper, faster impulse for kicking
            let impulse = SCNVector3(dirX * 6.0, 0.4, dirZ * 6.0)
            physicsBody.applyForce(impulse, asImpulse: true)
            
        case .liftObject:
            // Switch to kinematic or elevate target relative to character
            physicsBody.type = .kinematic
            targetNode.position = SCNVector3(charPos.x, charPos.y + 1.2, charPos.z - 0.5)
            
        default:
            break
        }
    }
    // MARK: - Renderer Update
        func renderer(
            _ renderer: SCNSceneRenderer,
            updateAtTime time: TimeInterval
        ) {
            guard isRunning, let scene = scene, let character = characterNode, let characterNode2 = self.characterNode, let ca2 = self.ca else { return }

            // 1. Update Locomotion, Tasks, and Obstacle Scanning
            updateLocomotionAndObstacles(characterNode: characterNode2, ca: ca2, scene: scene, time: time)

            // 2. Process Delta Time and Energy Management
            let dt = updateEnergyAndDeltaTime(time: time)

            // 3. Run Mission Supervisors and Navigation
            runMissionAndNavigationUpdates(time: time, dt: dt)

            // 4. Sensors, Detections, and Q-Learning Grid
            processSensorsAndLearning(character: character, scene: scene, time: time, dt: dt)

            // 5. Movement, Actions, and State Evaluation
            executeCharacterActionsAndEvaluation(character: character, scene: scene, time: time, dt: dt)

            // 6. Final Status, Recharge Stations, and Stats Updates
            finalizeFrameUpdates(character: character, time: time)
        }

        // MARK: - Modular Helpers

        private func updateLocomotionAndObstacles(characterNode: SCNNode, ca: FrankensteinCA, scene: SCNScene, time: TimeInterval) {
            updateLocomotionAndTasks(
                characterNode: characterNode,
                ca: ca,
                planSpline: planSpline,
                time: time
            )
            
            let characterPos2 = characterNode.worldPosition
            let fx = -sin(characterNode.eulerAngles.y)
            let fz = -cos(characterNode.eulerAngles.y)
            
            let probeEnd2 = SCNVector3(characterPos2.x + fx * 1.2, characterPos2.y, characterPos2.z + fz * 1.2)
            let options2: [String: Any] = [
                SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue,
                SCNHitTestOption.sortResults.rawValue: true
            ]
            
            let hits = scene.rootNode.hitTestWithSegment(from: characterPos2, to: probeEnd2, options: options2)
            
            if let hit = hits.first {
                let nodeName = (hit.node.name ?? "").lowercased()
                
                // Ignore blocks that are already securely in their target slot
                if isBlockInSlot(hit.node) {
                    return
                }
                
                if nodeName.contains("movableblock") || nodeName.contains("letterblock") {
                    // Proceed with tactical override generation...
                }
            }
        }

        private func updateEnergyAndDeltaTime(time: TimeInterval) -> Float {
            currentFrameTime = time
            let dt: Float = lastFrameTime == 0 ? 1.0 / 60.0 : Float(min(max(time - lastFrameTime, 1.0 / 240.0), 0.05))
            lastFrameTime = time
            dtFromLastFrame = dt

            energyManager.isRecharging = hasReportedRecharge
            if hasReportedRecharge {
                energyManager.recharge(dt: dt)
                if energyManager.powerLevel >= energyManager.maxPower {
                    ca?.missionQueue.completeGoal(id: "recharge", because: "Battery reached full charge")
                    hasReportedRecharge = false
                    hasCompletedRechargeGoal = false
                }
            } else {
                energyManager.consumeEnergy(for: locomotion.output.action, dt: dt)
            }

            rechargeStationNode?.isHidden = false
            rechargeStationNode?.physicsBody?.categoryBitMask = 1
            return dt
        }

        private func runMissionAndNavigationUpdates(time: TimeInterval, dt: Float) {
            updateMissionSupervisor()
            updateLetterMission()
            updateMissionSupervisor()
            syncMissionQueue()
            guard let scene = self.scene else { return }
            validateMissionTarget(scene: scene, isBlockInSlot: self.isBlockInSlot)
            
            let deltaTime = time - lastFrameTime
            updateNavigation(time: time, deltaTime: max(0.001, deltaTime))

            if let textGeo = powerMeterNode?.geometry as? SCNText {
                let percentage = Int(energyManager.powerLevel)
                textGeo.string = "  Power: \(percentage)%"
                if let mat = textGeo.materials.first {
                    mat.diffuse.contents = energyManager.powerLevel > 50 ? UIColor.systemGreen : (energyManager.powerLevel > 20 ? UIColor.systemYellow : UIColor.systemRed)
                }
            }

            if time - lastCATickTime >= caTickInterval {
                lastCATickTime = time
                DispatchQueue.main.async { [weak self] in self?.tickCA() }
            }
        }

        private func processSensorsAndLearning(character: SCNNode, scene: SCNScene, time: TimeInterval, dt: Float) {
            if time - lastSensorTime >= sensorInterval {
                lastSensorTime = time
                let detailedDetections = detectAllObjectsAhead(from: character, in: scene)
                latestDetections = detailedDetections.map { $0.info }
                latestDetectionNodes = Dictionary(uniqueKeysWithValues: detailedDetections.map { (ObjectIdentifier($0.node), $0.info) })
                latestDetection = latestDetections.first
                pushTargetNode = findPushTargetNode(character: character, in: scene, detections: detailedDetections)
                var wideScanRan = false
                if time - lastWideScanTime >= wideScanInterval {
                    lastWideScanTime = time
                    wideDetections = scanWideFieldOfView(from: character, in: scene)
                    wideScanRan = true
                }
                visibleObjects = mergeVisibleObjects(near: latestDetections, wide: wideDetections, character: character)
                objectMemory.observe(visibleObjects, time: time, isMovable: isMovableName)
                if wideScanRan {
                    forgetObjectsScanConfirmsGone(
                        character: character,
                        in: scene,
                        seenNames: Set(visibleObjects.map { $0.name })
                    )
                }
                refreshMissionMemory(character: character, time: time)

                verifiedGroundSupport = verifySupportBeneathCharacter(character: character, in: scene)
                let fanObstacles = scanClearanceFan(from: character, in: scene)
                updatePathField(character: character, detections: visibleObjects, extraObstacles: fanObstacles, time: time)
                updateObjectQValues(terrain: latestTerrainSample, detections: detailedDetections)
                let nearest = latestDetections.first
                let everythingSeen = visibleObjects
                DispatchQueue.main.async { [weak self] in
                    self?.onDetectedObject?(nearest)
                    self?.onDetectedObjects?(everythingSeen)
                }
                logRayObservations()
            }

            updateTerrainSampleAndPushTargets(character: character, scene: scene)
        }

        private func updateTerrainSampleAndPushTargets(character: SCNNode, scene: SCNScene) {
            latestTerrainSample = makeTerrainSample(for: character, in: scene)
            latestTerrainSample.objectName = latestDetection?.name ?? ""
            latestTerrainSample.carryingObject = carriedNode != nil
            latestTerrainSample.objectPickupable = canLiftNow

            if let target = pushTargetNode, target.parent != nil {
                let c = character.presentation.worldPosition
                let n = target.presentation.worldPosition
                let dx = Float(n.x - c.x)
                let dz = Float(n.z - c.z)
                let targetDistance = sqrt(dx * dx + dz * dz)
                if targetDistance.isFinite && targetDistance <= 2.3 {
                    let dimensions = worldDimensions(of: target)
                    let targetTop = Float(n.y) + dimensions.y * 0.5
                    latestTerrainSample.objectMovable = true
                    latestTerrainSample.objectName = target.name ?? "MovableBlock"
                    latestTerrainSample.distance = targetDistance
                    latestTerrainSample.obstacleHeight = max(0, targetTop - latestTerrainSample.groundHeight)
                    latestTerrainSample.obstacleDepth = dimensions.z
                    latestTerrainSample.canLandOnObject = dimensions.x >= 0.3 && dimensions.z >= 0.3 &&
                        latestTerrainSample.obstacleHeight > 0.05 && latestTerrainSample.obstacleHeight <= 1.0 &&
                        hasClearSpace(around: SCNVector3(n.x, Float(targetTop + 0.15), n.z), in: scene)
                    if latestTerrainSample.obstacleHeight > 0.45 {
                        latestTerrainSample.terrain = .hurdle
                    } else if latestTerrainSample.obstacleHeight > 0.05 {
                        latestTerrainSample.terrain = .raisedStep
                    }
                }
            }
        }

        private func executeCharacterActionsAndEvaluation(character: SCNNode, scene: SCNScene, time: TimeInterval, dt: Float) {
            let currentPosition = character.presentation.worldPosition
            updateStuckDuration(position: currentPosition, deltaTime: dt)

            let actualDisplacement: Float? = hasPreviousCharacterPosition ? measureForwardDisplacement(from: previousCharacterPosition, to: currentPosition) : nil
            previousCharacterPosition = currentPosition
            hasPreviousCharacterPosition = true

            if let prediction = pendingPrediction, let actualDisplacement {
                let error = predictivePerception.observe(prediction: prediction, actualForwardDisplacement: actualDisplacement, terrain: latestTerrainSample)
                if abs(error) > 0.18 { publishDebug("Prediction error adjusted.") }
                pendingPrediction = nil
            }

            markFieldOfViewDirty(character: character, time: time)

            let perceivedValues = locomotion.policy.learnedActionValues(terrain: latestTerrainSample, body: locomotion.body)
            let perceivedActions = FrankensteinActionConstraints.allowedActions(terrain: latestTerrainSample, body: locomotion.body)
            let advisoryValues = makeAdvisoryActionValues(baseValues: perceivedValues, allowedActions: perceivedActions)
            locomotion.receivePerception(allowedActions: perceivedActions, qValues: advisoryValues)

            let objectObservation = constructObjectObservation(character: character)
            
            latestPredictions = predictivePerception.predictAll(
                actions: perceivedActions,
                terrain: latestTerrainSample,
                body: locomotion.body,
                objectObservation: objectObservation
            )

            pushPerceptionToCA(terrain: latestTerrainSample, allowedActions: perceivedActions, time: time)

            let output = locomotion.step(deltaTime: dt, terrain: latestTerrainSample, actualDisplacement: actualDisplacement, objectObservation: objectObservation)

            pendingPrediction = latestPredictions[output.action] ?? predictivePerception.predict(
                actionName: String(describing: output.action),
                terrain: latestTerrainSample,
                body: locomotion.body,
                objectObservation: objectObservation
            )

            applyMovement(output: output, deltaTime: dt, character: character, scene: scene)
            applyPush(output: output, deltaTime: dt, character: character)
            if output.action == .kickObject, currentFrameTime >= kickCooldownUntil, let target = pushTargetNode, canManipulate(target, from: character) {
                applyKick(output: output, character: character)
                kickCooldownUntil = currentFrameTime + 1.2
            }

            evaluateActionOutcome(output: output, actualDisplacement: actualDisplacement, character: character, scene: scene, time: time)
        }

        private func constructObjectObservation(character: SCNNode) -> FrankensteinObjectObservation? {
            if let planned = plannedTargetObservation() { return planned }
            if let target = pushTargetNode, target.parent != nil, let characterNode = characterNode {
                let c = characterNode.presentation.worldPosition
                let n = target.presentation.worldPosition
                let dx = Float(n.x - c.x)
                let dz = Float(n.z - c.z)
                let distance = sqrt(dx * dx + dz * dz)
                if distance.isFinite && distance <= 2.3 {
                    let size = worldDimensions(of: target)
                    return FrankensteinObjectObservation(
                        name: target.name ?? "MovableBlock",
                        width: max(0.05, size.x),
                        height: max(0.05, size.y),
                        depth: max(0.05, size.z),
                        distance: distance,
                        pickupable: pickupTarget(for: target) != nil
                    )
                }
            }
            return latestDetection.map { item in
                FrankensteinObjectObservation(
                    name: item.name,
                    width: item.dimensions.x,
                    height: item.dimensions.y,
                    depth: item.dimensions.z,
                    distance: item.distance,
                    pickupable: item.pickupable
                )
            }
        }

        private func finalizeFrameUpdates(character: SCNNode, time: TimeInterval) {
            animateCharacter(character: character)
            updateCarriedObject()
            updateDoorInteraction(executedAction: locomotion.output.action)

            let policyUpdates = locomotion.policy.updateCount
            if policyUpdates > lastRecordedQUpdate {
                let newCount = policyUpdates - lastRecordedQUpdate
                for record in locomotion.policy.qUpdateRecords.suffix(newCount) {
                    qFloorGrid.record(position: character.presentation.worldPosition, action: record.action, newValue: record.newValue)
                }
                lastRecordedQUpdate = policyUpdates
            }

            if time - lastQGridPublishTime >= 0.2 {
                lastQGridPublishTime = time
                let cells = locomotion.policy.qDisplaySnapshot(objectsInView: visibleObservations(), terrain: latestTerrainSample, body: locomotion.body)
                DispatchQueue.main.async { [weak self] in self?.onQGrid?(cells) }
            }

            updatePlanSpline(character: character, time: time)
            qFloorGrid.update(position: character.presentation.worldPosition, policy: locomotion.policy, sample: latestTerrainSample, body: locomotion.body)

            handleRechargeStationInteraction(character: character, time: time)

            if time - lastStatsTime >= statsInterval {
                lastStatsTime = time
                publishGeneralStats()
            }
        }

        private func handleRechargeStationInteraction(character: SCNNode, time: TimeInterval) {
            if let station = effectiveRechargeStationNode {
                let c = character.presentation.worldPosition
                let size = worldDimensions(of: station)
                let s = station.presentation.worldPosition
                let topY = worldTopY(of: station)
                let onTop = abs(Float(c.x - s.x)) <= max(0.15, size.x * 0.5) &&
                    abs(Float(c.z - s.z)) <= max(0.15, size.z * 0.5) &&
                    abs(Float(c.y) + characterFootOffset - topY) <= 0.18
                if onTop {
                    if !hasReportedRecharge {
                        locomotion.reportRecharge()
                        hasReportedRecharge = true
                        setRechargeStationFlashing(true)
                        reinforceOutcome(stateKey: goalStateKey(terrain: latestTerrainSample), action: locomotion.output.action, reward: 2.0)
                    }
                } else {
                    if hasReportedRecharge { setRechargeStationFlashing(false) }
                    hasReportedRecharge = false
                }
            } else {
                setRechargeStationFlashing(false)
                hasReportedRecharge = false
            }
        }
    
    

    // MARK: - CA Path Field
    private func updatePathField(
        character: SCNNode,
        detections: [DetectedObjectInfo],
        extraObstacles: [FrankensteinCAPathField.Obstacle],
        time: TimeInterval
    ) {
        let c = character.presentation.worldPosition
        let characterXZ = SIMD2<Float>(Float(c.x), Float(c.z))
        var goalXZ: SIMD2<Float>?
        if let node = goalNode {
            let known = knownPosition(of: node)
            var target = SIMD2<Float>(known.x, known.z)
            if !needsRecharge, carriedNode == nil {
                let offset = characterXZ - target
                let length = simd_length(offset)
                if length > letterFetchStandoff {
                    target += offset / length * letterFetchStandoff
                }
            }
            goalXZ = target
        }
        // The route is planned from everything Frankenstein remembers, not only
        // what is in view this frame. Memory forgets an object when a scan
        // confirms it is gone (see forgetObjectsScanConfirmsGone).
        let carriedName = carriedNode?.name
        var obstacles: [FrankensteinCAPathField.Obstacle] = []
        var memoryObstacles: [FrankensteinCAPathField.Obstacle] = []
        for entry in objectMemory.objects.values {
            if entry.name == carriedName { continue }
            let className = objectClass(for: entry.name)
            if className == "rechargeStation" || entry.name.lowercased().contains("ceiling") { continue }
            memoryObstacles.append(
                FrankensteinCAPathField.Obstacle(
                    center: SIMD2<Float>(entry.position.x, entry.position.z),
                    halfExtent: SIMD2<Float>(entry.dimensions.x * 0.5, entry.dimensions.z * 0.5),
                    className: className
                )
            )
        }
        executive.field.setObjectMemoryObstacles(memoryObstacles)
        if let scene {
            for node in scene.rootNode.childNodes(passingTest: { node, _ in
                (node.name ?? "").lowercased().contains("chasm") && node.geometry != nil
            }) {
                let box = node.boundingBox
                let p = node.worldPosition
                obstacles.append(
                    FrankensteinCAPathField.Obstacle(
                        center: SIMD2<Float>(Float(p.x), Float(p.z)),
                        halfExtent: SIMD2<Float>(Float(box.max.x - box.min.x) * 0.5, Float(box.max.z - box.min.z) * 0.5),
                        className: "wall"
                    )
                )
            }
        }
        obstacles.append(contentsOf: extraObstacles)
        executive.field.observe(obstacles, time: time)
        executive.field.rebuild(character: characterXZ, goal: goalXZ)
        pathSteering = executive.field.steering()
        pathGoalDistance = pathSteering?.pathDistance ?? .infinity

        if pathGoalDistance.isFinite, lastPathDistance.isFinite, lastPathDistanceTime > 0, time > lastPathDistanceTime {
            let instant = (lastPathDistance - pathGoalDistance) / Float(time - lastPathDistanceTime)
            if instant.isFinite {
                goalProgressRate = 0.85 * goalProgressRate + 0.15 * instant
            }
        }
        lastPathDistance = pathGoalDistance
        lastPathDistanceTime = time
    }

    private func scanClearanceFan(
        from character: SCNNode,
        in scene: SCNScene
    ) -> [FrankensteinCAPathField.Obstacle] {
        let position = character.presentation.worldPosition
        let angles: [Float] = [-60, -40, -20, 0, 20, 40, 60]
        let range = clearanceRange
        var ahead = range
        var plus = range
        var minus = range
        var points: [FrankensteinCAPathField.Obstacle] = []
        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: true
        ]
        for degrees in angles {
            let theta = heading + degrees * .pi / 180
            let dx = -sin(theta)
            let dz = -cos(theta)
            let origin = SCNVector3(position.x, position.y + 0.5, position.z)
            let end = SCNVector3(origin.x + dx * range, origin.y, origin.z + dz * range)
            let hits = scene.rootNode.hitTestWithSegment(from: origin, to: end, options: options)
            var distance = range
            for hit in hits {
                let node = hit.node
                let name = (node.name ?? "").lowercased()
                guard !isCharacterPart(node), !isFloorSurface(node), !isQGridNode(node),
                      !name.contains("marker"), !name.contains("rechargestation"),
                      !name.contains("floor"), !name.contains("ground") else { continue }
                if hit.worldNormal.y > 0.85 { continue }
                if !needsRecharge, carriedNode == nil, let fetch = letterBlockTarget,
                   fetch === node || fetch === node.parent || fetch === meaningfulDetectionParent(for: node) {
                    continue
                }
                let hx = Float(hit.worldCoordinates.x - origin.x)
                let hz = Float(hit.worldCoordinates.z - origin.z)
                let hitDistance = sqrt(hx * hx + hz * hz)
                guard hitDistance >= Self.minimumHitDistance else { continue }
                distance = min(range, hitDistance)
                let target = meaningfulDetectionParent(for: node)
                if !isContainerNode(target) {
                    let className = objectClass(for: readableName(for: target))
                    if className != "rechargeStation" {
                        points.append(
                            FrankensteinCAPathField.Obstacle(
                                center: SIMD2<Float>(Float(hit.worldCoordinates.x), Float(hit.worldCoordinates.z)),
                                halfExtent: SIMD2<Float>(0.15, 0.15),
                                className: className
                            )
                        )
                    }
                }
                break
            }
            switch degrees {
            case -20...20: ahead = min(ahead, distance)
            case 21...: plus = min(plus, distance)
            default: minus = min(minus, distance)
            }
        }
        clearanceAhead = ahead
        clearancePlus = plus
        clearanceMinus = minus
        return points
    }

    private func wrappedAngle(_ value: Float) -> Float {
        var angle = value
        while angle > .pi { angle -= 2 * .pi }
        while angle < -.pi { angle += 2 * .pi }
        return angle
    }
    func updateLocomotionAndTasks(
            characterNode: SCNNode,
            ca: FrankensteinCA,
            planSpline: FrankensteinPlanSpline,
            time: TimeInterval
        ) {
            let characterPos = characterNode.worldPosition

            // 1. Strict Precedence: Execute Task Actions First
            if let currentTask = ca.missionQueue.currentTask, !currentTask.actions.isEmpty {
                let frontAction = currentTask.actions[0]
                
                if let target = currentTask.targetNode {
                    let targetPos = target.worldPosition
                    let dx = targetPos.x - characterPos.x
                    let dz = targetPos.z - characterPos.z
                    characterNode.eulerAngles.y = atan2(dx, dz)
                    
                    // Apply physics impulse / interaction based on the action type
                    executePhysicalAction(frontAction, on: target, characterNode: characterNode)
                    
                    ca.missionQueue.completeAction(frontAction, target: target, because: "Executed physical task action")
                }
                return // Bypass spline steering while task actions are pending
            }

            // 2. Fallback to Path Spline Navigation
            let activePath = ca.missionQueue.currentGoal?.subgoals.first?.targetNode != nil
                ? planSpline.approachPath
                : planSpline.deliveryPath

            guard let targetPoint = planSpline.lookAheadPoint(from: characterPos, path: activePath, distance: 0.8) else {
                return
            }

            let currentPos = characterNode.worldPosition
            let dx = targetPoint.x - currentPos.x
            let dz = targetPoint.z - currentPos.z
            let distance = sqrt(dx * dx + dz * dz)

            guard distance > 0.01 else { return }

            let targetHeading = atan2(dx, dz)
            characterNode.eulerAngles.y = targetHeading

            let speed: Float = 2.0
            let dt: Float = 1.0 / 60.0
            characterNode.worldPosition.x += sin(targetHeading) * speed * dt
            characterNode.worldPosition.z += cos(targetHeading) * speed * dt
        }
    private func headingBand(_ error: Float) -> String {
        switch abs(error) {
        case ..<0.2: return "aligned"
        case ..<0.8: return error > 0 ? "slightPlus" : "slightMinus"
        case ..<2.4: return error > 0 ? "farPlus" : "farMinus"
        default: return "behind"
        }
    }

    private func clearanceBand(_ value: Float) -> String {
        switch value {
        case ..<0.9: return "blocked"
        case ..<2.0: return "tight"
        default: return "open"
        }
    }

    private func pushPerceptionToCA(
        terrain: FrankensteinTerrainSample,
        allowedActions: [FrankensteinAction],
        time: TimeInterval
    ) {
        guard let ca else { return }
        var perception = FrankensteinCAPerception()
        perception.carryingLetterBlock = carryingLetterBlock

        switch missionDecision.phase {
        case .emergencyRecharge, .recharge:
            perception.goal = .recharge
            perception.subGoal = missionDecision.subGoal
        case .deliverLetter, .fetchLetter:
            if let index = letterTargetIndex {
                perception.goal = .placeLetterBlock(letter: letterWord[index], targetIndex: index)
            } else {
                perception.goal = .reachPosition
            }
            perception.subGoal = missionDecision.phase == .deliverLetter ? "carry block to slot" : "fetch block"
        case .dogInteraction:
            perception.goal = .completeInteraction("hug dog")
            perception.subGoal = carryingDog ? "give love" : "pick up dog"
        case .lettersComplete, .explore:
            perception.goal = .reachPosition
            perception.subGoal = missionDecision.subGoal
        }

        var routedHeading = pathSteering?.heading ?? heading
        var hasHeadingTarget = pathSteering != nil
        if pathSteering == nil, let node = goalNode, !carryingDog {
            let known = knownPosition(of: node)
            if let c = characterNode?.presentation.worldPosition {
                let dx = known.x - Float(c.x)
                let dz = known.z - Float(c.z)
                if sqrt(dx * dx + dz * dz) > 0.35 {
                    routedHeading = atan2(-dx, -dz)
                    hasHeadingTarget = true
                }
            }
        }
        perception.headingError = hasHeadingTarget ? wrappedAngle(routedHeading - heading) : 0
        if let characterPosition = characterNode?.presentation.worldPosition,
           let error = splineHeadingError(from: characterPosition) {
            perception.headingError = error
        }
        perception.pathDistance = pathGoalDistance
        perception.isDetouring = pathSteering?.isDetouring ?? false
        perception.goalProgressRate = goalProgressRate
        perception.atGoal = hasReportedRecharge || (pathGoalDistance.isFinite && pathGoalDistance < 0.35)
        if carriedNode == nil, let character = characterNode, let blocker = pathBlocker(character: character) {
            let c = character.presentation.worldPosition
            let b = blocker.presentation.worldPosition
            let dx = Float(b.x - c.x)
            let dz = Float(b.z - c.z)
            perception.obstructionName = blocker.name ?? "obstacle"
            perception.obstructionDistance = sqrt(dx * dx + dz * dz)
            perception.obstructionAction = blocker.name == "Table" ? .kickObject : .liftObject
            perception.obstructionBlocked = stuckSeconds > 0.8
        }
        perception.clearanceAhead = clearanceAhead
        perception.clearancePlus = clearancePlus
        perception.clearanceMinus = clearanceMinus

        if let detection = latestDetection {
            perception.nearestObjectClass = objectClass(for: detection.name)
            perception.nearestObjectDistance = detection.distance
            perception.nearestObjectPickupable = detection.pickupable
            perception.nearestObjectMovable = isMovableName(detection.name)
            perception.nearestObjectName = detection.name
        }
        if let target = pushTargetNode, target.parent != nil, let character = characterNode {
            let c = character.presentation.worldPosition
            let n = target.presentation.worldPosition
            let dx = Float(n.x - c.x)
            let dz = Float(n.z - c.z)
            let distance = sqrt(dx * dx + dz * dz)
            if distance.isFinite && distance <= 2.3 {
                perception.nearestObjectClass = "movable"
                perception.nearestObjectDistance = distance
                perception.nearestObjectPickupable = pickupTarget(for: target) != nil
                perception.nearestObjectMovable = true
                perception.nearestObjectName = target.name ?? "MovableBlock"
            }
        }
        if let planned = plannedTargetObservation() {
            perception.nearestObjectClass = "movable"
            perception.nearestObjectDistance = planned.distance
            perception.nearestObjectPickupable = planned.pickupable
            perception.nearestObjectMovable = true
            perception.nearestObjectName = planned.name
        }

        let distant = visibleObjects.filter { $0.distance >= 3.0 }
        perception.distantObjectSummary = distant.isEmpty ? "" : DetectedObjectInfo.summary(of: distant, limit: 3)
        perception.routeRelativeHeadings = executive.field.routePreview(maxCells: 8).map { wrappedAngle($0 - heading) }

        let goalValues = executive.learner.values(for: goalStateKey(terrain: terrain))
        let objectValues = latestDetection.map { executive.learner.values(for: objectStateKey(for: $0, terrain: terrain)) } ?? [:]
        var advisory: [FrankensteinAction: Float] = [:]
        for action in FrankensteinAction.allCases {
            let name = String(describing: action)
            let goalVal = goalValues[name] ?? 0
            let objVal = objectValues[name] ?? 0
            advisory[action] = 0.35 * goalVal + 0.20 * objVal
        }
        if allowedActions.contains(.liftObject), canLiftNow {
            advisory[.liftObject, default: 0] += 5.0
            advisory[.jump, default: 0] -= 5.0
        }

        if !needsRecharge, carryingLetterBlock || (carriedNode == nil && letterBlockTarget != nil),
           let character = characterNode,
           let goal = carryingLetterBlock ? letterSlotTarget : letterBlockTarget {
            let c = character.presentation.worldPosition
            let g = knownPosition(of: goal)
            let dx = g.x - Float(c.x)
            let dz = g.z - Float(c.z)
            let remaining = sqrt(dx * dx + dz * dz)
            let reach = carryingLetterBlock ? letterPlaceReach + 0.6 : manipulationDistance + 0.8
            if remaining > reach, abs(perception.headingError) < 0.5, clearanceAhead > 2.0, allowedActions.contains(.run) {
                let boost: Float = carryingLetterBlock ? 3.0 : 1.5
                advisory[.run, default: 0] += boost
                advisory[.walk, default: 0] -= 0.5
            }
        }

        updatePlatformDetour(terrain: terrain, perception: &perception)

        var stepAdvice = ""
        let climbable = terrain.terrain == .raisedStep || terrain.terrain == .hurdle
        if climbable, !carryingDog, terrain.obstacleHeight > 0.03, terrain.distance.isFinite {
            let rise = terrain.obstacleHeight
            let aligned = abs(perception.headingError) < 0.6
            let isTable = terrain.objectName.lowercased() == "table"

            if rise <= 0.45, terrain.distance <= 1.0, allowedActions.contains(.stepUp), aligned {
                advisory[.stepUp, default: 0] += 6.0
                advisory[.jump, default: 0] -= 3.0
                advisory[.backward, default: 0] -= 2.0
                stepAdvice = String(format: "step up (%.2f m rise, %.2f m away)", Double(rise), Double(terrain.distance))
            } else if rise > 0.45, rise <= 1.4, terrain.canLandOnObject, !terrain.objectMovable, !isTable,
                      terrain.distance <= 0.9, !carryingLetterBlock, allowedActions.contains(.jump), aligned {
                advisory[.jump, default: 0] += 4.0
                stepAdvice = String(format: "jump onto platform (%.2f m rise)", Double(rise))
            } else if terrain.distance > 0.9, terrain.distance <= 2.0, rise <= 1.4 {
                advisory[.run, default: 0] -= 3.0
                stepAdvice = String(format: "approach step at walking pace (%.2f m away)", Double(terrain.distance))
            }
        }
        if stepAdvice != lastStepAdvice {
            lastStepAdvice = stepAdvice
            if !stepAdvice.isEmpty { publishDebug("Step ahead: \(stepAdvice)") }
        }

        if stuckSeconds > 0.8 {
            let tableAhead = terrain.objectName.lowercased() == "table"
            for action in [FrankensteinAction.walk, .run, .stepForward] {
                advisory[action, default: 0] -= 4.0
            }
            if terrain.terrain == .raisedStep, allowedActions.contains(.stepUp) {
                advisory[.stepUp, default: 0] += 4.0
            }
            if tableAhead || terrain.objectMovable {
                if allowedActions.contains(.kickObject) { advisory[.kickObject, default: 0] += 4.0 }
                if allowedActions.contains(.pushObject) { advisory[.pushObject, default: 0] += 3.0 }
            }
        }
        if let target = pushTargetNode, target.parent != nil, let character = characterNode {
            let c = character.presentation.worldPosition
            let n = target.presentation.worldPosition
            let dx = Float(n.x - c.x)
            let dz = Float(n.z - c.z)
            let distance = sqrt(dx * dx + dz * dz)
            let forward = forwardVector()
            let ahead = dx * forward.x + dz * forward.z
            let alignment = distance > 0.001 ? ahead / distance : 0
            let routeBlocked = clearanceAhead < 1.0 || terrain.terrain == .hurdle ||
                terrain.terrain == .raisedStep || (pathSteering?.isDetouring ?? false)
            if distance.isFinite, distance <= 1.0, ahead > 0.05, alignment > 0.7,
               (routeBlocked || stuckSeconds > stuckThreshold) {
                advisory[.pushObject, default: 0] += 7.0
                advisory[.jump, default: 0] -= 1.0
            } else {
                advisory[.pushObject, default: 0] -= 1.0
            }
        }

        if !carryingLetterBlock, let detection = latestDetection, detection.distance <= 2.5,
           (detection.name.lowercased().contains("recharge") || detection.name.lowercased().contains("platform")) {
            advisory[.jump, default: 0] += 4.0
            advisory[.walk, default: 0] -= 1.0
        }
        
        applyMissionPhaseInfluence(to: &advisory, perception: perception, allowedActions: allowedActions)
        perception.advisoryValues = advisory
        perception.predictedOutcomes = latestPredictions
        perception.stateKey = [
            String(describing: terrain.terrain),
            headingBand(perception.headingError),
            clearanceBand(clearanceAhead),
            perception.nearestObjectClass,
            perception.nearestObjectDistance.isFinite ? distanceBand(perception.nearestObjectDistance) : "none",
            carriedNode != nil ? "carrying" : "empty"
        ].joined(separator: "|")
        perception.timestamp = time
        ca.receivePerception(perception, allowedActions: allowedActions)
    }

    private func addLetterBlocks(to scene: SCNScene) {
        let targetWord = Array("FRANKENSTEIN")
        let blockSize: CGFloat = 0.45

        scene.rootNode.childNodes { node, _ in
            return node.name?.hasPrefix("LetterBlock_") == true
        }.forEach { $0.removeFromParentNode() }

        for (index, letter) in targetWord.enumerated() {
            let blockName = "LetterBlock_\(letter)_\(index)"
            let box = SCNBox(width: blockSize, height: blockSize, length: blockSize, chamferRadius: 0.02)
            
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(red: 0.55, green: 0.35, blue: 0.20, alpha: 1.0)
            material.specular.contents = UIColor(white: 0.15, alpha: 1.0)
            box.materials = [material]

            let node = SCNNode(geometry: box)
            node.name = blockName

            let xPos = -4.0 + Float(index % 6) * 0.8
            let zPos = 2.0 + Float(index / 6) * 0.8
            node.position = SCNVector3(xPos, 0.3, zPos)

            let shape = SCNPhysicsShape(geometry: box, options: nil)
            let body = SCNPhysicsBody(type: .dynamic, shape: shape)
            body.mass = 1.0
            body.friction = 1.2
            body.rollingFriction = 1.0
            body.restitution = 0.02
            body.damping = 0.5
            body.angularDamping = 0.9
            body.allowsResting = true
            node.physicsBody = body

            scene.rootNode.addChildNode(node)

            let floatingTextGeometry = SCNText(string: String(letter), extrusionDepth: 0.03)
            floatingTextGeometry.font = UIFont.systemFont(ofSize: 2.2, weight: .black)
            
            let floatingMaterial = SCNMaterial()
            floatingMaterial.diffuse.contents = UIColor.systemCyan
            floatingMaterial.emission.contents = UIColor.systemBlue.withAlphaComponent(0.4)
            floatingMaterial.isDoubleSided = true
            floatingTextGeometry.materials = [floatingMaterial]

            let floatingNode = SCNNode(geometry: floatingTextGeometry)
            floatingNode.name = "FloatingLetter_\(letter)"
            floatingNode.scale = SCNVector3(0.45, 0.45, 0.45)
            
            let (minBox, maxBox) = floatingTextGeometry.boundingBox
            floatingNode.pivot = SCNMatrix4MakeTranslation((minBox.x + maxBox.x) * 0.5, minBox.y, 0)
            floatingNode.position = SCNVector3(0, 0.75, 0)

            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = [.Y]
            floatingNode.constraints = [billboard]

            node.addChildNode(floatingNode)
        }
    }
      
    private func addLetterPlaceholders(to scene: SCNScene) {
        let targetWord = Array("FRANKENSTEIN")
        let slotSize: CGFloat = 0.45
        scene.rootNode.childNodes { node, _ in
            return node.name?.hasPrefix("LetterSlot_") == true
        }.forEach { $0.removeFromParentNode() }
        for (index, letter) in targetWord.enumerated() {
            let slotName = "LetterSlot_\(index)_\(letter)"
            let box = SCNBox(width: slotSize, height: 0.05, length: slotSize, chamferRadius: 0.01)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemCyan
            material.isDoubleSided = true
            box.materials = [material]
            let node = SCNNode(geometry: box)
            node.name = slotName

            let xOffset = -5.0 + Float(index) * 0.52

            node.position = SCNVector3(xOffset, 0.05, -2.5)
            node.physicsBody = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: box, options: nil))
            scene.rootNode.addChildNode(node)

            let textGeometry = SCNText(string: String(letter), extrusionDepth: 0.02)
            textGeometry.font = UIFont.systemFont(ofSize: 1.92, weight: .bold)

            let textMaterial = SCNMaterial()
            textMaterial.diffuse.contents = UIColor.white
            textGeometry.materials = [textMaterial]
            let textNode = SCNNode(geometry: textGeometry)
            textNode.scale = SCNVector3(0.3, 0.3, 0.3)
            textNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)

            let (minBox, maxBox) = textGeometry.boundingBox
            let textWidth = (maxBox.x - minBox.x) * 0.3
            let textLength = (maxBox.z - minBox.z) * 0.3
            textNode.position = SCNVector3(-textWidth * 0.5, 0.04, textLength * 0.5)

            node.addChildNode(textNode)
        }
    }

    private func setupPowerMeter(on character: SCNNode) {
        powerMeterNode?.removeFromParentNode()

        let textGeometry = SCNText(string: "  Power: 100%", extrusionDepth: 0.01)
        textGeometry.font = UIFont.systemFont(ofSize: 0.98, weight: .bold)

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGreen
        material.isDoubleSided = true
        textGeometry.materials = [material]

        let node = SCNNode(geometry: textGeometry)
        node.name = "FrankensteinPowerMeter"
        node.scale = SCNVector3(0.5, 0.5, 0.5)
        node.position = SCNVector3(-0.4, 2.3, 0)

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = [.Y]
        node.constraints = [billboard]

        character.addChildNode(node)
        powerMeterNode = node
    }

    private func makeAdvisoryActionValues(
        baseValues: [FrankensteinAction: Float],
        allowedActions: [FrankensteinAction]
    ) -> [FrankensteinAction: Float] {
        var merged = baseValues
        let goalKey = goalStateKey(terrain: latestTerrainSample)
        let goalValues = executive.learner.values(for: goalKey)
        let objectKey = latestDetection.map { objectStateKey(for: $0, terrain: latestTerrainSample) }
        let objectValues = objectKey.map { executive.learner.values(for: $0) } ?? [:]
        for action in allowedActions {
            let actionName = String(describing: action)
            let goalValue = goalValues[actionName] ?? 0
            let objectValue = objectValues[actionName] ?? 0
            merged[action, default: 0] += 0.35 * goalValue + 0.20 * objectValue
        }
        if allowedActions.contains(.liftObject), canLiftNow {
            merged[.liftObject, default: 0] += 5.0
            merged[.jump, default: 0] -= 5.0
        }
        
        if carryingDog {
            merged[.placeObject, default: 0] += dogHoldSeconds >= dogLoveSeconds ? 8.0 : -4.0
            merged[.throwObject, default: 0] -= 6.0
        }
        if !needsRecharge, carryingLetterBlock, let character = characterNode, let slot = letterSlotTarget {
            let c = character.presentation.worldPosition
            let t = slot.presentation.worldPosition
            let dx = Float(t.x - c.x)
            let dz = Float(t.z - c.z)
            let distance = sqrt(dx * dx + dz * dz)
            if distance <= letterPlaceReach {
                merged[.placeObject, default: 0] += 8.0
            } else {
                merged[.placeObject, default: 0] -= 3.0
                merged[.throwObject, default: 0] -= 3.0
            }
        }
        
        if let target = pushTargetNode, target.parent != nil, allowedActions.contains(.pushObject), let character = characterNode {
            let c = character.presentation.worldPosition
            let n = target.presentation.worldPosition
            let dx = Float(n.x - c.x)
            let dz = Float(n.z - c.z)
            let distance = sqrt(dx * dx + dz * dz)
            let forward = forwardVector()
            let ahead = dx * forward.x + dz * forward.z
            let alignment = distance > 0.001 ? ahead / distance : 0
            
            let routeBlockedNow = clearanceAhead < 1.0 || latestTerrainSample.terrain == .hurdle ||
                latestTerrainSample.terrain == .raisedStep || (pathSteering?.isDetouring ?? false) || stuckSeconds > stuckThreshold

            if distance.isFinite, distance <= 2.0, ahead > 0.05, alignment > 0.4, routeBlockedNow {
                merged[.pushObject, default: 0] += 9.0
                merged[.walk, default: 0] -= 5.0
                merged[.run, default: 0] -= 5.0
            } else {
                merged[.pushObject, default: 0] -= 1.0
            }
        }
        return merged
    }

    private func findPushTargetNode(
        character: SCNNode,
        in scene: SCNScene,
        detections: [DetailedObjectDetection]
    ) -> SCNNode? {
        let forward = forwardVector()
        let c = character.presentation.worldPosition
        var candidates: [(node: SCNNode, distance: Float, ahead: Float, side: Float)] = []
        var visited = Set<ObjectIdentifier>()
        func consider(_ node: SCNNode) {
            guard visited.insert(ObjectIdentifier(node)).inserted,
                  node !== character, !isCharacterPart(node),
                  let name = node.name, isMovableName(name) else { return }
            let lower = name.lowercased()
            if lower.contains("floor") || lower.contains("wall") || lower.contains("platform") ||
                lower.contains("stair") || lower.contains("step") || lower.contains("doorframe") {
                return
            }
            guard node.geometry != nil || !node.childNodes.isEmpty else { return }
            let n = node.presentation.worldPosition
            let dx = Float(n.x - c.x)
            let dz = Float(n.z - c.z)
            let distance = sqrt(dx * dx + dz * dz)
            let ahead = dx * forward.x + dz * forward.z
            let side = abs(dx * forward.z - dz * forward.x)
            guard distance.isFinite, ahead > 0.05, ahead <= 2.3, side < 1.0 else { return }
            candidates.append((node, distance, ahead, side))
        }
        for detection in detections { consider(detection.node) }
        func visit(_ node: SCNNode) {
            consider(node)
            for child in node.childNodes { visit(child) }
        }
        visit(scene.rootNode)
        return candidates.sorted {
            if abs($0.ahead - $1.ahead) > 0.08 { return $0.ahead < $1.ahead }
            return $0.distance < $1.distance
        }.first?.node
    }

    private func updatePlanSpline(character: SCNNode, time: TimeInterval) {
        let goal = goalNode
        let destinationNode: SCNNode?
        var direct = false
        if needsRecharge {
            destinationNode = rechargeStationNode
        } else if let goal, isLooseBlocker(goal) || goal === dogTarget {
            destinationNode = goal
            direct = true
        } else {
            destinationNode = letterSlotTarget ?? goal
        }

        guard let destinationNode else {
            planSpline.update(time: time, character: character.presentation.worldPosition, object: nil, destination: nil)
            return
        }

        let queue = ca?.missionQueue.pendingActions ?? []
        let planMovesObject = queue.contains(.pushObject) || queue.contains(.liftObject) || queue.contains(.placeObject)
        var objectPosition: SCNVector3?
        var lifting = false

        if !needsRecharge {
            if !direct, !carryingLetterBlock, let block = letterBlockTarget, block.parent != nil {
                objectPosition = block.presentation.worldPosition
                lifting = true
            }
        } else if let target = pushTargetNode, target.parent != nil {
            objectPosition = target.presentation.worldPosition
        } else if planMovesObject {
            objectPosition = visibleObjects.filter { isMovableName($0.name) }.min(by: { $0.distance < $1.distance })?.worldPosition
        }

        planSpline.update(
            time: time,
            character: character.presentation.worldPosition,
            object: objectPosition,
            destination: destinationNode.presentation.worldPosition,
            approachFromCharacterSide: lifting
        )
    }

    private func visibleObservations() -> [FrankensteinObjectObservation] {
        visibleObjects.prefix(12).map { item in
            FrankensteinObjectObservation(
                name: item.name,
                width: item.dimensions.x,
                height: item.dimensions.y,
                depth: item.dimensions.z,
                distance: item.distance,
                pickupable: item.pickupable
            )
        }
    }

    private func markFieldOfViewDirty(character: SCNNode, time: TimeInterval) {
        let policy = locomotion.policy
        policy.visionTime = time
        policy.currentGoalCategory = ca?.goalContext.goal.category ?? "recharge"
        policy.markVisibleDirty(terrain: latestTerrainSample, body: locomotion.body)
        policy.markVisibleDirty(objects: visibleObservations(), terrain: latestTerrainSample, body: locomotion.body)
        qFloorGrid.markVisible(
            position: character.presentation.worldPosition,
            heading: Float(character.presentation.eulerAngles.y),
            halfAngle: wideScanHalfAngleDegrees * .pi / 180,
            range: 6
        )
    }

    private func knownPosition(of node: SCNNode) -> SIMD3<Float> {
        if let entry = objectMemory.recall(node.name) {
            return entry.position
        }
        let p = node.presentation.worldPosition
        return SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
    }

    private func rememberNode(_ node: SCNNode, time: TimeInterval) {
        guard let name = node.name else { return }
        let p = node.presentation.worldPosition
        let d = worldDimensions(of: node)
        objectMemory.remember(
            name: name,
            position: SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)),
            dimensions: SIMD3<Float>(Float(d.x), Float(d.y), Float(d.z)),
            pickupable: pickupTarget(for: node) != nil,
            movable: isMovableName(name),
            time: time
        )
    }

    private func seedMissionMemory(from scene: SCNScene) {
        for node in scene.rootNode.childNodes(passingTest: { node, _ in
            let name = node.name ?? ""
            return name.hasPrefix("LetterBlock_") || name.hasPrefix("LetterSlot_") || name == self.dogName
        }) {
            rememberNode(node, time: 0)
        }
    }

    /// Farthest remembered object a scan is trusted to confirm as gone.
    private let memoryForgetRange: Float = 8

    /// A remembered object is dropped only when it is inside the scan cone and
    /// a ray to its last known position reaches that spot without meeting
    /// anything. An object behind another one is occluded, not gone, so it is
    /// kept. Objects outside the cone are kept until they are looked at again.
    private func forgetObjectsScanConfirmsGone(
        character: SCNNode,
        in scene: SCNScene,
        seenNames: Set<String>
    ) {
        let c = character.presentation.worldPosition
        let halfAngle = wideScanHalfAngleDegrees * .pi / 180
        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: true
        ]

        for entry in Array(objectMemory.objects.values) where !seenNames.contains(entry.name) {
            let dx = entry.position.x - Float(c.x)
            let dz = entry.position.z - Float(c.z)
            let distance = sqrt(dx * dx + dz * dz)
            guard distance.isFinite, distance > 0.3, distance <= memoryForgetRange else { continue }

            let bearing = wrappedAngle(atan2(-dx, -dz) - heading)
            guard abs(bearing) <= halfAngle else { continue }

            let rayY = entry.position.y + max(0.05, entry.dimensions.y * 0.25)
            let origin = SCNVector3(Float(c.x), rayY, Float(c.z))
            let end = SCNVector3(entry.position.x, rayY, entry.position.z)
            let hits = scene.rootNode.hitTestWithSegment(from: origin, to: end, options: options)

            var blocked = false
            for hit in hits {
                let hitNode = hit.node
                guard !isCharacterPart(hitNode), !isFloorSurface(hitNode), !isQGridNode(hitNode) else { continue }
                let target = pickupTarget(for: hitNode) ?? meaningfulDetectionParent(for: hitNode)
                guard !isContainerNode(target), !isCharacterPart(target) else { continue }

                let hx = Float(hit.worldCoordinates.x - c.x)
                let hz = Float(hit.worldCoordinates.z - c.z)
                if sqrt(hx * hx + hz * hz) < distance + 0.1 {
                    blocked = true
                    break
                }
            }

            if !blocked {
                objectMemory.forget(entry.name)
                publishDebug("[OBJECT MEMORY] forgot \(entry.name): scan reached its last position and found nothing")
            }
        }
    }

    private func refreshMissionMemory(character: SCNNode, time: TimeInterval) {
        let c = character.presentation.worldPosition
        let inView = Set(visibleObjects.map { $0.name })
        let targets: [SCNNode?] = [letterBlockTarget, letterSlotTarget, dogTarget]
        for case let node? in targets where node.parent != nil {
            guard let name = node.name else { continue }
            let p = node.presentation.worldPosition
            let dx = Float(p.x - c.x)
            let dz = Float(p.z - c.z)
            let close = sqrt(dx * dx + dz * dz) <= memoryRefreshRange
            if inView.contains(name) || close || objectMemory.recall(name) == nil {
                rememberNode(node, time: time)
            }
        }
        if let held = carriedNode {
            rememberNode(held, time: time)
        }
    }

    private func plannedTargetObservation() -> FrankensteinObjectObservation? {
        guard !needsRecharge, carriedNode == nil, let character = characterNode else { return nil }
        let target: SCNNode?
        if let dog = dogTarget {
            target = dog
        } else if letterTargetIndex != nil {
            target = letterBlockTarget
        } else {
            target = nil
        }
        guard let target, target.parent != nil, let entry = objectMemory.recall(target.name) else { return nil }
        let c = character.presentation.worldPosition
        let dx = entry.position.x - Float(c.x)
        let dz = entry.position.z - Float(c.z)
        let distance = sqrt(dx * dx + dz * dz)
        guard distance.isFinite, distance <= 2.3 else { return nil }
        return FrankensteinObjectObservation(
            name: entry.name,
            width: max(0.05, entry.dimensions.x),
            height: max(0.05, entry.dimensions.y),
            depth: max(0.05, entry.dimensions.z),
            distance: distance,
            pickupable: entry.pickupable
        )
    }

    private func letter(ofBlock node: SCNNode) -> Character? {
        guard let name = node.name, name.hasPrefix("LetterBlock_") else { return nil }
        let parts = name.split(separator: "_")
        guard parts.count >= 2, let letter = parts[1].first else { return nil }
        return letter
    }

    private func letterSlotNode(index: Int) -> SCNNode? {
        guard let scene, letterWord.indices.contains(index) else { return nil }
        return scene.rootNode.childNode(withName: "LetterSlot_\(index)_\(letterWord[index])", recursively: true)
    }

    private func letterSlotIndex(forCarried block: SCNNode) -> Int? {
        guard let letter = letter(ofBlock: block) else { return nil }
        return letterWord.indices.first { energyManager.placedLetters[$0] == nil && letterWord[$0] == letter }
    }

    private func looseLetterBlock(forLetter letter: Character, atIndex index: Int) -> SCNNode? {
        guard let scene else { return nil }
        if let exactMatch = scene.rootNode.childNodes(passingTest: { node, _ in
            node !== self.carriedNode && node.name == "LetterBlock_\(letter)_\(index)"
        }).first {
            return exactMatch
        }
        return scene.rootNode.childNodes(passingTest: { node, _ in
            node !== self.carriedNode && node.parent != nil && self.letter(ofBlock: node) == letter
        }).first
    }

    private func updateLetterMission() {
        guard let scene, let character = characterNode else { return }
        guard !needsRecharge else { return }

        if carryingLetterBlock, !wasCarryingLetter {
            carryStartTime = currentFrameTime
            reinforceOutcome(stateKey: goalStateKey(terrain: latestTerrainSample), action: .liftObject, reward: 1.5)
        }
        wasCarryingLetter = carryingLetterBlock

        for index in letterWord.indices where energyManager.placedLetters[index] == nil {
            guard let slot = letterSlotNode(index: index) else { continue }
            let sp = slot.presentation.worldPosition
            let expectedLetter = letterWord[index]

            if let block = looseLetterBlock(forLetter: expectedLetter, atIndex: index), block.parent != nil {
                let bp = block.presentation.worldPosition
                let dx = Float(bp.x - sp.x)
                let dz = Float(bp.z - sp.z)

                if sqrt(dx * dx + dz * dz) <= letterSlotTolerance, Float(bp.y) < Float(sp.y) + 0.6 {
                    finalizePlacedLetter(block, index: index, slot: slot)
                }
            }
        }

        let c = character.presentation.worldPosition
        updateDogLove(character: character)

        if carryingDog {
            dogTarget = nil
            runAssist(character: character)
            return
        }

        if let held = carriedNode, let index = letterSlotIndex(forCarried: held) {
            letterTargetIndex = index
            letterBlockTarget = held
            letterSlotTarget = letterSlotNode(index: index)
            dogTarget = nil
            runAssist(character: character)
            return
        }

        dogTarget = nil

        let letterBlockRemains = letterWord.indices.contains { index in
            energyManager.placedLetters[index] == nil && looseLetterBlock(forLetter: letterWord[index], atIndex: index)?.parent != nil
        }

        if carriedNode == nil, !letterBlockRemains, currentFrameTime >= dogCooldownUntil,
           let dog = scene.rootNode.childNode(withName: dogName, recursively: true), dog.parent != nil {
            let p = dog.presentation.worldPosition
            let dx = Float(p.x - c.x)
            let dz = Float(p.z - c.z)
            if sqrt(dx * dx + dz * dz) <= dogDetourRange {
                dogTarget = dog
            }
        }

        var nextTarget: (index: Int, block: SCNNode, slot: SCNNode)?
        for index in letterWord.indices where energyManager.placedLetters[index] == nil {
            let letter = letterWord[index]
            if let block = looseLetterBlock(forLetter: letter, atIndex: index), block.parent != nil,
               let slot = letterSlotNode(index: index) {
                nextTarget = (index, block, slot)
                break
            }
        }

        if let nextTarget {
            letterTargetIndex = nextTarget.index
            letterBlockTarget = nextTarget.block
            letterSlotTarget = nextTarget.slot
        } else {
            letterTargetIndex = nil
            letterBlockTarget = nil
            letterSlotTarget = nil
        }

        runAssist(character: character)
    }

    private var lastStepAdvice = ""
    private var carryStartTime: TimeInterval?
    private var wasCarryingLetter = false
    private var deliveryStreak = 0
    private var lastDeliveryTime: TimeInterval = -100

    private func finalizePlacedLetter(_ block: SCNNode, index: Int, slot: SCNNode) {
        guard energyManager.placedLetters[index] == nil else { return }
        let letterChar = letterWord[index]
        let sp = slot.presentation.worldPosition

        block.position = SCNVector3(
            sp.x,
            sp.y + worldDimensions(of: slot).y * 0.5 + worldDimensions(of: block).y * 0.5 + 0.005,
            sp.z
        )
        if let body = block.physicsBody {
            body.velocity = SCNVector3Zero
            body.angularVelocity = SCNVector4Zero
            body.type = .kinematic
            body.resetTransform()
        }

        objectMemory.forget(block.name ?? "")
        block.name = "PlacedLetter_\(letterChar)_\(index)"
        energyManager.placedLetters[index] = letterChar

        let elapsed = carryStartTime.map { Float(currentFrameTime - $0) } ?? 10
        let speedBonus = max(0, 8 - elapsed) * 0.25
        deliveryStreak = (currentFrameTime - lastDeliveryTime < 40) ? deliveryStreak + 1 : 1
        lastDeliveryTime = currentFrameTime
        carryStartTime = nil
        let streakBonus = min(2.0, 0.5 * Float(deliveryStreak - 1))

        reinforceOutcome(
            stateKey: goalStateKey(terrain: latestTerrainSample),
            action: locomotion.output.action,
            reward: 3.0 + speedBonus + streakBonus
        )
        publishDebug("Delivered \(letterChar) (slot \(index + 1)) in \(String(format: "%.1f", Double(elapsed))) s, streak \(deliveryStreak)")
    }

    private func faceToward(_ node: SCNNode, character: SCNNode) {
        let p = knownPosition(of: node)
        let c = character.presentation.worldPosition
        let dx = p.x - Float(c.x)
        let dz = p.z - Float(c.z)
        guard sqrt(dx * dx + dz * dz) > 0.05 else { return }
        let desired = atan2(-dx, -dz)
        heading = desired
        locomotion.setHeading(desired)
        character.eulerAngles.y = desired
    }

    private func runAssist(character: SCNNode) {
        let c = character.presentation.worldPosition
        func planarDistance(to node: SCNNode) -> Float {
            let p = knownPosition(of: node)
            let dx = p.x - Float(c.x)
            let dz = p.z - Float(c.z)
            return sqrt(dx * dx + dz * dz)
        }

        if carryingDog {
            if dogHoldSeconds >= dogLoveSeconds + 0.5 {
                _ = placeCarriedObjectAhead()
            }
            return
        }

        if let held = carriedNode, letter(ofBlock: held) == nil, held.name != dogName {
            let direction = blockerThrowDirection ?? SIMD2<Float>(-cos(heading), sin(heading))
            if dropCarriedObject(distance: blockerThrowDistance, thrown: true, direction: direction) {
                blockerThrowDirection = nil
                showAssistNote("Threw \(held.name ?? "block") off the path")
            }
            return
        }

        if let blocker = pathBlocker(character: character) {
            ca?.missionQueue.pushTacticalOverride(
                PlanTask(
                    targetNode: blocker,
                    description: "Clear obstacle: \(blocker.name ?? "obstacle")",
                    completionCondition: { perception in
                        guard let perception else { return false }
                        return perception.clearanceAhead > 1.8 || perception.obstructionName.isEmpty
                    }
                ),
                reason: "\(blocker.name ?? "obstacle") on the route"
            )
            if clearBlocker(blocker, character: character) {
                return
            }
        } else {
            ca?.missionQueue.completeTopTacticalTask(
                matchingDescriptionPrefix: "Clear obstacle:",
                because: "route is clear"
            )
        }

        if carryingLetterBlock {
            if let slot = letterSlotTarget, planarDistance(to: slot) <= letterPlaceReach {
                _ = placeCarriedObjectAhead()
            }
        } else if let node = letterBlockTarget ?? dogTarget, node.parent != nil {
            let reach = planarDistance(to: node)
            if reach <= manipulationDistance + 0.3 {
                faceToward(node, character: character)
            }
            if reach <= manipulationDistance {
                _ = attemptPickup()
            }
        }
    }

    private let blockerThrowDistance: Float = 1.8
    private let blockerPathClearance: Float = 0.65
    private var blockerThrowDirection: SIMD2<Float>?

    private func isLooseBlocker(_ node: SCNNode) -> Bool {
        guard node.parent != nil, node !== carriedNode, let name = node.name else { return false }
        return name.hasPrefix("MovableBlock") || name.hasPrefix("StackBlock") || name == "Table"
    }

    private func blockerClearance(_ node: SCNNode) -> Float {
        node.name == "Table" ? 1.0 : blockerPathClearance
    }

    private func distance(from point: SIMD2<Float>, toPolyline path: [SIMD2<Float>]) -> Float {
        guard path.count >= 2 else { return path.first.map { simd_distance(point, $0) } ?? .infinity }
        var best = Float.infinity
        for k in 0..<(path.count - 1) {
            let a = path[k]
            let b = path[k + 1]
            let ab = b - a
            let lengthSquared = simd_dot(ab, ab)
            let t = lengthSquared > 1e-6 ? min(1, max(0, simd_dot(point - a, ab) / lengthSquared)) : 0
            best = min(best, simd_distance(point, a + ab * t))
        }
        return best
    }

    private func pathBlocker(character: SCNNode) -> SCNNode? {
        guard let scene else { return nil }
        let c = character.presentation.worldPosition
        let start = SIMD2<Float>(Float(c.x), Float(c.z))

        if stuckSeconds > 0.8, let table = scene.rootNode.childNode(withName: "Table", recursively: false), table.parent != nil {
            let t = table.presentation.worldPosition
            let dx = Float(t.x - c.x), dz = Float(t.z - c.z)
            if sqrt(dx * dx + dz * dz) <= 1.6 { return table }
        }

        let goal: SCNNode? = carryingLetterBlock ? letterSlotTarget : letterBlockTarget
        guard let goal, goal.parent != nil else { return nil }
        let g = knownPosition(of: goal)
        let goalXZ = SIMD2<Float>(g.x, g.z)

        var path: [SIMD2<Float>] = [start, goalXZ]
                if !carryingLetterBlock, planSpline.approachPath.count >= 2 {
                    path = planSpline.approachPath.map { SIMD2<Float>($0.x, $0.z) }
                }

        let goalTop = Float(goal.presentation.worldPosition.y)
        let candidates = scene.rootNode.childNodes { node, _ in self.isLooseBlocker(node) }

        var best: (node: SCNNode, distance: Float)?
        for node in candidates {
            let p = node.presentation.worldPosition
            let xz = SIMD2<Float>(Float(p.x), Float(p.z))
            let fromHim = simd_distance(xz, start)
            guard fromHim <= 2.5 else { continue }

            let onTopOfTarget = !carryingLetterBlock && simd_distance(xz, goalXZ) <= 0.45 && Float(p.y) > goalTop + 0.2
            let blocked = stuckSeconds > 0.8
            let forward = forwardVector()
            let inFront = (xz.x - start.x) * forward.x + (xz.y - start.y) * forward.z > 0
            let corridor = blockerClearance(node) * (blocked ? 1.8 : 1.0)
            let onPath = (distance(from: xz, toPolyline: path) <= corridor || (blocked && inFront && fromHim <= 1.6)) &&
                simd_distance(xz, goalXZ) > 0.3

            guard onTopOfTarget || onPath else { continue }
            if best == nil || fromHim < best!.distance {
                best = (node, fromHim)
            }
        }
        return best?.node
    }

    @discardableResult
    private func clearBlocker(_ blocker: SCNNode, character: SCNNode) -> Bool {
        let c = character.presentation.worldPosition
        let b = blocker.presentation.worldPosition
        let reach = sqrt(Float((b.x - c.x) * (b.x - c.x)) + Float((b.z - c.z) * (b.z - c.z)))
        let isTable = blocker.name == "Table"
        guard reach <= (isTable ? 1.7 : 1.1) else { return false }
        if kickCooldownUntil > currentFrameTime { return false }

        let aside = asideDirection(for: blocker, character: character)

        if !isTable, carriedNode == nil, canManipulate(blocker, from: character),
           pickupTarget(for: blocker) != nil, attemptPickup(of: blocker) {
            blockerThrowDirection = aside
            return true
        }

        configurePhysicsBody(for: blocker, forceDynamic: true)
        guard let body = blocker.physicsBody else { return false }
        body.type = .dynamic
        let speed: Float = isTable ? 3.2 : 2.0
        body.velocity = SCNVector3(aside.x * speed, isTable ? 1.2 : 0.6, aside.y * speed)
        body.angularVelocity = SCNVector4Zero
        kickCooldownUntil = currentFrameTime + 1.2
        showAssistNote("Kicked \(blocker.name ?? "obstacle") out of the path")
        return true
    }

    private func asideDirection(for blocker: SCNNode, character: SCNNode) -> SIMD2<Float> {
        let c = character.presentation.worldPosition
        let b = blocker.presentation.worldPosition
        let goal: SCNNode? = carryingLetterBlock ? letterSlotTarget : letterBlockTarget
        var toGoal = SIMD2<Float>(-sin(heading), -cos(heading))
        if let goal {
            let g = knownPosition(of: goal)
            let delta = SIMD2<Float>(g.x - Float(c.x), g.z - Float(c.z))
            if simd_length(delta) > 0.001 { toGoal = simd_normalize(delta) }
        }
        let offset = SIMD2<Float>(Float(b.x - c.x), Float(b.z - c.z))
        let side = toGoal.x * offset.y - toGoal.y * offset.x
        return side >= 0 ? SIMD2<Float>(-toGoal.y, toGoal.x) : SIMD2<Float>(toGoal.y, -toGoal.x)
    }

    private var kickCooldownUntil: TimeInterval = 0

    private func showAssistNote(_ text: String) {
        publishDebug(text)
    }

    private func updateDogLove(character: SCNNode) {
        let dt = dtFromLastFrame
        if carryingDog {
            dogHoldSeconds += dt
            energyManager.love = min(100, energyManager.love + 12 * dt)
            showLoveHearts(true, on: character)
        } else {
            if wasCarryingDog {
                dogCooldownUntil = currentFrameTime + dogCooldownSeconds
            }
            dogHoldSeconds = 0
            showLoveHearts(false, on: character)
        }
        wasCarryingDog = carryingDog
    }

    private func showLoveHearts(_ visible: Bool, on character: SCNNode) {
        if loveHeartsNode == nil {
            let text = SCNText(string: " ", extrusionDepth: 0.01)
            text.font = UIFont.systemFont(ofSize: 0.6)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemPink
            material.emission.contents = UIColor.systemPink
            text.materials = [material]
            let node = SCNNode(geometry: text)
            node.name = "LoveHeartsMarker"
            node.scale = SCNVector3(0.5, 0.5, 0.5)
            let (minBox, maxBox) = text.boundingBox
            node.pivot = SCNMatrix4MakeTranslation((minBox.x + maxBox.x) * 0.5, 0, 0)
            node.position = SCNVector3(0, 2.4, 0)
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .Y
            node.constraints = [billboard]
            let bob = SCNAction.sequence([
                SCNAction.moveBy(x: 0, y: 0.15, z: 0, duration: 0.5),
                SCNAction.moveBy(x: 0, y: -0.15, z: 0, duration: 0.5)
            ])
            node.runAction(SCNAction.repeatForever(bob))
            character.addChildNode(node)
            loveHeartsNode = node
        }
        loveHeartsNode?.isHidden = !visible
    }

    private func addDog(to scene: SCNScene) {
        scene.rootNode.childNode(withName: dogName, recursively: false)?.removeFromParentNode()
        let dog = SCNNode()
        dog.name = dogName
        func part(_ geometry: SCNGeometry, _ color: UIColor, _ position: SCNVector3) -> SCNNode {
            let material = SCNMaterial()
            material.diffuse.contents = color
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.position = position
            return node
        }
        let fur = UIColor(red: 0.62, green: 0.40, blue: 0.22, alpha: 1)
        let dark = UIColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1)
        dog.addChildNode(part(SCNBox(width: 0.22, height: 0.20, length: 0.46, chamferRadius: 0.06), fur, SCNVector3(0, 0, 0)))
        dog.addChildNode(part(SCNSphere(radius: 0.12), fur, SCNVector3(0, 0.10, -0.28)))
        dog.addChildNode(part(SCNBox(width: 0.06, height: 0.12, length: 0.04, chamferRadius: 0.01), dark, SCNVector3(-0.07, 0.24, -0.28)))
        dog.addChildNode(part(SCNBox(width: 0.06, height: 0.12, length: 0.04, chamferRadius: 0.01), dark, SCNVector3(0.07, 0.24, -0.28)))
        dog.addChildNode(part(SCNSphere(radius: 0.04), dark, SCNVector3(0, 0.08, -0.39)))
        dog.addChildNode(part(SCNCylinder(radius: 0.025, height: 0.22), fur, SCNVector3(0, 0.12, 0.28)))
        if let tail = dog.childNodes.last {
            tail.eulerAngles = SCNVector3(0.9, 0, 0)
            let wag = SCNAction.sequence([
                SCNAction.rotateBy(x: 0, y: 0, z: 0.5, duration: 0.15),
                SCNAction.rotateBy(x: 0, y: 0, z: -0.5, duration: 0.15)
            ])
            tail.runAction(SCNAction.repeatForever(wag))
        }
        dog.position = SCNVector3(1.5, 0.15, 5.0)
        let shape = SCNPhysicsShape(
            shapes: [SCNPhysicsShape(geometry: SCNBox(width: 0.24, height: 0.24, length: 0.7, chamferRadius: 0), options: nil)],
            transforms: [NSValue(scnMatrix4: SCNMatrix4MakeTranslation(0, 0.05, -0.05))]
        )
        let body = SCNPhysicsBody(type: .dynamic, shape: shape)
        body.mass = 1.0
        body.friction = 0.8
        body.angularDamping = 0.9
        dog.physicsBody = body
        scene.rootNode.addChildNode(dog)
    }

    private func addMovableBlockCourse(to scene: SCNScene) {
        guard !spawnedMovableBlocks else { return }
        spawnedMovableBlocks = true
        let existing = scene.rootNode.childNodes(passingTest: { node, _ in
            let name = node.name?.lowercased() ?? ""
            return name.contains("movableblock_") || name.contains("stackblock_")
        })
        guard existing.isEmpty else { return }
        let blockSize: CGFloat = 0.8
        let placements: [(name: String, x: Float, y: Float, z: Float)] = [
            ("MovableBlock_01", 3.7, 0.4, 4.6),
            ("MovableBlock_02", 4.6, 0.4, 4.6),
            ("MovableBlock_03", 3.7, 0.4, 3.7),
            ("StackBlock_04", -3.8, 0.4, 2.8),
            ("StackBlock_05", -4.7, 0.4, 2.8),
            ("StackBlock_06", -3.8, 1.2, 2.8),
            ("MovableBlock_07", 3.8, 0.4, -1.8),
            ("MovableBlock_08", 4.7, 0.4, -1.8),
            ("MovableBlock_09", -3.8, 0.4, -4.5),
            ("MovableBlock_10", -4.7, 0.4, -4.5)
        ]
        for placement in placements {
            let box = SCNBox(width: blockSize, height: blockSize, length: blockSize, chamferRadius: 0.035)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(red: 0.55, green: 0.35, blue: 0.20, alpha: 1.0)
            material.specular.contents = UIColor(white: 0.15, alpha: 1.0)
            box.materials = [material]
            let node = SCNNode(geometry: box)
            node.name = placement.name
            node.position = SCNVector3(placement.x, placement.y, placement.z)
            node.physicsBody = SCNPhysicsBody(type: .dynamic, shape: SCNPhysicsShape(geometry: box, options: nil))
            node.physicsBody?.mass = 1.2
            node.physicsBody?.friction = 0.3
            node.physicsBody?.rollingFriction = 0.3
            node.physicsBody?.restitution = 0.02
            node.physicsBody?.damping = 0.15
            node.physicsBody?.angularDamping = 0.3
            node.physicsBody?.allowsResting = true
            scene.rootNode.addChildNode(node)
        }
        publishDebug("Added 10 movable blocks.")
    }

    private func isMovableName(_ name: String) -> Bool {
        let value = name.lowercased()
        if value.hasPrefix("letterblock_") || value.hasPrefix("placedletter_") { return false }
        return value.contains("movable") || value.contains("block") || value.contains("crate") ||
            value.contains("box") || value.contains("pickup") || value.contains("stackblock") || value == "table"
    }

    private func isLetterBlockName(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix("LetterBlock_") || name.hasPrefix("PlacedLetter_")
    }

    private func annotateBearing(_ info: DetectedObjectInfo, character: SCNNode) -> DetectedObjectInfo {
        let c = character.presentation.worldPosition
        let dx = info.worldPosition.x - c.x
        let dz = info.worldPosition.z - c.z
        var annotated = info
        if dx * dx + dz * dz > 0.0001 {
            annotated.bearing = wrappedAngle(atan2(-dx, -dz) - heading)
        }
        return annotated
    }

    private func mergeVisibleObjects(
        near: [DetectedObjectInfo],
        wide: [DetectedObjectInfo],
        character: SCNNode
    ) -> [DetectedObjectInfo] {
        var merged = wide.map { annotateBearing($0, character: character) }
        for item in near {
            let duplicate = merged.contains {
                $0.name == item.name &&
                abs(Float($0.worldPosition.x - item.worldPosition.x)) < 0.15 &&
                abs(Float($0.worldPosition.z - item.worldPosition.z)) < 0.15
            }
            if !duplicate {
                merged.append(annotateBearing(item, character: character))
            }
        }
        return merged.sorted { $0.distance < $1.distance }
    }

    private func scanWideFieldOfView(
            from character: SCNNode,
            in scene: SCNScene
        ) -> [DetectedObjectInfo] {
            let position = character.presentation.worldPosition
            let options: [String: Any] = [
                SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
                SCNHitTestOption.backFaceCulling.rawValue: true
            ]
            var nearestByNode: [ObjectIdentifier: DetectedObjectInfo] = [:]
            var angle = -wideScanHalfAngleDegrees
            while angle <= wideScanHalfAngleDegrees + 0.01 {
                let theta = heading + angle * .pi / 180
                let dx = -sin(theta)
                let dz = -cos(theta)
                for rayHeight in wideScanHeights {
                    let origin = SCNVector3(position.x, position.y + rayHeight, position.z)
                    let end = SCNVector3(origin.x + dx * wideScanRange, origin.y, origin.z + dz * wideScanRange)
                    let hits = scene.rootNode.hitTestWithSegment(from: origin, to: end, options: options)
                    for hit in hits {
                        let hitNode = hit.node
                        let lowered = (hitNode.name ?? "").lowercased()
                        guard !isCharacterPart(hitNode), !isFloorSurface(hitNode),
                              !isQGridNode(hitNode), !lowered.contains("marker") else { continue }
                        
                        let hx = hit.worldCoordinates.x - position.x
                        let hz = hit.worldCoordinates.z - position.z
                        let hitDistance = sqrt(hx * hx + hz * hz)
                        guard hitDistance >= Self.minimumHitDistance else { continue }
                        
                        let target: SCNNode = pickupTarget(for: hitNode) ?? meaningfulDetectionParent(for: hitNode)
                        guard !isContainerNode(target), !isCharacterPart(target), target !== character else { continue }
                        
                        let dimensions = worldDimensions(of: target)
                        guard dimensions.x > 0.001, dimensions.y > 0.001, dimensions.z > 0.001,
                              max(dimensions.x, max(dimensions.y, dimensions.z)) <= wideScanMaximumExtent else { continue }
                        
                        let resolvedName = target.name ?? hitNode.name ?? "object"
                        let lowerName = resolvedName.lowercased()
                        let isMovable = lowerName.contains("movable") || lowerName.contains("crate")

                        let rawInfo = DetectedObjectInfo(
                            name: resolvedName,
                            distance: hitDistance,
                            bearing: 0.0, // Will be updated by annotateBearing
                            dimensions: dimensions,
                            worldPosition: target.presentation.worldPosition,
                            pickupable: pickupTarget(for: target) != nil,
                            movable: isMovable,
                            topY: worldTopY(of: target)
                        )

                        let info = annotateBearing(rawInfo, character: character)
                        let key = ObjectIdentifier(target)
                        if let existing = nearestByNode[key], existing.distance <= hitDistance {
                            // Keep nearest
                        } else {
                            nearestByNode[key] = info
                        }
                        break
                    }
                }
                angle += wideScanStepDegrees
            }
            return nearestByNode.values.sorted { $0.distance < $1.distance }
        }
    private func detectAllObjectsAhead(
        from character: SCNNode,
        in scene: SCNScene
    ) -> [DetailedObjectDetection] {
        latestRayObservations.removeAll()
        var unique: [ObjectIdentifier: DetailedObjectDetection] = [:]
        for height in [Float(0.12), 0.40, 0.90, 1.2, 1.5] {
            for lateral in [Float(-0.6), -0.3, 0, 0.3, 0.6] {
                if let found = detectDetailedObjectAhead(from: character, in: scene, rayHeight: height, lateral: lateral) {
                    let key = ObjectIdentifier(found.node)
                    if let existing = unique[key] {
                        if found.info.distance < existing.info.distance { unique[key] = found }
                    } else {
                        unique[key] = found
                    }
                }
            }
        }
        return unique.values.sorted { $0.info.distance < $1.info.distance }
    }
    

    private func detectDetailedObjectAhead(
            from character: SCNNode,
            in scene: SCNScene,
            rayHeight: Float,
            lateral: Float
        ) -> DetailedObjectDetection? {
            let characterPresentation = character.presentation
            let position = characterPresentation.worldPosition
            let localForwardPoint = characterPresentation.convertPosition(SCNVector3(0, 0, -1), to: nil)
            
            var forward = SCNVector3(
                localForwardPoint.x - position.x,
                localForwardPoint.y - position.y,
                localForwardPoint.z - position.z
            )
            let forwardLength = sqrt(forward.x * forward.x + forward.y * forward.y + forward.z * forward.z)
            guard forwardLength > 0.0001 else { return nil }
            forward.x /= forwardLength
            forward.y /= forwardLength
            forward.z /= forwardLength

            // Compute orthogonal right vector for lateral offset (-forward.z, 0, forward.x)
            let rightX = -forward.z
            let rightZ = forward.x

            let origin = SCNVector3(
                position.x + rightX * lateral,
                position.y + rayHeight,
                position.z + rightZ * lateral
            )
            let rayLength: Float = 4.0
            let end = SCNVector3(
                origin.x + forward.x * rayLength,
                origin.y,
                origin.z + forward.z * rayLength
            )

            let options: [String: Any] = [
                SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
                SCNHitTestOption.backFaceCulling.rawValue: true
            ]
            let hits = scene.rootNode.hitTestWithSegment(from: origin, to: end, options: options)
            for hit in hits {
                let hitNode = hit.node
                guard !isCharacterPart(hitNode), !isFloorSurface(hitNode), !isQGridNode(hitNode) else { continue }
                let hitPoint = hit.worldCoordinates
                
                let dxHit = hitPoint.x - origin.x
                let dzHit = hitPoint.z - origin.z
                let hitDistance = sqrt(dxHit * dxHit + dzHit * dzHit)
                guard hitDistance >= Self.minimumHitDistance else { continue }
                
                let target: SCNNode = pickupTarget(for: hitNode) ?? meaningfulDetectionParent(for: hitNode)
                guard !isContainerNode(target), target !== character, !isCharacterPart(target) else { continue }
                
                let dimensions = worldDimensions(of: target)
                guard dimensions.x > 0.001, dimensions.y > 0.001, dimensions.z > 0.001 else { continue }
                guard max(dimensions.x, max(dimensions.y, dimensions.z)) <= Self.maximumObstacleExtent else { continue }
                
                let dx = hitPoint.x - position.x
                let dz = hitPoint.z - position.z
                let distance = sqrt(dx * dx + dz * dz)
                guard distance <= rayLength else { continue }
                
                let resolvedName = readableName(for: target)
                let lowerName = resolvedName.lowercased()
                let isMovable = lowerName.contains("movable") || lowerName.contains("crate")

                let rawInfo = DetectedObjectInfo(
                    name: resolvedName,
                    distance: distance,
                    bearing: 0.0,
                    dimensions: dimensions,
                    worldPosition: target.presentation.worldPosition,
                    pickupable: pickupTarget(for: target) != nil,
                    movable: isMovable,
                    topY: worldTopY(of: target)
                )
                let info = annotateBearing(rawInfo, character: character)
                return DetailedObjectDetection(node: target, info: info)
            }
            return nil
        }

    private func logRay(
        origin: SCNVector3,
        direction: SCNVector3,
        hitNode: SCNNode,
        resolvedName: String,
        distance: Float
    ) {
        let observation = RaycastObservation(
            origin: origin,
            direction: direction,
            hitNodeName: hitNode.name ?? "unnamed",
            resolvedObjectName: resolvedName,
            distance: distance
        )
        latestRayObservations.append(observation)
    }

    private func logRayObservations() {}

    private func verifySupportBeneathCharacter(
        character: SCNNode,
        in scene: SCNScene
    ) -> Bool {
        let position = character.presentation.worldPosition
        let feetY = Float(position.y) + characterFootOffset
        let offsets: [(Float, Float)] = [
            (0, 0), (0.18, 0), (-0.18, 0), (0, 0.18), (0, -0.18), (0.12, 0.12), (-0.12, -0.12)
        ]
        for (dx, dz) in offsets {
            let probe = SCNVector3(position.x + dx, feetY, position.z + dz)
            if let supportY = raycastSupport(at: probe, in: scene, riseAllowance: 0.35) {
                let feetAboveSupport = feetY - supportY
                if feetAboveSupport >= -0.08 && feetAboveSupport <= 0.22 {
                    return true
                }
            }
        }
        return false
    }

    private func verifyLandingSite(
        proposedPosition: SCNVector3,
        currentFeetY: Float,
        in scene: SCNScene
    ) -> Bool {
        let supportY = raycastSupport(at: proposedPosition, in: scene, riseAllowance: 1.5)
        guard let landingY = supportY else { return false }
        let heightDelta = landingY - currentFeetY
        guard abs(heightDelta) <= FrankensteinPhysicalBody.maxJumpableHeight else { return false }
        return hasClearSpace(
            around: SCNVector3(proposedPosition.x, landingY + 0.15, proposedPosition.z),
            in: scene
        )
    }

    private func objectClass(for name: String) -> String {
        let value = name.lowercased()
        if value.contains("recharge") { return "rechargeStation" }
        if value.contains("wall") { return "wall" }
        if value.contains("door") { return "door" }
        if value.contains("table") { return "table" }
        if value.contains("crate") || value.contains("box") { return "crate" }
        if value.contains("pickup") || value.contains("movable") || value.contains("carryable") { return "movable" }
        return "object"
    }

    private func distanceBand(_ distance: Float) -> String {
        switch distance {
        case ..<0.75: return "contact"
        case ..<1.5: return "near"
        case ..<3.0: return "mid"
        default: return "far"
        }
    }

    private func objectStateKey(
        for info: DetectedObjectInfo,
        terrain: FrankensteinTerrainSample
    ) -> String {
        [
            String(describing: terrain.terrain),
            objectClass(for: info.name),
            distanceBand(info.distance),
            terrain.carryingObject ? "carrying" : "empty",
            verifiedGroundSupport ? "supported" : "unsupported",
            (pathSteering?.isDetouring ?? false) ? "detour" : "direct"
        ].joined(separator: "|")
    }

    private func goalStateKey(
        terrain: FrankensteinTerrainSample
    ) -> String {
        let progress: String
        let goalDistance = pathGoalDistance.isFinite ? pathGoalDistance : rechargePlatformDistance
        switch goalDistance {
        case ..<1.0: progress = "atGoal"
        case ..<3.0: progress = "nearGoal"
        case ..<8.0: progress = "midGoal"
        default: progress = "farGoal"
        }
        return [
            String(describing: terrain.terrain),
            progress,
            verifiedGroundSupport ? "supported" : "unsupported",
            latestTerrainSample.carryingObject ? "carrying" : "empty",
            (pathSteering?.isDetouring ?? false) ? "detour" : "direct"
        ].joined(separator: "|")
    }

    private func updateObjectQValues(
        terrain: FrankensteinTerrainSample,
        detections: [DetailedObjectDetection]
    ) {
        let allowed = FrankensteinActionConstraints.allowedActions(terrain: terrain, body: locomotion.body)
        var actionNames = allowed.map { String(describing: $0) }
        if detections.contains(where: { isMovableName($0.info.name) && $0.info.distance <= 2.3 }),
           !actionNames.contains(String(describing: FrankensteinAction.pushObject)) {
            actionNames.append(String(describing: FrankensteinAction.pushObject))
        }
        for detection in detections {
            executive.learner.ensure(key: objectStateKey(for: detection.info, terrain: terrain), actions: actionNames)
        }
        executive.learner.ensure(key: goalStateKey(terrain: terrain), actions: actionNames)
    }

    private func reinforceOutcome(
        stateKey: String,
        action: FrankensteinAction,
        reward: Float,
        nextStateKey: String? = nil
    ) {
        executive.learner.reinforce(
            key: stateKey,
            action: String(describing: action),
            reward: reward,
            nextKey: nextStateKey
        )
    }

    private func makeTerrainSample(
        for character: SCNNode,
        in scene: SCNScene
    ) -> FrankensteinTerrainSample {
        let position = character.presentation.worldPosition
        let forward = forwardVector()
        var sample = FrankensteinTerrainSample()
        let currentGround = raycastGround(near: position, in: scene)
        sample.groundHeight = currentGround ?? Float(position.y)
        sample.nextGroundHeight = sample.groundHeight
        sample.distance = 5
        sample.isGroundAhead = true
        sample.isLandingAreaClear = false
        sample.gapWidth = 0
        sample.gapNearEdgeDistance = .infinity
        sample.gapFarEdgeDistance = .infinity
        sample.landingHeightDelta = 0
        if let detection = detectObjectAhead(from: character, in: scene) {
            sample.distance = detection.distance
            let rise = detection.topY > 0 ? max(0, detection.topY - sample.groundHeight) : detection.dimensions.y
            sample.obstacleHeight = rise
            sample.obstacleDepth = detection.dimensions.z
            sample.objectName = detection.name
            let name = detection.name.lowercased()
            let bottomY = Float(detection.worldPosition.y) - detection.dimensions.y * 0.5
            if name.contains("ceiling") || bottomY > sample.groundHeight + 0.8 {
                sample.terrain = .lowCeiling
            } else if rise <= 0.08 {
                sample.terrain = .uneven
            } else if rise <= 0.45 {
                sample.terrain = .raisedStep
            } else {
                sample.terrain = .hurdle
            }
            sample.objectMovable = isMovableName(detection.name)
            let isLandableStatic = name.contains("recharge") || name.contains("platform") || name.contains("table")
            if (sample.objectMovable || isLandableStatic),
               rise > 0.05, rise <= FrankensteinPhysicalBody.maxJumpableHeight,
               detection.dimensions.x >= 0.3, detection.dimensions.z >= 0.3 {
                sample.canLandOnObject = hasClearSpace(
                    around: SCNVector3(detection.worldPosition.x, detection.topY + 0.15, detection.worldPosition.z),
                    in: scene
                )
            }
            if sample.terrain == .hurdle || sample.terrain == .raisedStep {
                let landingDistance = detection.distance + max(detection.dimensions.z, 0.3) + 0.4
                let landingProbe = SCNVector3(position.x + forward.x * landingDistance, position.y, position.z + forward.z * landingDistance)
                if let landingHeight = raycastGround(near: landingProbe, in: scene) {
                    let delta = landingHeight - sample.groundHeight
                    sample.landingHeightDelta = delta
                    sample.nextGroundHeight = landingHeight
                    sample.isLandingAreaClear = abs(delta) <= 0.25 && hasClearSpace(around: SCNVector3(landingProbe.x, landingHeight + 0.15, landingProbe.z), in: scene)
                }
            }
        } else {
            sample.terrain = .flat
        }
        let distances: [Float] = [0.65, 1.0, 1.5, 2.2, 3.0]
        var groundHits: [(distance: Float, height: Float)] = []
        var firstProbeHasGround = false
        for (index, distance) in distances.enumerated() {
            let probe = SCNVector3(position.x + forward.x * distance, position.y + 3.0, position.z + forward.z * distance)
            if let height = raycastGround(near: probe, in: scene) {
                groundHits.append((distance, height))
                if index == 0 { firstProbeHasGround = true }
            }
        }
        sample.isGroundAhead = firstProbeHasGround
        if !firstProbeHasGround {
            if let landing = groundHits.last {
                sample.terrain = .gap
                sample.distance = distances[0]
                sample.gapNearEdgeDistance = distances[0]
                sample.gapFarEdgeDistance = landing.distance
                sample.gapWidth = max(0, landing.distance - distances[0])
                sample.nextGroundHeight = landing.height
                sample.landingHeightDelta = landing.height - sample.groundHeight
                sample.isLandingAreaClear = sample.gapWidth > 0 && sample.gapWidth <= 3.5
            } else {
                sample.terrain = .gap
                sample.distance = distances[0]
                sample.isLandingAreaClear = false
            }
            sample.updateCrossability()
            return sample
        }
        if let nearest = groundHits.first {
            sample.nextGroundHeight = nearest.height
            sample.landingHeightDelta = nearest.height - sample.groundHeight
            let rise = nearest.height - sample.groundHeight
            if rise > 0.05 && rise <= 0.45 {
                sample.terrain = .raisedStep
                sample.obstacleHeight = rise
                sample.distance = nearest.distance
            }
        }
        sample.updateCrossability()
        return sample
    }

    private func worldTopY(of node: SCNNode) -> Float {
        let (minimum, maximum) = node.boundingBox
        var top = -Float.infinity
        for x in [minimum.x, maximum.x] {
            for y in [minimum.y, maximum.y] {
                for z in [minimum.z, maximum.z] {
                    let world = node.presentation.convertPosition(SCNVector3(x, y, z), to: nil)
                    top = max(top, Float(world.y))
                }
            }
        }
        return top.isFinite ? top : 0
    }

    private func raycastSupport(
        at position: SCNVector3,
        in scene: SCNScene,
        riseAllowance: Float = 0.9
    ) -> Float? {
        let start = SCNVector3(position.x, position.y + riseAllowance, position.z)
        let end = SCNVector3(position.x, position.y - 8.0, position.z)
        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: false
        ]
        let hits = scene.rootNode.hitTestWithSegment(from: start, to: end, options: options)
        for hit in hits {
            guard !isCharacterPart(hit.node), !isQGridNode(hit.node) else { continue }
            if hit.worldNormal.y <= 0.35 && !isGroundLikeNode(hit.node) { continue }
            let name = (hit.node.name ?? "").lowercased()
            if name.contains("marker") || name.contains("rechargestation") { continue }
            return Float(hit.worldCoordinates.y)
        }
        return nil
    }

    private func groundSurfaceY(atX x: Float, z: Float, in scene: SCNScene) -> Float? {
        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: false
        ]
        let hits = scene.rootNode.hitTestWithSegment(
            from: SCNVector3(x, 20, z),
            to: SCNVector3(x, -20, z),
            options: options
        )
        for hit in hits {
            guard !isCharacterPart(hit.node), !isQGridNode(hit.node), isGroundLikeNode(hit.node) else { continue }
            let name = (hit.node.name ?? "").lowercased()
            if name.contains("marker") || name.contains("rechargestation") { continue }
            if hit.worldNormal.y <= 0.35 { continue }
            return Float(hit.worldCoordinates.y)
        }
        return nil
    }

    private func raycastGround(
        near position: SCNVector3,
        in scene: SCNScene
    ) -> Float? {
        let start = SCNVector3(position.x, position.y + 3.0, position.z)
        let end = SCNVector3(position.x, position.y - 8.0, position.z)
        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: true
        ]
        let hits = scene.rootNode.hitTestWithSegment(from: start, to: end, options: options)
        let validHits = hits.filter { !isCharacterPart($0.node) && !isQGridNode($0.node) }
        if let groundHit = validHits.first(where: { isGroundLikeNode($0.node) }) {
            return Float(groundHit.worldCoordinates.y)
        }
        return validHits.first.map { Float($0.worldCoordinates.y) }
    }

    private func hasClearSpace(
        around position: SCNVector3,
        in scene: SCNScene
    ) -> Bool {
        let offsets: [(Float, Float)] = [(0, 0), (0.25, 0), (-0.25, 0), (0, 0.25), (0, -0.25)]
        for (dx, dz) in offsets {
            let start = SCNVector3(position.x + dx, position.y, position.z + dz)
            let end = SCNVector3(start.x, start.y + 1.2, start.z)
            let options: [String: Any] = [
                SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
                SCNHitTestOption.backFaceCulling.rawValue: true
            ]
            let hits = scene.rootNode.hitTestWithSegment(from: start, to: end, options: options)
            if hits.contains(where: { !isCharacterPart($0.node) && !isGroundLikeNode($0.node) }) {
                return false
            }
        }
        return true
    }

    private func detectObjectAhead(
        from character: SCNNode,
        in scene: SCNScene
    ) -> DetectedObjectInfo? {
        latestDetections.first
    }

    private static let containerNodeNames: Set<String> = ["ObstacleCourse", "TerrainRoot", "SceneRoot"]
    private static let maximumObstacleExtent: Float = 6.0
    private static let minimumHitDistance: Float = 0.05

    private func isContainerNode(_ node: SCNNode) -> Bool {
        let name = (node.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.containerNodeNames.contains(name)
    }

    private func meaningfulDetectionParent(for node: SCNNode) -> SCNNode {
        var current: SCNNode? = node
        var bestCandidate = node
        while let candidate = current {
            if isContainerNode(candidate) { break }
            let name = (candidate.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !isGenericDetectionNodeName(name), !isFloorSurface(candidate) {
                let extent = worldDimensions(of: candidate)
                let isGroupingNode = max(extent.x, max(extent.y, extent.z)) > Self.maximumObstacleExtent
                if isGroupingNode { break }
                bestCandidate = candidate
            }
            current = candidate.parent
        }
        return bestCandidate
    }

    private func isGenericDetectionNodeName(_ name: String) -> Bool {
        let value = name.lowercased()
        return value == "node" || value == "root" || value == "geometry" || value.hasPrefix("scn")
    }

    private func measureForwardDisplacement(
        from previous: SCNVector3,
        to current: SCNVector3
    ) -> Float {
        let dx = Float(current.x - previous.x)
        let dz = Float(current.z - previous.z)
        let forward = forwardVector()
        let value = dx * forward.x + dz * forward.z
        return value.isFinite ? value : 0
    }

    private var isFollowingSpline: Bool {
        !isDetouringPlatform && stuckSeconds <= 0.8 && planSpline.approachPath.count >= 2
    }

    // MARK: - Platform Detour
    private var platformDetourWaypoint: SIMD2<Float>?
    private var platformDetourUntil: TimeInterval = 0
    private var platformDetourName = ""

    private var isDetouringPlatform: Bool {
        platformDetourWaypoint != nil && currentFrameTime < platformDetourUntil
    }

    private func isUnclimbablePlatform(_ terrain: FrankensteinTerrainSample) -> Bool {
        guard terrain.terrain == .hurdle || terrain.terrain == .raisedStep,
              terrain.obstacleHeight > 0.03,
              !terrain.objectName.lowercased().contains("recharge") else { return false }
        if terrain.objectMovable || terrain.objectName.lowercased() == "table" {
            return false
        }
        let rise = terrain.obstacleHeight
        if carryingLetterBlock, rise > 0.45 { return true }
        if rise <= 0.45 { return false }
        if rise <= 1.4, terrain.canLandOnObject { return false }
        return true
    }

    private func updatePlatformDetour(
        terrain: FrankensteinTerrainSample,
        perception: inout FrankensteinCAPerception
    ) {
        guard let character = characterNode else { return }
        let position = character.presentation.worldPosition
        let here = SIMD2<Float>(Float(position.x), Float(position.z))

        if let waypoint = platformDetourWaypoint {
            if currentFrameTime >= platformDetourUntil || simd_distance(here, waypoint) < 0.5 {
                platformDetourWaypoint = nil
                ca?.missionQueue.completeTopTacticalTask(
                    matchingDescriptionPrefix: "Step around obstacle:",
                    because: "passed \(platformDetourName)"
                )
                publishDebug("Detour: passed \(platformDetourName)")
            } else {
                let dx = waypoint.x - here.x
                let dz = waypoint.y - here.y
                perception.headingError = wrappedAngle(atan2(-dx, -dz) - heading)
                return
            }
        }

        guard !carryingDog, isUnclimbablePlatform(terrain),
              terrain.distance.isFinite, terrain.distance <= 1.8 else { return }
        guard let detection = visibleObjects.first(where: { $0.name == terrain.objectName }) else { return }

        let center = SIMD2<Float>(Float(detection.worldPosition.x), Float(detection.worldPosition.z))
        let left = SIMD2<Float>(-cos(heading), sin(heading))
        let forward = SIMD2<Float>(-sin(heading), -cos(heading))
        let lateral = simd_dot(here - center, left)
        var side: Float
        if abs(lateral) > 0.25 {
            side = lateral >= 0 ? 1 : -1
        } else {
            side = clearancePlus >= clearanceMinus ? 1 : -1
        }
        let half = max(detection.dimensions.x, detection.dimensions.z) * 0.5
        let waypoint = center + left * side * (half + 0.9) + forward * 0.4

        platformDetourWaypoint = waypoint
        platformDetourName = terrain.objectName
        platformDetourUntil = currentFrameTime + 6
        ca?.missionQueue.pushTacticalOverride(
            PlanTask(description: "Step around obstacle: \(terrain.objectName)"),
            reason: "cannot climb \(terrain.objectName)"
        )
        let dx = waypoint.x - here.x
        let dz = waypoint.y - here.y
        perception.headingError = wrappedAngle(atan2(-dx, -dz) - heading)
        publishDebug("Detour: cannot climb \(terrain.objectName) (\(String(format: "%.2f", Double(terrain.obstacleHeight))) m), going around the \(side > 0 ? "left" : "right")")
    }

    private func splineHeadingError(from position: SCNVector3) -> Float? {
            guard isFollowingSpline,
                  let target = splineLookAheadPoint(
                      from: position,
                      path: planSpline.approachPath,
                      distance: 0.8
                  ) else { return nil }
            
            let dx = target.x - Float(position.x)
            let dz = target.z - Float(position.z)
            
            guard sqrt(dx * dx + dz * dz) > 0.05 else { return 0 }
            return wrappedAngle(atan2(-dx, -dz) - heading)
        }

    private func splineLookAheadPoint(
            from position: SCNVector3,
            path: [SIMD3<Float>],
            distance: Float = 0.8
        ) -> SCNVector3? {
            guard path.count >= 2 else { return nil }

            let p = SIMD2<Float>(Float(position.x), Float(position.z))

            let signature = "\(path.count)|\(path[0].x)|\(path[0].z)"
            if signature != lastSplineSignature {
                lastSplineSignature = signature
                lastSplineIndex = 0
            }

            if lastSplineIndex < 0 || lastSplineIndex >= path.count {
                lastSplineIndex = 0
            }

            let searchWindow = 15
            let startIdx = max(0, lastSplineIndex)
            let endIdx = min(path.count - 1, lastSplineIndex + searchWindow)

            var nearestIndex = startIdx
            var nearestDistance = Float.greatestFiniteMagnitude

            for i in startIdx...endIdx {
                let pt2D = SIMD2<Float>(path[i].x, path[i].z)
                let d = simd_distance(p, pt2D)
                if d < nearestDistance {
                    nearestDistance = d
                    nearestIndex = i
                }
            }
            
            if nearestDistance > 2.0 {
                for i in path.indices {
                    let pt2D = SIMD2<Float>(path[i].x, path[i].z)
                    let d = simd_distance(p, pt2D)
                    if d < nearestDistance {
                        nearestDistance = d
                        nearestIndex = i
                    }
                }
            }

            nearestIndex = max(0, min(nearestIndex, path.count - 1))
            lastSplineIndex = nearestIndex

            var remaining = max(0, distance)
            var current = path[nearestIndex]

            for i in nearestIndex..<(path.count - 1) {
                let next = path[i + 1]
                let segment = next - current
                let segmentLength = simd_length(segment)

                if segmentLength <= 0.0001 {
                    current = next
                    continue
                }

                if remaining <= segmentLength {
                    let interpolated = current + segment / segmentLength * remaining
                    return SCNVector3(interpolated.x, interpolated.y, interpolated.z)
                }

                remaining -= segmentLength
                current = next
            }

            if let lastPt = path.last {
                return SCNVector3(lastPt.x, lastPt.y, lastPt.z)
            }
            return nil
        }
    private func applyMovement(
        output: FrankensteinLocomotionOutput,
        deltaTime dt: Float,
        character: SCNNode,
        scene: SCNScene
    ) {
        guard dt.isFinite, dt > 0 else { return }
        
        heading = output.heading
        let fv = forwardVector()
        let forward = SCNVector3(fv.x, fv.y, fv.z)
        
        handleObjectInteractions(output: output)
        
        let speed = calculateSpeed(output: output, character: character, scene: scene)
        
        let oldWorld = character.presentation.worldPosition
        var proposedWorld = calculateProposedPosition(
            oldWorld: oldWorld,
            forward: forward,
            speed: speed,
            dt: dt
        )

        applyNavigationSteering(
            output: output,
            oldWorld: oldWorld,
            proposedWorld: &proposedWorld,
            dt: dt
        )

        verifyAndAdjustLandingSupport(
            oldWorld: oldWorld,
            proposedWorld: &proposedWorld,
            speed: speed,
            character: character,
            scene: scene
        )

        character.position = proposedWorld
    }

    private func handleObjectInteractions(output: FrankensteinLocomotionOutput) {
        if output.liftRequested, locomotion.policy.pendingAction == .liftObject {
            let stateKeyBeforePickup = latestDetection.map { objectStateKey(for: $0, terrain: latestTerrainSample) }
            let succeeded = attemptPickup()
            locomotion.reportPickupOutcome(succeeded: succeeded)
            predictivePerception.observeInteraction(action: .liftObject, succeeded: succeeded)
            if let stateKeyBeforePickup {
                reinforceOutcome(stateKey: stateKeyBeforePickup, action: .liftObject, reward: succeeded ? 1.0 : -0.5)
            }
        }
        
        if output.placeRequested, locomotion.policy.pendingAction == .placeObject {
            let stateKeyBeforePlace = latestDetection.map { objectStateKey(for: $0, terrain: latestTerrainSample) }
            let ok = placeCarriedObjectAhead()
            locomotion.reportObjectActionOutcome(.placeObject, reward: ok ? 0.5 : -0.5)
            predictivePerception.observeInteraction(action: .placeObject, succeeded: ok)
            if let stateKeyBeforePlace {
                reinforceOutcome(stateKey: stateKeyBeforePlace, action: .placeObject, reward: ok ? 0.5 : -0.5)
            }
        }
        
        if output.throwRequested, locomotion.policy.pendingAction == .throwObject {
            let stateKeyBeforeThrow = latestDetection.map { objectStateKey(for: $0, terrain: latestTerrainSample) }
            let ok = throwCarriedObjectAhead()
            locomotion.reportObjectActionOutcome(.throwObject, reward: ok ? 0.3 : -0.5)
            predictivePerception.observeInteraction(action: .throwObject, succeeded: ok)
            if let stateKeyBeforeThrow {
                reinforceOutcome(stateKey: stateKeyBeforeThrow, action: .throwObject, reward: ok ? 0.3 : -0.5)
            }
        }
    }

    private func calculateSpeed(output: FrankensteinLocomotionOutput, character: SCNNode, scene: SCNScene) -> Float {
        let hasMovableInView = visibleObjects.contains { isMovableName($0.name) }
        let activePushNode = pushTargetNode ?? (hasMovableInView ? findPushTargetNode(character: character, in: scene, detections: detectAllObjectsAhead(from: character, in: scene)) : nil)
        
        let baseSpeed: Float = (output.action == .pushObject)
            ? (activePushNode == nil ? 0.45 : max(0.45, output.speed))
            : max(0, output.speed)
             
        let direction = (output.action == .pushObject && output.moveDirection == 0) ? 1.0 : output.moveDirection
        return baseSpeed * direction
    }

    private func calculateProposedPosition(
        oldWorld: SCNVector3,
        forward: SCNVector3,
        speed: Float,
        dt: Float
    ) -> SCNVector3 {
        return SCNVector3(
            oldWorld.x + forward.x * speed * dt,
            oldWorld.y,
            oldWorld.z + forward.z * speed * dt
        )
    }

    private func applyNavigationSteering(
        output: FrankensteinLocomotionOutput,
        oldWorld: SCNVector3,
        proposedWorld: inout SCNVector3,
        dt: Float
    ) {
        if output.action != .pushObject,
           output.action != .kickObject,
           let speed = [output.speed].first, speed > 0,
           isFollowingSpline,
           let target = splineLookAheadPoint(
               from: oldWorld,
               path: planSpline.approachPath,
               distance: 0.8
           ) {
            let dx = target.x - Float(oldWorld.x)
            let dz = target.y - Float(oldWorld.z)
            let distanceToTarget = sqrt(dx * dx + dz * dz)
            
            if distanceToTarget > 0.05 {
                let desiredHeading = atan2(-dx, -dz)
                var angleDifference = desiredHeading - heading
                while angleDifference > Float.pi { angleDifference -= 2 * Float.pi }
                while angleDifference < -Float.pi { angleDifference += 2 * Float.pi }
                
                let maxTurn: Float = 3.5 * dt
                heading += min(max(angleDifference, -maxTurn), maxTurn)
                locomotion.setHeading(heading)

                let stepDist = min(distanceToTarget, speed * dt)
                proposedWorld.x = oldWorld.x + (dx / distanceToTarget) * stepDist
                proposedWorld.z = oldWorld.z + (dz / distanceToTarget) * stepDist
            }
        }
        
        if isDetouringPlatform, let waypoint = platformDetourWaypoint,
           output.action != .pushObject, output.action != .kickObject {
            let dx = waypoint.x - Float(oldWorld.x)
            let dz = waypoint.y - Float(oldWorld.z)
            let distanceToWaypoint = sqrt(dx * dx + dz * dz)
            
            if distanceToWaypoint > 0.05 {
                var angleDifference = atan2(-dx, -dz) - heading
                while angleDifference > Float.pi { angleDifference -= 2 * Float.pi }
                while angleDifference < -Float.pi { angleDifference += 2 * Float.pi }
                
                let maxTurn: Float = 3.0 * dt
                heading += min(max(angleDifference, -maxTurn), maxTurn)
                locomotion.setHeading(heading)
            }
        }
    }

    private func verifyAndAdjustLandingSupport(
        oldWorld: SCNVector3,
        proposedWorld: inout SCNVector3,
        speed: Float,
        character: SCNNode,
        scene: SCNScene
    ) {
        let currentFeetY = Float(oldWorld.y) + characterFootOffset
        verifiedLandingSupport = verifyLandingSite(
            proposedPosition: proposedWorld,
            currentFeetY: currentFeetY,
            in: scene
        )

        if speed > 0,
           latestTerrainSample.terrain == .gap,
           !latestTerrainSample.isLandingAreaClear,
           !verifiedLandingSupport {
            proposedWorld.x = oldWorld.x
            proposedWorld.z = oldWorld.z
        }
    }

    // MARK: - Mission-Queue-Based Action Outcome Evaluation

    private func evaluateActionOutcome(
        output: FrankensteinLocomotionOutput,
        actualDisplacement: Float?,
        character: SCNNode,
        scene: SCNScene,
        time: TimeInterval
    ) {
        guard let ca else { return }

        let queue = ca.missionQueue
        let action = output.action

        // Only evaluate an action that belongs to the active CA mission task.
        // A task with a bound action list owns exactly those actions. A task
        // with an empty list (for example "Approach...") leaves the movement to
        // the CA, so whatever movement the CA chose is that task's action and
        // must be evaluated too; otherwise walking toward a goal is never scored.
        // Feedback is still withheld when a bound task runs a different action.
        guard let activeTask = queue.currentTask,
              activeTask.actions.isEmpty || activeTask.actions.contains(action) else {
            outcomeWindowElapsedTime = 0
            outcomeWindowDisplacement = 0
            outcomeWindowGoalProgress = 0
            outcomeWindowPathProgress = 0
            lastEvaluatedActionName = ""
            lastOutcomeEvaluationTime = time
            return
        }

        let actionName = String(describing: action)

        // The mission queue is authoritative for the target.
        let goal = queue.currentTargetNode
        let goalID = goal.map { ObjectIdentifier($0) }

        // MARK: - Calculate actual frame time

        let fallbackDelta = max(
            1.0 / 60.0,
            Double(max(0, dtFromLastFrame))
        )

        let rawDelta: TimeInterval

        if lastOutcomeEvaluationTime > 0,
           time.isFinite,
           time > lastOutcomeEvaluationTime {

            rawDelta = time - lastOutcomeEvaluationTime

        } else {
            rawDelta = fallbackDelta
        }

        let frameDelta = min(max(rawDelta, 0.001), 0.1)

        lastOutcomeEvaluationTime = time

        // MARK: - Measure distance to the mission target

        var currentDistance: Float?

        if let goal {
            let characterPosition = character.presentation.worldPosition
            let goalPosition = goal.presentation.worldPosition

            let dx = Float(characterPosition.x - goalPosition.x)
            let dz = Float(characterPosition.z - goalPosition.z)

            let distance = sqrt(dx * dx + dz * dz)

            if distance.isFinite {
                currentDistance = distance
            }
        }

        // MARK: - Reset when the mission target changes

        if goalID != lastGoalNodeID {
            lastGoalNodeID = goalID

            lastGoalDistance = currentDistance ?? .infinity
            lastEvalPathDistance = pathGoalDistance

            outcomeWindowElapsedTime = 0
            outcomeWindowDisplacement = 0
            outcomeWindowGoalProgress = 0
            outcomeWindowPathProgress = 0

            lastEvaluatedActionName = ""
        }

        // MARK: - Reset when the executed action changes

        if actionName != lastEvaluatedActionName {
            lastEvaluatedActionName = actionName

            outcomeWindowElapsedTime = 0
            outcomeWindowDisplacement = 0
            outcomeWindowGoalProgress = 0
            outcomeWindowPathProgress = 0

            lastGoalDistance = currentDistance ?? .infinity
            lastEvalPathDistance = pathGoalDistance
        }

        // MARK: - Accumulate physical measurements

        let displacement: Float

        if let actualDisplacement,
           actualDisplacement.isFinite {
            displacement = actualDisplacement
        } else {
            displacement = 0
        }

        outcomeWindowDisplacement += displacement
        outcomeWindowElapsedTime += frameDelta

        // Accumulate progress toward the mission target.
        if let currentDistance,
           lastGoalDistance.isFinite {

            let progress = lastGoalDistance - currentDistance

            if progress.isFinite {
                outcomeWindowGoalProgress += progress
            }
        }

        if let currentDistance {
            lastGoalDistance = currentDistance
        }

        // Accumulate progress along the planned route.
        if pathGoalDistance.isFinite,
           lastEvalPathDistance.isFinite {

            let pathProgress = lastEvalPathDistance - pathGoalDistance

            if pathProgress.isFinite {
                outcomeWindowPathProgress += pathProgress
            }
        }

        lastEvalPathDistance = pathGoalDistance

        // MARK: - Classify the action

        let movementActions: Set<FrankensteinAction> = [
            .walk,
            .run,
            .stepForward,
            .backward,
            .crouch,
            .crawl,
            .roll,
            .jump,
            .stepUp,
            .stepDown,
            .pushObject
        ]

        let turningActions: Set<FrankensteinAction> = [
            .turnLeft,
            .turnRight
        ]

        let isMovementAction = movementActions.contains(action)
        let isTurningAction = turningActions.contains(action)

        // Interaction actions are evaluated through their own confirmed
        // physical outcomes, not by measuring character displacement.
        guard isMovementAction || isTurningAction else {
            return
        }

        // MARK: - Wait for a complete evaluation window

        guard outcomeWindowElapsedTime >= outcomeWindowDuration else {
            return
        }

        let windowDuration = Float(outcomeWindowElapsedTime)

        guard windowDuration > 0,
              windowDuration.isFinite else {
            return
        }

        // MARK: - Calculate actual progress

        let hasGeometricTarget =
            goal != nil || pathGoalDistance.isFinite

        let measuredProgress: Float

        if hasGeometricTarget {
            // Use the strongest geometric progress measurement.
            // This avoids counting the same progress twice.
            measuredProgress = max(
                outcomeWindowGoalProgress,
                outcomeWindowPathProgress
            )
        } else {
            // Without a geometric target, use actual forward displacement.
            measuredProgress = outcomeWindowDisplacement
        }

        let goalProgressRate = measuredProgress / windowDuration

        // MARK: - Detect lack of progress

        let madeProgress = measuredProgress > noProgressThreshold

        let displacementIsSmall =
            abs(outcomeWindowDisplacement) < noProgressThreshold

        if isMovementAction && !madeProgress && displacementIsSmall {
            consecutiveNoProgressCount += 1
        } else if madeProgress {
            consecutiveNoProgressCount = 0
        }

        // MARK: - Confirm whether an obstacle caused the blockage

        let obstacleDetected =
            latestTerrainSample.terrain == .hurdle ||
            pushTargetNode != nil

        let blocked =
            isMovementAction &&
            !madeProgress &&
            displacementIsSmall &&
            obstacleDetected

        // MARK: - Send outcome to FrankensteinCA

        ca.reportActionOutcome(
            action: action,
            goalProgressRate: goalProgressRate,
            windowDuration: windowDuration,
            blocked: blocked
        )

        // MARK: - Prepare the next evaluation window

        outcomeWindowElapsedTime = 0
        outcomeWindowDisplacement = 0
        outcomeWindowGoalProgress = 0
        outcomeWindowPathProgress = 0

        lastGoalDistance = currentDistance ?? .infinity
        lastEvalPathDistance = pathGoalDistance
    }

    func randomFloat(in range: ClosedRange<Float> = 0.0...1.0) -> Float {
        return Float.random(in: range)
    }

    private func applyKick(output: FrankensteinLocomotionOutput, character: SCNNode) {
        guard output.action == .kickObject,
              let node = pushTargetNode,
              !isLetterBlockName(node.name),
              let body = node.physicsBody else { return }
        var forward = forwardVector()
        if isLooseBlocker(node) {
            let aside = asideDirection(for: node, character: character)
            forward = SIMD3<Float>(aside.x, 0, aside.y)
        }

        body.type = .dynamic
        body.velocity = SCNVector3(forward.x * 5.0, 2.0, forward.z * 5.0)
        body.angularVelocity = SCNVector4(randomFloat(), randomFloat(), randomFloat(), 1.0)

        locomotion.reportObjectActionOutcome(.throwObject, reward: 2.0)
    }

    private func animateCharacter(character: SCNNode) {
        let swing = locomotion.gaitSwing
        let phase = locomotion.gaitPhase
        findNode(named: "FrankensteinLeftLeg", under: character)?.eulerAngles.x = swing * 0.65
        findNode(named: "FrankensteinRightLeg", under: character)?.eulerAngles.x = -swing * 0.65
        findNode(named: "FrankensteinLeftArm", under: character)?.eulerAngles.x = -swing * 0.45
        findNode(named: "FrankensteinRightArm", under: character)?.eulerAngles.x = swing * 0.45
        if let head = findNode(named: "FrankensteinHead", under: character) {
            head.eulerAngles.y = sin(phase) * 0.04
        }
        if let torso = findNode(named: "FrankensteinTorso", under: character) {
            let crouch = min(max(locomotion.output.crouch, 0), 1)
            torso.position.y = 1.28 - 0.15 * crouch
        }
    }

    private func configurePhysicsWorld(in scene: SCNScene) {
        scene.physicsWorld.gravity = SCNVector3(0, -worldGravity, 0)
        scene.physicsWorld.speed = CGFloat(animationSpeed)
        func visit(_ node: SCNNode) {
            if node !== characterNode && !isCharacterPart(node) && !isQGridNode(node) {
                configurePhysicsBody(for: node, forceDynamic: false)
            }
            for child in node.childNodes { visit(child) }
        }
        visit(scene.rootNode)
    }

    private func configurePhysicsBody(for node: SCNNode, forceDynamic: Bool) {
        let hasOwnGeometry = node.geometry != nil
        let hasDescendantGeometry = node.childNodes.contains { child in
            child.geometry != nil || child.childNodes.contains(where: { $0.geometry != nil })
        }
        guard hasOwnGeometry || hasDescendantGeometry else { return }
        let name = (node.name ?? "").lowercased()
        if name.hasPrefix("tabletop") || name.hasPrefix("tableleg") { return }
        if name.contains("chasm") || name.contains("void") || name.contains("gap") ||
           name.contains("qfloorgrid") || name.contains("marker") || name.contains("camera") || name.contains("light") {
            return
        }
        if isCharacterPart(node) || isQGridNode(node) { return }
        
        let movableTokens = ["table", "crate", "box", "movable", "pickup", "chair", "stool", "block", "object", "stair", "step"]
        let supportTokens = ["floor", "ground", "platform", "terrain", "wall", "doorframe"]
        
        let shouldBeDynamic = forceDynamic || movableTokens.contains(where: { name.contains($0) })
        let shouldBeStatic = supportTokens.contains(where: { name.contains($0) }) && !name.contains("table")

        if shouldBeDynamic {
            if node.physicsBody == nil || node.physicsBody?.type != .dynamic {
                let shape = SCNPhysicsShape(node: node, options: nil)
                let body = SCNPhysicsBody(type: .dynamic, shape: shape)
                let size = worldDimensions(of: node)
                let volume = max(0.01, size.x * size.y * size.z)
                body.mass = CGFloat(min(40, max(1.0, volume * 2.0)))
                body.friction = 0.8
                body.rollingFriction = 0.8
                body.restitution = 0.02
                body.damping = 0.12
                body.angularDamping = 0.2
                body.allowsResting = true
                node.physicsBody = body
            }
        } else if shouldBeStatic {
            if node.physicsBody == nil || node.physicsBody?.type != .static {
                let shape = SCNPhysicsShape(node: node, options: nil)
                let body = SCNPhysicsBody(type: .static, shape: shape)
                body.friction = 0.9
                body.restitution = 0
                node.physicsBody = body
            }
        }
    }

    private func worldDimensions(of node: SCNNode) -> SCNVector3 {
        let (minimum, maximum) = node.boundingBox
        let scale = worldScale(of: node)
        return SCNVector3(
            abs(maximum.x - minimum.x) * abs(scale.x),
            abs(maximum.y - minimum.y) * abs(scale.y),
            abs(maximum.z - minimum.z) * abs(scale.z)
        )
    }

    private func worldScale(of node: SCNNode) -> SCNVector3 {
        let transform = node.presentation.worldTransform
        let scaleX = sqrt(transform.m11 * transform.m11 + transform.m21 * transform.m21 + transform.m31 * transform.m31)
        let scaleY = sqrt(transform.m12 * transform.m12 + transform.m22 * transform.m22 + transform.m32 * transform.m32)
        let scaleZ = sqrt(transform.m13 * transform.m13 + transform.m23 * transform.m23 + transform.m33 * transform.m33)
        return SCNVector3(scaleX, scaleY, scaleZ)
    }

    private func readableName(for node: SCNNode) -> String {
        if let name = node.name, !name.isEmpty {
            return name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        }
        if node.geometry is SCNBox { return "Box-shaped object" }
        if node.geometry is SCNSphere { return "Sphere-shaped object" }
        if node.geometry is SCNCylinder { return "Cylinder-shaped object" }
        return "Unnamed scene object"
    }

    private func findNode(named name: String, under root: SCNNode) -> SCNNode? {
        if root.name == name { return root }
        return root.childNode(withName: name, recursively: true)
    }

    private func findNode(containing text: String, under root: SCNNode) -> SCNNode? {
        let search = text.lowercased()
        if root.name?.lowercased().contains(search) == true { return root }
        for child in root.childNodes {
            if let found = findNode(containing: search, under: child) { return found }
        }
        return nil
    }

    private func pickupTarget(for node: SCNNode) -> SCNNode? {
        var current: SCNNode? = node
        while let candidate = current {
            let name = candidate.name?.lowercased() ?? ""
            if name.contains("table") { return nil }

            if name.contains("pickup") || name.contains("movable") || name.contains("carryable") ||
               name.contains("crate") || name.contains("box") || name.contains("letterblock") {
                return candidate
            }
            current = candidate.parent
        }
        return nil
    }

    @discardableResult
    func attemptPickup(of explicit: SCNNode? = nil) -> Bool {
        guard let character = characterNode, let scene = scene, let hand = handNode else { return false }
        let chosen: SCNNode?
        if let explicit, carriedNode == nil, canManipulate(explicit, from: character) {
            chosen = explicit
        } else {
            chosen = reachablePickupTarget(character: character, scene: scene)
        }
        guard let target = chosen else { return false }
        let depth = worldDimensions(of: target).z
        carriedOriginalParent = target.parent
        carriedOriginalPosition = target.position
        if let body = target.physicsBody {
            body.velocity = SCNVector3Zero
            body.angularVelocity = SCNVector4Zero
            body.type = .kinematic
        }
        target.removeFromParentNode()
        hand.addChildNode(target)
        target.position = SCNVector3(0, -0.08, -(0.20 + depth * 0.5))
        target.physicsBody?.resetTransform()
        guard target.parent === hand else { return false }
        carriedNode = target
        if let task = ca?.missionQueue.currentTask,
           task.actions.first == .liftObject,
           task.targetNode == target {
            _ = ca?.missionQueue.completeCurrentMissionTask(
                because: "SceneKit confirmed object attached to Frankenstein's hand"
            )
        }
        publishDebug("Pickup confirmed.")
        return true
    }

    private func nearestPickupNode(from character: SCNNode, in scene: SCNScene) -> SCNNode? {
        let position = character.presentation.worldPosition
        let forward = forwardVector()
        let start = SCNVector3(position.x, position.y + 0.7, position.z)
        let end = SCNVector3(start.x + forward.x * 2.0, start.y, start.z + forward.z * 2.0)
        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: true
        ]
        let hits = scene.rootNode.hitTestWithSegment(from: start, to: end, options: options)
        return hits.first(where: {
            !isCharacterPart($0.node) && !isGroundLikeNode($0.node) && pickupTarget(for: $0.node) != nil
        })?.node
    }

    private func applyPush(
        output: FrankensteinLocomotionOutput,
        deltaTime dt: Float,
        character: SCNNode
    ) {
        let pushIsExecuting = output.pushRequested || output.action == .pushObject
        guard pushIsExecuting else {
            blockConnectionStartGeneration = nil
            trackedBlockID = nil
            pushLastNodePosition = nil
            pushTrackedNodeID = nil
            pushAccumulatedMeters = 0
            return
        }
        guard let node = pushTargetNode, node.parent != nil else {
            blockConnectionStartGeneration = nil
            trackedBlockID = nil
            pushLastNodePosition = nil
            pushTrackedNodeID = nil
            pushAccumulatedMeters = 0
            return
        }
        guard carriedNode == nil, canManipulate(node, from: character) else {
            blockConnectionStartGeneration = nil
            trackedBlockID = nil
            pushLastNodePosition = nil
            pushTrackedNodeID = nil
            pushAccumulatedMeters = 0
            return
        }

        let targetID = ObjectIdentifier(node)
        if trackedBlockID != targetID {
            trackedBlockID = targetID
            blockConnectionStartGeneration = ca?.generation ?? 0
        }

        if pushTrackedNodeID != targetID {
            pushTrackedNodeID = targetID
            pushLastNodePosition = nil
            pushAccumulatedMeters = 0
        }

        let forward = forwardVector()
        let c = character.presentation.worldPosition
        let n = node.presentation.worldPosition

        let dx = Float(n.x - c.x)
        let dz = Float(n.z - c.z)
        let ahead = dx * forward.x + dz * forward.z
        let sideways = abs(dx * forward.z - dz * forward.x)

        guard ahead > 0.05, ahead < 1.8, sideways < 0.85 else {
            pushLastNodePosition = nil
            return
        }

        configurePhysicsBody(for: node, forceDynamic: true)
        guard let body = node.physicsBody else { return }

        body.velocity = SCNVector3(forward.x * pushBlockSpeed, body.velocity.y, forward.z * pushBlockSpeed)
        body.angularVelocity = SCNVector4Zero

        let current = SIMD2<Float>(Float(n.x), Float(n.z))
        if let last = pushLastNodePosition {
            let moved = current - last
            pushAccumulatedMeters += moved.x * forward.x + moved.y * forward.z
        }
        pushLastNodePosition = current

        locomotion.reportPushProgress(pushAccumulatedMeters)
    }

    @discardableResult
    private func dropCarriedObject(
        distance: Float,
        thrown: Bool,
        direction: SIMD2<Float>? = nil
    ) -> Bool {
        guard let carriedNode,
              let character = characterNode,
              let scene else {
            return false
        }

        let forward: SIMD3<Float> = direction.map {
            SIMD3<Float>($0.x, 0, $0.y)
        } ?? forwardVector()

        let position = character.presentation.worldPosition
        let halfDepth = worldDimensions(of: carriedNode).z * 0.5
        let reach = distance + halfDepth

        let destinationXZ = SCNVector3(
            position.x + forward.x * reach,
            position.y,
            position.z + forward.z * reach
        )

        let startWorld = carriedNode.presentation.worldPosition

        carriedNode.removeFromParentNode()
        scene.rootNode.addChildNode(carriedNode)

        carriedNode.position = scene.rootNode.convertPosition(
            startWorld,
            from: nil
        )

        carriedNode.position = SCNVector3(
            destinationXZ.x,
            max(Float(carriedNode.position.y), Float(position.y) + 0.25),
            destinationXZ.z
        )

        var snappedIndex: Int?
        var snappedSlot: SCNNode?

        if !thrown,
           let index = letterSlotIndex(forCarried: carriedNode),
           let slot = letterSlotNode(index: index) {

            let sp = slot.presentation.worldPosition
            let toSlot = sqrt(
                Float((sp.x - position.x) * (sp.x - position.x)) +
                Float((sp.z - position.z) * (sp.z - position.z))
            )

            if toSlot <= letterPlaceReach {
                carriedNode.position = SCNVector3(
                    sp.x,
                    sp.y +
                        worldDimensions(of: slot).y * 0.5 +
                        worldDimensions(of: carriedNode).y * 0.5 +
                        0.005,
                    sp.z
                )

                snappedIndex = index
                snappedSlot = slot
            }
        }

        configurePhysicsBody(for: carriedNode, forceDynamic: true)

        if let body = carriedNode.physicsBody {
            body.velocity = SCNVector3Zero
            body.angularVelocity = SCNVector4Zero
            body.resetTransform()

            if thrown {
                body.applyForce(
                    SCNVector3(forward.x * 2.2, 3.0, forward.z * 2.2),
                    asImpulse: true
                )
            }
        }

        if let snappedIndex,
           let snappedSlot {
            finalizePlacedLetter(
                carriedNode,
                index: snappedIndex,
                slot: snappedSlot
            )

            if let task = ca?.missionQueue.currentTask,
               task.actions.first == .placeObject,
               task.targetNode == snappedSlot {
                ca?.missionQueue.completeCurrentMissionTask(
                    because: "Letter snapped into its matching slot"
                )
            }
        } else {
            rememberNode(carriedNode, time: currentFrameTime)
        }

        self.carriedNode = nil
        self.carriedOriginalParent = nil

        return true
    }

    @discardableResult
    func placeCarriedObjectAhead() -> Bool { dropCarriedObject(distance: 0.9, thrown: false) }

    @discardableResult
    func throwCarriedObjectAhead() -> Bool { dropCarriedObject(distance: 2.6, thrown: true) }

    private func updateCarriedObject() {
        if let carriedNode, carriedNode.parent == nil { self.carriedNode = nil }
    }

    private func updateDoorInteraction(executedAction: FrankensteinAction) {
        let forwardActions: Set<FrankensteinAction> = [.walk, .run, .stepForward, .stepUp, .jump]
        guard forwardActions.contains(executedAction), let character = characterNode, let door = doorNode else { return }
        let characterPosition = character.presentation.worldPosition
        let doorPosition = door.presentation.worldPosition
        let dx = Float(characterPosition.x - doorPosition.x)
        let dz = Float(characterPosition.z - doorPosition.z)
        let distance = sqrt(dx * dx + dz * dz)
        guard distance < interactionDistance else { return }
        let facing = forwardVector()
        let toDoor = SIMD2<Float>(-dx, -dz)
        let toDoorLength = simd_length(toDoor)
        if toDoorLength > 0.001 {
            let alignment = simd_dot(SIMD2<Float>(facing.x, facing.z), toDoor / toDoorLength)
            guard alignment > 0.3 else { return }
        }
        guard door.name?.lowercased().contains("door") == true, abs(door.eulerAngles.y) < 0.1 else { return }
        door.runAction(SCNAction.rotateBy(x: 0, y: CGFloat.pi / 2, z: 0, duration: 0.35))
        publishDebug("Opened nearby door.")
    }

    private func isCharacterPart(_ node: SCNNode) -> Bool {
        guard let characterNode else { return false }
        if node === characterNode { return true }
        var current: SCNNode? = node.parent
        while let parent = current {
            if parent === characterNode { return true }
            current = parent.parent
        }
        return false
    }

    private func isFloorSurface(_ node: SCNNode) -> Bool {
        let name = node.name?.lowercased() ?? ""
        if name.contains("floor") || name.contains("ground") { return true }
        let size = worldDimensions(of: node)
        return size.y < 0.2 && max(size.x, size.z) > 3.0
    }

    private func isGroundLikeNode(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node
        while let candidate = current {
            let name = candidate.name?.lowercased() ?? ""
            if name.contains("floor") || name.contains("ground") || name.contains("terrain") || name.contains("platform") {
                return true
            }
            current = candidate.parent
        }
        return false
    }

    private func forwardVector() -> SIMD3<Float> {
        SIMD3<Float>(-sin(heading), 0, -cos(heading))
    }

    private func publishGeneralStats() {
        let action = locomotion.activeActionName
        let terrain = String(describing: latestTerrainSample.terrain)
        if action != lastDisplayedActionName {
            lastDisplayedActionName = action
            DispatchQueue.main.async { [weak self] in self?.onActionChanged?(action) }
        }
        if let narrative = ca?.lastDecisionDescription {
            DispatchQueue.main.async { [weak self] in self?.onPlanText?(narrative) }
        }
        let data = getMissionQueuePlanString()

        DispatchQueue.main.async { [weak self] in
            self?.onMissionText?(data)
        }
        
        let perception = getFrankensteinPerception()
        DispatchQueue.main.async { [weak self] in
            self?.onPerceptionText?(perception)
        }
        
        let goals = getCurrentGoalSummary()
        DispatchQueue.main.async { [weak self] in
            self?.onGoalText?(goals)
        }
       
        let currentTasks = getCurrentTaskAndActions()
        
        DispatchQueue.main.async { [weak self] in
            self?.onCurrentTaskText?(currentTasks)
        }
        
        
        let pathText = pathGoalDistance.isFinite ? String(format: "%.2f", Double(pathGoalDistance)) : "n/a"
        let stats = """
        Action: \(action)
        Power: \(Int(energyManager.powerLevel))%
        Love: \(Int(energyManager.love))%
        Terrain: \(terrain)
        Distance ahead: \(String(format: "%.2f", Double(latestTerrainSample.distance))) m
        Visible objects: \(visibleObjects.count)
        Recharge distance: \(String(format: "%.2f", Double(rechargePlatformDistance))) m
        CA path distance: \(pathText) m
        Mission queue: \(ca?.missionQueue.summary ?? "CA not attached")
        CA plan: \(ca?.plannedSequence.map { String(describing: $0) }.joined(separator: " > ") ?? "n/a")
        """
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStats?(stats)
            if stats != self.lastDebugMessage {
                self.lastDebugMessage = stats
                self.onDebugInfo?(stats)
            }
        }
    }

    private func publishDebug(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onDebugInfo?(message) }
    }
}

extension Coordinator {
    func attachExecutiveCA(_ ca: FrankensteinCA) { attachCA(ca) }
    func logExecutiveControlState(terrain: FrankensteinTerrainSample, locomotion: FrankensteinLocomotion) {}
}
