import Foundation
import SceneKit
import simd
import SwiftUI
import UIKit

final class Coordinator: NSObject, SCNSceneRendererDelegate {

    // MARK: - Callbacks

    var onCAStats: ((Int, Int) -> Void)?

    private var ca: FrankensteinCA?

    private var lastCATickTime: TimeInterval = 0
    private let caTickInterval: TimeInterval = 0.25

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
    private var latestPolicyObservation: FrankensteinObjectObservation?

    private var lastActionName = ""
    private var lastDebugMessage = ""

    // MARK: - Jump State

    private let standingHeight: Float = 1.8
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

    // MARK: - Attach Cellular Automaton

    func attachCA(_ ca: FrankensteinCA) {
        self.ca = ca

        // Connect the exact same CA instance to locomotion.
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

    // MARK: - Attach Actual Displayed Scene

    func attach(
        scene: SCNScene,
        characterNode: SCNNode
    ) {
        self.scene = scene
        self.characterNode = characterNode

        previousCharacterPosition =
            characterNode.presentation.worldPosition

        hasPreviousCharacterPosition = true
        jumpBaseY = nil

        doorNode = findNode(
            containing: "door",
            under: scene.rootNode
        )

        tableNode = findNode(
            containing: "table",
            under: scene.rootNode
        )

        publishDebug("Coordinator attached to displayed scene.")
    }

    func attachDoor(_ node: SCNNode?) {
        doorNode = node
    }

    func attachTable(_ node: SCNNode?) {
        tableNode = node
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

            DispatchQueue.main.async { [weak self] in
                self?.tickCA()
            }
        }

        // MARK: 3. Sense objects and terrain

        if time - lastSensorTime >= sensorInterval {
            lastSensorTime = time

            // One raycast observation is shared by terrain,
            // Q-learning, and the UI.
            latestDetection = detectObjectAhead(
                from: character,
                in: scene
            )

            latestPolicyObservation = makePolicyObservation(
                from: latestDetection
            )

            latestTerrainSample = makeTerrainSample(
                for: character,
                in: scene,
                detection: latestDetection
            )

            let detection = latestDetection

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

        // MARK: 5. Select a locomotion action

        let output = locomotion.step(
            deltaTime: dt,
            terrain: latestTerrainSample,
            actualDisplacement: actualDisplacement
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

        qFloorGrid.update(
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

    // MARK: - Policy Object Observation

    private func makePolicyObservation(
        from detection: DetectedObjectInfo?
    ) -> FrankensteinObjectObservation? {
        guard let detection else {
            return nil
        }

        return FrankensteinObjectObservation(
            name: detection.name,
            width: Float(detection.dimensions.x),
            height: Float(detection.dimensions.y),
            depth: Float(detection.dimensions.z),
            distance: detection.distance,
            pickupable: detection.pickupable
        )
    }

    // MARK: - Terrain Sensing

    private func makeTerrainSample(
        for character: SCNNode,
        in scene: SCNScene,
        detection: DetectedObjectInfo?
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

        // Use the same object detection collected by the renderer.
        // Do not perform a second object raycast here.
        if let detection {
            sample.distance = detection.distance
            sample.obstacleHeight = detection.dimensions.y
            sample.obstacleDepth = detection.dimensions.z

            let name = detection.name.lowercased()

            if name.contains("ceiling") {
                sample.terrain = .lowCeiling
            } else if name.contains("step") ||
                        name.contains("stair") {
                sample.terrain = .raisedStep
            } else if detection.dimensions.y <= 0.35 {
                sample.terrain = .uneven
            } else {
                sample.terrain = .hurdle
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
            SCNHitTestOption.backFaceCulling.rawValue: false
        ]

        let hits = scene.rootNode.hitTestWithSegment(
            from: start,
            to: end,
            options: options
        )

        let validHits = hits.filter {
            !isCharacterPart($0.node)
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
                SCNHitTestOption.backFaceCulling.rawValue: false
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

    // MARK: - Detect Object Ahead

    private func detectObjectAhead(
        from character: SCNNode,
        in scene: SCNScene
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
            position.x,
            position.y + 0.7,
            position.z
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
            SCNHitTestOption.backFaceCulling.rawValue: false
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

            guard !isGroundLikeNode(hitNode) else {
                continue
            }

            // Resolve a geometry child to its meaningful pickup/object parent.
            let target = pickupTarget(for: hitNode)
                ?? meaningfulDetectionParent(for: hitNode)

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

            let hitPosition = hit.worldCoordinates

            let dx = Float(hitPosition.x - start.x)
            let dy = Float(hitPosition.y - start.y)
            let dz = Float(hitPosition.z - start.z)

            let distance = sqrt(
                dx * dx +
                dy * dy +
                dz * dz
            )

            guard distance <= rayLength else {
                continue
            }

            let name = readableName(for: target)

            return DetectedObjectInfo(
                name: name,
                dimensions: dimensions,
                distance: distance,
                worldPosition: target.presentation.worldPosition,
                pickupable: pickupTarget(for: target) != nil
            )
        }

        return nil
    }

    // MARK: - Resolve the Actual Object from a Child Mesh

    private func meaningfulDetectionParent(
        for node: SCNNode
    ) -> SCNNode {

        var current: SCNNode? = node
        var bestCandidate = node

        while let candidate = current {
            let name = (candidate.name ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !name.isEmpty,
               !isGenericDetectionNodeName(name),
               !isGroundLikeNode(candidate) {
                bestCandidate = candidate
            }

            // Do not promote a hit to the entire scene or course container.
            if name == "ObstacleCourse" ||
               name == "TerrainRoot" ||
               name == "SceneRoot" {
                break
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
        heading = output.heading

        let forward = forwardVector()
        let speed = max(0, output.speed)

        let oldPosition = character.position

        var newPosition = SCNVector3(
            oldPosition.x + forward.x * speed * dt,
            oldPosition.y,
            oldPosition.z + forward.z * speed * dt
        )

        // Prevent unverified movement over a gap.
        if latestTerrainSample.terrain == .gap &&
            !latestTerrainSample.isLandingAreaClear {
            newPosition.x = oldPosition.x
            newPosition.z = oldPosition.z
        }

        // Prevent walking directly through a nearby hurdle.
        if output.jump <= 0,
           latestTerrainSample.terrain == .hurdle,
           latestTerrainSample.distance < 0.45 {
            newPosition.x = oldPosition.x
            newPosition.z = oldPosition.z
        }

        // Apply jump height relative to the jump's starting height.
        if output.jump > 0 {
            if jumpBaseY == nil {
                jumpBaseY = Float(oldPosition.y)
            }

            let baseY = jumpBaseY ?? Float(oldPosition.y)

            let heightOffset = max(
                0,
                locomotion.body.height - standingHeight
            )

            newPosition.y = baseY + heightOffset
        } else {
            jumpBaseY = nil

            // Follow the detected floor when grounded.
            if let ground = raycastGround(
                near: SCNVector3(
                    newPosition.x,
                    newPosition.y,
                    newPosition.z
                ),
                in: scene
            ) {
                if abs(newPosition.y - ground) < 0.5 {
                    newPosition.y = ground
                }
            }
        }

        character.position = newPosition
        character.eulerAngles.y = heading
    }

    // MARK: - Forward Vector

    private func forwardVector() -> SIMD3<Float> {
        SIMD3<Float>(
            sin(heading),
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
                name.contains("crate") {
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

        if let handNode {
            handNode.addChildNode(target)
            target.position = SCNVector3(0, -0.08, -0.20)
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
            SCNHitTestOption.backFaceCulling.rawValue: false
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
    func placeCarriedObjectAhead() -> Bool {
        guard let carriedNode,
              let character = characterNode,
              let scene else {
            return false
        }

        let forward = forwardVector()
        let position = character.presentation.worldPosition

        let destination = SCNVector3(
            position.x + forward.x * 0.9,
            position.y,
            position.z + forward.z * 0.9
        )

        carriedNode.removeFromParentNode()
        scene.rootNode.addChildNode(carriedNode)

        // Convert world coordinates to the root node's local coordinates.
        carriedNode.position = scene.rootNode.convertPosition(
            destination,
            from: nil
        )

        self.carriedNode = nil
        carriedOriginalParent = nil

        publishDebug("Placed object ahead.")
        return true
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

// MARK: - Executive Control Integration

extension Coordinator {

    /// Attach the same CA instance owned by FrankensteinSceneView.
    /// Call this from make/updateCoordinator after Coordinator creation.
    func attachExecutiveCA(_ ca: FrankensteinCA) {
        attachCA(ca)

        print(
            "[Coordinator] Shared CA attached; " +
            "generation=\(ca.generation), " +
            "live cells=\(ca.liveCellCount)"
        )
    }

    /// Log policy/CA/execution state without changing scene mechanics.
    func logExecutiveControlState(
        terrain: FrankensteinTerrainSample,
        locomotion: FrankensteinLocomotion
    ) {
        print(
            "[Coordinator] CA generation=" +
            "\(locomotion.attachedCAGeneration), " +
            "live cells=\(locomotion.attachedCALiveCellCount)"
        )

        print("[Coordinator] CA decision=\(locomotion.caCommandName)")
        print("[Coordinator] applied action=\(locomotion.activeActionName)")

        print(
            "[Coordinator] terrain=\(terrain.terrain), " +
            "Q updates=\(locomotion.policy.updateCount), " +
            "states=\(locomotion.policy.learnedStateCount)"
        )
    }
}
