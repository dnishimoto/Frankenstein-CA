import Foundation
import SceneKit
import simd
import SwiftUI
import UIKit

final class Coordinator: NSObject, SCNSceneRendererDelegate {
    private var powerLevel: Float = 100.0
    private weak var powerMeterNode: SCNNode?
    private var currentFrameTime: TimeInterval = 0
    private let requiredRechargeContactDuration: TimeInterval = 1.0
    private var hasCompletedRechargeGoal = false

    // CA perception state (the CA, not the Coordinator, turns the character
    // by choosing turnLeft / turnRight; these values are only its inputs).
    private var clearanceAhead: Float = 4
    private var clearancePlus: Float = 4     // side reached by .turnRight
    private var clearanceMinus: Float = 4    // side reached by .turnLeft
    private var goalProgressRate: Float = 0
    private var lastPathDistance: Float = .infinity
    private var lastPathDistanceTime: TimeInterval = 0
    private let clearanceRange: Float = 3.0

    private var lastGoalDistance: Float = .infinity

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
    
    private var effectiveRechargeStationNode: SCNNode? {
        return powerLevel < 30.0 ? rechargeStationNode : nil
    }

    // MARK: - Simulation

    private let locomotion: FrankensteinLocomotion
    private let qFloorGrid = FrankensteinQFloorGrid()
    private let predictivePerception = FrankensteinPredictivePerception()
    private var pendingPrediction: FrankensteinPredictedOutcome?
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
    //
    // The narrow corridor scan above drives terrain classification, so it
    // stays as it is. This second, wide scan sees the whole forward half-plane
    // out to a long range and feeds the path field, the CA and the UI.

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
    private let planSpline = FrankensteinPlanSpline()
    private var lastStuckSamplePosition: SCNVector3?
    private var stuckSeconds: Float = 0
    private let stuckThreshold: Float = 0.8
    private var spawnedMovableBlocks = false
    private var pushLastNodePosition: SIMD2<Float>?
    private var pushTrackedNodeID: ObjectIdentifier?
    private var pushAccumulatedMeters: Float = 0
    private let pushBlockSpeed: Float = 0.6

    var onPlanText: ((String) -> Void)?
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

    private func canManipulate(_ target: SCNNode, from character: SCNNode) -> Bool {
        guard target.parent != nil, target !== carriedNode,
              !isCharacterPart(target) else { return false }
        let c = character.presentation.worldPosition
        let n = target.presentation.worldPosition
        let dx = Float(n.x - c.x)
        let dz = Float(n.z - c.z)
        let distance = sqrt(dx * dx + dz * dz)
        guard distance.isFinite, distance > 0.001,
              distance < manipulationDistance else { return false }
        let forward = forwardVector()
        let length = sqrt(forward.x * forward.x + forward.z * forward.z)
        guard length > 0.001 else { return false }
        let ahead = dx * forward.x + dz * forward.z
        return ahead > 0.05 && ahead / (distance * length) >= minimumManipulationAlignment
    }

    private func reachablePickupTarget(character: SCNNode, scene: SCNScene) -> SCNNode? {
        guard carriedNode == nil, handNode != nil,
              let hit = nearestPickupNode(from: character, in: scene),
              let target = pickupTarget(for: hit),
              canManipulate(target, from: character) else { return nil }
        return target
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
        locomotion: FrankensteinLocomotion
    ) {
        self.scene = scene
        self.characterNode = characterNode
        self.locomotion = locomotion

        super.init()

        previousCharacterPosition =
            characterNode.presentation.worldPosition

        hasPreviousCharacterPosition = true
    }

    // MARK: - CA Attachment

    func attachCA(_ ca: FrankensteinCA) {
        self.ca = ca
        locomotion.attachCA(ca)

        publishCAStats()

        print("[CA] Connected to Coordinator and Locomotion.")
        print("[CA] Generation: \(ca.generation)")
        print("[CA] Live cells: \(ca.liveCellCount)")
    }

    private func tickCA() {
        guard let ca else { return }

        ca.step()
        publishCAStats()

        print(
            "[CA] Generation: \(ca.generation), " +
            "Live cells: \(ca.liveCellCount)"
        )
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
        guard let station = effectiveRechargeStationNode else {
            return nil
        }

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

        while bearingError > .pi {
            bearingError -= 2 * .pi
        }

        while bearingError < -.pi {
            bearingError += 2 * .pi
        }

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
                            let worldPoint = node.presentation.convertPosition(
                                SCNVector3(x, y, z),
                                to: nil
                            )

                            minimumWorldY = min(
                                minimumWorldY,
                                Float(worldPoint.y)
                            )
                        }
                    }
                }
            }

            for child in node.childNodes {
                visit(child)
            }
        }

        visit(character)

        guard minimumWorldY.isFinite else {
            return 0
        }

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

            characterVerticalVelocity = 0
            hasReportedFall = false
            hasReportedRecharge = false

            previousCharacterPosition =
                characterNode.presentation.worldPosition

            hasPreviousCharacterPosition = true
            jumpBaseY = nil

            doorNode = findNode(containing: "door", under: scene.rootNode)
            tableNode = findNode(containing: "table", under: scene.rootNode)
            rechargeStationNode = findNode(
                containing: "rechargestation",
                under: scene.rootNode
            )

            qFloorGrid.attach(to: scene)
            planSpline.attach(to: scene)
            addLetterPlaceholders(to: scene)
            
            setupPowerMeter(on: characterNode)

            publishDebug("Coordinator attached to displayed scene.")
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
            let box = SCNBox(
                width: blockSize,
                height: blockSize,
                length: blockSize,
                chamferRadius: 0.035
            )
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(
                hue: CGFloat((placements.firstIndex(where: { $0.name == placement.name }) ?? 0)) / CGFloat(placements.count),
                saturation: 0.55,
                brightness: 0.82,
                alpha: 1
            )
            material.specular.contents = UIColor(white: 0.22, alpha: 1)
            box.materials = [material]

            let node = SCNNode(geometry: box)
            node.name = placement.name
            node.position = SCNVector3(placement.x, placement.y, placement.z)
            node.physicsBody = SCNPhysicsBody(type: .dynamic, shape: SCNPhysicsShape(geometry: box, options: nil))
            node.physicsBody?.mass = 1.5
            node.physicsBody?.friction = 0.9
            node.physicsBody?.rollingFriction = 0.9
            node.physicsBody?.restitution = 0.02
            node.physicsBody?.damping = 0.15
            node.physicsBody?.angularDamping = 0.3
            node.physicsBody?.allowsResting = true
            scene.rootNode.addChildNode(node)
        }

        publishDebug("Added 10 movable blocks.")
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
            if candidate.name == "FrankensteinQFloorGrid" {
                return true
            }

            current = candidate.parent
        }

        return false
    }

    func attachDoor(_ node: SCNNode?) {
        doorNode = node
    }

    func attachTable(_ node: SCNNode?) {
        tableNode = node

        guard let node, let scene else { return }

        placeObjectOnSupportSurface(node, in: scene)
        configurePhysicsBody(for: node, forceDynamic: true)

        publishDebug("Table attached.")
    }

    @discardableResult
    private func placeObjectOnSupportSurface(
        _ node: SCNNode,
        in scene: SCNScene
    ) -> Bool {
        guard let bottomY = worldBottomY(of: node),
              let surfaceY = supportSurfaceBelow(node, in: scene) else {
            return false
        }

        let correction = surfaceY - bottomY
        guard correction.isFinite, abs(correction) > 0.001 else {
            return true
        }

        let oldWorldPosition = node.presentation.worldPosition
        let correctedWorldPosition = SCNVector3(
            oldWorldPosition.x,
            oldWorldPosition.y + correction,
            oldWorldPosition.z
        )

        if let parent = node.parent {
            node.position = parent.convertPosition(correctedWorldPosition, from: nil)
        } else {
            node.position = correctedWorldPosition
        }

        node.physicsBody?.resetTransform()
        return true
    }

    private func supportSurfaceBelow(
        _ object: SCNNode,
        in scene: SCNScene
    ) -> Float? {
        guard let bottomY = worldBottomY(of: object) else {
            return nil
        }

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
                if candidate === object {
                    belongsToObject = true
                    break
                }
                current = candidate.parent
            }

            guard !belongsToObject,
                  !isCharacterPart(hitNode),
                  !isQGridNode(hitNode),
                  hit.worldNormal.y > 0.5 else {
                continue
            }

            let name = (hitNode.name ?? "").lowercased()
            if name.contains("marker") || name.contains("rechargestation") {
                continue
            }

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

            for child in current.childNodes {
                inspect(child)
            }
        }

        inspect(node)
        return lowest.isFinite ? lowest : nil
    }

    func attachHand(_ node: SCNNode?) {
        handNode = node
    }

    // MARK: - Start / Stop

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
    }

    // MARK: - Renderer Update

    func renderer(
        _ renderer: SCNSceneRenderer,
        updateAtTime time: TimeInterval
    ) {
        guard isRunning,
              let scene = scene,
              let character = characterNode else {
            return
        }

        currentFrameTime = time

        let dt: Float
        if lastFrameTime == 0 {
            dt = 1.0 / 60.0
        } else {
            dt = Float(min(max(time - lastFrameTime, 1.0 / 240.0), 0.05))
        }

        lastFrameTime = time
        dtFromLastFrame = dt

        // MARK: Power Level & Recharge Station Visibility Management
        if hasReportedRecharge {
            powerLevel = min(100.0, powerLevel + dt * 35.0)
            if powerLevel >= 100.0 {
                hasReportedRecharge = false
                hasCompletedRechargeGoal = false
            }
        } else {
            let drainRate: Float = locomotion.output.speed > 0 ? 2.0 : 0.4
            powerLevel = max(0.0, powerLevel - dt * drainRate)
        }

        // Frankenstein only sees/interacts with the recharge station when power < 30%
        let shouldShowRecharge = powerLevel < 30.0
        rechargeStationNode?.isHidden = !shouldShowRecharge
        rechargeStationNode?.physicsBody?.categoryBitMask = shouldShowRecharge ? 1 : 0

        if let textGeo = powerMeterNode?.geometry as? SCNText {
            let percentage = Int(powerLevel)
            textGeo.string = "⚡ Power: \(percentage)%"
            if let mat = textGeo.materials.first {
                if powerLevel > 50 {
                    mat.diffuse.contents = UIColor.systemGreen
                } else if powerLevel > 20 {
                    mat.diffuse.contents = UIColor.systemYellow
                } else {
                    mat.diffuse.contents = UIColor.systemRed
                }
            }
        }

        if time - lastCATickTime >= caTickInterval {
            lastCATickTime = time
            DispatchQueue.main.async { [weak self] in
                self?.tickCA()
            }
        }

        // MARK: 1. Object perception

        if time - lastSensorTime >= sensorInterval {
            lastSensorTime = time

            let detailedDetections = detectAllObjectsAhead(
                from: character,
                in: scene
            )

            latestDetections = detailedDetections.map { $0.info }

            latestDetectionNodes = Dictionary(
                uniqueKeysWithValues: detailedDetections.map {
                    (ObjectIdentifier($0.node), $0.info)
                }
            )

            latestDetection = latestDetections.first

            pushTargetNode = findPushTargetNode(
                character: character,
                in: scene,
                detections: detailedDetections
            )

            if time - lastWideScanTime >= wideScanInterval {
                lastWideScanTime = time
                wideDetections = scanWideFieldOfView(
                    from: character,
                    in: scene
                )
            }

            visibleObjects = mergeVisibleObjects(
                near: latestDetections,
                wide: wideDetections,
                character: character
            )

            verifiedGroundSupport = verifySupportBeneathCharacter(
                character: character,
                in: scene
            )

            let fanObstacles = scanClearanceFan(
                from: character,
                in: scene
            )

            updatePathField(
                character: character,
                detections: visibleObjects,
                extraObstacles: fanObstacles,
                time: time
            )

            updateObjectQValues(
                terrain: latestTerrainSample,
                detections: detailedDetections
            )

            let nearest = latestDetections.first
            let everythingSeen = visibleObjects

            DispatchQueue.main.async { [weak self] in
                self?.onDetectedObject?(nearest)
                self?.onDetectedObjects?(everythingSeen)
            }

            logRayObservations()
        }

        latestTerrainSample = makeTerrainSample(
            for: character,
            in: scene
        )

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
                latestTerrainSample.obstacleHeight = max(
                    0,
                    targetTop - latestTerrainSample.groundHeight
                )
                latestTerrainSample.obstacleDepth = dimensions.z
                latestTerrainSample.canLandOnObject =
                    dimensions.x >= 0.3 && dimensions.z >= 0.3 &&
                    latestTerrainSample.obstacleHeight > 0.05 &&
                    latestTerrainSample.obstacleHeight <= 1.0 &&
                    hasClearSpace(
                        around: SCNVector3(n.x, Float(targetTop + 0.15), n.z),
                        in: scene
                    )
                if latestTerrainSample.obstacleHeight > 0.45 {
                    latestTerrainSample.terrain = .hurdle
                } else if latestTerrainSample.obstacleHeight > 0.05 {
                    latestTerrainSample.terrain = .raisedStep
                }
            }
        }

        let currentPosition = character.presentation.worldPosition
        updateStuckDuration(position: currentPosition, deltaTime: dt)

        let actualDisplacement: Float?
        if hasPreviousCharacterPosition {
            actualDisplacement = measureForwardDisplacement(
                from: previousCharacterPosition,
                to: currentPosition
            )
        } else {
            actualDisplacement = nil
        }

        previousCharacterPosition = currentPosition
        hasPreviousCharacterPosition = true

        if let prediction = pendingPrediction, let actualDisplacement {
            let error = predictivePerception.observe(
                prediction: prediction,
                actualForwardDisplacement: actualDisplacement,
                terrain: latestTerrainSample
            )
            if abs(error) > 0.18 {
                publishDebug("Prediction error adjusted.")
            }
            pendingPrediction = nil
        }

        markFieldOfViewDirty(character: character, time: time)

        let perceivedValues = locomotion.policy.learnedActionValues(
            terrain: latestTerrainSample,
            body: locomotion.body
        )

        let perceivedActions = FrankensteinActionConstraints.allowedActions(
            terrain: latestTerrainSample,
            body: locomotion.body
        )

        let advisoryValues = makeAdvisoryActionValues(
            baseValues: perceivedValues,
            allowedActions: perceivedActions
        )

        locomotion.receivePerception(
            allowedActions: perceivedActions,
            qValues: advisoryValues
        )

        let objectObservation: FrankensteinObjectObservation? = {
            if let target = pushTargetNode,
               target.parent != nil,
               let character = characterNode {
                let c = character.presentation.worldPosition
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
        }()

        pushPerceptionToCA(
            terrain: latestTerrainSample,
            allowedActions: perceivedActions,
            time: time
        )

        let output = locomotion.step(
            deltaTime: dt,
            terrain: latestTerrainSample,
            actualDisplacement: actualDisplacement,
            objectObservation: objectObservation
        )

        pendingPrediction = predictivePerception.predict(
            actionName: String(describing: output.action),
            terrain: latestTerrainSample,
            body: locomotion.body,
            objectObservation: objectObservation
        )

        applyMovement(
            output: output,
            deltaTime: dt,
            character: character,
            scene: scene
        )

        applyPush(
            output: output,
            deltaTime: dt,
            character: character
        )

        let finalPosition = character.presentation.worldPosition
        let stationaryByDesign: Set<FrankensteinAction> = [
            .turnLeft, .turnRight, .recover,
            .liftObject, .placeObject, .throwObject
        ]

        if !stationaryByDesign.contains(output.action) {
            ca?.observeMovementForFutility(
                action: output.action,
                x: Float(finalPosition.x),
                z: Float(finalPosition.z),
                timestamp: time
            )
        }

        if goalProgressRate > 0.15 {
            ca?.forgiveFutility(for: output.action, amount: 0.05)
        }

        evaluateActionOutcome(
            output: output,
            actualDisplacement: actualDisplacement,
            character: character,
            scene: scene,
            time: time
        )

        animateCharacter(character: character)
        updateCarriedObject()
        updateDoorInteraction(executedAction: output.action)

        let policyUpdates = locomotion.policy.updateCount
        if policyUpdates > lastRecordedQUpdate {
            let newCount = policyUpdates - lastRecordedQUpdate
            for record in locomotion.policy.qUpdateRecords.suffix(newCount) {
                qFloorGrid.record(
                    position: character.presentation.worldPosition,
                    action: record.action,
                    newValue: record.newValue
                )
            }
            lastRecordedQUpdate = policyUpdates
        }

        if time - lastQGridPublishTime >= 0.2 {
            lastQGridPublishTime = time
            let cells = locomotion.policy.qDisplaySnapshot(
                objectsInView: visibleObservations(),
                terrain: latestTerrainSample,
                body: locomotion.body
            )
            DispatchQueue.main.async { [weak self] in
                self?.onQGrid?(cells)
            }
        }

        updatePlanSpline(character: character, time: time)

        qFloorGrid.update(
            position: character.presentation.worldPosition,
            policy: locomotion.policy,
            sample: latestTerrainSample,
            body: locomotion.body
        )

        if time - lastStatsTime >= statsInterval {
            lastStatsTime = time
            publishGeneralStats()
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
        // Only target the recharge station if power is < 30%
        if let station = effectiveRechargeStationNode {
            let s = station.presentation.worldPosition
            goalXZ = SIMD2<Float>(Float(s.x), Float(s.z))
        }

        var obstacles: [FrankensteinCAPathField.Obstacle] = []

        for detection in detections {
            let className = objectClass(for: detection.name)
            if className == "rechargeStation" { continue }
            if detection.name.lowercased().contains("ceiling") { continue }

            obstacles.append(
                FrankensteinCAPathField.Obstacle(
                    center: SIMD2<Float>(
                        Float(detection.worldPosition.x),
                        Float(detection.worldPosition.z)
                    ),
                    halfExtent: SIMD2<Float>(
                        Float(detection.dimensions.x) * 0.5,
                        Float(detection.dimensions.z) * 0.5
                    ),
                    className: className
                )
            )
        }

        obstacles.append(contentsOf: extraObstacles)

        executive.field.observe(obstacles, time: time)
        executive.field.rebuild(character: characterXZ, goal: goalXZ)

        pathSteering = executive.field.steering()
        pathGoalDistance = pathSteering?.pathDistance ?? .infinity

        if pathGoalDistance.isFinite,
           lastPathDistance.isFinite,
           lastPathDistanceTime > 0,
           time > lastPathDistanceTime {
            let instant = (lastPathDistance - pathGoalDistance) /
                Float(time - lastPathDistanceTime)

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

                guard !isCharacterPart(node),
                      !isFloorSurface(node),
                      !isQGridNode(node),
                      !name.contains("marker"),
                      !name.contains("rechargestation"),
                      !name.contains("floor"),
                      !name.contains("ground") else {
                    continue
                }

                if hit.worldNormal.y > 0.85 { continue }

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
            perception.goal = .recharge
            perception.subGoal = ""

            let routedHeading = pathSteering?.heading ?? heading
            perception.headingError = pathSteering == nil ? 0 : wrappedAngle(routedHeading - heading)

            perception.pathDistance = pathGoalDistance
            perception.isDetouring = pathSteering?.isDetouring ?? false
            perception.goalProgressRate = goalProgressRate

            perception.atGoal =
                hasReportedRecharge ||
                (pathGoalDistance.isFinite && pathGoalDistance < 0.35)

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

            if let target = pushTargetNode,
               target.parent != nil,
               let character = characterNode {
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

            let distant = visibleObjects.filter { $0.distance >= 3.0 }
            perception.distantObjectSummary = distant.isEmpty ? "" : DetectedObjectInfo.summary(of: distant, limit: 3)

            perception.routeRelativeHeadings = executive.field
                .routePreview(maxCells: 8)
                .map { wrappedAngle($0 - heading) }

            let goalValues = executive.learner.values(for: goalStateKey(terrain: terrain))
            let objectValues = latestDetection.map {
                executive.learner.values(for: objectStateKey(for: $0, terrain: terrain))
            } ?? [:]

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

            if let target = pushTargetNode,
               target.parent != nil,
               let character = characterNode {
                let c = character.presentation.worldPosition
                let n = target.presentation.worldPosition
                let dx = Float(n.x - c.x)
                let dz = Float(n.z - c.z)
                let distance = sqrt(dx * dx + dz * dz)
                let forward = forwardVector()
                let ahead = dx * forward.x + dz * forward.z
                let sideways = abs(dx * forward.z - dz * forward.x)
                let alignment = distance > 0.001 ? ahead / distance : 0

                let routeBlocked =
                    clearanceAhead < 1.0 ||
                    terrain.terrain == .hurdle ||
                    terrain.terrain == .raisedStep ||
                    (pathSteering?.isDetouring ?? false)

                if distance.isFinite,
                   distance <= 1.0,
                   ahead > 0.05,
                   alignment > 0.7,
                   (routeBlocked || stuckSeconds > stuckThreshold) {
                    advisory[.pushObject, default: 0] += 7.0
                    advisory[.jump, default: 0] -= 1.0
                } else {
                    advisory[.pushObject, default: 0] -= 1.0
                }
            }

            if let detection = latestDetection,
               detection.distance <= 2.5,
               (detection.name.lowercased().contains("recharge") ||
                detection.name.lowercased().contains("platform")) {
                advisory[.jump, default: 0] += 4.0
                advisory[.walk, default: 0] -= 1.0
            }

            if let target = pushTargetNode, target.parent != nil {
                perception.subGoal = "Approach and interact with movable block"
            } else if let detection = latestDetection, detection.distance < 3.0 {
                perception.subGoal = "Approach \(detection.name)"
            } else {
                perception.subGoal = ""
            }

            perception.advisoryValues = advisory
            perception.stateKey = [
                String(describing: terrain.terrain),
                headingBand(perception.headingError),
                clearanceBand(clearanceAhead),
                perception.nearestObjectClass,
                perception.nearestObjectDistance.isFinite ? distanceBand(perception.nearestObjectDistance) : "none",
                carriedNode != nil ? "carrying" : "empty"
            ].joined(separator: "|")

            perception.timestamp = time
            ca.receivePerception(perception)
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
            
            // Shifted to the left corner (adjust -5.0 to fit your exact left wall/corner boundary)
            let xOffset = -5.0 + Float(index) * 0.52
            
            node.position = SCNVector3(xOffset, 0.05, -2.5)
            node.physicsBody = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: box, options: nil))
            scene.rootNode.addChildNode(node)

            let textGeometry = SCNText(string: String(letter), extrusionDepth: 0.02)
            textGeometry.font = UIFont.systemFont(ofSize: 0.32, weight: .bold)
            
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
        
        let textGeometry = SCNText(string: "⚡ Power: 100%", extrusionDepth: 0.01)
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

            let objectKey = latestDetection.map {
                objectStateKey(for: $0, terrain: latestTerrainSample)
            }

            let objectValues = objectKey.map {
                executive.learner.values(for: $0)
            } ?? [:]

            for action in allowedActions {
                let actionName = String(describing: action)
                let goalValue = goalValues[actionName] ?? 0
                let objectValue = objectValues[actionName] ?? 0

                merged[action, default: 0] +=
                    0.35 * goalValue +
                    0.20 * objectValue
            }

            if allowedActions.contains(.liftObject), canLiftNow {
                merged[.liftObject, default: 0] += 5.0
                merged[.jump, default: 0] -= 5.0
            }

            if let target = pushTargetNode,
               target.parent != nil,
               allowedActions.contains(.pushObject),
               let character = characterNode {
                let c = character.presentation.worldPosition
                let n = target.presentation.worldPosition
                let dx = Float(n.x - c.x)
                let dz = Float(n.z - c.z)
                let distance = sqrt(dx * dx + dz * dz)
                let forward = forwardVector()
                let ahead = dx * forward.x + dz * forward.z
                let sideways = abs(dx * forward.z - dz * forward.x)
                let alignment = distance > 0.001 ? ahead / distance : 0
                let routeBlocked = clearanceAhead < 1.0 ||
                    latestTerrainSample.terrain == .hurdle ||
                    latestTerrainSample.terrain == .raisedStep ||
                    (pathSteering?.isDetouring ?? false)
                if distance.isFinite, distance <= 1.0,
                   ahead > 0.05, alignment > 0.7,
                   (routeBlocked || stuckSeconds > stuckThreshold) {
                    merged[.pushObject, default: 0] += 7.0
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
                  node !== character,
                  !isCharacterPart(node),
                  let name = node.name,
                  isMovableName(name) else { return }

            let lower = name.lowercased()
            if lower.contains("floor") || lower.contains("wall") ||
                lower.contains("platform") || lower.contains("stair") ||
                lower.contains("step") || lower.contains("doorframe") {
                return
            }
            guard node.geometry != nil || !node.childNodes.isEmpty else { return }

            let n = node.presentation.worldPosition
            let dx = Float(n.x - c.x)
            let dz = Float(n.z - c.z)
            let distance = sqrt(dx * dx + dz * dz)
            let ahead = dx * forward.x + dz * forward.z
            let side = abs(dx * forward.z - dz * forward.x)
            guard distance.isFinite, ahead > 0.05, ahead <= 2.3,
                  side < 1.0 else { return }
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
        guard let station = effectiveRechargeStationNode else {
            planSpline.update(
                time: time,
                character: character.presentation.worldPosition,
                object: nil,
                destination: nil
            )
            return
        }

        let queue = ca?.planBuffer.pendingActions ?? []
        let planMovesObject = queue.contains(.pushObject) ||
            queue.contains(.liftObject) ||
            queue.contains(.placeObject)

        var objectPosition: SCNVector3?

        if let target = pushTargetNode, target.parent != nil {
            objectPosition = target.presentation.worldPosition
        } else if planMovesObject {
            objectPosition = visibleObjects
                .filter { isMovableName($0.name) }
                .min(by: { $0.distance < $1.distance })?
                .worldPosition
        }

        planSpline.update(
            time: time,
            character: character.presentation.worldPosition,
            object: objectPosition,
            destination: station.presentation.worldPosition
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

        policy.markVisibleDirty(
            terrain: latestTerrainSample,
            body: locomotion.body
        )

        policy.markVisibleDirty(
            objects: visibleObservations(),
            terrain: latestTerrainSample,
            body: locomotion.body
        )

        qFloorGrid.markVisible(
            position: character.presentation.worldPosition,
            heading: Float(character.presentation.eulerAngles.y),
            halfAngle: wideScanHalfAngleDegrees * .pi / 180,
            range: 6
        )
    }

    private func isMovableName(_ name: String) -> Bool {
        let value = name.lowercased()
        return value.contains("movable") ||
            value.contains("block") ||
            value.contains("crate") ||
            value.contains("box") ||
            value.contains("pickup")
    }

    private func annotateBearing(
        _ info: DetectedObjectInfo,
        character: SCNNode
    ) -> DetectedObjectInfo {
        let c = character.presentation.worldPosition
        let dx = Float(info.worldPosition.x - c.x)
        let dz = Float(info.worldPosition.z - c.z)
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

                    guard !isCharacterPart(hitNode),
                          !isFloorSurface(hitNode),
                          !isQGridNode(hitNode),
                          !lowered.contains("marker") else {
                        continue
                    }

                    let hx = Float(hit.worldCoordinates.x - position.x)
                    let hz = Float(hit.worldCoordinates.z - position.z)
                    let hitDistance = sqrt(hx * hx + hz * hz)

                    guard hitDistance >= Self.minimumHitDistance else { continue }

                    let target: SCNNode
                    if let pickupNode = pickupTarget(for: hitNode) {
                        target = pickupNode
                    } else {
                        target = meaningfulDetectionParent(for: hitNode)
                    }

                    guard !isContainerNode(target),
                          !isCharacterPart(target),
                          target !== character else {
                        continue
                    }

                    let dimensions = worldDimensions(of: target)
                    guard dimensions.x > 0.001,
                          dimensions.y > 0.001,
                          dimensions.z > 0.001,
                          max(dimensions.x, max(dimensions.y, dimensions.z)) <= wideScanMaximumExtent else {
                        continue
                    }

                    let info = DetectedObjectInfo(
                        name: readableName(for: target),
                        dimensions: dimensions,
                        distance: hitDistance,
                        worldPosition: target.presentation.worldPosition,
                        pickupable: pickupTarget(for: target) != nil,
                        topY: worldTopY(of: target)
                    )

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

        for height in [Float(0.12), 0.40, 0.90] {
            for lateral in [Float(-0.6), -0.3, 0, 0.3, 0.6] {
                if let found = detectDetailedObjectAhead(
                    from: character,
                    in: scene,
                    rayHeight: height,
                    lateral: lateral
                ) {
                    let key = ObjectIdentifier(found.node)
                    if let existing = unique[key] {
                        if found.info.distance < existing.info.distance {
                            unique[key] = found
                        }
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

        let origin = SCNVector3(
            position.x + forward.z * lateral,
            position.y + rayHeight,
            position.z - forward.x * lateral
        )

        let rayLength: Float = 4.0
        let end = SCNVector3(origin.x + forward.x * rayLength, origin.y, origin.z + forward.z * rayLength)

        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: true
        ]

        let hits = scene.rootNode.hitTestWithSegment(from: origin, to: end, options: options)

        for hit in hits {
            let hitNode = hit.node
            guard !isCharacterPart(hitNode),
                  !isFloorSurface(hitNode),
                  !isQGridNode(hitNode) else {
                continue
            }

            let hitPoint = hit.worldCoordinates
            let hitDistance = sqrt(Float((hitPoint.x - origin.x) * (hitPoint.x - origin.x) + Float((hitPoint.z - origin.z) * (hitPoint.z - origin.z))))

            guard hitDistance >= Self.minimumHitDistance else { continue }

            let target: SCNNode
            if let pickupNode = pickupTarget(for: hitNode) {
                target = pickupNode
            } else {
                target = meaningfulDetectionParent(for: hitNode)
            }

            guard !isContainerNode(target),
                  target !== character,
                  !isCharacterPart(target) else {
                continue
            }

            let dimensions = worldDimensions(of: target)
            guard dimensions.x > 0.001, dimensions.y > 0.001, dimensions.z > 0.001 else { continue }
            guard max(dimensions.x, max(dimensions.y, dimensions.z)) <= Self.maximumObstacleExtent else { continue }

            let dx = Float(hitPoint.x - origin.x)
            let dz = Float(hitPoint.z - origin.z)
            let distance = sqrt(dx * dx + dz * dz)
            guard distance <= rayLength else { continue }

            let resolvedName = readableName(for: target)
            let info = DetectedObjectInfo(
                name: resolvedName,
                dimensions: dimensions,
                distance: distance,
                worldPosition: target.presentation.worldPosition,
                pickupable: pickupTarget(for: target) != nil,
                topY: worldTopY(of: target)
            )

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
        
        // Allow jumps up to Frankenstein's maximum jumpable height (1.4m)
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
               rise > 0.05,
               rise <= FrankensteinPhysicalBody.maxJumpableHeight,
               detection.dimensions.x >= 0.3,
               detection.dimensions.z >= 0.3 {
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

    private func applyMovement(
        output: FrankensteinLocomotionOutput,
        deltaTime dt: Float,
        character: SCNNode,
        scene: SCNScene
    ) {
        guard dt.isFinite, dt > 0 else { return }
        heading = output.heading
        let forward = forwardVector()

        let baseSpeed: Float = (output.action == .pushObject) ? (pushTargetNode == nil ? 0 : max(0.45, output.speed)) : max(0, output.speed)
        let direction = (output.action == .pushObject && output.moveDirection == 0) ? 1.0 : output.moveDirection
        let speed = baseSpeed * direction

        if output.liftRequested, locomotion.policy.pendingAction == .liftObject {
            let stateKeyBeforePickup = latestDetection.map { objectStateKey(for: $0, terrain: latestTerrainSample) }
            let succeeded = attemptPickup()
            locomotion.reportPickupOutcome(succeeded: succeeded)
            if let stateKeyBeforePickup {
                reinforceOutcome(stateKey: stateKeyBeforePickup, action: .liftObject, reward: succeeded ? 1.0 : -0.5)
            }
        }

        if output.placeRequested, locomotion.policy.pendingAction == .placeObject {
            let stateKeyBeforePlace = latestDetection.map { objectStateKey(for: $0, terrain: latestTerrainSample) }
            let ok = placeCarriedObjectAhead()
            locomotion.reportObjectActionOutcome(.placeObject, reward: ok ? 0.5 : -0.5)
            if let stateKeyBeforePlace {
                reinforceOutcome(stateKey: stateKeyBeforePlace, action: .placeObject, reward: ok ? 0.5 : -0.5)
            }
        }

        if output.throwRequested, locomotion.policy.pendingAction == .throwObject {
            let stateKeyBeforeThrow = latestDetection.map { objectStateKey(for: $0, terrain: latestTerrainSample) }
            let ok = throwCarriedObjectAhead()
            locomotion.reportObjectActionOutcome(.throwObject, reward: ok ? 0.3 : -0.5)
            if let stateKeyBeforeThrow {
                reinforceOutcome(stateKey: stateKeyBeforeThrow, action: .throwObject, reward: ok ? 0.3 : -0.5)
            }
        }

        let oldWorld = character.presentation.worldPosition
        var proposedWorld = SCNVector3(
            oldWorld.x + forward.x * speed * dt,
            oldWorld.y,
            oldWorld.z + forward.z * speed * dt
        )

        let currentFeetY = Float(oldWorld.y) + characterFootOffset
        verifiedLandingSupport = verifyLandingSite(proposedPosition: proposedWorld, currentFeetY: currentFeetY, in: scene)

        if speed > 0, latestTerrainSample.terrain == .gap, !latestTerrainSample.isLandingAreaClear, !verifiedLandingSupport {
            proposedWorld.x = oldWorld.x
            proposedWorld.z = oldWorld.z
        }

        let isClimbing = locomotion.stepUpInProgress || output.action == .stepUp || output.action == .jump || output.action == .pushObject
        let isBlockingObstacle = latestTerrainSample.terrain == .hurdle || latestTerrainSample.terrain == .raisedStep

        if output.jump <= 0, speed > 0, !isClimbing, isBlockingObstacle, latestTerrainSample.distance < 0.5 {
            proposedWorld.x = oldWorld.x
            proposedWorld.z = oldWorld.z
        }

        if output.jump > 0 {
            if jumpBaseY == nil {
                jumpBaseY = Float(oldWorld.y)
                characterVerticalVelocity = 0
            }
            let baseY = jumpBaseY ?? Float(oldWorld.y)
            let heightOffset = max(0, locomotion.body.height - standingHeight)
            proposedWorld.y = baseY + heightOffset
        } else {
            jumpBaseY = nil
            let oldFeetY = currentFeetY
            let support = raycastSupport(
                at: SCNVector3(proposedWorld.x, oldFeetY, proposedWorld.z),
                in: scene,
                riseAllowance: max(1.0, abs(characterVerticalVelocity * dt) + 0.5)
            )

            characterVerticalVelocity -= worldGravity * dt
            let fallingFeetY = oldFeetY + characterVerticalVelocity * dt

            if let groundY = support, groundY.isFinite {
                let feetAboveSupport = oldFeetY - groundY
                let crossedSurface = oldFeetY >= groundY - 0.06 && fallingFeetY <= groundY
                let standingOnSurface = feetAboveSupport >= -0.06 && feetAboveSupport <= 0.10 && characterVerticalVelocity <= 0.5

                if standingOnSurface || crossedSurface {
                    proposedWorld.y = groundY - characterFootOffset
                    characterVerticalVelocity = 0
                } else if oldFeetY < groundY {
                    proposedWorld.y = groundY - characterFootOffset
                    characterVerticalVelocity = 0
                } else {
                    proposedWorld.y = fallingFeetY - characterFootOffset
                }
            } else {
                proposedWorld.y = fallingFeetY - characterFootOffset
            }
        }

        if let parent = character.parent {
            character.position = parent.convertPosition(proposedWorld, from: nil)
        } else {
            character.position = proposedWorld
        }
        character.eulerAngles.y = heading

        let finalFeetY = Float(character.presentation.worldPosition.y) + characterFootOffset
        if finalFeetY < -3.0 && !hasReportedFall {
            hasReportedFall = true
            locomotion.completeEpisode(.fell)
            executive.learner.clearTraces()
            reinforceOutcome(stateKey: goalStateKey(terrain: latestTerrainSample), action: output.action, reward: -2.0)
        } else if finalFeetY > -0.5 {
            hasReportedFall = false
        }

        // Only register recharge if the station is active (power < 30%) and reached
        if let station = effectiveRechargeStationNode {
            let c = character.presentation.worldPosition
            let size = worldDimensions(of: station)
            let s = station.presentation.worldPosition
            let topY = worldTopY(of: station)

            let onTop =
                abs(Float(c.x - s.x)) <= max(0.15, size.x * 0.5) &&
                abs(Float(c.z - s.z)) <= max(0.15, size.z * 0.5) &&
                abs(Float(c.y) + characterFootOffset - topY) <= 0.18

            if onTop {
                if !hasReportedRecharge {
                    locomotion.reportRecharge()
                    hasReportedRecharge = true
                    reinforceOutcome(stateKey: goalStateKey(terrain: latestTerrainSample), action: output.action, reward: 2.0)
                }
            } else {
                hasReportedRecharge = false
            }
        }
    }

    private func evaluateActionOutcome(
        output: FrankensteinLocomotionOutput,
        actualDisplacement: Float?,
        character: SCNNode,
        scene: SCNScene,
        time: TimeInterval
    ) {
        guard let station = effectiveRechargeStationNode else { return }

        let action = output.action
        let actionName = String(describing: action)
        let currentPosition = character.presentation.worldPosition
        let stationPosition = station.presentation.worldPosition

        let currentDx = Float(currentPosition.x - stationPosition.x)
        let currentDz = Float(currentPosition.z - stationPosition.z)
        let currentDistance = sqrt(currentDx * currentDx + currentDz * currentDz)
        let currentStateKey = goalStateKey(terrain: latestTerrainSample)

        guard actionName == lastEvaluatedActionName else {
            lastEvaluatedActionName = actionName
            lastGoalActionTime = time
            lastGoalActionPosition = currentPosition
            lastGoalDistance = currentDistance
            consecutiveNoProgressCount = 0
            outcomeWindowElapsedTime = 0
            outcomeWindowDisplacement = 0
            outcomeWindowGoalProgress = 0
            outcomeWindowPathProgress = 0
            lastEvalPathDistance = pathGoalDistance
            previousGoalStateKey = currentStateKey
            previousGoalAction = action
            return
        }

        defer {
            previousGoalStateKey = currentStateKey
            previousGoalAction = action
        }

        guard let displacement = actualDisplacement else { return }

        let previousDistance = lastGoalDistance
        let goalProgress = previousDistance - currentDistance

        rechargePlatformDistance = currentDistance
        lastGoalDistance = currentDistance

        outcomeWindowElapsedTime += Double(dtFromLastFrame)
        outcomeWindowDisplacement += displacement
        outcomeWindowGoalProgress += goalProgress

        if pathGoalDistance.isFinite, lastEvalPathDistance.isFinite {
            outcomeWindowPathProgress += lastEvalPathDistance - pathGoalDistance
        }
        lastEvalPathDistance = pathGoalDistance

        guard outcomeWindowElapsedTime >= outcomeWindowDuration else { return }

        let movingActions: Set<FrankensteinAction> = [.walk, .run, .stepForward, .crouch, .crawl, .roll]
        ca?.reportActionOutcome(
            action: action,
            goalProgressRate: outcomeWindowPathProgress / Float(outcomeWindowElapsedTime),
            windowDuration: Float(outcomeWindowElapsedTime),
            blocked: movingActions.contains(action) && abs(outcomeWindowDisplacement) < noProgressThreshold
        )

        var reward: Float = 0
        let nearbyClass: String? = {
            guard let detection = latestDetection, detection.distance < 1.0 else { return nil }
            return objectClass(for: detection.name)
        }()

        if abs(outcomeWindowDisplacement) < noProgressThreshold {
            consecutiveNoProgressCount += 1
            reward += noProgressPenalty
            if let nearbyClass { executive.field.learnClassOutcome(className: nearbyClass, blocked: true) }
        } else if outcomeWindowGoalProgress > 0.001 {
            consecutiveNoProgressCount = 0
            reward += outcomeWindowDisplacement * 0.25
            reward += outcomeWindowGoalProgress * goalProgressRewardScale
            if let nearbyClass { executive.field.learnClassOutcome(className: nearbyClass, blocked: false) }
        } else if outcomeWindowGoalProgress < -0.001 {
            consecutiveNoProgressCount += 1
            reward += outcomeWindowGoalProgress * goalProgressRewardScale
        } else {
            reward += outcomeWindowDisplacement * 0.05
        }

        if hasReportedRecharge {
            reward += 2.0
            if !hasReachedRechargePlatform {
                hasReachedRechargePlatform = true
                rechargePlatformContactTime = time
            }
        } else {
            hasReachedRechargePlatform = false
        }

        if hasReportedRecharge {
            if rechargePlatformContactTime == 0 { rechargePlatformContactTime = time }
            let contactDuration = time - rechargePlatformContactTime
            reward += 0.25

            if contactDuration >= requiredRechargeContactDuration, !hasCompletedRechargeGoal {
                hasCompletedRechargeGoal = true
                reward += 5.0
                locomotion.completeEpisode(.recharged)
                executive.learner.clearTraces()
                ca?.goalContext.advanceToNextGoal()
                ca?.planBuffer.invalidate(reason: "Recharge complete")
            }
        } else {
            rechargePlatformContactTime = 0
            hasReachedRechargePlatform = false
        }

        reinforceOutcome(
            stateKey: previousGoalStateKey ?? currentStateKey,
            action: previousGoalAction ?? action,
            reward: reward,
            nextStateKey: currentStateKey
        )

        outcomeWindowElapsedTime = 0
        outcomeWindowDisplacement = 0
        outcomeWindowGoalProgress = 0
        outcomeWindowPathProgress = 0
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
        scene.physicsWorld.speed = 1

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
        if name.contains("chasm") || name.contains("void") || name.contains("gap") ||
           name.contains("qfloorgrid") || name.contains("marker") || name.contains("camera") || name.contains("light") {
            return
        }
        if isCharacterPart(node) || isQGridNode(node) { return }

        let movableTokens = ["table", "crate", "box", "movable", "pickup", "chair", "stool", "block", "object"]
        let supportTokens = ["floor", "ground", "platform", "stair", "step", "terrain", "wall", "doorframe"]

        let shouldBeDynamic = forceDynamic || movableTokens.contains(where: { name.contains($0) })
        let shouldBeStatic = supportTokens.contains(where: { name.contains($0) })

        if shouldBeDynamic {
            if node.physicsBody == nil || node.physicsBody?.type != .dynamic {
                let shape = SCNPhysicsShape(node: node, options: nil)
                let body = SCNPhysicsBody(type: .dynamic, shape: shape)
                let size = worldDimensions(of: node)
                let volume = max(0.01, size.x * size.y * size.z)

                body.mass = CGFloat(min(30, max(0.5, volume * 3.0)))
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
            if name.contains("pickup") || name.contains("movable") || name.contains("carryable") ||
               name.contains("crate") || name.contains("box") || name == "table" {
                return candidate
            }
            current = candidate.parent
        }
        return nil
    }

    @discardableResult
    func attemptPickup() -> Bool {
        guard let character = characterNode, let scene = scene,
              let hand = handNode,
              let target = reachablePickupTarget(character: character, scene: scene)
        else { return false }

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
            pushLastNodePosition = nil
            pushTrackedNodeID = nil
            pushAccumulatedMeters = 0
            return
        }
        guard let node = pushTargetNode, node.parent != nil else {
            pushLastNodePosition = nil
            pushTrackedNodeID = nil
            pushAccumulatedMeters = 0
            return
        }

        guard carriedNode == nil, canManipulate(node, from: character) else {
            pushLastNodePosition = nil
            pushTrackedNodeID = nil
            pushAccumulatedMeters = 0
            return
        }

        let targetID = ObjectIdentifier(node)
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
    private func dropCarriedObject(distance: Float, thrown: Bool) -> Bool {
        guard let carriedNode, let character = characterNode, let scene else { return false }

        let forward = forwardVector()
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

        carriedNode.position = scene.rootNode.convertPosition(startWorld, from: nil)
        carriedNode.position = SCNVector3(
            destinationXZ.x,
            max(Float(carriedNode.position.y), Float(position.y) + 0.25),
            destinationXZ.z
        )

        configurePhysicsBody(for: carriedNode, forceDynamic: true)
        if let body = carriedNode.physicsBody {
            body.type = .dynamic
            body.velocity = SCNVector3Zero
            body.angularVelocity = SCNVector4Zero
            body.resetTransform()

            if thrown {
                body.applyForce(SCNVector3(forward.x * 2.2, 3.0, forward.z * 2.2), asImpulse: true)
            }
        }

        self.carriedNode = nil
        carriedOriginalParent = nil
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

        let pathText = pathGoalDistance.isFinite ? String(format: "%.2f", Double(pathGoalDistance)) : "n/a"
        let stats = """
        Action: \(action)
        Power: \(Int(powerLevel))%
        Terrain: \(terrain)
        Distance ahead: \(String(format: "%.2f", Double(latestTerrainSample.distance))) m
        Visible objects: \(visibleObjects.count)
        Recharge distance: \(String(format: "%.2f", Double(rechargePlatformDistance))) m
        CA path distance: \(pathText) m
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
        
        // Shifted to the left corner (adjust -5.0 to fit your exact left wall/corner boundary)
        let xOffset = -5.0 + Float(index) * 0.52
        
        node.position = SCNVector3(xOffset, 0.05, -2.5)
        node.physicsBody = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: box, options: nil))
        scene.rootNode.addChildNode(node)

        let textGeometry = SCNText(string: String(letter), extrusionDepth: 0.02)
        textGeometry.font = UIFont.systemFont(ofSize: 0.32, weight: .bold)
        
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
