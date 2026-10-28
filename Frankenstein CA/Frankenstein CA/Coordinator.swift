import Foundation
import SceneKit
import simd
import SwiftUI
import UIKit

final class Coordinator: NSObject, SCNSceneRendererDelegate {
    private var goalCorrectionActiveUntil: TimeInterval = 0
    private var currentFrameTime: TimeInterval = 0
    private let requiredRechargeContactDuration: TimeInterval = 1.0
    private var hasCompletedRechargeGoal = false

    private var goalCorrectionCooldown: TimeInterval = 0
    private let goalCorrectionInterval: TimeInterval = 0.75
    private let goalAlignmentThreshold: Float = 0.35

    private var lastGoalDistance: Float = .infinity

    var onCAStats: ((Int, Int) -> Void)?

    private var ca: FrankensteinCA?
    private var lastCATickTime: TimeInterval = 0
    private let caTickInterval: TimeInterval = 0.25

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

    // MARK: - Object and Goal Q-Learning

    private var objectQValues: [String: [String: Float]] = [:]
    private let objectQLearningRate: Float = 0.20
    private let goalDiscountFactor: Float = 0.90

    private let noProgressThreshold: Float = 0.015
    private let noProgressPenalty: Float = -0.05
    private let goalProgressRewardScale: Float = 2.0

    private var previousGoalStateKey: String?
    private var previousGoalAction: FrankensteinAction?

    // MARK: - Outcome Window

    private var outcomeWindowElapsedTime: TimeInterval = 0
    private var outcomeWindowDisplacement: Float = 0
    private var outcomeWindowGoalProgress: Float = 0
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
        objectQValues.removeAll()
        latestDetections.removeAll()
        latestDetectionNodes.removeAll()
        latestRayObservations.removeAll()

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

            verifiedGroundSupport = verifySupportBeneathCharacter(
                character: character,
                in: scene
            )

            updateObjectQValues(
                terrain: latestTerrainSample,
                detections: detailedDetections
            )

            let detections = latestDetections

            DispatchQueue.main.async { [weak self] in
                self?.onDetectedObject?(detections.first)
                self?.onDetectedObjects?(detections)
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

        // MARK: 2. Actual displacement and prediction

        let currentPosition = character.presentation.worldPosition

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

        // MARK: 3. Advisory object/goal values

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

        let objectObservation: FrankensteinObjectObservation? = latestDetection.map { item in
            FrankensteinObjectObservation(
                name: item.name,
                width: item.dimensions.x,
                height: item.dimensions.y,
                depth: item.dimensions.z,
                distance: item.distance,
                pickupable: item.pickupable
            )
        }

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

        applyMovement(
            output: output,
            deltaTime: dt,
            character: character,
            scene: scene
        )

        applyGoalCorrection(
            output: output,
            character: character,
            time: time
        )

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
        updateDoorInteraction()

        let policyUpdates = locomotion.policy.updateCount

        if policyUpdates > lastRecordedQUpdate {
            let newCount = policyUpdates - lastRecordedQUpdate

            for record in locomotion.policy.updateLog.suffix(newCount) {
                qFloorGrid.record(
                    position: character.presentation.worldPosition,
                    action: record.action,
                    newValue: record.newValue
                )
            }

            lastRecordedQUpdate = policyUpdates
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

    // MARK: - Advisory Values

    private func makeAdvisoryActionValues(
        baseValues: [FrankensteinAction: Float],
        allowedActions: [FrankensteinAction]
    ) -> [FrankensteinAction: Float] {
        var merged = baseValues

        let goalKey = goalStateKey(terrain: latestTerrainSample)
        let goalValues = objectQValues[goalKey] ?? [:]

        let objectKey = latestDetection.map {
            objectStateKey(for: $0, terrain: latestTerrainSample)
        }

        let objectValues = objectKey.flatMap { objectQValues[$0] } ?? [:]

        for action in allowedActions {
            let actionName = String(describing: action)

            let goalValue = goalValues[actionName] ?? 0
            let objectValue = objectValues[actionName] ?? 0

            merged[action, default: 0] +=
                0.35 * goalValue +
                0.20 * objectValue
        }

        return merged
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

    // MARK: - Object and Goal Q-Learning

    private func objectClass(for name: String) -> String {
        let value = name.lowercased()

        if value.contains("recharge") {
            return "rechargeStation"
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
            verifiedGroundSupport ? "supported" : "unsupported"
        ].joined(separator: "|")
    }

    private func goalStateKey(
        terrain: FrankensteinTerrainSample
    ) -> String {
        let progress: String

        switch rechargePlatformDistance {
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
            latestTerrainSample.carryingObject ? "carrying" : "empty"
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

        for detection in detections {
            let key = objectStateKey(
                for: detection.info,
                terrain: terrain
            )

            for action in allowed {
                let actionName = String(describing: action)

                if objectQValues[key]?[actionName] == nil {
                    objectQValues[key, default: [:]][actionName] = 0
                }
            }
        }

        let goalKey = goalStateKey(terrain: terrain)

        for action in allowed {
            let actionName = String(describing: action)

            if objectQValues[goalKey]?[actionName] == nil {
                objectQValues[goalKey, default: [:]][actionName] = 0
            }
        }
    }

    private func reinforceOutcome(
        stateKey: String,
        action: FrankensteinAction,
        reward: Float,
        nextStateKey: String? = nil
    ) {
        let actionName = String(describing: action)

        let currentValue = objectQValues[stateKey]?[actionName] ?? 0

        var maxNextValue: Float = 0

        if let nextStateKey {
            maxNextValue = objectQValues[nextStateKey]?.values.max() ?? 0
        }

        let target = reward + goalDiscountFactor * maxNextValue
        let updatedValue = currentValue +
            objectQLearningRate * (target - currentValue)

        objectQValues[stateKey, default: [:]][actionName] = updatedValue
    }

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

  
    private func applyMovement(
        output: FrankensteinLocomotionOutput,
        deltaTime dt: Float,
        character: SCNNode,
        scene: SCNScene
    ) {
        guard dt.isFinite, dt > 0 else { return }

        // Preserve the corrected heading temporarily so the CA
        // cannot immediately overwrite the goal correction.
        if currentFrameTime >= goalCorrectionActiveUntil {
            heading = output.heading
        }

        // Calculate forward from the resolved heading.
        let forward = forwardVector()
        let speed = max(0, output.speed) * output.moveDirection

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
            output.action == .jump

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

        guard outcomeWindowElapsedTime >= outcomeWindowDuration else {
            return
        }

        var reward: Float = 0

        if abs(outcomeWindowDisplacement) < noProgressThreshold {
            consecutiveNoProgressCount += 1
            reward += noProgressPenalty

            if consecutiveNoProgressCount >= 3 {
                publishDebug(
                    "No measurable progress for \(actionName); reconsidering action."
                )
            }
        } else if outcomeWindowGoalProgress > 0.001 {
            consecutiveNoProgressCount = 0

            reward += outcomeWindowDisplacement * 0.25
            reward += outcomeWindowGoalProgress * goalProgressRewardScale
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
            windowGoalProgress=\(String(format: "%.3f", outcomeWindowGoalProgress))
            reward=\(String(format: "%.3f", reward))
            noProgressCount=\(consecutiveNoProgressCount)
            """
        )

        outcomeWindowElapsedTime = 0
        outcomeWindowDisplacement = 0
        outcomeWindowGoalProgress = 0
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

    private func updateDoorInteraction() {
        guard let character = characterNode,
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

        let stats = """
        Action: \(action)
        Terrain: \(terrain)
        Distance ahead: \(String(format: "%.2f", Double(latestTerrainSample.distance))) m
        Ground ahead: \(latestTerrainSample.isGroundAhead)
        Verified support: \(verifiedGroundSupport)
        Verified landing: \(verifiedLandingSupport)
        Visible objects: \(latestDetections.count)
        Recharge distance: \(String(format: "%.2f", Double(rechargePlatformDistance))) m
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
        print("[Coordinator] object/goal Q states=\(objectQValues.count)")
    }

    // MARK: - Goal Correction

    private func applyGoalCorrection(
        output: FrankensteinLocomotionOutput,
        character: SCNNode,
        time: TimeInterval
    ) {
        guard let station = rechargeStationNode else {
            return
        }

        guard latestDetections.isEmpty || latestDetection == nil else {
            return
        }

        guard output.action == .walk || output.action == .run else {
            return
        }

        guard time >= goalCorrectionCooldown else {
            return
        }

        let characterPosition = character.presentation.worldPosition
        let stationPosition = station.presentation.worldPosition

        let dx = Float(stationPosition.x - characterPosition.x)
        let dz = Float(stationPosition.z - characterPosition.z)

        let distance = sqrt(dx * dx + dz * dz)

        guard distance > 0.001 else {
            return
        }

        let desiredHeading = atan2(-dx, -dz)

        var headingError = desiredHeading - heading

        while headingError > .pi {
            headingError -= 2 * .pi
        }

        while headingError < -.pi {
            headingError += 2 * .pi
        }

        guard abs(headingError) > goalAlignmentThreshold else {
            return
        }

        let turnAmount: Float = headingError > 0
            ? 0.45
            : -0.45

        heading += turnAmount
        character.eulerAngles.y = heading

        goalCorrectionCooldown = time + goalCorrectionInterval

        publishDebug(
            "Goal correction: turning toward recharge platform; " +
            "distance=\(String(format: "%.2f", distance)) m."
        )
    }
}
