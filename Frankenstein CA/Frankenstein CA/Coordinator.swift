
import Foundation
import SceneKit
import UIKit

final class Coordinator: NSObject, SCNSceneRendererDelegate {

    let character: FrankensteinCharacter
    let ca: FrankensteinCA

    var onStats: ((Int, Int) -> Void)?
    var onDebugInfo: ((String) -> Void)?

    private let locomotion: FrankensteinLocomotion

    private var lastUpdateTime: TimeInterval = 0
    private var lastTerrainSample = FrankensteinTerrainSample(
        terrain: .flat,
        distance: 0,
        obstacleHeight: 0,
        gapWidth: 0,
        groundHeight: 0,
        nextGroundHeight: 0,
        isGroundAhead: true,
        isLandingAreaClear: true
    )
    private var lastAction = "INITIALIZING"
    private var lastObstacleDistance: Float = 0

    private var sensorNodes: [SCNNode] = []
    private var debugUpdateCounter = 0

    private var isJumping = false
    private var jumpElapsed: Float = 0
    private let jumpDuration: Float = 0.65
    private let jumpHeight: Float = 1.0
    private var jumpStartY: Float = 0

    private var isStepping = false
    private var stepStartY: Float = 0
    private var stepTargetY: Float = 0
    private var stepElapsed: Float = 0

    private var obstacleCooldown: Float = 0
    private var avoidanceDirection: Float = 1

    private let sensorDistance: Float = 1.5
    private let maximumSafeStep: Float = 0.45

    init(
        character: FrankensteinCharacter,
        ca: FrankensteinCA,
        onStats: ((Int, Int) -> Void)? = nil,
        onDebugInfo: ((String) -> Void)? = nil
    ) {
        self.character = character
        self.ca = ca
        self.onStats = onStats
        self.onDebugInfo = onDebugInfo
        self.locomotion = FrankensteinLocomotion()

        super.init()
    }

    // MARK: - Scene update

    func renderer(
        _ renderer: SCNSceneRenderer,
        updateAtTime time: TimeInterval
    ) {
        guard let scene = renderer.scene else { return }

        let deltaTime: Float

        if lastUpdateTime == 0 {
            deltaTime = 1.0 / 60.0
        } else {
            deltaTime = Float(
                min(max(time - lastUpdateTime, 0), 0.05)
            )
        }

        lastUpdateTime = time
        obstacleCooldown = max(0, obstacleCooldown - deltaTime)

        // 1. Advance CA animation.
        let caMotion: FrankensteinMotion =
            ca.step(deltaTime: deltaTime)

        // 2. Sense the terrain and objects.
        let position = character.root.presentation.position
        let heading = character.root.presentation.eulerAngles.y

        let terrainSample = sampleTerrain(
            in: scene,
            at: position,
            heading: heading
        )

        lastTerrainSample = terrainSample

        // 3. Ask the locomotion controller to choose movement.
        let locomotionOutput = locomotion.step(
            deltaTime: deltaTime,
            terrain: terrainSample
        )

        // 4. Combine animation and navigation outputs.
        var output = FrankensteinLocomotionOutput()

        output.walkPhase = caMotion.walkPhase
        output.armLift = caMotion.armLift
        output.headTurn = caMotion.headTurn
        output.mouthOpen = caMotion.mouthOpen

        output.heading = locomotionOutput.heading
        output.speed = locomotionOutput.speed
        output.crouch = locomotionOutput.crouch
        output.jump = locomotionOutput.jump
        output.lean = locomotionOutput.lean
        output.stride = locomotionOutput.stride
        output.action = locomotionOutput.action
        output.reward = locomotionOutput.reward
        output.status = locomotionOutput.status

        // 5. Apply the output to the articulated character.
        character.applyLocomotion(output)

        // 6. Display debug data at a reduced update rate.
        debugUpdateCounter += 1

        if debugUpdateCounter % 3 == 0 {
            onStats?(ca.generationCount, ca.liveCellCount)
            publishDebugInfo(
                position: position,
                terrain: terrainSample,
                output: locomotionOutput
            )
        }

        // 7. Update optional sensor visualization.
        visualizeSensorRays(
            in: scene,
            position: position,
            heading: heading,
            terrain: terrainSample
        )
    }

    // MARK: - Terrain sensing

    private func sampleTerrain(
        in scene: SCNScene,
        at position: SCNVector3,
        heading: Float
    ) -> FrankensteinTerrainSample {

        let forwardX = sin(heading)
        let forwardZ = -cos(heading)

        let start = SCNVector3(
            position.x,
            position.y + 0.15,
            position.z
        )

        let ahead = SCNVector3(
            position.x + forwardX * sensorDistance,
            position.y + 0.15,
            position.z + forwardZ * sensorDistance
        )

        // Check whether the ground exists below the character.
        let groundStart = SCNVector3(
            position.x,
            position.y + 1.0,
            position.z
        )

        let groundEnd = SCNVector3(
            position.x,
            position.y - 2.0,
            position.z
        )

        let groundHits = scene.rootNode.hitTestWithSegment(
            from: groundStart,
            to: groundEnd,
            options: nil
        )

        let hasGround = groundHits.contains { hit in
            !isCharacterNode(hit.node) &&
            isGroundNode(hit.node)
        }

        // Check the ground ahead to identify a potential gap.
        let aheadGroundStart = SCNVector3(
            ahead.x,
            position.y + 1.0,
            ahead.z
        )

        let aheadGroundEnd = SCNVector3(
            ahead.x,
            position.y - 2.0,
            ahead.z
        )

        let aheadHits = scene.rootNode.hitTestWithSegment(
            from: aheadGroundStart,
            to: aheadGroundEnd,
            options: nil
        )

        let hasGroundAhead = aheadHits.contains { hit in
            !isCharacterNode(hit.node) &&
            isGroundNode(hit.node)
        }

        // Check for solid objects ahead at body height.
        let bodyHeights: [Float] = [0.35, 0.8, 1.25]

        var detectedName: String?
        var detectedDistance: Float = sensorDistance

        for height in bodyHeights {
            let rayStart = SCNVector3(
                position.x,
                position.y + height,
                position.z
            )

            let rayEnd = SCNVector3(
                position.x + forwardX * sensorDistance,
                position.y + height,
                position.z + forwardZ * sensorDistance
            )

            let hits = scene.rootNode.hitTestWithSegment(
                from: rayStart,
                to: rayEnd,
                options: nil
            )

            if let hit = hits.first(where: {
                !isCharacterNode($0.node) &&
                !isGroundNode($0.node) &&
                !isDecorativeNode($0.node)
            }) {
                detectedName = nodeName(for: hit.node)
                detectedDistance = distance(
                    from: position,
                    to: hit.worldCoordinates
                )
                break
            }
        }

        lastObstacleDistance = detectedName == nil ? 0 : detectedDistance

        let name = (detectedName ?? "").lowercased()

        // Gaps take priority over other classifications.
        if !hasGroundAhead {
            lastAction = "GAP DETECTED"

            return FrankensteinTerrainSample(
                terrain: .gap,
                distance: sensorDistance,
                obstacleHeight: 0,
                gapWidth: 1.0,
                groundHeight: position.y,
                nextGroundHeight: position.y,
                isGroundAhead: false,
                isLandingAreaClear: true
            )
        }

        if name.contains("ceiling") {
            lastAction = "CROUCH"

            return FrankensteinTerrainSample(
                terrain: .lowCeiling,
                distance: detectedDistance,
                obstacleHeight: 1.0,
                gapWidth: 0,
                groundHeight: position.y,
                nextGroundHeight: position.y,
                isGroundAhead: hasGround,
                isLandingAreaClear: true
            )
        }

        if name.contains("hurdle") {
            lastAction = "JUMP"

            return FrankensteinTerrainSample(
                terrain: .hurdle,
                distance: detectedDistance,
                obstacleHeight: 0.7,
                gapWidth: 0,
                groundHeight: position.y,
                nextGroundHeight: position.y,
                isGroundAhead: hasGround,
                isLandingAreaClear: true
            )
        }

        if name.contains("step") || name.contains("stair") {
            lastAction = "STEP UP"

            return FrankensteinTerrainSample(
                terrain: .raisedStep,
                distance: detectedDistance,
                obstacleHeight: maximumSafeStep,
                gapWidth: 0,
                groundHeight: position.y,
                nextGroundHeight: position.y + maximumSafeStep,
                isGroundAhead: hasGround,
                isLandingAreaClear: true
            )
        }

        if let detectedName = detectedName {
            lastAction = "AVOID: \(detectedName)"

            return FrankensteinTerrainSample(
                terrain: .uneven,
                distance: detectedDistance,
                obstacleHeight: 1.0,
                gapWidth: 0,
                groundHeight: position.y,
                nextGroundHeight: position.y,
                isGroundAhead: hasGround,
                isLandingAreaClear: false
            )
        }

        lastAction = "WALK"

        return FrankensteinTerrainSample(
            terrain: .flat,
            distance: sensorDistance,
            obstacleHeight: 0,
            gapWidth: 0,
            groundHeight: position.y,
            nextGroundHeight: position.y,
            isGroundAhead: hasGround,
            isLandingAreaClear: true
        )
    }

    // MARK: - Node filtering

    private func isCharacterNode(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node

        while let candidate = current {
            if candidate === character.root {
                return true
            }

            current = candidate.parent
        }

        return false
    }

    private func nodeName(for node: SCNNode) -> String {
        var current: SCNNode? = node

        while let candidate = current {
            if let name = candidate.name, !name.isEmpty {
                if name != "ObstacleCourse" {
                    return name
                }
            }

            current = candidate.parent
        }

        return "Unnamed obstacle"
    }

    private func isGroundNode(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node

        while let candidate = current {
            let name = (candidate.name ?? "").lowercased()

            if name.contains("ground") ||
                name.contains("terrain") ||
                name.contains("floor") {
                return true
            }

            current = candidate.parent
        }

        return false
    }

    private func isDecorativeNode(_ node: SCNNode) -> Bool {
        let name = nodeName(for: node).lowercased()

        return name.contains("marker") ||
               name.contains("camera") ||
               name.contains("light")
    }

    private func distance(
        from a: SCNVector3,
        to b: SCNVector3
    ) -> Float {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z

        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    // MARK: - Sensor visualization

    private func visualizeSensorRays(
        in scene: SCNScene,
        position: SCNVector3,
        heading: Float,
        terrain: FrankensteinTerrainSample
    ) {
        // Keep debug geometry optional to avoid unnecessary scene updates.
   
        let root: SCNNode

        if let existingRoot = scene.rootNode.childNode(
            withName: "SensorDebug",
            recursively: false
        ) {
            root = existingRoot
        } else {
            root = makeSensorDebugRoot(in: scene)
        }

        root.childNodes.forEach { $0.removeFromParentNode() }


        root.childNodes.forEach { $0.removeFromParentNode() }

        let forwardX = sin(heading)
        let forwardZ = -cos(heading)

        let start = SCNVector3(
            position.x,
            position.y + 0.8,
            position.z
        )

        let end = SCNVector3(
            position.x + forwardX * sensorDistance,
            position.y + 0.8,
            position.z + forwardZ * sensorDistance
        )

        let color: UIColor = terrain.terrain == .gap
            ? .red
            : (terrain.terrain == .flat ? .green : .orange)

        let line = SCNGeometry.line(
            from: start,
            to: end,
            color: color
        )

        let rayNode = SCNNode(geometry: line)
        root.addChildNode(rayNode)
    }

    private func makeSensorDebugRoot(
        in scene: SCNScene
    ) -> SCNNode {
        let node = SCNNode()
        node.name = "SensorDebug"
        scene.rootNode.addChildNode(node)
        return node
    }

    // MARK: - Debug information

    private func publishDebugInfo(
        position: SCNVector3,
        terrain: FrankensteinTerrainSample,
        output: FrankensteinLocomotionOutput
    ) {
        let info = """
        Action: \(lastAction)
        Terrain: \(String(describing: terrain.terrain))
        Obstacle distance: \(String(format: "%.2f", lastObstacleDistance))
        Position: (
          \(String(format: "%.2f", position.x)),
          \(String(format: "%.2f", position.y)),
          \(String(format: "%.2f", position.z))
        )
        Speed: \(String(format: "%.2f", output.speed))
        CA generation: \(ca.generationCount)
        Live cells: \(ca.liveCellCount)
        """

        onDebugInfo?(info)
    }

    // MARK: - Reset

    func resetCA() {
        ca.reset()
        locomotion.resetEpisode()

        lastUpdateTime = 0
 
        lastTerrainSample = FrankensteinTerrainSample(
            terrain: .flat,
            distance: 0,
            obstacleHeight: 0,
            gapWidth: 0,
            groundHeight: 0,
            nextGroundHeight: 0,
            isGroundAhead: true,
            isLandingAreaClear: true
        )
        lastAction = "RESET"
        lastObstacleDistance = 0

        isJumping = false
        jumpElapsed = 0
        stepElapsed = 0
        isStepping = false

        obstacleCooldown = 0
        avoidanceDirection = 1
        debugUpdateCounter = 0
    }
}

// MARK: - Debug line geometry

private extension SCNGeometry {
    static func line(
        from start: SCNVector3,
        to end: SCNVector3,
        color: UIColor
    ) -> SCNGeometry {
        let vertices = [start, end]

        let source = SCNGeometrySource(vertices: vertices)

        let indices: [Int32] = [0, 1]

        let element = SCNGeometryElement(
            indices: indices,
            primitiveType: .line
        )

        let geometry = SCNGeometry(
            sources: [source],
            elements: [element]
        )

        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant

        geometry.materials = [material]

        return geometry
    }
}
