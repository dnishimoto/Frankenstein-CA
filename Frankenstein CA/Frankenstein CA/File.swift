
import Foundation
import SwiftUI
import SceneKit

final class Coordinator: NSObject, SCNSceneRendererDelegate {

    var character: FrankensteinCharacter?
    var ca: FrankensteinCA?
    var isRunning = true

    private let locomotion = FrankensteinLocomotion()
    private var lastTime: TimeInterval = 0
    private var frameCounter = 0
    private let onStats: (Int, Int) -> Void

    // Route through the course. Coordinates match the terrain scene.
    private let waypoints: [SCNVector3] = [
        SCNVector3(5.5, 0, 7.0),
        SCNVector3(5.5, 0, 2.0),
        SCNVector3(3.5, 0, -4.5),
        SCNVector3(3.5, 0, -7.5),
        SCNVector3(5.5, 0, -9.0)
    ]

    private var waypointIndex = 0
    private var currentHeading: Float = 0
    private var lastActionName = "Starting"

    init(onStats: @escaping (Int, Int) -> Void) {
        self.onStats = onStats
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resetCA),
            name: .frankensteinReset,
            object: nil
        )
    }

    // MARK: - Terrain sensing

    private func terrainAhead(
        position: SCNVector3,
        heading: Float
    ) -> FrankensteinTerrainSample {

        let lookAhead: Float = 1.6
        let x = position.x + sin(heading) * lookAhead
        let z = position.z - cos(heading) * lookAhead

        // Hurdle at (3.5, 0.45, -6).
        if abs(x - 3.5) < 1.5 && abs(z + 6.0) < 1.0 {
            return FrankensteinTerrainSample(
                terrain: .hurdle,
                distance: max(0.2, abs(z + 6.0)),
                obstacleHeight: 0.9,
                gapWidth: 0,
                groundHeight: 0,
                nextGroundHeight: 0,
                isGroundAhead: true,
                isLandingAreaClear: true
            )
        }

        // Hurdle at (-2.5, 0.35, -3).
        if abs(x + 2.5) < 1.5 && abs(z + 3.0) < 1.0 {
            return FrankensteinTerrainSample(
                terrain: .hurdle,
                distance: max(0.2, abs(z + 3.0)),
                obstacleHeight: 0.7,
                gapWidth: 0,
                groundHeight: 0,
                nextGroundHeight: 0,
                isGroundAhead: true,
                isLandingAreaClear: true
            )
        }

        // Low ceiling.
        if abs(x) < 2.2 && abs(z + 8.0) < 1.6 {
            return FrankensteinTerrainSample(
                terrain: .lowCeiling,
                distance: lookAhead,
                obstacleHeight: 2.0,
                gapWidth: 0,
                groundHeight: 0,
                nextGroundHeight: 0,
                isGroundAhead: true,
                isLandingAreaClear: true
            )
        }

        // Stepped platform on the left.
        if abs(x + 3.5) < 1.5 && z > 1.0 && z < 6.5 {
            return FrankensteinTerrainSample(
                terrain: .raisedStep,
                distance: lookAhead,
                obstacleHeight: 0.5,
                gapWidth: 0,
                groundHeight: 0,
                nextGroundHeight: 0.5,
                isGroundAhead: true,
                isLandingAreaClear: true
            )
        }

        // Central gap: avoid crossing x = 0.
        if abs(x) < 1.0 {
            return FrankensteinTerrainSample(
                terrain: .gap,
                distance: lookAhead,
                obstacleHeight: 0,
                gapWidth: 2.0,
                groundHeight: 0,
                nextGroundHeight: 0,
                isGroundAhead: false,
                isLandingAreaClear: true
            )
        }

        return FrankensteinTerrainSample(
            terrain: .flat,
            distance: lookAhead,
            obstacleHeight: 0,
            gapWidth: 0,
            groundHeight: 0,
            nextGroundHeight: 0,
            isGroundAhead: true,
            isLandingAreaClear: true
        )
    }

    // MARK: - Update loop

    func renderer(
        _ renderer: SCNSceneRenderer,
        updateAtTime time: TimeInterval
    ) {
        guard isRunning, let character, let ca else {
            lastTime = time
            return
        }

        let delta: Float
        if lastTime == 0 {
            delta = 1.0 / 60.0
        } else {
            delta = Float(min(max(time - lastTime, 0), 0.05))
        }
        lastTime = time

        // Evolve the CA.
        let caMotion = ca.step(deltaTime: delta)

        // Current character position.
        let position = character.root.position

        // Follow the current waypoint.
        let target = waypoints[waypointIndex]
        let dx = target.x - position.x
        let dz = target.z - position.z
        let distanceToTarget = sqrt(dx * dx + dz * dz)

        if distanceToTarget < 0.55 {
            if waypointIndex < waypoints.count - 1 {
                waypointIndex += 1
            } else {
                // Loop around and repeat the course.
                waypointIndex = 0
            }
        }

        // Calculate desired direction toward the waypoint.
        let updatedTarget = waypoints[waypointIndex]
        let targetDX = updatedTarget.x - position.x
        let targetDZ = updatedTarget.z - position.z
        let desiredHeading = atan2(targetDX, -targetDZ)

        // Smooth turning rather than snapping instantly.
        var turn = desiredHeading - currentHeading
        while turn > Float.pi { turn -= 2 * Float.pi }
        while turn < -Float.pi { turn += 2 * Float.pi }

        currentHeading += max(-1.8 * delta, min(1.8 * delta, turn))

        // Sense the terrain in front of Frankenstein.
        let terrain = terrainAhead(
            position: position,
            heading: currentHeading
        )

        // Ask the locomotion controller for a behavior.
        let motion = locomotion.step(
            deltaTime: delta,
            terrain: terrain
        )

        var combined = motion
        combined.headTurn += caMotion.headTurn * 0.25
        combined.mouthOpen = caMotion.mouthOpen

        // The waypoint controller supplies steering.
        combined.heading = currentHeading

        // CA activity adds some variation to gait speed.
        let caSpeedFactor: Float =
            0.9 + Float(ca.liveCellCount % 6) * 0.025

        let speed = max(0, motion.speed) * caSpeedFactor

        // Don't walk straight into a detected gap.
        if terrain.terrain == .gap {
            combined.heading = currentHeading + 0.8
        } else {
            character.root.position.x +=
                sin(currentHeading) * speed * delta

            character.root.position.z -=
                cos(currentHeading) * speed * delta
        }

        character.root.eulerAngles.y = Float(combined.heading)
        character.applyLocomotion(combined)

        frameCounter += 1
        if frameCounter % 12 == 0 {
            let generation = ca.generationCount
            let liveCells = ca.liveCellCount

            DispatchQueue.main.async { [weak self] in
                self?.onStats(generation, liveCells)
            }
        }
    }

    @objc func resetCA() {
        ca?.reset()
        locomotion.resetEpisode()
        waypointIndex = 0
        currentHeading = 0
        lastTime = 0
        frameCounter = 0
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
