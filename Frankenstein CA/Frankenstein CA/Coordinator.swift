
import Foundation
import SceneKit
import simd
import SwiftUI


// MARK: - Coordinator

/// Coordinates perception, action selection, locomotion, and UI reporting.
final class Coordinator: NSObject, SCNSceneRendererDelegate {

    // MARK: Public callbacks

    var onStats: ((String) -> Void)?
    var onDebugInfo: ((String) -> Void)?
    var onDetectedObject: ((DetectedObjectInfo?) -> Void)?
    var onActionChanged: ((String) -> Void)?

    // MARK: Scene references

    private weak var scene: SCNScene?
    private weak var characterNode: SCNNode?
    private weak var doorNode: SCNNode?
    private weak var tableNode: SCNNode?

    /// Set this to the character's actual hand/grip node to enable pickup.
    private weak var handNode: SCNNode?

    // MARK: Runtime state

    private let locomotion: FrankensteinLocomotion

    private var isRunning = false
    private var previousTime: TimeInterval = 0

    private(set) var lastDetectedObject: DetectedObjectInfo?
    private(set) var currentAction = "idle"
    private(set) var currentTerrain = "unknown"
    private(set) var lastStatus = "Ready"

    // MARK: Configuration

    var rayLength: Float = 3.0
    var rayStartHeight: Float = 0.9
    var groundRayLength: Float = 4.0
    var objectInteractionDistance: Float = 1.25

    /// SceneKit's forward direction for a character facing -Z.
    var forwardDirection = SCNVector3(0, 0, -1)

    private var openedDoor = false
    private var isHoldingObject = false
    private weak var heldObject: SCNNode?

    // MARK: Initialization

    init(
        scene: SCNScene,
        characterNode: SCNNode,
        locomotion: FrankensteinLocomotion
    ) {
        self.scene = scene
        self.characterNode = characterNode
        self.locomotion = locomotion
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        isRunning = true
        previousTime = 0
        lastStatus = "Running"
        publishDebug("Coordinator started")
    }

    func stop() {
        isRunning = false
        lastStatus = "Stopped"
        publishDebug("Coordinator stopped")
    }

    func reset() {
        isRunning = false
        previousTime = 0
        lastDetectedObject = nil
        currentAction = "idle"
        currentTerrain = "unknown"
        openedDoor = false
        isHoldingObject = false
        heldObject = nil
        lastStatus = "Reset"
        publishDetectedObject(nil)
        publishDebug("Coordinator reset")
    }

    // MARK: Scene setup

    /// Points the coordinator at the scene and character the view actually
    /// displays. The weak references set in `init` are placeholders.
    func attach(scene: SCNScene, characterNode: SCNNode) {
        self.scene = scene
        self.characterNode = characterNode

        if let door = scene.rootNode.childNode(
            withName: "Door",
            recursively: true
        ) {
            doorNode = door
        }

        if let table = scene.rootNode.childNode(
            withName: "Table",
            recursively: true
        ) {
            tableNode = table
        }
    }

    func attachDoor(_ node: SCNNode) {
        doorNode = node
    }

    func attachTable(_ node: SCNNode) {
        tableNode = node
    }

    func attachHand(_ node: SCNNode) {
        handNode = node
    }

    // MARK: Scene renderer

    func renderer(
        _ renderer: SCNSceneRenderer,
        updateAtTime time: TimeInterval
    ) {
        guard isRunning,
              let character = characterNode,
              let sceneRoot = scene?.rootNode else {
            return
        }

        let dt: TimeInterval
        if previousTime == 0 {
            dt = 1.0 / 60.0
        } else {
            dt = min(max(time - previousTime, 1.0 / 240.0), 0.05)
        }
        previousTime = time

        // 1. Perception
        let sensed = senseEnvironment(
            character: character,
            sceneRoot: sceneRoot
        )

        currentTerrain = sensed.terrain
        lastDetectedObject = sensed.object
        publishDetectedObject(sensed.object)

        // 2. Interactions
        updateHeldObject()
        updateDoorInteraction(character: character, sensedObject: sensed.object)

        // 3. Terrain sample
        let terrainSample = makeTerrainSample(from: sensed)

        // 4. Locomotion decision
        let output = locomotion.step(
            deltaTime: Float(dt),
            terrain: terrainSample
        )

        currentAction = locomotion.activeActionName
        onActionChanged?(currentAction)

        // 5. Apply movement
        applyMovement(
            output: output,
            character: character,
            deltaTime: dt
        )

        // 6. UI diagnostics
        publishDebug(
            """
            Action: \(currentAction)
            Terrain: \(currentTerrain)
            Object: \(sensed.object?.name ?? "none")
            Distance: \(sensed.object.map { String(format: "%.2f", $0.distance) } ?? "—")
            Status: \(lastStatus)
            """
        )
    }

    // MARK: - Perception

    private struct SensorResult {
        var terrain: String = "flat"
        var obstacleDistance: Float = .infinity
        var obstacleHeight: Float = 0
        var groundAhead: Bool = true
        var groundHeight: Float = 0
        var object: DetectedObjectInfo?
        var hitNode: SCNNode?
    }

    private func senseEnvironment(
        character: SCNNode,
        sceneRoot: SCNNode
    ) -> SensorResult {
        var result = SensorResult()

        let start = character.presentation.worldPosition
        let direction = normalizedForward(for: character)

        let rayOrigin = SCNVector3(
            start.x,
            start.y + rayStartHeight,
            start.z
        )

        // Raycast forward at torso height.
        if let hit = firstHit(
            from: rayOrigin,
            direction: direction,
            length: rayLength,
            excluding: character
        ) {
            let hitPosition = hit.worldCoordinates
            let distance = distanceBetween(rayOrigin, hitPosition)

            result.obstacleDistance = distance
            result.hitNode = hit.node

            let info = makeDetectedObjectInfo(
                node: hit.node,
                hitPosition: hitPosition,
                distance: distance
            )
            result.object = info

            let dimensions = worldDimensions(of: hit.node)
            result.obstacleHeight = dimensions.y

            if dimensions.y < 0.65 {
                result.terrain = "low obstacle"
            } else if dimensions.y < 1.25 {
                result.terrain = "hurdle"
            } else {
                result.terrain = "wall or object"
            }

            if isLowCeiling(hit.node) {
                result.terrain = "low ceiling"
            }
        }

        // Probe for ground ahead.
        let groundProbeOrigin = SCNVector3(
            start.x + direction.x * 1.0,
            start.y + rayStartHeight,
            start.z + direction.z * 1.0
        )

        if let groundHit = firstGroundHit(
            from: groundProbeOrigin,
            length: groundRayLength,
            excluding: character
        ) {
            result.groundAhead = true
            result.groundHeight = groundHit.worldCoordinates.y
        } else {
            result.groundAhead = false
            result.terrain = "gap"
        }

        // Explicitly expose table / low-ceiling context.
        if result.object == nil,
           let table = tableNode,
           isInFront(table, of: character, within: rayLength) {

            let characterPosition = character.presentation.worldPosition
            let tablePosition = table.presentation.worldPosition

            let info = makeDetectedObjectInfo(
                node: table,
                hitPosition: tablePosition,
                distance: distanceBetween(
                    characterPosition,
                    tablePosition
                )
            )

            result.object = info
            result.terrain = "low ceiling"
        }

        return result
    }

    private func firstHit(
        from origin: SCNVector3,
        direction: SCNVector3,
        length: Float,
        excluding character: SCNNode
    ) -> SCNHitTestResult? {
        guard let scene else { return nil }

        let end = SCNVector3(
            origin.x + direction.x * length,
            origin.y + direction.y * length,
            origin.z + direction.z * length
        )

        let options: [String: Any] = [
            SCNHitTestOption.searchMode.rawValue:
                SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.ignoreHiddenNodes.rawValue:
                true
        ]

        let results: [SCNHitTestResult] = scene.rootNode.hitTestWithSegment(
            from: origin,
            to: end,
            options: options
        )

        return results.first { hit in
            let node = hit.node
            return node !== character &&
                   !isDescendant(node, of: character) &&
                   node.opacity > 0.01
        }
    }

    private func firstGroundHit(
        from origin: SCNVector3,
        length: Float,
        excluding character: SCNNode
    ) -> SCNHitTestResult? {
        guard let scene else { return nil }

        let end = SCNVector3(
            origin.x,
            origin.y - length,
            origin.z
        )

        let options: [String: Any] = [
            SCNHitTestOption.searchMode.rawValue:
                SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.ignoreHiddenNodes.rawValue:
                true
        ]

        let results: [SCNHitTestResult] = scene.rootNode.hitTestWithSegment(
            from: origin,
            to: end,
            options: options
        )

        return results.first { hit in
            let node = hit.node
            return node !== character &&
                   !isDescendant(node, of: character) &&
                   node.physicsBody != nil
        }
    }

    // MARK: - Terrain adapter

    private func makeTerrainSample(
        from sensor: SensorResult
    ) -> FrankensteinTerrainSample {
        var sample = FrankensteinTerrainSample()

        sample.distance = sensor.obstacleDistance.isFinite
            ? sensor.obstacleDistance
            : rayLength

        sample.obstacleHeight = sensor.obstacleHeight
        sample.groundHeight = sensor.groundHeight
        sample.nextGroundHeight = sensor.groundHeight
        sample.isGroundAhead = sensor.groundAhead

        switch sensor.terrain.lowercased() {
        case "gap":
            sample.terrain = .gap
            sample.gapWidth = 2.0
            sample.gapNearEdgeDistance = max(0, sample.distance)
            sample.gapFarEdgeDistance = sample.gapNearEdgeDistance + sample.gapWidth
            sample.isLandingAreaClear = true

        case "hurdle":
            sample.terrain = .hurdle

        case "low ceiling":
            sample.terrain = .lowCeiling

        case "raised step":
            sample.terrain = .raisedStep

        case "uneven":
            sample.terrain = .uneven

        default:
            sample.terrain = .flat
        }

        return sample
    }

    // MARK: - Movement adapter

    private func applyMovement(
        output: FrankensteinLocomotionOutput,
        character: SCNNode,
        deltaTime: TimeInterval
    ) {
        let dt = Float(deltaTime)

        let heading = output.heading
        let speed = output.speed

        let dx = sin(heading) * speed * dt
        let dz = -cos(heading) * speed * dt

        character.position.x += dx
        character.position.z += dz

        if output.jump > 0 {
            lastStatus = "Jump requested"
        } else if output.crouch > 0 {
            lastStatus = "Crouching or crawling"
        } else {
            lastStatus = "Moving"
        }
    }

    // MARK: - Door interaction

    private func updateDoorInteraction(
        character: SCNNode,
        sensedObject: DetectedObjectInfo?
    ) {
        guard let door = doorNode, !openedDoor else { return }

        let distance = distanceBetween(
            character.presentation.worldPosition,
            door.presentation.worldPosition
        )

        guard distance <= objectInteractionDistance else { return }

        openedDoor = true

        door.runAction(
            SCNAction.rotateBy(
                x: 0,
                y: -.pi / 2,
                z: 0,
                duration: 0.7
            )
        )

        lastStatus = "Door opening"
        publishDebug("Door interaction triggered")
    }

    // MARK: - Pickup, carry, place

    @discardableResult
    func pickUp(_ node: SCNNode) -> Bool {
        guard !isHoldingObject,
              let hand = handNode,
              isPickupable(node) else {
            return false
        }

        let distance = distanceBetween(
            hand.presentation.worldPosition,
            node.presentation.worldPosition
        )

        guard distance <= objectInteractionDistance else {
            lastStatus = "Object too far away to pick up"
            return false
        }

        node.physicsBody?.velocity = SCNVector3(0, 0, 0)
        node.physicsBody?.angularVelocity = SCNVector4(0, 0, 0, 0)
        node.physicsBody?.type = .kinematic

        let worldTransform = node.presentation.worldTransform

        node.removeFromParentNode()
        hand.addChildNode(node)

        node.transform = hand.convertTransform(
            worldTransform,
            from: scene?.rootNode
        )

        node.runAction(
            SCNAction.move(
                to: SCNVector3(0, -0.08, -0.18),
                duration: 0.2
            )
        )

        heldObject = node
        isHoldingObject = true
        lastStatus = "Holding \(node.name ?? "object")"
        publishDebug(lastStatus)
        return true
    }

    func placeHeldObject(at worldPosition: SCNVector3) {
        guard let object = heldObject,
              let root = scene?.rootNode else {
            return
        }

        let worldTransform = object.presentation.worldTransform

        object.removeFromParentNode()
        root.addChildNode(object)

        object.transform = worldTransform
        object.position = worldPosition

        if let body = object.physicsBody {
            body.type = .dynamic
            body.velocity = SCNVector3(0, 0, 0)
            body.angularVelocity = SCNVector4(0, 0, 0, 0)
        }

        heldObject = nil
        isHoldingObject = false
        lastStatus = "Object placed"
        publishDebug(lastStatus)
    }

    func dropHeldObject() {
        guard let object = heldObject else { return }
        placeHeldObject(at: object.presentation.worldPosition)
    }

    private func updateHeldObject() {
        guard isHoldingObject, heldObject != nil else { return }
        // The object is parented to the hand node, so it follows the hand.
    }

    // MARK: - Helpers

    private func normalizedForward(for node: SCNNode) -> SCNVector3 {
        let transform = node.presentation.worldTransform

        let raw = SCNVector3(
            -transform.m31,
            -transform.m32,
            -transform.m33
        )

        let length = sqrt(
            raw.x * raw.x + raw.y * raw.y + raw.z * raw.z
        )

        guard length > 0.0001 else {
            return forwardDirection
        }

        return SCNVector3(
            raw.x / length,
            raw.y / length,
            raw.z / length
        )
    }

    private func makeDetectedObjectInfo(
        node: SCNNode,
        hitPosition: SCNVector3,
        distance: Float
    ) -> DetectedObjectInfo {
        let dimensions = worldDimensions(of: node)

        return DetectedObjectInfo(
            name: node.name ?? "Unnamed object",
            dimensions: dimensions,
            distance: distance,
            worldPosition: hitPosition,
            pickupable: isPickupable(node)
        )
    }

    private func worldDimensions(of node: SCNNode) -> SCNVector3 {
        let (minBound, maxBound) = node.boundingBox
        let scale = worldScale(of: node)

        return SCNVector3(
            abs((maxBound.x - minBound.x) * scale.x),
            abs((maxBound.y - minBound.y) * scale.y),
            abs((maxBound.z - minBound.z) * scale.z)
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

    private func isDescendant(
        _ node: SCNNode,
        of ancestor: SCNNode
    ) -> Bool {
        var current = node.parent

        while let parent = current {
            if parent === ancestor {
                return true
            }
            current = parent.parent
        }

        return false
    }

    private func isPickupable(_ node: SCNNode) -> Bool {
        // Split into small steps. The compiler fails to type-check the
        // one-line optional-chained subscript on NSMutableDictionary.
        if let data = node.userData {
            let value: Any? = data.object(forKey: "pickupable")

            if let flag = value as? NSNumber, flag.boolValue {
                return true
            }
        }

        let name = (node.name ?? "").lowercased()

        return name.contains("pickup") ||
               name.contains("movable") ||
               name.contains("carryable") ||
               name.contains("crate")
    }
    private func isLowCeiling(_ node: SCNNode) -> Bool {
        let name = (node.name ?? "").lowercased()

        return name.contains("table") ||
               name.contains("ceiling") ||
               name.contains("lowbarrier")
    }

    private func isInFront(
        _ target: SCNNode,
        of character: SCNNode,
        within distance: Float
    ) -> Bool {
        let c = character.presentation.worldPosition
        let t = target.presentation.worldPosition

        let direction = normalizedForward(for: character)
        let toTarget = SCNVector3(
            t.x - c.x,
            t.y - c.y,
            t.z - c.z
        )

        let targetDistance = sqrt(
            toTarget.x * toTarget.x +
            toTarget.y * toTarget.y +
            toTarget.z * toTarget.z
        )

        guard targetDistance <= distance, targetDistance > 0 else {
            return false
        }

        let dot = (
            toTarget.x * direction.x +
            toTarget.y * direction.y +
            toTarget.z * direction.z
        ) / targetDistance

        return dot > 0.5
    }

    private func distanceBetween(
        _ a: SCNVector3,
        _ b: SCNVector3
    ) -> Float {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z

        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    private func publishDetectedObject(_ object: DetectedObjectInfo?) {
        onDetectedObject?(object)
    }

    private func publishDebug(_ message: String) {
        onDebugInfo?(message)
    }
}

// MARK: - UI data model

struct DetectedObjectInfo {
    let name: String
    let dimensions: SCNVector3
    let distance: Float
    let worldPosition: SCNVector3
    let pickupable: Bool

    var dimensionsText: String {
        String(
            format: "%.2f × %.2f × %.2f",
            dimensions.x,
            dimensions.y,
            dimensions.z
        )
    }

    var distanceText: String {
        String(format: "%.2f m", distance)
    }
}
