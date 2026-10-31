import Foundation
import SceneKit
import simd
import SwiftUI
import UIKit

final class Coordinator: NSObject, SCNSceneRendererDelegate {
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
        guard let station = rechargeStationNode else {
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

        publishDebug("Coordinator attached to displayed scene.")
    }

    /// Add a useful supply of genuinely movable, stackable blocks to the
    /// existing course. Positions are kept in side bays so the original route
    /// remains traversable. Names deliberately match the perception/pickup rules.
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

        publishDebug("Added 10 movable blocks, including a two-block stack; blocks can be pushed, carried where supported, and used as jump-up surfaces.")
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

        publishDebug("Table attached; gravity and collision physics enabled.")
    }

    @discardableResult
    private func placeObjectOnSupportSurface(
        _ node: SCNNode,
        in scene: SCNScene
    ) -> Bool {
        guard let bottomY = worldBottomY(of: node),
              let surfaceY = supportSurfaceBelow(node, in: scene) else {
            publishDebug(
                "Could not find a support surface beneath \(readableName(for: node))."
            )

            return false
        }

        let correction = surfaceY - bottomY

        guard correction.isFinite,
              abs(correction) > 0.001 else {
            return true
        }

        let oldWorldPosition = node.presentation.worldPosition

        let correctedWorldPosition = SCNVector3(
            oldWorldPosition.x,
            oldWorldPosition.y + correction,
            oldWorldPosition.z
        )

        if let parent = node.parent {
            node.position = parent.convertPosition(
                correctedWorldPosition,
                from: nil
            )
        } else {
            node.position = correctedWorldPosition
        }

        node.physicsBody?.resetTransform()

        publishDebug(
            "Placed \(readableName(for: node)) on support surface."
        )

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

        let start = SCNVector3(
            worldPosition.x,
            bottomY - 0.02,
            worldPosition.z
        )

        let end = SCNVector3(
            worldPosition.x,
            bottomY - 20.0,
            worldPosition.z
        )

        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: true
        ]

        let hits = scene.rootNode.hitTestWithSegment(
            from: start,
            to: end,
            options: options
        )

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

            if name.contains("marker") ||
                name.contains("rechargestation") {
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

                let validBounds =
                    minimum.x.isFinite &&
                    minimum.y.isFinite &&
                    minimum.z.isFinite &&
                    maximum.x.isFinite &&
                    maximum.y.isFinite &&
                    maximum.z.isFinite &&
                    maximum.x >= minimum.x &&
                    maximum.y >= minimum.y &&
                    maximum.z >= minimum.z

                if validBounds {
                    for x in [minimum.x, maximum.x] {
                        for y in [minimum.y, maximum.y] {
                            for z in [minimum.z, maximum.z] {
                                let world = current.presentation.convertPosition(
                                    SCNVector3(x, y, z),
                                    to: nil
                                )

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
        if running {
            start()
        } else {
            stop()
        }
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
            dt = Float(
                min(
                    max(time - lastFrameTime, 1.0 / 240.0),
                    0.05
                )
            )
        }

        lastFrameTime = time
        dtFromLastFrame = dt

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

            // Resolve push targets geometrically, not only from the narrow
            // ray list. The narrow scan can miss a block when a higher/nearer
            // surface masks it, which previously left applyPush with no target.
            pushTargetNode = findPushTargetNode(
                character: character,
                in: scene,
                detections: detailedDetections
            )

            // Wide, long-range view for planning and the UI.
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

            // CA: identified objects -> distance-path field.
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

        // Refresh terrain every frame so locomotion does not act on stale
        // obstacle, gap, and ground data between sensor updates.
        latestTerrainSample = makeTerrainSample(
            for: character,
            in: scene
        )

        latestTerrainSample.objectName = latestDetection?.name ?? ""
        latestTerrainSample.carryingObject = carriedNode != nil
        latestTerrainSample.objectPickupable =
            (latestDetection?.pickupable ?? false) &&
            (latestDetection?.distance ?? .infinity) <= pickupDistance

        // Keep movable-block classification independent of which surface won
        // the narrow raycast. This is required both for the 1 m push gate and
        // for permitting a jump onto the block's measured top surface.
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

        // MARK: 2. Actual displacement and prediction

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
                publishDebug(
                    "Prediction error: expected \(String(format: "%.2f", prediction.expectedForwardDisplacement)) m, measured \(String(format: "%.2f", actualDisplacement)) m; model adjusted."
                )
            }

            pendingPrediction = nil
        }

        // MARK: 3. Dirty Q-values in the field of vision
        //
        // Everything he can see has its Q-values marked dirty. The policy and
        // the floor grid then change only those values when they update.
        markFieldOfViewDirty(character: character, time: time)

        // MARK: 3b. CA advisory values (learned object + goal Q-values)

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

        // MARK: 4. CA executive decision

        // Prefer the block that is actually pushable in front of Frankenstein
        // over a nearer wall/floor ray hit. This is the observation passed to
        // action constraints, the CA executive, and Q-learning.
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
                        pickupable: false
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

        // MARK: 5. Apply CA decision
        //
        // The CA chooses turnLeft / turnRight itself from the routed path
        // and ray-fan clearance, so the Coordinator no longer overrides the
        // heading; output.heading is the single source of truth.

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

        // Loop detection uses the executed action and the real position.
        let finalPosition = character.presentation.worldPosition

        // Actions that are stationary by design (turning, recovering,
        // object handling) must not look like a futile loop.
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

        // MARK: 6. Evaluate measured outcome

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

        // Publish the Q network grid (all Q-values, dirty ones flagged).
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

    /// Feeds identified objects (class, footprint) and the goal into the CA
    /// path field, relaxes it, and stores the routed steering result.
    private func updatePathField(
        character: SCNNode,
        detections: [DetectedObjectInfo],
        extraObstacles: [FrankensteinCAPathField.Obstacle],
        time: TimeInterval
    ) {
        let c = character.presentation.worldPosition
        let characterXZ = SIMD2<Float>(Float(c.x), Float(c.z))

        var goalXZ: SIMD2<Float>?

        if let station = rechargeStationNode {
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

        // Smoothed progress toward the goal along the routed path (m/s).
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

    // MARK: - Ray Fan (free space + wall memory)

    /// Casts a horizontal fan of rays around the heading. Produces the
    /// three clearance sectors the CA reasons with, plus small obstacle
    /// points (walls and unnamed solids) so the path field can remember
    /// what the rays hit even when no "object" was identified.
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

            // Same forward convention as forwardVector().
            let dx = -sin(theta)
            let dz = -cos(theta)

            let origin = SCNVector3(
                position.x,
                position.y + 0.5,
                position.z
            )

            let end = SCNVector3(
                origin.x + dx * range,
                origin.y,
                origin.z + dz * range
            )

            let hits = scene.rootNode.hitTestWithSegment(
                from: origin,
                to: end,
                options: options
            )

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

                // Ignore ground-like slabs the ray happens to graze.
                if hit.worldNormal.y > 0.85 { continue }

                let hx = Float(hit.worldCoordinates.x - origin.x)
                let hz = Float(hit.worldCoordinates.z - origin.z)
                let hitDistance = sqrt(hx * hx + hz * hz)

                guard hitDistance >= Self.minimumHitDistance else {
                    continue
                }

                distance = min(range, hitDistance)

                let target = meaningfulDetectionParent(for: node)

                if !isContainerNode(target) {
                    let className = objectClass(
                        for: readableName(for: target)
                    )

                    if className != "rechargeStation" {
                        points.append(
                            FrankensteinCAPathField.Obstacle(
                                center: SIMD2<Float>(
                                    Float(hit.worldCoordinates.x),
                                    Float(hit.worldCoordinates.z)
                                ),
                                halfExtent: SIMD2<Float>(0.15, 0.15),
                                className: className
                            )
                        )
                    }
                }

                break
            }

            switch degrees {
            case -20...20:
                ahead = min(ahead, distance)
            case 21...:
                plus = min(plus, distance)
            default:
                minus = min(minus, distance)
            }
        }

        clearanceAhead = ahead
        clearancePlus = plus
        clearanceMinus = minus

        return points
    }

    // MARK: - CA Perception Hand-off

    private func wrappedAngle(_ value: Float) -> Float {
        var angle = value

        while angle > .pi { angle -= 2 * .pi }
        while angle < -.pi { angle += 2 * .pi }

        return angle
    }

    private func headingBand(_ error: Float) -> String {
        switch abs(error) {
        case ..<0.2:
            return "aligned"
        case ..<0.8:
            return error > 0 ? "slightPlus" : "slightMinus"
        case ..<2.4:
            return error > 0 ? "farPlus" : "farMinus"
        default:
            return "behind"
        }
    }

    private func clearanceBand(_ value: Float) -> String {
        switch value {
        case ..<0.9:
            return "blocked"
        case ..<2.0:
            return "tight"
        default:
            return "open"
        }
    }

    /// Builds the perception the CA scores actions against, and hands it
    /// over. Called every frame, immediately before locomotion.step.
    private func pushPerceptionToCA(
        terrain: FrankensteinTerrainSample,
        allowedActions: [FrankensteinAction],
        time: TimeInterval
    ) {
        guard let ca else { return }

        var perception = FrankensteinCAPerception()

        let routedHeading = pathSteering?.heading ?? heading
        perception.headingError = pathSteering == nil
            ? 0
            : wrappedAngle(routedHeading - heading)

        perception.pathDistance = pathGoalDistance
        perception.isDetouring = pathSteering?.isDetouring ?? false
        perception.goalProgressRate = goalProgressRate

        perception.atGoal =
            hasReportedRecharge ||
            (pathGoalDistance.isFinite && pathGoalDistance < 0.35)

        perception.clearanceAhead = clearanceAhead
        perception.clearancePlus = clearancePlus
        perception.clearanceMinus = clearanceMinus

        // MARK: - Nearby object perception

        if let detection = latestDetection {
            perception.nearestObjectClass = objectClass(for: detection.name)
            perception.nearestObjectDistance = detection.distance
            perception.nearestObjectPickupable = detection.pickupable
            perception.nearestObjectMovable = isMovableName(detection.name)
            perception.nearestObjectName = detection.name
        }

        // Include the actual push target when available.
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
                perception.nearestObjectPickupable = false
                perception.nearestObjectMovable = true
                perception.nearestObjectName = target.name ?? "MovableBlock"
            }
        }

        // MARK: - Distant object perception

        let distant = visibleObjects.filter {
            $0.distance >= 3.0
        }

        perception.distantObjectSummary = distant.isEmpty
            ? ""
            : DetectedObjectInfo.summary(of: distant, limit: 3)

        // MARK: - Route preview

        perception.routeRelativeHeadings = executive.field
            .routePreview(maxCells: 8)
            .map {
                wrappedAngle($0 - heading)
            }

        // MARK: - Learned goal and object values

        let goalValues = executive.learner.values(
            for: goalStateKey(terrain: terrain)
        )

        let objectValues = latestDetection.map {
            executive.learner.values(
                for: objectStateKey(for: $0, terrain: terrain)
            )
        } ?? [:]

        var advisory: [FrankensteinAction: Float] = [:]

        // Combine learned goal and object values.
        for action in FrankensteinAction.allCases {
            let name = String(describing: action)

            advisory[action] =
                0.35 * (goalValues[name] ?? 0) +
                0.20 * (objectValues[name] ?? 0)
        }

        // MARK: - Jump onto a reachable movable object

        if terrain.objectMovable,
           terrain.canLandOnObject,
           terrain.obstacleHeight > 0.05,
           terrain.obstacleHeight <= 1.0 {

            advisory[.jump, default: 0] += 4.0
        }

        // MARK: - Pickup preference

        if let detection = latestDetection,
           carriedNode == nil,
           detection.pickupable,
           objectClass(for: detection.name) != "movable",
           detection.distance <= pickupDistance {

            advisory[.liftObject, default: 0] += 5.0
            advisory[.jump, default: 0] -= 5.0
        }

        // MARK: - Push preference

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

            let alignment = distance > 0.001
                ? ahead / distance
                : 0

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

        // MARK: - Deliver CA advisory values

        perception.advisoryValues = advisory

        // MARK: - State key

        perception.stateKey = [
            String(describing: terrain.terrain),
            headingBand(perception.headingError),
            clearanceBand(clearanceAhead),
            perception.nearestObjectClass,
            perception.nearestObjectDistance.isFinite
                ? distanceBand(perception.nearestObjectDistance)
                : "none",
            carriedNode != nil ? "carrying" : "empty"
        ].joined(separator: "|")

        perception.timestamp = time

        ca.receivePerception(perception)
    }
    // MARK: - Advisory Values

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

        // Direct reflex override: lift genuinely pickupable objects, but do
        // not confuse a pushable crate/block with a hand-held object.
        if let detection = latestDetection,
           carriedNode == nil,
           detection.pickupable,
           objectClass(for: detection.name) != "movable",
           detection.distance <= pickupDistance {
            merged[.liftObject, default: 0] += 5.0
            merged[.jump, default: 0] -= 5.0
        }

        // Strategic push bias is only applied when a movable object is ahead
        // and the current route looks blocked/detoured. The policy still has
        // to mark pushObject as allowed; this score does not bypass safety.
        // If the block's top is a verified landing surface, keep jumping
        // available and positively score it. Pushing only wins when the block
        // is closely aligned and the route is genuinely obstructed/stuck.
        if latestTerrainSample.objectMovable,
           latestTerrainSample.canLandOnObject,
           latestTerrainSample.obstacleHeight > 0.05,
           latestTerrainSample.obstacleHeight <= 1.0 {
            merged[.jump, default: 0] += 4.0
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
 

    // MARK: - Push Target Resolution

    /// Finds the nearest named movable block in front of the character. This
    /// supplements ray-hit detection, which can miss the block when another
    /// surface occludes the narrow scan. Only concrete geometry nodes are
    /// eligible, and the target must be in a reachable forward corridor.
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

        // Ray-detected nodes are tried first, then the scene graph provides
        // the occlusion-resistant fallback.
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

    // MARK: - Wide Field of View Scan

    /// The objects in the wide field of vision, as policy observations.
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

    /// Marks the Q-values in Frankenstein's field of vision as dirty.
    private func markFieldOfViewDirty(character: SCNNode, time: TimeInterval) {
        let policy = locomotion.policy
        policy.visionTime = time

        // The state straight ahead (terrain + nearest object).
        policy.markVisibleDirty(
            terrain: latestTerrainSample,
            body: locomotion.body
        )

        // Every object seen in the wide field of vision.
        policy.markVisibleDirty(
            objects: visibleObservations(),
            terrain: latestTerrainSample,
            body: locomotion.body
        )

        // The floor cells in view.
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

    /// Wide scan results plus anything the narrow scan sees that the wide
    /// scan missed, nearest first, each with a bearing.
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

    /// A fan of horizontal rays across about 170 degrees, out to
    /// `wideScanRange` metres, at two heights. Unlike the corridor scan it
    /// accepts large objects (walls, long hurdles) and objects off to the side.
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

            // Same forward convention as forwardVector().
            let dx = -sin(theta)
            let dz = -cos(theta)

            for rayHeight in wideScanHeights {
                let origin = SCNVector3(
                    position.x,
                    position.y + rayHeight,
                    position.z
                )

                let end = SCNVector3(
                    origin.x + dx * wideScanRange,
                    origin.y,
                    origin.z + dz * wideScanRange
                )

                let hits = scene.rootNode.hitTestWithSegment(
                    from: origin,
                    to: end,
                    options: options
                )

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

                    guard hitDistance >= Self.minimumHitDistance else {
                        continue
                    }

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
                          max(dimensions.x, max(dimensions.y, dimensions.z))
                            <= wideScanMaximumExtent else {
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

                    if let existing = nearestByNode[key],
                       existing.distance <= hitDistance {
                        // Keep the nearest hit for this object.
                    } else {
                        nearestByNode[key] = info
                    }

                    // The first solid thing along a ray hides what is behind it.
                    break
                }
            }

            angle += wideScanStepDegrees
        }

        return nearestByNode.values.sorted { $0.distance < $1.distance }
    }

    // MARK: - Full Object Perception

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

        return unique.values
            .sorted { $0.info.distance < $1.info.distance }
    }

    private func detectDetailedObjectAhead(
        from character: SCNNode,
        in scene: SCNScene,
        rayHeight: Float,
        lateral: Float
    ) -> DetailedObjectDetection? {
        let characterPresentation = character.presentation
        let position = characterPresentation.worldPosition

        let localForwardPoint = characterPresentation.convertPosition(
            SCNVector3(0, 0, -1),
            to: nil
        )

        var forward = SCNVector3(
            localForwardPoint.x - position.x,
            localForwardPoint.y - position.y,
            localForwardPoint.z - position.z
        )

        let forwardLength = sqrt(
            forward.x * forward.x +
            forward.y * forward.y +
            forward.z * forward.z
        )

        guard forwardLength > 0.0001 else {
            return nil
        }

        forward.x /= forwardLength
        forward.y /= forwardLength
        forward.z /= forwardLength

        let origin = SCNVector3(
            position.x + forward.z * lateral,
            position.y + rayHeight,
            position.z - forward.x * lateral
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

        let hits = scene.rootNode.hitTestWithSegment(
            from: origin,
            to: end,
            options: options
        )

        for hit in hits {
            let hitNode = hit.node

            guard !isCharacterPart(hitNode),
                  !isFloorSurface(hitNode),
                  !isQGridNode(hitNode) else {
                logRay(
                    origin: origin,
                    direction: forward,
                    hitNode: hitNode,
                    resolvedName: "filtered",
                    distance: rayLength
                )

                continue
            }

            let hitPoint = hit.worldCoordinates

            let hitDistance = sqrt(
                Float((hitPoint.x - origin.x) * (hitPoint.x - origin.x)) +
                Float((hitPoint.z - origin.z) * (hitPoint.z - origin.z))
            )

            guard hitDistance >= Self.minimumHitDistance else {
                continue
            }

            let target: SCNNode

            if let pickupNode = pickupTarget(for: hitNode) {
                target = pickupNode
            } else {
                target = meaningfulDetectionParent(for: hitNode)
            }

            guard !isContainerNode(target),
                  target !== character,
                  !isCharacterPart(target) else {
                logRay(
                    origin: origin,
                    direction: forward,
                    hitNode: hitNode,
                    resolvedName: readableName(for: target),
                    distance: hitDistance
                )

                continue
            }

            let dimensions = worldDimensions(of: target)

            guard dimensions.x > 0.001,
                  dimensions.y > 0.001,
                  dimensions.z > 0.001 else {
                continue
            }

            guard max(
                dimensions.x,
                max(dimensions.y, dimensions.z)
            ) <= Self.maximumObstacleExtent else {
                logRay(
                    origin: origin,
                    direction: forward,
                    hitNode: hitNode,
                    resolvedName: "container",
                    distance: hitDistance
                )

                continue
            }

            let dx = Float(hitPoint.x - origin.x)
            let dz = Float(hitPoint.z - origin.z)

            let distance = sqrt(dx * dx + dz * dz)

            guard distance <= rayLength else {
                continue
            }

            let resolvedName = readableName(for: target)

            logRay(
                origin: origin,
                direction: forward,
                hitNode: hitNode,
                resolvedName: resolvedName,
                distance: distance
            )

            let info = DetectedObjectInfo(
                name: resolvedName,
                dimensions: dimensions,
                distance: distance,
                worldPosition: target.presentation.worldPosition,
                pickupable: pickupTarget(for: target) != nil,
                topY: worldTopY(of: target)
            )

            print(
                """
                [Object Seen]
                rayHeight=\(rayHeight)
                lateral=\(lateral)
                rayOrigin=(\(origin.x), \(origin.y), \(origin.z))
                rayDirection=(\(forward.x), \(forward.y), \(forward.z))
                hitNode=\(hitNode.name ?? "unnamed")
                resolvedTarget=\(target.name ?? "unnamed")
                resolvedName=\(resolvedName)
                objectClass=\(objectClass(for: resolvedName))
                distance=\(String(format: "%.2f", distance)) m
                dimensions=(\(dimensions.x), \(dimensions.y), \(dimensions.z))
                pickupable=\(info.pickupable)
                worldPosition=(\(info.worldPosition.x), \(info.worldPosition.y), \(info.worldPosition.z))
                """
            )

            return DetailedObjectDetection(
                node: target,
                info: info
            )
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

    private func logRayObservations() {
        if latestRayObservations.isEmpty {
            print(
                """
                [Perception] Empty forward view:
                15 rays cast; no non-floor, non-character object was hit within 4 m.
                """
            )

            return
        }

        for observation in latestRayObservations {
            print(
                """
                [Ray] origin=(\(observation.origin.x), \(observation.origin.y), \(observation.origin.z)) \
                direction=(\(observation.direction.x), \(observation.direction.y), \(observation.direction.z)) \
                hit=\(observation.hitNodeName) \
                resolved=\(observation.resolvedObjectName) \
                distance=\(String(format: "%.2f", observation.distance))
                """
            )
        }
    }

    // MARK: - Ground Verification

    private func verifySupportBeneathCharacter(
        character: SCNNode,
        in scene: SCNScene
    ) -> Bool {
        let position = character.presentation.worldPosition
        let feetY = Float(position.y) + characterFootOffset

        let offsets: [(Float, Float)] = [
            (0, 0),
            (0.18, 0),
            (-0.18, 0),
            (0, 0.18),
            (0, -0.18),
            (0.12, 0.12),
            (-0.12, -0.12)
        ]

        for (dx, dz) in offsets {
            let probe = SCNVector3(
                position.x + dx,
                feetY,
                position.z + dz
            )

            if let supportY = raycastSupport(
                at: probe,
                in: scene,
                riseAllowance: 0.35
            ) {
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
        let supportY = raycastSupport(
            at: proposedPosition,
            in: scene,
            riseAllowance: 0.35
        )

        guard let landingY = supportY else {
            return false
        }

        let heightDelta = landingY - currentFeetY

        guard abs(heightDelta) <= 0.65 else {
            return false
        }

        return hasClearSpace(
            around: SCNVector3(
                proposedPosition.x,
                landingY + 0.15,
                proposedPosition.z
            ),
            in: scene
        )
    }

    // MARK: - Object and Goal State Keys (CA-perceived state)

    private func objectClass(for name: String) -> String {
        let value = name.lowercased()

        if value.contains("recharge") {
            return "rechargeStation"
        }

        if value.contains("wall") {
            return "wall"
        }

        if value.contains("door") {
            return "door"
        }

        if value.contains("table") {
            return "table"
        }

        if value.contains("crate") || value.contains("box") {
            return "crate"
        }

        if value.contains("pickup") ||
            value.contains("movable") ||
            value.contains("carryable") {
            return "movable"
        }

        return "object"
    }

    private func distanceBand(_ distance: Float) -> String {
        switch distance {
        case ..<0.75:
            return "contact"
        case ..<1.5:
            return "near"
        case ..<3.0:
            return "mid"
        default:
            return "far"
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

        // Prefer the CA-routed path distance; fall back to straight-line.
        let goalDistance = pathGoalDistance.isFinite
            ? pathGoalDistance
            : rechargePlatformDistance

        switch goalDistance {
        case ..<1.0:
            progress = "atGoal"
        case ..<3.0:
            progress = "nearGoal"
        case ..<8.0:
            progress = "midGoal"
        default:
            progress = "farGoal"
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
        let allowed = FrankensteinActionConstraints.allowedActions(
            terrain: terrain,
            body: locomotion.body
        )

        var actionNames = allowed.map { String(describing: $0) }
        if detections.contains(where: {
            isMovableName($0.info.name) && $0.info.distance <= 2.3
        }), !actionNames.contains(String(describing: FrankensteinAction.pushObject)) {
            actionNames.append(String(describing: FrankensteinAction.pushObject))
        }

        for detection in detections {
            executive.learner.ensure(
                key: objectStateKey(for: detection.info, terrain: terrain),
                actions: actionNames
            )
        }

        executive.learner.ensure(
            key: goalStateKey(terrain: terrain),
            actions: actionNames
        )
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

    // MARK: - Terrain Sensing

    // MARK: - Terrain Sensing

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

                let rise = detection.topY > 0
                    ? max(0, detection.topY - sample.groundHeight)
                    : detection.dimensions.y

                sample.obstacleHeight = rise
                sample.obstacleDepth = detection.dimensions.z
                sample.objectName = detection.name

                let name = detection.name.lowercased()
                let bottomY =
                    Float(detection.worldPosition.y) - detection.dimensions.y * 0.5

                if name.contains("ceiling") ||
                    bottomY > sample.groundHeight + 0.8 {
                    sample.terrain = .lowCeiling
                } else if rise <= 0.08 {
                    sample.terrain = .uneven
                } else if rise <= 0.45 {
                    sample.terrain = .raisedStep
                } else {
                    sample.terrain = .hurdle
                }

                // A movable block can be shoved, and its top may be a landing
                // surface when it is within jump height and clear above.
                sample.objectMovable = isMovableName(detection.name)

                if sample.objectMovable,
                   rise > 0.05,
                   rise <= 1.0,
                   detection.dimensions.x >= 0.3,
                   detection.dimensions.z >= 0.3 {
                    sample.canLandOnObject = hasClearSpace(
                        around: SCNVector3(
                            detection.worldPosition.x,
                            detection.topY + 0.15,
                            detection.worldPosition.z
                        ),
                        in: scene
                    )
                }

                if sample.terrain == .hurdle || sample.terrain == .raisedStep {
                    let landingDistance =
                        detection.distance + max(detection.dimensions.z, 0.3) + 0.4

                    let landingProbe = SCNVector3(
                        position.x + forward.x * landingDistance,
                        position.y,
                        position.z + forward.z * landingDistance
                    )

                    if let landingHeight = raycastGround(near: landingProbe, in: scene) {
                        let delta = landingHeight - sample.groundHeight

                        sample.landingHeightDelta = delta
                        sample.nextGroundHeight = landingHeight

                        sample.isLandingAreaClear =
                            abs(delta) <= 0.25 &&
                            hasClearSpace(
                                around: SCNVector3(
                                    landingProbe.x,
                                    landingHeight + 0.15,
                                    landingProbe.z
                                ),
                                in: scene
                            )
                    }
                }
            } else {
                sample.terrain = .flat
            }

            let distances: [Float] = [0.65, 1.0, 1.5, 2.2, 3.0]

            var groundHits: [(distance: Float, height: Float)] = []
            var firstProbeHasGround = false

            for (index, distance) in distances.enumerated() {
                let probe = SCNVector3(
                    position.x + forward.x * distance,
                    position.y + 3.0,
                    position.z + forward.z * distance
                )

                if let height = raycastGround(near: probe, in: scene) {
                    groundHits.append((distance, height))

                    if index == 0 {
                        firstProbeHasGround = true
                    }
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
                    sample.landingHeightDelta =
                        landing.height - sample.groundHeight

                    sample.isLandingAreaClear =
                        sample.gapWidth > 0 &&
                        sample.gapWidth <= 3.5
                } else {
                    sample.terrain = .gap
                    sample.distance = distances[0]
                    sample.isLandingAreaClear = false
                }

                return sample
            }

            if let nearest = groundHits.first {
                sample.nextGroundHeight = nearest.height
                sample.landingHeightDelta =
                    nearest.height - sample.groundHeight

                let rise = nearest.height - sample.groundHeight

                if rise > 0.05 && rise <= 0.45 {
                    sample.terrain = .raisedStep
                    sample.obstacleHeight = rise
                    sample.distance = nearest.distance
                }
            }

            return sample
        }
  

    // MARK: - Raycast Helpers

    private func worldTopY(of node: SCNNode) -> Float {
        let (minimum, maximum) = node.boundingBox
        var top = -Float.infinity

        for x in [minimum.x, maximum.x] {
            for y in [minimum.y, maximum.y] {
                for z in [minimum.z, maximum.z] {
                    let world = node.presentation.convertPosition(
                        SCNVector3(x, y, z),
                        to: nil
                    )

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
        let start = SCNVector3(
            position.x,
            position.y + riseAllowance,
            position.z
        )

        let end = SCNVector3(
            position.x,
            position.y - 8.0,
            position.z
        )

        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: false
        ]

        let hits = scene.rootNode.hitTestWithSegment(
            from: start,
            to: end,
            options: options
        )

        for hit in hits {
            guard !isCharacterPart(hit.node),
                  !isQGridNode(hit.node) else {
                continue
            }

            if hit.worldNormal.y <= 0.35 && !isGroundLikeNode(hit.node) {
                continue
            }

            let name = (hit.node.name ?? "").lowercased()

            if name.contains("marker") ||
                name.contains("rechargestation") {
                continue
            }

            return Float(hit.worldCoordinates.y)
        }

        return nil
    }

    private func raycastGround(
        near position: SCNVector3,
        in scene: SCNScene
    ) -> Float? {
        let start = SCNVector3(
            position.x,
            position.y + 3.0,
            position.z
        )

        let end = SCNVector3(
            position.x,
            position.y - 8.0,
            position.z
        )

        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: true
        ]

        let hits = scene.rootNode.hitTestWithSegment(
            from: start,
            to: end,
            options: options
        )

        let validHits = hits.filter {
            !isCharacterPart($0.node) && !isQGridNode($0.node)
        }

        if let groundHit = validHits.first(where: {
            isGroundLikeNode($0.node)
        }) {
            return Float(groundHit.worldCoordinates.y)
        }

        if let fallback = validHits.first {
            return Float(fallback.worldCoordinates.y)
        }

        return nil
    }

    private func hasClearSpace(
        around position: SCNVector3,
        in scene: SCNScene
    ) -> Bool {
        let offsets: [(Float, Float)] = [
            (0, 0),
            (0.25, 0),
            (-0.25, 0),
            (0, 0.25),
            (0, -0.25)
        ]

        for (dx, dz) in offsets {
            let start = SCNVector3(
                position.x + dx,
                position.y,
                position.z + dz
            )

            let end = SCNVector3(
                start.x,
                start.y + 1.2,
                start.z
            )

            let options: [String: Any] = [
                SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
                SCNHitTestOption.backFaceCulling.rawValue: true
            ]

            let hits = scene.rootNode.hitTestWithSegment(
                from: start,
                to: end,
                options: options
            )

            if hits.contains(where: {
                !isCharacterPart($0.node) &&
                !isGroundLikeNode($0.node)
            }) {
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

    private static let containerNodeNames: Set<String> = [
        "ObstacleCourse", "TerrainRoot", "SceneRoot"
    ]

    private static let maximumObstacleExtent: Float = 6.0
    private static let minimumHitDistance: Float = 0.05

    private func isContainerNode(_ node: SCNNode) -> Bool {
        let name = (node.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Self.containerNodeNames.contains(name)
    }

    private func meaningfulDetectionParent(
        for node: SCNNode
    ) -> SCNNode {
        var current: SCNNode? = node
        var bestCandidate = node

        while let candidate = current {
            if isContainerNode(candidate) {
                break
            }

            let name = (candidate.name ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !name.isEmpty,
               !isGenericDetectionNodeName(name),
               !isFloorSurface(candidate) {

                let extent = worldDimensions(of: candidate)

                let isGroupingNode =
                    max(extent.x, max(extent.y, extent.z)) >
                    Self.maximumObstacleExtent

                if isGroupingNode {
                    break
                }

                bestCandidate = candidate
            }

            current = candidate.parent
        }

        return bestCandidate
    }

    private func isGenericDetectionNodeName(_ name: String) -> Bool {
        let value = name.lowercased()

        return value == "node" ||
            value == "root" ||
            value == "geometry" ||
            value.hasPrefix("scn")
    }

    // MARK: - Displacement

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

    // MARK: - Movement

    // MARK: - Movement

        private func applyMovement(
            output: FrankensteinLocomotionOutput,
            deltaTime dt: Float,
            character: SCNNode,
            scene: SCNScene
        ) {
            guard dt.isFinite, dt > 0 else { return }

            // The CA turns the character through turnLeft / turnRight actions,
            // so the locomotion heading is authoritative.
            heading = output.heading

            // Calculate forward from the resolved heading.
            let forward = forwardVector()
            // A push is a coupled body+object action. Some locomotion outputs
            // intentionally give manipulation actions zero walking speed; in
            // this case move gently toward the target so contact is maintained.
            let baseSpeed: Float
            if output.action == .pushObject {
                baseSpeed = pushTargetNode == nil ? 0 : max(0.45, output.speed)
            } else {
                baseSpeed = max(0, output.speed)
            }
            let direction = (output.action == .pushObject && output.moveDirection == 0)
                ? 1.0
                : output.moveDirection
            let speed = baseSpeed * direction

            if output.liftRequested,
               locomotion.policy.pendingAction == .liftObject {

                let stateKeyBeforePickup = latestDetection.map {
                    objectStateKey(for: $0, terrain: latestTerrainSample)
                }

                let succeeded = attemptPickup()
                locomotion.reportPickupOutcome(succeeded: succeeded)

                if let stateKeyBeforePickup {
                    reinforceOutcome(
                        stateKey: stateKeyBeforePickup,
                        action: .liftObject,
                        reward: succeeded ? 1.0 : -0.5
                    )
                }
            }

            if output.placeRequested,
               locomotion.policy.pendingAction == .placeObject {

                let stateKeyBeforePlace = latestDetection.map {
                    objectStateKey(for: $0, terrain: latestTerrainSample)
                }

                let ok = placeCarriedObjectAhead()

                locomotion.reportObjectActionOutcome(
                    .placeObject,
                    reward: ok ? 0.5 : -0.5
                )

                if let stateKeyBeforePlace {
                    reinforceOutcome(
                        stateKey: stateKeyBeforePlace,
                        action: .placeObject,
                        reward: ok ? 0.5 : -0.5
                    )
                }
            }

            if output.throwRequested,
               locomotion.policy.pendingAction == .throwObject {

                let stateKeyBeforeThrow = latestDetection.map {
                    objectStateKey(for: $0, terrain: latestTerrainSample)
                }

                let ok = throwCarriedObjectAhead()

                locomotion.reportObjectActionOutcome(
                    .throwObject,
                    reward: ok ? 0.3 : -0.5
                )

                if let stateKeyBeforeThrow {
                    reinforceOutcome(
                        stateKey: stateKeyBeforeThrow,
                        action: .throwObject,
                        reward: ok ? 0.3 : -0.5
                    )
                }
            }

            let oldWorld = character.presentation.worldPosition

            var proposedWorld = SCNVector3(
                oldWorld.x + forward.x * speed * dt,
                oldWorld.y,
                oldWorld.z + forward.z * speed * dt
            )

            let currentFeetY =
                Float(oldWorld.y) + characterFootOffset

            verifiedLandingSupport = verifyLandingSite(
                proposedPosition: proposedWorld,
                currentFeetY: currentFeetY,
                in: scene
            )

            // Do not move into an unsupported gap.
            if speed > 0,
               latestTerrainSample.terrain == .gap,
               !latestTerrainSample.isLandingAreaClear,
               !verifiedLandingSupport {

                proposedWorld.x = oldWorld.x
                proposedWorld.z = oldWorld.z
            }

            let isClimbing =
                locomotion.stepUpInProgress ||
                output.action == .stepUp ||
                output.action == .jump ||
                output.action == .pushObject

            let isBlockingObstacle =
                latestTerrainSample.terrain == .hurdle ||
                latestTerrainSample.terrain == .raisedStep

            // Block ordinary walking into close obstacles.
            if output.jump <= 0,
               speed > 0,
               !isClimbing,
               isBlockingObstacle,
               latestTerrainSample.distance < 0.5 {

                proposedWorld.x = oldWorld.x
                proposedWorld.z = oldWorld.z
            }

            // Vertical movement.
            if output.jump > 0 {
                if jumpBaseY == nil {
                    jumpBaseY = Float(oldWorld.y)
                    characterVerticalVelocity = 0
                }

                let baseY = jumpBaseY ?? Float(oldWorld.y)
                let heightOffset = max(
                    0,
                    locomotion.body.height - standingHeight
                )

                proposedWorld.y = baseY + heightOffset
            } else {
                jumpBaseY = nil

                let oldFeetY = currentFeetY

                let support = raycastSupport(
                    at: SCNVector3(
                        proposedWorld.x,
                        oldFeetY,
                        proposedWorld.z
                    ),
                    in: scene,
                    riseAllowance: max(
                        1.0,
                        abs(characterVerticalVelocity * dt) + 0.5
                    )
                )

                characterVerticalVelocity -= worldGravity * dt

                let fallingFeetY =
                    oldFeetY + characterVerticalVelocity * dt

                if let groundY = support, groundY.isFinite {
                    let feetAboveSurface = oldFeetY - groundY

                    let crossedSurface =
                        oldFeetY >= groundY - 0.06 &&
                        fallingFeetY <= groundY

                    let standingOnSurface =
                        feetAboveSurface >= -0.06 &&
                        feetAboveSurface <= 0.10 &&
                        characterVerticalVelocity <= 0.5

                    if standingOnSurface || crossedSurface {
                        proposedWorld.y =
                            groundY - characterFootOffset

                        characterVerticalVelocity = 0
                    } else if oldFeetY < groundY {
                        proposedWorld.y =
                            groundY - characterFootOffset

                        characterVerticalVelocity = 0
                    } else {
                        proposedWorld.y =
                            fallingFeetY - characterFootOffset
                    }
                } else {
                    proposedWorld.y =
                        fallingFeetY - characterFootOffset
                }
            }

            // Jump landing. Once the jump is coming down, land on the first
            // surface reached: the ground, or the top of a block. Without this
            // the jump would never end and would time out as a failure.
            if output.jump > 0, locomotion.jumpIsDescending {
                let feetNow = Float(proposedWorld.y) + characterFootOffset

                if let surfaceY = raycastSupport(
                    at: SCNVector3(
                        proposedWorld.x,
                        feetNow,
                        proposedWorld.z
                    ),
                    in: scene,
                    riseAllowance: 1.6
                ), feetNow <= surfaceY + 0.04 {

                    let takeoffY = jumpBaseY ?? Float(oldWorld.y)
                    let landedOnTop =
                        surfaceY - characterFootOffset - takeoffY > 0.2

                    proposedWorld.y = surfaceY - characterFootOffset
                    characterVerticalVelocity = 0
                    jumpBaseY = nil

                    locomotion.confirmJumpLanding(
                        actualForwardDistance: locomotion.jumpTravelledDistance,
                        actualHeight: surfaceY,
                        landingAreaIsClear: true
                    )

                    publishDebug(
                        landedOnTop
                            ? "Jump landed on top of an object."
                            : "Jump landed."
                    )
                }
            }

            // Convert world coordinates to the character's parent space.
            if let parent = character.parent {
                character.position = parent.convertPosition(
                    proposedWorld,
                    from: nil
                )
            } else {
                character.position = proposedWorld
            }

            // Keep the resolved heading for visual orientation.
            character.eulerAngles.y = heading

            // Detect falling and terminate the episode once.
            let finalWorldY =
                Float(character.presentation.worldPosition.y)

            let finalFeetY =
                finalWorldY + characterFootOffset

            if finalFeetY < -3.0 && !hasReportedFall {
                hasReportedFall = true
                locomotion.completeEpisode(.fell)
                executive.learner.clearTraces()

                reinforceOutcome(
                    stateKey: goalStateKey(
                        terrain: latestTerrainSample
                    ),
                    action: output.action,
                    reward: -2.0
                )

                publishDebug(
                    "FALL: no supporting surface detected; episode ended."
                )
            } else if finalFeetY > -0.5 {
                hasReportedFall = false
            }

            // Verify recharge contact AFTER movement.
            if let station = rechargeStationNode {
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

                        reinforceOutcome(
                            stateKey: goalStateKey(
                                terrain: latestTerrainSample
                            ),
                            action: output.action,
                            reward: 2.0
                        )

                        publishDebug(
                            "Goal reached: recharge platform contact verified."
                        )
                    }
                } else {
                    hasReportedRecharge = false
                }
            }
        }


    // MARK: - Measured Outcome Evaluation

    private func evaluateActionOutcome(
        output: FrankensteinLocomotionOutput,
        actualDisplacement: Float?,
        character: SCNNode,
        scene: SCNScene,
        time: TimeInterval
    ) {
        guard let station = rechargeStationNode else {
            return
        }

        let action = output.action
        let actionName = String(describing: action)

        let currentPosition = character.presentation.worldPosition
        let stationPosition = station.presentation.worldPosition

        let currentDx = Float(currentPosition.x - stationPosition.x)
        let currentDz = Float(currentPosition.z - stationPosition.z)

        let currentDistance = sqrt(
            currentDx * currentDx +
            currentDz * currentDz
        )

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

        guard let displacement = actualDisplacement else {
            return
        }

        let previousDistance = lastGoalDistance
        let goalProgress = previousDistance - currentDistance

        rechargePlatformDistance = currentDistance
        lastGoalDistance = currentDistance

        outcomeWindowElapsedTime += Double(dtFromLastFrame)
        outcomeWindowDisplacement += displacement
        outcomeWindowGoalProgress += goalProgress

        // Progress along the obstacle-aware route (what the CA is judged on).
        if pathGoalDistance.isFinite, lastEvalPathDistance.isFinite {
            outcomeWindowPathProgress += lastEvalPathDistance - pathGoalDistance
        }

        lastEvalPathDistance = pathGoalDistance

        guard outcomeWindowElapsedTime >= outcomeWindowDuration else {
            return
        }

        // Tell the CA what its action achieved for the goal.
        let movingActions: Set<FrankensteinAction> = [
            .walk, .run, .stepForward, .crouch, .crawl, .roll
        ]

        ca?.reportActionOutcome(
            action: action,
            goalProgressRate: outcomeWindowPathProgress /
                Float(outcomeWindowElapsedTime),
            windowDuration: Float(outcomeWindowElapsedTime),
            blocked: movingActions.contains(action) &&
                abs(outcomeWindowDisplacement) < noProgressThreshold
        )

        var reward: Float = 0

        // Identified object nearest ahead (used to adapt CA path costs).
        let nearbyClass: String? = {
            guard let detection = latestDetection,
                  detection.distance < 1.0 else {
                return nil
            }

            return objectClass(for: detection.name)
        }()

        if abs(outcomeWindowDisplacement) < noProgressThreshold {
            consecutiveNoProgressCount += 1
            reward += noProgressPenalty

            // Blocked by an identified object: make it costlier to route through.
            if let nearbyClass {
                executive.field.learnClassOutcome(
                    className: nearbyClass,
                    blocked: true
                )
            }

            if consecutiveNoProgressCount >= 3 {
                publishDebug(
                    "No measurable progress for \(actionName); reconsidering action."
                )
            }
        } else if outcomeWindowGoalProgress > 0.001 {
            consecutiveNoProgressCount = 0

            reward += outcomeWindowDisplacement * 0.25
            reward += outcomeWindowGoalProgress * goalProgressRewardScale

            if let nearbyClass {
                executive.field.learnClassOutcome(
                    className: nearbyClass,
                    blocked: false
                )
            }
        } else if outcomeWindowGoalProgress < -0.001 {
            consecutiveNoProgressCount += 1

            reward += outcomeWindowGoalProgress * goalProgressRewardScale

            if consecutiveNoProgressCount >= 3 {
                publishDebug(
                    "Moving away from recharge platform; reconsidering \(actionName)."
                )
            }
        } else {
            reward += outcomeWindowDisplacement * 0.05
        }

        if hasReportedRecharge {
            reward += 2.0

            if !hasReachedRechargePlatform {
                hasReachedRechargePlatform = true
                rechargePlatformContactTime = time

                publishDebug(
                    "Goal reached: recharge platform contact verified."
                )
            }
        } else {
            hasReachedRechargePlatform = false
        }

        if hasReportedRecharge {
            if rechargePlatformContactTime == 0 {
                rechargePlatformContactTime = time
            }

            let contactDuration = time - rechargePlatformContactTime

            reward += 0.25

            if contactDuration >= requiredRechargeContactDuration,
               !hasCompletedRechargeGoal {
                hasCompletedRechargeGoal = true
                reward += 5.0

                publishDebug(
                    "GOAL COMPLETE: maintained recharge-platform contact for " +
                    "\(String(format: "%.2f", contactDuration)) seconds."
                )

                locomotion.completeEpisode(.recharged)
                executive.learner.clearTraces()
            }
        } else {
            rechargePlatformContactTime = 0
            hasReachedRechargePlatform = false
        }

        let stateKey = previousGoalStateKey ?? currentStateKey
        let learnedAction = previousGoalAction ?? action

        reinforceOutcome(
            stateKey: stateKey,
            action: learnedAction,
            reward: reward,
            nextStateKey: currentStateKey
        )

        print(
            """
            [Goal Outcome]
            action=\(actionName)
            windowDisplacement=\(String(format: "%.3f", outcomeWindowDisplacement))
            previousGoalDistance=\(String(format: "%.3f", previousDistance))
            currentGoalDistance=\(String(format: "%.3f", currentDistance))
            pathGoalDistance=\(String(format: "%.3f", pathGoalDistance))
            windowGoalProgress=\(String(format: "%.3f", outcomeWindowGoalProgress))
            reward=\(String(format: "%.3f", reward))
            noProgressCount=\(consecutiveNoProgressCount)
            """
        )

        outcomeWindowElapsedTime = 0
        outcomeWindowDisplacement = 0
        outcomeWindowGoalProgress = 0
        outcomeWindowPathProgress = 0
    }

    // MARK: - Character Animation

    private func animateCharacter(character: SCNNode) {
        let swing = locomotion.gaitSwing
        let phase = locomotion.gaitPhase

        findNode(named: "FrankensteinLeftLeg", under: character)?
            .eulerAngles.x = swing * 0.65

        findNode(named: "FrankensteinRightLeg", under: character)?
            .eulerAngles.x = -swing * 0.65

        findNode(named: "FrankensteinLeftArm", under: character)?
            .eulerAngles.x = -swing * 0.45

        findNode(named: "FrankensteinRightArm", under: character)?
            .eulerAngles.x = swing * 0.45

        if let head = findNode(named: "FrankensteinHead", under: character) {
            head.eulerAngles.y = sin(phase) * 0.04
        }

        if let torso = findNode(named: "FrankensteinTorso", under: character) {
            let crouch = min(max(locomotion.output.crouch, 0), 1)

            torso.position.y = 1.28 - 0.15 * crouch
        }
    }

    // MARK: - Physics

    private func configurePhysicsWorld(in scene: SCNScene) {
        scene.physicsWorld.gravity = SCNVector3(0, -worldGravity, 0)
        scene.physicsWorld.speed = 1

        func visit(_ node: SCNNode) {
            if node !== characterNode &&
                !isCharacterPart(node) &&
                !isQGridNode(node) {
                configurePhysicsBody(for: node, forceDynamic: false)
            }

            for child in node.childNodes { visit(child) }
        }

        visit(scene.rootNode)
    }

    private func configurePhysicsBody(
        for node: SCNNode,
        forceDynamic: Bool
    ) {
        let hasOwnGeometry = node.geometry != nil

        let hasDescendantGeometry = node.childNodes.contains { child in
            child.geometry != nil ||
            child.childNodes.contains(where: { $0.geometry != nil })
        }

        guard hasOwnGeometry || hasDescendantGeometry else { return }

        let name = (node.name ?? "").lowercased()

        if name.contains("chasm") ||
            name.contains("void") ||
            name.contains("gap") ||
            name.contains("qfloorgrid") ||
            name.contains("marker") ||
            name.contains("camera") ||
            name.contains("light") {
            return
        }

        if isCharacterPart(node) || isQGridNode(node) {
            return
        }

        let movableTokens = [
            "table", "crate", "box", "movable",
            "pickup", "chair", "stool", "block", "object"
        ]

        let supportTokens = [
            "floor", "ground", "platform",
            "stair", "step", "terrain", "wall", "doorframe"
        ]

        let shouldBeDynamic =
            forceDynamic ||
            movableTokens.contains(where: { name.contains($0) })

        let shouldBeStatic =
            supportTokens.contains(where: { name.contains($0) })

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

    // MARK: - Dimensions and Names

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

        let scaleX = sqrt(
            transform.m11 * transform.m11 +
            transform.m21 * transform.m21 +
            transform.m31 * transform.m31
        )

        let scaleY = sqrt(
            transform.m12 * transform.m12 +
            transform.m22 * transform.m22 +
            transform.m32 * transform.m32
        )

        let scaleZ = sqrt(
            transform.m13 * transform.m13 +
            transform.m23 * transform.m23 +
            transform.m33 * transform.m33
        )

        return SCNVector3(scaleX, scaleY, scaleZ)
    }

    private func readableName(for node: SCNNode) -> String {
        if let name = node.name, !name.isEmpty {
            return name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
        }

        if node.geometry is SCNBox {
            return "Box-shaped object"
        }

        if node.geometry is SCNSphere {
            return "Sphere-shaped object"
        }

        if node.geometry is SCNCylinder {
            return "Cylinder-shaped object"
        }

        return "Unnamed scene object"
    }

    private func findNode(
        named name: String,
        under root: SCNNode
    ) -> SCNNode? {
        if root.name == name {
            return root
        }

        return root.childNode(
            withName: name,
            recursively: true
        )
    }

    private func findNode(
        containing text: String,
        under root: SCNNode
    ) -> SCNNode? {
        let search = text.lowercased()

        if root.name?.lowercased().contains(search) == true {
            return root
        }

        for child in root.childNodes {
            if let found = findNode(containing: search, under: child) {
                return found
            }
        }

        return nil
    }

    // MARK: - Pickup

    private func pickupTarget(for node: SCNNode) -> SCNNode? {
        var current: SCNNode? = node

        while let candidate = current {
            let name = candidate.name?.lowercased() ?? ""

            if name.contains("pickup") ||
                name.contains("movable") ||
                name.contains("carryable") ||
                name.contains("crate") ||
                name.contains("box") ||
                name == "table" {
                return candidate
            }

            current = candidate.parent
        }

        return nil
    }

    @discardableResult
    func attemptPickup() -> Bool {
        guard carriedNode == nil,
              let character = characterNode,
              let scene,
              let detection = latestDetection,
              detection.pickupable,
              detection.distance <= pickupDistance,
              let hitNode = nearestPickupNode(
                from: character,
                in: scene
              ),
              let target = pickupTarget(for: hitNode) else {
            return false
        }

        carriedOriginalParent = target.parent
        carriedOriginalPosition = target.position

        target.removeFromParentNode()

        let carriedDepth = worldDimensions(of: target).z

        if let handNode {
            handNode.addChildNode(target)
            target.position = SCNVector3(
                0,
                -0.08,
                -(0.20 + carriedDepth * 0.5)
            )
        } else {
            character.addChildNode(target)
            target.position = SCNVector3(0.35, 1.0, -0.35)
        }

        carriedNode = target

        publishDebug("Picked up \(readableName(for: target)).")

        return true
    }

    private func nearestPickupNode(
        from character: SCNNode,
        in scene: SCNScene
    ) -> SCNNode? {
        let position = character.presentation.worldPosition
        let forward = forwardVector()

        let start = SCNVector3(
            position.x,
            position.y + 0.7,
            position.z
        )

        let end = SCNVector3(
            start.x + forward.x * 2.0,
            start.y,
            start.z + forward.z * 2.0
        )

        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            SCNHitTestOption.backFaceCulling.rawValue: true
        ]

        let hits = scene.rootNode.hitTestWithSegment(
            from: start,
            to: end,
            options: options
        )

        return hits.first(where: {
            !isCharacterPart($0.node) &&
            !isGroundLikeNode($0.node) &&
            pickupTarget(for: $0.node) != nil
        })?.node
    }

    // MARK: - Push

    /// While the CA's action is pushObject, the block ahead is driven forward
    /// along the character's heading, a little faster than the body walks so
    /// it stays out in front. The distance it really moved is reported back
    /// so the push is judged by its result.
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

        // The block must be in front of the body and within reach.
        guard ahead > 0.05, ahead < 1.8, sideways < 0.85 else {
            pushLastNodePosition = nil
            return
        }

        configurePhysicsBody(for: node, forceDynamic: true)

        guard let body = node.physicsBody else { return }

        body.velocity = SCNVector3(
            forward.x * pushBlockSpeed,
            body.velocity.y,
            forward.z * pushBlockSpeed
        )

        // Keep it from tumbling while shoved.
        body.angularVelocity = SCNVector4Zero

        let current = SIMD2<Float>(Float(n.x), Float(n.z))

        if let last = pushLastNodePosition {
            let moved = current - last

            pushAccumulatedMeters += moved.x * forward.x + moved.y * forward.z
        }

        pushLastNodePosition = current

        locomotion.reportPushProgress(pushAccumulatedMeters)
    }

    // MARK: - Place / Throw

    @discardableResult
    private func dropCarriedObject(
        distance: Float,
        thrown: Bool
    ) -> Bool {
        guard let carriedNode,
              let character = characterNode,
              let scene else {
            return false
        }

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

        carriedNode.position = scene.rootNode.convertPosition(
            startWorld,
            from: nil
        )

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
                body.applyForce(
                    SCNVector3(forward.x * 2.2, 3.0, forward.z * 2.2),
                    asImpulse: true
                )
            }
        }

        self.carriedNode = nil
        carriedOriginalParent = nil

        publishDebug(
            thrown
                ? "Object released with an impulse."
                : "Object released; gravity determines final support."
        )

        return true
    }

    @discardableResult
    func placeCarriedObjectAhead() -> Bool {
        dropCarriedObject(distance: 0.9, thrown: false)
    }

    @discardableResult
    func throwCarriedObjectAhead() -> Bool {
        dropCarriedObject(distance: 2.6, thrown: true)
    }

    private func updateCarriedObject() {
        if let carriedNode, carriedNode.parent == nil {
            self.carriedNode = nil
        }
    }

    // MARK: - Door

    /// Doors open only when the CA's executed action pushes forward into
    /// them: the CA decides to go through, the door does not act on its own.
    private func updateDoorInteraction(executedAction: FrankensteinAction) {
        let forwardActions: Set<FrankensteinAction> = [
            .walk, .run, .stepForward, .stepUp, .jump
        ]

        guard forwardActions.contains(executedAction),
              let character = characterNode,
              let door = doorNode else {
            return
        }

        let characterPosition = character.presentation.worldPosition
        let doorPosition = door.presentation.worldPosition

        let dx = Float(characterPosition.x - doorPosition.x)
        let dz = Float(characterPosition.z - doorPosition.z)
        let distance = sqrt(dx * dx + dz * dz)

        guard distance < interactionDistance else {
            return
        }

        // The door must be in front of the character, not beside or behind it.
        let facing = forwardVector()
        let toDoor = SIMD2<Float>(-dx, -dz)
        let toDoorLength = simd_length(toDoor)

        if toDoorLength > 0.001 {
            let alignment = simd_dot(
                SIMD2<Float>(facing.x, facing.z),
                toDoor / toDoorLength
            )

            guard alignment > 0.3 else { return }
        }

        guard door.name?.lowercased().contains("door") == true else {
            return
        }

        guard abs(door.eulerAngles.y) < 0.1 else {
            return
        }

        door.runAction(
            SCNAction.rotateBy(
                x: 0,
                y: CGFloat.pi / 2,
                z: 0,
                duration: 0.35
            )
        )

        publishDebug("Opened nearby door.")
    }

    // MARK: - Filtering

    private func isCharacterPart(_ node: SCNNode) -> Bool {
        guard let characterNode else {
            return false
        }

        if node === characterNode {
            return true
        }

        var current: SCNNode? = node.parent

        while let parent = current {
            if parent === characterNode {
                return true
            }

            current = parent.parent
        }

        return false
    }

    private func isFloorSurface(_ node: SCNNode) -> Bool {
        let name = node.name?.lowercased() ?? ""

        if name.contains("floor") || name.contains("ground") {
            return true
        }

        let size = worldDimensions(of: node)

        return size.y < 0.2 && max(size.x, size.z) > 3.0
    }

    private func isGroundLikeNode(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node

        while let candidate = current {
            let name = candidate.name?.lowercased() ?? ""

            if name.contains("floor") ||
                name.contains("ground") ||
                name.contains("terrain") ||
                name.contains("platform") {
                return true
            }

            current = candidate.parent
        }

        return false
    }

    // MARK: - Forward Vector

    private func forwardVector() -> SIMD3<Float> {
        SIMD3<Float>(
            -sin(heading),
            0,
            -cos(heading)
        )
    }

    // MARK: - Statistics

    private func publishGeneralStats() {
        let action = locomotion.activeActionName
        let terrain = String(describing: latestTerrainSample.terrain)

        if action != lastDisplayedActionName {
            lastDisplayedActionName = action

            DispatchQueue.main.async { [weak self] in
                self?.onActionChanged?(action)
            }
        }

        if let narrative = ca?.lastDecisionDescription {
            DispatchQueue.main.async { [weak self] in
                self?.onPlanText?(narrative)
            }
        }

        let pathText = pathGoalDistance.isFinite
            ? String(format: "%.2f", Double(pathGoalDistance))
            : "n/a"

        let stats = """
        Action: \(action)
        Terrain: \(terrain)
        Distance ahead: \(String(format: "%.2f", Double(latestTerrainSample.distance))) m
        Ground ahead: \(latestTerrainSample.isGroundAhead)
        Verified support: \(verifiedGroundSupport)
        Verified landing: \(verifiedLandingSupport)
        Visible objects: \(visibleObjects.count)
        Recharge distance: \(String(format: "%.2f", Double(rechargePlatformDistance))) m
        CA path distance: \(pathText) m
        CA path detour: \(pathSteering?.isDetouring ?? false)
        CA path generation: \(pathSteering?.generation ?? 0)
        CA plan: \(ca?.plannedSequence.map { String(describing: $0) }.joined(separator: " > ") ?? "n/a")
        CA goal seeking: \(ca?.goalSeekingStatus ?? "n/a")
        No-progress count: \(consecutiveNoProgressCount)
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
        DispatchQueue.main.async { [weak self] in
            self?.onDebugInfo?(message)
        }
    }
}

extension Coordinator {
    func attachExecutiveCA(_ ca: FrankensteinCA) {
        attachCA(ca)

        print(
            "[Coordinator] Shared CA attached; " +
            "generation=\(ca.generation), " +
            "live cells=\(ca.liveCellCount)"
        )
    }

    func logExecutiveControlState(
        terrain: FrankensteinTerrainSample,
        locomotion: FrankensteinLocomotion
    ) {
        print("[Coordinator] CA generation=\(locomotion.attachedCAGeneration), live cells=\(locomotion.attachedCALiveCellCount)")
        print("[Coordinator] CA decision=\(locomotion.caCommandName)")
        print("[Coordinator] applied action=\(locomotion.activeActionName)")
        print("[Coordinator] terrain=\(terrain.terrain), Q updates=\(locomotion.policy.updateCount), states=\(locomotion.policy.learnedStateCount)")
        print("[Coordinator] visible objects=\(latestDetections.count)")
        print("[Coordinator] CA object/goal Q states=\(executive.learner.stateCount)")
        print("[Coordinator] CA path field generation=\(executive.field.generation), path distance=\(pathGoalDistance)")
    }
}
