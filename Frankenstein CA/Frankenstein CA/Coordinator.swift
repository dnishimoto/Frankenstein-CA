import Foundation
import SceneKit
import simd
import SwiftUI
import UIKit


final class Coordinator: NSObject, SCNSceneRendererDelegate {
    
    // MARK: - Cellular Automaton

    var onCAStats: ((Int, Int) -> Void)?

    private var ca: FrankensteinCA?

    private var lastCATickTime: TimeInterval = 0
    private let caTickInterval: TimeInterval = 0.25


    // MARK: - Callbacks

    var onStats: ((String) -> Void)?
    var onDebugInfo: ((String) -> Void)?
    var onDetectedObject: ((DetectedObjectInfo?) -> Void)?
    var onActionChanged: ((String) -> Void)?

    // MARK: - Scene References

    private weak var scene: SCNScene?
    private weak var characterNode: SCNNode?
    private weak var doorNode: SCNNode?
    private weak var tableNode: SCNNode?
    private weak var handNode: SCNNode?

    // MARK: - Simulation

    private let locomotion: FrankensteinLocomotion
    private let qFloorGrid = FrankensteinQFloorGrid()
    private let predictivePerception = FrankensteinPredictivePerception()
    private var pendingPrediction: FrankensteinPredictedOutcome?
    private var lastRecordedQUpdate = 0
    private var rechargeStationNode: SCNNode?

    // SceneKit physics and character fall tracking. Frankenstein remains
    // kinematic/manual-movement controlled; loose objects are physics-driven.
    private var characterVerticalVelocity: Float = 0
    private var hasReportedFall = false
    private var hasReportedRecharge = false
    private let worldGravity: Float = 9.8

    // MARK: - Lifecycle

    private var isRunning = false
    private var lastFrameTime: TimeInterval = 0
    private var lastSensorTime: TimeInterval = 0
    private var lastStatsTime: TimeInterval = 0

    private let sensorInterval: TimeInterval = 0.10
    private let statsInterval: TimeInterval = 0.25

    // MARK: - Movement State

    private var heading: Float = 0
    private var previousCharacterPosition = SCNVector3Zero
    private var hasPreviousCharacterPosition = false

    private var latestTerrainSample = FrankensteinTerrainSample()
    private var latestDetection: DetectedObjectInfo?

    private var lastActionName = ""
    private var lastDebugMessage = ""

    // MARK: - Jump State

    private let standingHeight: Float = 1.8
    /// Vertical distance from the character root origin to the lowest visible foot/boot point.
    /// Grounding must compare the feet with the support surface, not the model origin.
    private var characterFootOffset: Float = 0
    private var jumpBaseY: Float?

    // MARK: - Object Interaction

    private var carriedNode: SCNNode?
    private var carriedOriginalParent: SCNNode?
    private var carriedOriginalPosition = SCNVector3Zero

    private let pickupDistance: Float = 1.25
    private let interactionDistance: Float = 1.25

    // MARK: - Original Initializer
    //
    // Keep this signature compatible with FrankensteinSceneView.

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

    /// Connect the existing cellular automaton to the coordinator.
   
    func attachCA(_ ca: FrankensteinCA) {
        self.ca = ca

        // Connect this exact CA instance to locomotion.
        locomotion.attachCA(ca)

        // Publish the initial generation and live-cell count.
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
    /// Send generation and live-cell counts to the UI.
    private func publishCAStats() {
        guard let ca else { return }

        let generation = ca.generation
        let liveCells = ca.liveCellCount

        DispatchQueue.main.async { [weak self] in
            self?.onCAStats?(generation, liveCells)
        }
    }

    // MARK: - Attach Actual Displayed Scene
    //
    // FrankensteinSceneView calls this after constructing the scene.

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

        // Discover commonly named course objects.
        doorNode = findNode(
            containing: "door",
            under: scene.rootNode
        )

        tableNode = findNode(
            containing: "table",
            under: scene.rootNode
        )

        // Build the Q-value board on the floor. It was never attached
        // before, so update() found nothing to draw on.
        qFloorGrid.attach(to: scene)

        rechargeStationNode = findNode(
            containing: "rechargestation",
            under: scene.rootNode
        )

        publishDebug("Coordinator attached to displayed scene.")
    }

    /// The Q board is a display, not terrain. Rays must ignore it.
    private func isQGridNode(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node
        while let candidate = current {
            if candidate.name == "FrankensteinQFloorGrid" { return true }
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

    /// Returns the highest solid surface directly beneath an object's
    /// footprint, excluding the object and its own child meshes.
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

            // Never use the table itself or one of its child meshes as support.
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

            // Decorative markers and the charging station are not support.
            if name.contains("marker") ||
                name.contains("rechargestation") {
                continue
            }

            return Float(hit.worldCoordinates.y)
        }

        return nil
    }

    /// Moves a node vertically so its lowest world-space point touches
    /// the highest valid support surface below it.
    ///
    /// If no surface is found, the node is left unchanged.
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

        // Move along world Y, not the parent's local Y axis.
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
    func attachHand(_ node: SCNNode?) {
        handNode = node
    }

    // MARK: - Start / Stop
    //
    // These methods are required by FrankensteinSceneView.

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

        // MARK: 1. Calculate frame time

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

        // MARK: 2. Advance the cellular automaton

        if time - lastCATickTime >= caTickInterval {
            lastCATickTime = time

            // SceneKit renderer callbacks are not guaranteed to run on
            // the main thread. Update the ObservableObject on the main thread.
            DispatchQueue.main.async { [weak self] in
                self?.tickCA()
            }
        }

        // MARK: 3. Sense objects and terrain

        if time - lastSensorTime >= sensorInterval {
            lastSensorTime = time

            latestDetection = detectObjectAhead(
                from: character,
                in: scene
            )

            latestTerrainSample = makeTerrainSample(
                for: character,
                in: scene
            )

            let detection = latestDetection

            // Object detection -> Coordinator: attach what was seen to the sample.
            latestTerrainSample.objectName = detection?.name ?? ""
            latestTerrainSample.carryingObject = carriedNode != nil
            latestTerrainSample.objectPickupable =
                (detection?.pickupable ?? false) &&
                (detection?.distance ?? .infinity) <= pickupDistance

            DispatchQueue.main.async { [weak self] in
                self?.onDetectedObject?(detection)
            }
        }

        // MARK: 4. Measure actual displacement

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

        // Compare the previous action's prediction with measured movement.
        if let prediction = pendingPrediction, let actualDisplacement {
            let error = predictivePerception.observe(
                prediction: prediction,
                actualForwardDisplacement: actualDisplacement,
                terrain: latestTerrainSample
            )
            if abs(error) > 0.18 {
                publishDebug("Prediction error: expected \(String(format: "%.2f", prediction.expectedForwardDisplacement)) m, measured \(String(format: "%.2f", actualDisplacement)) m; model adjusted.")
            }
            pendingPrediction = nil
        }

        // MARK: 4b. Coordinator -> Q-policy and CA
        // The policy only reports stored values for what was seen. The
        // coordinator hands both the perception and those values to the CA
        // (through locomotion); the CA alone chooses the behavior.

        let perceivedValues = locomotion.policy.learnedActionValues(
            terrain: latestTerrainSample,
            body: locomotion.body
        )
        let perceivedActions = FrankensteinActionConstraints.allowedActions(
            terrain: latestTerrainSample,
            body: locomotion.body
        )
        locomotion.receivePerception(
            allowedActions: perceivedActions,
            qValues: perceivedValues
        )

        // MARK: 5. Select a locomotion action

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

        // Predict the selected action's likely consequence before execution.
        // The next renderer sample compares this estimate with measured movement.
        pendingPrediction = predictivePerception.predict(
            actionName: String(describing: output.action),
            terrain: latestTerrainSample,
            body: locomotion.body,
            objectObservation: objectObservation
        )

        // MARK: 6. Apply movement to the character

        applyMovement(
            output: output,
            deltaTime: dt,
            character: character,
            scene: scene
        )

        // MARK: 7. Animate the character

        animateCharacter(character: character)

        // MARK: 8. Update object and door interactions

        updateCarriedObject()
        updateDoorInteraction()

        // MARK: 9. Update the Q-learning floor visualization

        // Attribute each new Q-update to the floor cell he stands in.
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

        // MARK: 10. Publish general statistics

        if time - lastStatsTime >= statsInterval {
            lastStatsTime = time
            publishGeneralStats()
        }
    }


    // MARK: - Terrain Sensing

    private func makeTerrainSample(
        for character: SCNNode,
        in scene: SCNScene
    ) -> FrankensteinTerrainSample {

        let position = character.presentation.worldPosition
        let forward = forwardVector()

        var sample = FrankensteinTerrainSample()

        let currentGround = raycastGround(
            near: position,
            in: scene
        )

        sample.groundHeight =
            currentGround ?? Float(position.y)

        sample.nextGroundHeight = sample.groundHeight
        sample.distance = 5
        sample.isGroundAhead = true
        sample.isLandingAreaClear = false
        sample.gapWidth = 0
        sample.gapNearEdgeDistance = .infinity
        sample.gapFarEdgeDistance = .infinity
        sample.landingHeightDelta = 0

        // Detect a forward object independently of ground sensing.
        if let detection = detectObjectAhead(
            from: character,
            in: scene
        ) {
            sample.distance = detection.distance

            // Height above what he is standing on, not the box's full height.
            let rise = detection.topY > 0
                ? max(0, detection.topY - sample.groundHeight)
                : detection.dimensions.y
            sample.obstacleHeight = rise
            sample.obstacleDepth = detection.dimensions.z
            sample.objectName = detection.name

            let name = detection.name.lowercased()

            let bottomY = Float(detection.worldPosition.y) - detection.dimensions.y * 0.5
            if name.contains("ceiling") ||
                bottomY > sample.groundHeight + 0.8 {
                // Overhead slab: it starts above knee height.
                sample.terrain = .lowCeiling
            } else if rise <= 0.08 {
                sample.terrain = .uneven
            } else if rise <= 0.45 {
                sample.terrain = .raisedStep
            } else {
                sample.terrain = .hurdle
            }

            // Landing: on top of the obstacle, or beyond it.
            if sample.terrain == .hurdle || sample.terrain == .raisedStep {
                let topProbe = SCNVector3(
                    position.x + forward.x * (detection.distance + detection.dimensions.z * 0.5),
                    detection.topY + 0.1,
                    position.z + forward.z * (detection.distance + detection.dimensions.z * 0.5)
                )
                let onTopClear = rise <= 0.75 && hasClearSpace(
                    around: SCNVector3(topProbe.x, detection.topY + 0.15, topProbe.z),
                    in: scene
                )

                var beyondClear = false
                let landingDistance =
                    detection.distance + max(detection.dimensions.z, 0.3) + 0.4
                let beyondProbe = SCNVector3(
                    position.x + forward.x * landingDistance,
                    position.y,
                    position.z + forward.z * landingDistance
                )
                if let landingHeight = raycastGround(near: beyondProbe, in: scene) {
                    let delta = landingHeight - sample.groundHeight
                    sample.landingHeightDelta = delta
                    sample.nextGroundHeight = landingHeight
                    beyondClear = abs(delta) <= 0.25 && hasClearSpace(
                        around: SCNVector3(beyondProbe.x, landingHeight + 0.15, beyondProbe.z),
                        in: scene
                    )
                }
                sample.isLandingAreaClear = onTopClear || beyondClear
            }
        } else {
            sample.terrain = .flat
        }

        // Probe the ground at several distances ahead.
        let distances: [Float] = [
            0.65, 1.0, 1.5, 2.2, 3.0
        ]

        var groundHits: [(distance: Float, height: Float)] = []
        var firstProbeHasGround = false

        for (index, distance) in distances.enumerated() {
            let probe = SCNVector3(
                position.x + forward.x * distance,
                position.y + 3.0,
                position.z + forward.z * distance
            )

            if let height = raycastGround(
                near: probe,
                in: scene
            ) {
                groundHits.append((distance, height))

                if index == 0 {
                    firstProbeHasGround = true
                }
            }
        }

        sample.isGroundAhead = firstProbeHasGround

        // A missing near probe followed by a farther ground hit
        // can indicate a gap. This is a geometric estimate.
        if !firstProbeHasGround {
            if let landing = groundHits.last {
                sample.terrain = .gap
                sample.distance = distances[0]
                sample.gapNearEdgeDistance = distances[0]
                sample.gapFarEdgeDistance = landing.distance

                sample.gapWidth = max(
                    0,
                    landing.distance - distances[0]
                )

                sample.nextGroundHeight = landing.height
                sample.landingHeightDelta =
                    landing.height - sample.groundHeight

                let landingPosition = SCNVector3(
                    position.x + forward.x * landing.distance,
                    landing.height + 0.15,
                    position.z + forward.z * landing.distance
                )

                sample.isLandingAreaClear = hasClearSpace(
                    around: landingPosition,
                    in: scene
                ) && sample.gapWidth > 0
                    && sample.gapWidth <= 3.5
            } else {
                sample.terrain = .gap
                sample.distance = distances[0]
                sample.isLandingAreaClear = false
            }

            return sample
        }

        // If ground is present, use the nearest successful probe
        // to estimate a raised step or a lower surface.
        if let nearest = groundHits.first {
            sample.nextGroundHeight = nearest.height

            sample.landingHeightDelta =
                nearest.height - sample.groundHeight

            let rise =
                nearest.height - sample.groundHeight

            if rise > 0.05 && rise <= 0.45 {
                sample.terrain = .raisedStep
                sample.obstacleHeight = rise
                sample.distance = nearest.distance
            }
        }

        return sample
    }

    // MARK: - World top of a node

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

    // MARK: - Support surface (what he stands on, including boxes and steps)

    /// Highest solid top surface at or just below his feet. Unlike
    /// raycastGround, this counts crates, steps and platforms, so he can
    /// stand on them. It starts only 0.9 above his feet so a ceiling
    /// overhead is never mistaken for ground.
    private func raycastSupport(
        at position: SCNVector3,
        in scene: SCNScene,
        riseAllowance: Float = 0.9
    ) -> Float? {
        let start = SCNVector3(position.x, position.y + riseAllowance, position.z)
        let end = SCNVector3(position.x, position.y - 8.0, position.z)

        let options: [String: Any] = [
            SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
            // Include both face orientations; the upward-normal test below still
            // rejects walls/ceilings but avoids missing thin floor meshes.
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

            // Prefer an upward-facing surface. Named floor/ground/platform nodes
            // are also accepted when imported mesh normals are reversed.
            if hit.worldNormal.y <= 0.35 && !isGroundLikeNode(hit.node) {
                continue
            }

            let name = (hit.node.name ?? "").lowercased()
            if name.contains("marker") || name.contains("rechargestation") {
                continue
            }

            return Float(hit.worldCoordinates.y)
        }

        return nil
    }

    // MARK: - Ground Raycast

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

        // Prefer a named ground/floor/platform node when available.
        if let groundHit = validHits.first(where: {
            isGroundLikeNode($0.node)
        }) {
            return Float(groundHit.worldCoordinates.y)
        }

        // Fallback for scenes whose floor geometry has no name.
        if let fallback = validHits.first {
            return Float(fallback.worldCoordinates.y)
        }

        return nil
    }

    // MARK: - Landing Clearance

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

    // MARK: - Object Ray Trace

  
    /// Sweeps several ray heights and sideways offsets so low boxes, which a
    /// single torso-height ray passes over, are still seen. Returns the
    /// nearest object found.
    private func detectObjectAhead(
        from character: SCNNode,
        in scene: SCNScene
    ) -> DetectedObjectInfo? {
        var nearest: DetectedObjectInfo?

        for height in [Float(0.12), 0.40, 0.90] {
            for lateral in [Float(0), 0.3, -0.3] {
                guard let found = detectObjectAhead(
                    from: character,
                    in: scene,
                    rayHeight: height,
                    lateral: lateral
                ) else { continue }

                if nearest == nil || found.distance < nearest!.distance {
                    nearest = found
                }
            }
        }

        return nearest
    }

    private func detectObjectAhead(
        from character: SCNNode,
        in scene: SCNScene,
        rayHeight: Float,
        lateral: Float
    ) -> DetectedObjectInfo? {

        // Use the presentation node so detection follows the animated character.
        let characterPresentation = character.presentation
        let position = characterPresentation.worldPosition

        // SceneKit forward is local -Z. Convert that direction into world space
        // so character rotation is respected.
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

        // Start around the character's upper torso.
        let start = SCNVector3(
            position.x + forward.z * lateral,
            position.y + rayHeight,
            position.z - forward.x * lateral
        )

        // Keep the ray level, so it detects objects in front rather than
        // aiming toward the floor or ceiling.
        let rayLength: Float = 4.0
        let end = SCNVector3(
            start.x + forward.x * rayLength,
            start.y,
            start.z + forward.z * rayLength
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

        // Hits are normally returned nearest first. Filter before selecting,
        // so Frankenstein's body and floor do not hide a real object behind them.
        for hit in hits {
            let hitNode = hit.node

            guard !isCharacterPart(hitNode) else {
                continue
            }

            guard !isFloorSurface(hitNode), !isQGridNode(hitNode) else {
                continue
            }

            // Resolve a geometry child to its meaningful pickup/object parent.
            let hitPoint = hit.worldCoordinates
            let hitDistance = sqrt(
                Float((hitPoint.x - start.x) * (hitPoint.x - start.x)) +
                Float((hitPoint.z - start.z) * (hitPoint.z - start.z))
            )

            guard hitDistance >= Self.minimumHitDistance else {
                continue
            }

            let target = pickupTarget(for: hitNode)
                ?? meaningfulDetectionParent(for: hitNode)

            guard !isContainerNode(target) else {
                continue
            }

            guard target !== character else {
                continue
            }

            guard !isCharacterPart(target) else {
                continue
            }

            let dimensions = worldDimensions(of: target)

            // Ignore nodes without measurable geometry.
            guard dimensions.x > 0.001,
                  dimensions.y > 0.001,
                  dimensions.z > 0.001 else {
                continue
            }

            // A container-sized result means the hit resolved to a group.
            guard max(dimensions.x, max(dimensions.y, dimensions.z)) <=
                    Self.maximumObstacleExtent else {
                continue
            }

            let hitPosition = hit.worldCoordinates

            let dx = Float(hitPosition.x - start.x)
            let dz = Float(hitPosition.z - start.z)

            let distance = sqrt(dx * dx + dz * dz)

            guard distance <= rayLength else {
                continue
            }

            let name = readableName(for: target)

            return DetectedObjectInfo(
                name: name,
                dimensions: dimensions,
                distance: distance,
                worldPosition: target.presentation.worldPosition,
                pickupable: pickupTarget(for: target) != nil,
                topY: worldTopY(of: target)
            )
        }

        return nil
    }

    // MARK: - Resolve the actual object from a child mesh

    /// Names of nodes that only group the scene. A hit must never be promoted
    /// to one of these, because their bounding box covers the whole course.
    private static let containerNodeNames: Set<String> = [
        "ObstacleCourse", "TerrainRoot", "SceneRoot"
    ]

    /// Largest believable single obstacle. Anything larger is a grouping node.
    private static let maximumObstacleExtent: Float = 6.0

    /// Ignore hits closer than this. They are back faces or a ray that
    /// started inside a box, not an obstacle in front of him.
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

            // Stop BEFORE accepting a container as the candidate.
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


    // MARK: - Actual Displacement

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

        heading = output.heading
        let forward = forwardVector()
        let speed = max(0, output.speed) * output.moveDirection

        // Execute CA-requested object interactions once for the pending action.
        if output.liftRequested,
           locomotion.policy.pendingAction == .liftObject {
            locomotion.reportPickupOutcome(succeeded: attemptPickup())
        }
        if output.placeRequested,
           locomotion.policy.pendingAction == .placeObject {
            let ok = placeCarriedObjectAhead()
            locomotion.reportObjectActionOutcome(.placeObject, reward: ok ? 0.5 : -0.5)
        }
        if output.throwRequested,
           locomotion.policy.pendingAction == .throwObject {
            let ok = throwCarriedObjectAhead()
            locomotion.reportObjectActionOutcome(.throwObject, reward: ok ? 0.3 : -0.5)
        }

        // Recharge requires contact with the station's top surface.
        if let station = rechargeStationNode {
            let c = character.presentation.worldPosition
            let size = worldDimensions(of: station)
            let s = station.presentation.worldPosition
            let topY = worldTopY(of: station)
            let onTop = abs(Float(c.x - s.x)) <= max(0.15, size.x * 0.5) &&
                abs(Float(c.z - s.z)) <= max(0.15, size.z * 0.5) &&
                abs(Float(c.y) - topY) <= 0.18
            if onTop {
                if !hasReportedRecharge {
                    locomotion.reportRecharge()
                    hasReportedRecharge = true
                    publishDebug("Charging station physically contacted; verify charge-state increase separately.")
                }
            } else {
                hasReportedRecharge = false
            }
        }

        // IMPORTANT: all calculations below use world coordinates. SceneKit's
        // node.position is parent-local and must not be mixed with raycast world Y.
        let oldWorld = character.presentation.worldPosition
        var proposedWorld = SCNVector3(
            oldWorld.x + forward.x * speed * dt,
            oldWorld.y,
            oldWorld.z + forward.z * speed * dt
        )

        // Do not walk into a known gap unless perception has identified a safe landing.
        if speed > 0,
           latestTerrainSample.terrain == .gap,
           !latestTerrainSample.isLandingAreaClear {
            proposedWorld.x = oldWorld.x
            proposedWorld.z = oldWorld.z
        }

        // Block ordinary walking into a close hurdle. Parentheses make the
        // terrain conditions apply together rather than only to one branch.
        let isClimbing = locomotion.stepUpInProgress ||
            output.action == .stepUp || output.action == .jump
        let isBlockingObstacle = latestTerrainSample.terrain == .hurdle ||
            latestTerrainSample.terrain == .raisedStep
        if output.jump <= 0,
           speed > 0,
           !isClimbing,
           isBlockingObstacle,
           latestTerrainSample.distance < 0.5 {
            proposedWorld.x = oldWorld.x
            proposedWorld.z = oldWorld.z
        }

        if output.jump > 0 {
            // Locomotion supplies the jump height relative to standing height.
            if jumpBaseY == nil {
                jumpBaseY = Float(oldWorld.y)
                characterVerticalVelocity = 0
            }
            let baseY = jumpBaseY ?? Float(oldWorld.y)
            let heightOffset = max(0, locomotion.body.height - standingHeight)
            proposedWorld.y = baseY + heightOffset
        } else {
            jumpBaseY = nil

            let oldRootY = Float(oldWorld.y)
            let oldFeetY = oldRootY + characterFootOffset
            let probe = SCNVector3(proposedWorld.x, oldFeetY, proposedWorld.z)
            let support = raycastSupport(
                at: probe,
                in: scene,
                // Search high enough to reacquire the floor after a missed frame,
                // but use the foot position so overhead geometry is not mistaken
                // for support.
                riseAllowance: max(1.0, abs(characterVerticalVelocity * dt) + 0.5)
            )

            characterVerticalVelocity -= worldGravity * dt
            let fallingFeetY = oldFeetY + characterVerticalVelocity * dt

            if let groundY = support, groundY.isFinite {
                let feetAboveSurface = oldFeetY - groundY
                let crossedSurface = oldFeetY >= groundY - 0.06 && fallingFeetY <= groundY
                let standingOnSurface = feetAboveSurface >= -0.06 &&
                    feetAboveSurface <= 0.10 && characterVerticalVelocity <= 0.5

                if standingOnSurface || crossedSurface {
                    // Set the FEET on the support surface; preserve root/foot offset.
                    proposedWorld.y = groundY - characterFootOffset
                    characterVerticalVelocity = 0
                } else if oldFeetY < groundY {
                    // If a support exists directly beneath the character, correct
                    // small or large penetration instead of allowing the root to
                    // continue below the floor. A real gap has no nearby support;
                    // the lower pit surface, if present, is still a valid landing.
                    proposedWorld.y = groundY - characterFootOffset
                    characterVerticalVelocity = 0
                } else {
                    proposedWorld.y = fallingFeetY - characterFootOffset
                }
            } else {
                // No support below: this is a genuine gap/fall, not a landing.
                proposedWorld.y = fallingFeetY - characterFootOffset
            }
        }

        // Convert the calculated world-space position into parent-local coordinates.
        if let parent = character.parent {
            character.position = parent.convertPosition(proposedWorld, from: nil)
        } else {
            character.position = proposedWorld
        }
        character.eulerAngles.y = heading

        let finalWorldY = Float(character.presentation.worldPosition.y)
        let finalFeetY = finalWorldY + characterFootOffset
        if finalFeetY < -3.0 && !hasReportedFall {
            hasReportedFall = true
            locomotion.completeEpisode(.fell)
            publishDebug("FALL: no supporting surface detected; episode ended.")
        } else if finalFeetY > -0.5 {
            hasReportedFall = false
        }
    }

    /// Measure the visible character geometry's lowest point relative to the root.
    /// This prevents the controller from treating the torso/root origin as the feet.
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
                            minimumWorldY = min(minimumWorldY, Float(worldPoint.y))
                        }
                    }
                }
            }
            for child in node.childNodes { visit(child) }
        }

        visit(character)
        guard minimumWorldY.isFinite else { return 0 }
        // Clamp tiny negative values from geometry precision; preserve real offsets.
        return min(0.25, max(-0.25, minimumWorldY - rootWorldY))
    }

    // MARK: - Forward Vector

    private func forwardVector() -> SIMD3<Float> {
        // A node rotated by eulerAngles.y = h faces (-sin h, -cos h).
        // Movement must use the same vector the model visibly faces.
        SIMD3<Float>(
            -sin(heading),
            0,
            -cos(heading)
        )
    }

    // MARK: - Character Animation

    private func animateCharacter(character: SCNNode) {
        let swing = locomotion.gaitSwing
        let phase = locomotion.gaitPhase

        findNode(
            named: "FrankensteinLeftLeg",
            under: character
        )?.eulerAngles.x = swing * 0.65

        findNode(
            named: "FrankensteinRightLeg",
            under: character
        )?.eulerAngles.x = -swing * 0.65

        findNode(
            named: "FrankensteinLeftArm",
            under: character
        )?.eulerAngles.x = -swing * 0.45

        findNode(
            named: "FrankensteinRightArm",
            under: character
        )?.eulerAngles.x = swing * 0.45

        if let head = findNode(
            named: "FrankensteinHead",
            under: character
        ) {
            head.eulerAngles.y = sin(phase) * 0.04
        }

        if let torso = findNode(
            named: "FrankensteinTorso",
            under: character
        ) {
            let crouch = min(
                max(locomotion.output.crouch, 0),
                1
            )

            torso.position.y = 1.28 - 0.15 * crouch
        }
    }

    // MARK: - SceneKit Physics

    /// Enable gravity for the world and configure physical bodies for visible
    /// floor/support surfaces and loose movable objects. The chasm is
    /// deliberately excluded: no body is created for a void/gap node.
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
            name.contains("qfloorgrid") || name.contains("marker") ||
            name.contains("camera") || name.contains("light") {
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

    // MARK: - Object Dimensions

    private func worldDimensions(
        of node: SCNNode
    ) -> SCNVector3 {

        let (minimum, maximum) = node.boundingBox
        let scale = worldScale(of: node)

        return SCNVector3(
            abs(maximum.x - minimum.x) * abs(scale.x),
            abs(maximum.y - minimum.y) * abs(scale.y),
            abs(maximum.z - minimum.z) * abs(scale.z)
        )
    }

    private func worldScale(
        of node: SCNNode
    ) -> SCNVector3 {

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

    // MARK: - Object Names

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
            if let found = findNode(
                containing: search,
                under: child
            ) {
                return found
            }
        }

        return nil
    }

    // MARK: - Pickupable Objects

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

    // MARK: - Pick Up

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

        // Hold large objects further out so a table does not sit inside him.
        let carriedDepth = worldDimensions(of: target).z

        if let handNode {
            handNode.addChildNode(target)
            target.position = SCNVector3(0, -0.08, -(0.20 + carriedDepth * 0.5))
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

    // MARK: - Place Carried Object

    @discardableResult
    /// Moves the carried object into the scene at `distance` ahead and rests
    /// it on whatever surface is there (floor, another crate, a table).
    /// Returns the final world position, or nil when nothing is carried.
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

        // Release the object into the real scene. Do not snap it to a raycast
        // height: gravity and collision shapes determine where it settles.
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
                body.applyForce(
                    SCNVector3(forward.x * 2.2, 3.0, forward.z * 2.2),
                    asImpulse: true
                )
            }
        }

        self.carriedNode = nil
        carriedOriginalParent = nil

        publishDebug(thrown
            ? "Object released with an impulse; gravity and collisions determine its trajectory."
            : "Object released; gravity and collisions determine its final support.")

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

    // MARK: - Door Interaction

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

    // MARK: - Scene Filtering

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

    /// True only for the floor itself. A box that merely sits under a node
    /// named "Terrain" or "Platform" is an obstacle, not floor.
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

    // MARK: - Statistics

    private func publishGeneralStats() {
        let action = locomotion.activeActionName
        let terrain = String(describing: latestTerrainSample.terrain)

        if action != lastActionName {
            lastActionName = action

            DispatchQueue.main.async { [weak self] in
                self?.onActionChanged?(action)
            }
        }

        let stats = """
        Action: \(action)
        Terrain: \(terrain)
        Distance ahead: \(String(format: "%.2f", Double(latestTerrainSample.distance))) m
        Ground ahead: \(latestTerrainSample.isGroundAhead)
        Landing clear: \(latestTerrainSample.isLandingAreaClear)
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
    /// Attach the same CA instance owned by FrankensteinSceneView.
    /// Call this from make/updateCoordinator after Coordinator creation.
    func attachExecutiveCA(_ ca: FrankensteinCA) {
        attachCA(ca)
        print("[Coordinator] Shared CA attached; generation=\(ca.generation), live cells=\(ca.liveCellCount)")
    }

    /// Use this in the existing renderer loop after terrain sensing and after locomotion.step.
    /// It makes policy/CA/execution discrepancies visible without changing scene mechanics.
    func logExecutiveControlState(terrain: FrankensteinTerrainSample, locomotion: FrankensteinLocomotion) {
        print("[Coordinator] CA generation=\(locomotion.attachedCAGeneration), live cells=\(locomotion.attachedCALiveCellCount)")
        print("[Coordinator] CA decision=\(locomotion.caCommandName)")
        print("[Coordinator] applied action=\(locomotion.activeActionName)")
        print("[Coordinator] terrain=\(terrain.terrain), Q updates=\(locomotion.policy.updateCount), states=\(locomotion.policy.learnedStateCount)")
    }
}
