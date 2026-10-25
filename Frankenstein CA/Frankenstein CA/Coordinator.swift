
import Foundation
import SceneKit
import UIKit

/// Runs the simulation each frame:
///
///   1. sense the world from his true pose (rays against solid geometry)
///   2. locomotion asks the Q policy for a skill and drives the body
///   3. the physical body moves through the real scene and reports what
///      actually happened (collisions, landings, falls, goal)
///   4. that report is fed back to locomotion on the next frame, which
///      measures each finished skill and teaches the policy once.
final class Coordinator: NSObject, SCNSceneRendererDelegate {

    private typealias B = FrankensteinPhysicalBody

    let character: FrankensteinCharacter
    let ca: FrankensteinCA

    var onStats: ((Int, Int) -> Void)?
    var onDebugInfo: ((String) -> Void)?

    private let locomotion: FrankensteinLocomotion
    private let dynamics = FrankensteinBodyDynamics()
    private let probe = FrankensteinWorldProbe()

    // Set to true when sensor rays are needed for debugging.
    private let debugSensors: Bool

    private var lastUpdateTime: TimeInterval = 0
    private var lastFeedback = FrankensteinMotionFeedback()
    private var lastTerrain = FrankensteinTerrainSample()
    private var frameCounter = 0

    // Sensing is the most expensive part of a frame; every other frame
    // is plenty at 60 fps.
    private let senseEveryNFrames = 2

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

        lastFeedback = idleFeedback()
        character.root.position = dynamics.position
    }

    // MARK: - Scene update

    func renderer(
        _ renderer: SCNSceneRenderer,
        updateAtTime time: TimeInterval
    ) {
        processPendingReset()

        guard let scene = renderer.scene else { return }

        probe.root = scene.rootNode

        let deltaTime: Float

        if lastUpdateTime == 0 {
            deltaTime = 1.0 / 60.0
        } else {
            deltaTime = Float(
                min(max(time - lastUpdateTime, 0), 0.05)
            )
        }

        lastUpdateTime = time
        frameCounter += 1

        // 1. Advance the cellular automaton (drives the body animation).
        let caMotion = ca.step(deltaTime: deltaTime)

        // 2. Sense the world from his true physical pose.
        let heading = locomotion.output.heading

        if frameCounter % senseEveryNFrames == 1 {
            lastTerrain = probe.sense(
                pose: dynamics.pose(heading: heading)
            )
        }

        let terrain = lastTerrain

        // 3. The Q policy chooses and runs skills; the previous frame's
        // measured result is what it learns from.
        let locomotionOutput = locomotion.step(
            deltaTime: deltaTime,
            terrain: terrain,
            feedback: lastFeedback
        )

        // 4. The body tries to do it against real geometry.
        let feedback = dynamics.advance(
            deltaTime: deltaTime,
            command: FrankensteinBodyCommand(
                speed: locomotionOutput.speed,
                heading: locomotionOutput.heading,
                posture: locomotionOutput.posture,
                jumpRequested: locomotionOutput.jumpRequested
            ),
            probe: probe
        )

        lastFeedback = feedback

        // 5. Show him where the body really is.
        var visual = locomotionOutput
        visual.walkPhase = caMotion.walkPhase
        visual.armLift = caMotion.armLift
        visual.headTurn = caMotion.headTurn
        visual.mouthOpen = caMotion.mouthOpen

        character.root.position = dynamics.position
        character.applyLocomotion(visual)

        // 6. A finished attempt (goal or fall) starts a new one from the
        // start line. What he has learned is kept.
        if let end = locomotion.pendingEpisodeEnd {
            logEpisode(end)
            locomotion.resetEpisode()
            dynamics.teleport(to: B.startPosition)
            lastFeedback = idleFeedback()
            lastTerrain = FrankensteinTerrainSample()
            character.root.position = dynamics.position
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
                        terrain: terrain,
                        output: locomotionOutput,
                        feedback: feedback
                    )
                }
            }
        }

        // 8. Draw optional sensor visualization.
        if debugSensors {
            visualizeSensorRays(
                in: scene,
                position: dynamics.position,
                heading: locomotionOutput.heading,
                terrain: terrain
            )
        }
    }

    private func idleFeedback() -> FrankensteinMotionFeedback {
        var feedback = FrankensteinMotionFeedback()
        feedback.position = dynamics.position
        feedback.grounded = true
        feedback.feetHeight = dynamics.feetY
        feedback.bodyHeight = dynamics.bodyHeight
        return feedback
    }

    // MARK: - Learning log

    private func logEpisode(_ end: FrankensteinEpisodeEnd) {
        let policy = locomotion.policy

        let result = end == .reachedGoal ? "REACHED GOAL" : "FELL"

        let explore = String(format: "%.2f", policy.exploration)
        let jumps = "\(locomotion.successfulJumps)/\(locomotion.jumpAttempts)"

        let line = """
        [Q] attempt \(locomotion.episodes): \(result) | \
        skills \(locomotion.actionsCompleted) | \
        states \(policy.learnedStateCount) | \
        updates \(policy.updateCount) | explore \(explore) | \
        jumps \(jumps) | collisions \(locomotion.collisions) | \
        falls \(locomotion.falls) | goals \(locomotion.goalsReached)
        """

        print(line)
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

        let forwardX = -sin(heading)
        let forwardZ = -cos(heading)

        let start = SCNVector3(
            position.x,
            position.y + 0.8,
            position.z
        )

        let length = min(terrain.distance + B.radius, B.lookAhead)

        let end = SCNVector3(
            position.x + forwardX * length,
            position.y + 0.8,
            position.z + forwardZ * length
        )

        let color: UIColor

        switch terrain.terrain {
        case .gap:
            color = .red
        case .flat:
            color = .green
        case .lowCeiling:
            color = .purple
        default:
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
        terrain: FrankensteinTerrainSample,
        output: FrankensteinLocomotionOutput,
        feedback: FrankensteinMotionFeedback
    ) {
        // Avoid building strings if no UI is receiving them.
        guard let callback = onDebugInfo else { return }

        let policy = locomotion.policy
        let position = feedback.position

        var preferred = "none yet"

        if let best = policy.preferredAction(
            terrain: terrain,
            body: locomotion.body
        ) {
            let value = String(format: "%.2f", best.value)
            preferred = "\(best.action) (Q \(value), tried \(best.tries)x)"
        }

        let info = """
        Skill: \(locomotion.activeActionName)  (\(output.status))
        Posture: \(output.posture)
        Sees: \(terrain.terrain) at \(String(format: "%.2f", terrain.distance))
        Size: height/clearance \(String(format: "%.2f", terrain.obstacleHeight)), \
        gap \(String(format: "%.2f", terrain.gapWidth))
        Would choose now: \(preferred)
        Position: (\(String(format: "%.2f", position.x)), \
        \(String(format: "%.2f", position.y)), \
        \(String(format: "%.2f", position.z)))
        Measured speed: \(String(format: "%.2f", feedback.speed))
        Learned states: \(policy.learnedStateCount)  \
        updates: \(policy.updateCount)  \
        explore: \(String(format: "%.2f", policy.exploration))
        Jumps: \(locomotion.successfulJumps)/\(locomotion.jumpAttempts)  \
        falls: \(locomotion.falls)  goals: \(locomotion.goalsReached)
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
        dynamics.teleport(to: B.startPosition)

        lastUpdateTime = 0
        lastFeedback = idleFeedback()
        lastTerrain = FrankensteinTerrainSample()
        frameCounter = 0

        character.root.position = dynamics.position
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
