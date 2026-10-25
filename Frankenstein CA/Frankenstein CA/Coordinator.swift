
import Foundation
import SceneKit
import UIKit

final class Coordinator: NSObject, SCNSceneRendererDelegate {

    let character: FrankensteinCharacter
    let ca: FrankensteinCA

    var onStats: ((Int, Int) -> Void)?
    var onDebugInfo: ((String) -> Void)?

    private let locomotion: FrankensteinLocomotion

    // Set to true when sensor rays are needed for debugging.
    private let debugSensors: Bool

    private var lastUpdateTime: TimeInterval = 0
    private var lastAction = "INITIALIZING"
    private var lastObstacleDistance: Float = 0

    private let sensorDistance: Float = 1.5
    private let maximumSafeStep: Float = 0.45

    // Reset requests are consumed by the renderer.
    private let resetLock = NSLock()
    private var resetRequested = false

    init(
        character: FrankensteinCharacter,
        ca: FrankensteinCA,
        onStats: ((Int, Int) -> Void)? = nil,
        onDebugInfo: ((String) -> Void)? = nil,
        debugSensors: Bool = false
    ) {
        self.character = character
        self.ca = ca
        self.onStats = onStats
        self.onDebugInfo = onDebugInfo
        self.debugSensors = debugSensors
        self.locomotion = FrankensteinLocomotion()

        super.init()
    }

    // MARK: - Scene update

    func renderer(
        _ renderer: SCNSceneRenderer,
        updateAtTime time: TimeInterval
    ) {
        processPendingReset()

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

        // 1. Advance the cellular automaton.
        let caMotion = ca.step(deltaTime: deltaTime)

        // 2. Read the current character transform.
        let position = character.root.presentation.position
        let heading = character.root.presentation.eulerAngles.y

        // 3. Sense the terrain ahead.
        let terrainSample = sampleTerrain(
            in: scene,
            at: position,
            heading: heading
        )

        // 4. Calculate the locomotion response.
        let locomotionOutput = locomotion.step(
            deltaTime: deltaTime,
            terrain: terrainSample
        )

        // 5. Combine CA animation and locomotion.
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

        character.applyLocomotion(output)

        // 6. Move only when the path and supporting ground are safe.
        // Save the original position so an unsafe step can be rejected.
        let root = character.root
        let oldPosition = root.position

        let speed = max(0, locomotionOutput.speed)
        let movementHeading = locomotionOutput.heading

        if speed > 0.01 && deltaTime > 0 {
            let stepDistance = min(speed * deltaTime, 0.04)

            let proposedPosition = SCNVector3(
                oldPosition.x + sin(movementHeading) * stepDistance,
                oldPosition.y,
                oldPosition.z - cos(movementHeading) * stepDistance
            )

            // Sample just ahead of the proposed position.
            let proposedTerrain = sampleTerrain(
                in: scene,
                at: proposedPosition,
                heading: movementHeading
            )

            let hasSupportingGround =
                proposedTerrain.isGroundAhead

            let noDetectedObstacle =
                proposedTerrain.obstacleHeight < 0.15

            let terrainAllowsMovement =
                proposedTerrain.terrain == .flat ||
                proposedTerrain.terrain == .slope ||
                proposedTerrain.terrain == .uneven

            if hasSupportingGround &&
                noDetectedObstacle &&
                terrainAllowsMovement {

                root.position = proposedPosition
            } else {
                // Stay in place if the proposed step is unsafe.
                root.position = oldPosition
            }
        }

        // 7. Publish UI information at a reduced update rate.
        if onStats != nil || onDebugInfo != nil {
            if Int(time * 20) !=
                Int((time - Double(deltaTime)) * 20) {

                let generation = ca.generationCount
                let liveCells = ca.liveCellCount

                if let onStats = onStats {
                    DispatchQueue.main.async {
                        onStats(generation, liveCells)
                    }
                }

                if onDebugInfo != nil {
                    publishDebugInfo(
                        position: root.position,
                        terrain: terrainSample,
                        output: locomotionOutput
                    )
                }
            }
        }

        // 8. Draw optional sensor visualization.
        if debugSensors {
            visualizeSensorRays(
                in: scene,
                position: root.presentation.position,
                heading: root.presentation.eulerAngles.y,
                terrain: terrainSample
            )
        }
    }

    // MARK: - Terrain sensing

    private func sampleTerrain(
        in scene: SCNScene,
        at position: SCNVector3,
        heading: Float
    ) -> FrankensteinTerrainSample {

        let forwardX = sin(heading)
        let forwardZ = -cos(heading)

        // Check ground directly beneath the character.
        let groundHits = scene.rootNode.hitTestWithSegment(
            from: SCNVector3(
                position.x,
                position.y + 1.0,
                position.z
            ),
            to: SCNVector3(
                position.x,
                position.y - 2.0,
                position.z
            ),
            options: nil
        )

        let hasGround = groundHits.contains { hit in
            !isCharacterNode(hit.node) &&
            isGroundNode(hit.node)
        }

        // Check ground ahead. A missing surface may indicate a gap.
        let aheadX = position.x + forwardX * sensorDistance
        let aheadZ = position.z + forwardZ * sensorDistance

        let aheadHits = scene.rootNode.hitTestWithSegment(
            from: SCNVector3(
                aheadX,
                position.y + 1.0,
                aheadZ
            ),
            to: SCNVector3(
                aheadX,
                position.y - 2.0,
                aheadZ
            ),
            options: nil
        )

        let hasGroundAhead = aheadHits.contains { hit in
            !isCharacterNode(hit.node) &&
            isGroundNode(hit.node)
        }

        // Cast horizontal rays at several body heights.
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
                aheadX,
                position.y + height,
                aheadZ
            )

            let hits = scene.rootNode.hitTestWithSegment(
                from: rayStart,
                to: rayEnd,
                options: nil
            )

            if let hit = hits.first(where: { hit in
                !isCharacterNode(hit.node) &&
                !isGroundNode(hit.node) &&
                !isDecorativeNode(hit.node) &&
                !isBoundaryNode(hit.node)
            }) {
                detectedName = nodeName(for: hit.node)
                detectedDistance = distance(
                    from: position,
                    to: hit.worldCoordinates
                )
                break
            }
        }

        lastObstacleDistance = detectedName == nil
            ? 0
            : detectedDistance

        let name = (detectedName ?? "").lowercased()

        // Classify a missing ground surface first.
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
            lastAction = "OBSTACLE: \(detectedName)"

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
               name.contains("floor") ||
               name.contains("platform") {
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
               name.contains("light") ||
               name.contains("sensordebug")
    }

    private func isBoundaryNode(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node

        while let candidate = current {
            let name = (candidate.name ?? "").lowercased()

            if name.contains("boundary") ||
               name.contains("sidewall") {
                return true
            }

            current = candidate.parent
        }

        return false
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

    // MARK: - Optional sensor visualization

    private func visualizeSensorRays(
        in scene: SCNScene,
        position: SCNVector3,
        heading: Float,
        terrain: FrankensteinTerrainSample
    ) {
        let root: SCNNode

        if let existingRoot = scene.rootNode.childNode(
            withName: "SensorDebug",
            recursively: false
        ) {
            root = existingRoot
        } else {
            root = makeSensorDebugRoot(in: scene)
        }

        // Only rebuild the ray when debug visualization is enabled.
        root.childNodes.forEach {
            $0.removeFromParentNode()
        }

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

        let color: UIColor

        if terrain.terrain == .gap {
            color = .red
        } else if terrain.terrain == .flat {
            color = .green
        } else {
            color = .orange
        }

        let rayNode = SCNNode(
            geometry: SCNGeometry.line(
                from: start,
                to: end,
                color: color
            )
        )

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
        // Avoid building strings if no UI is receiving them.
        guard let callback = onDebugInfo else { return }

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

        DispatchQueue.main.async {
            callback(info)
        }
    }

    // MARK: - Reset

    func resetCA() {
        resetLock.lock()
        resetRequested = true
        resetLock.unlock()
    }

    private func processPendingReset() {
        resetLock.lock()
        let shouldReset = resetRequested
        resetRequested = false
        resetLock.unlock()

        guard shouldReset else { return }

        ca.reset()
        locomotion.resetEpisode()

        lastUpdateTime = 0
        lastAction = "RESET"
        lastObstacleDistance = 0
    }
}

// MARK: - Debug line geometry

private extension SCNGeometry {

    static func line(
        from start: SCNVector3,
        to end: SCNVector3,
        color: UIColor
    ) -> SCNGeometry {
        let source = SCNGeometrySource(
            vertices: [start, end]
        )

        let element = SCNGeometryElement(
            indices: [Int32(0), Int32(1)],
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
