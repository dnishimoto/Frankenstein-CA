
import Foundation
import SceneKit

final class FrankensteinLocomotion {

    let policy = FrankensteinLearningPolicy()

    private(set) var body = FrankensteinBodyState()
    private(set) var output = FrankensteinLocomotionOutput()

    private var elapsed: Float = 0
    private var actionTimer: Float = 0
    private var lastDistance: Float = 0
    private var action: FrankensteinAction = .walk

    private let gravity: Float = 9.8
    private let jumpImpulse: Float = 5.4
    private let maximumTilt: Float = 0.75

    private var jumpInProgress = false
    private var timedActionRemaining: Float = 0
    private var actionInProgress = false

    private let rollDuration: Float = 0.85
    private let crawlSpeed: Float = 0.35
    private let rollSpeed: Float = 1.1
    private let stepDownSpeed: Float = 0.45

    private var hasExternalMovementMeasurement = false

    // MARK: - Main Update

    func step(
        deltaTime: Float,
        terrain: FrankensteinTerrainSample,
        actualDisplacement: Float? = nil
    ) -> FrankensteinLocomotionOutput {

        let dt = min(max(deltaTime, 0), 0.05)
        elapsed += dt
        actionTimer += dt

        hasExternalMovementMeasurement = actualDisplacement != nil

        if let actualDisplacement {
            body.distanceTravelled += max(
                -1.0,
                min(1.0, actualDisplacement)
            )
        }

        // Finish timed actions before choosing another action.
        if actionInProgress {
            timedActionRemaining -= dt

            if timedActionRemaining <= 0 {
                actionInProgress = false

                if action == .roll {
                    output.crouch = 0
                }
            }
        }

        if !actionInProgress &&
            !jumpInProgress &&
            actionTimer >= 0.22 {

            actionTimer = 0
            action = policy.choose(
                terrain: terrain,
                body: body
            )

            beginActionIfNeeded(terrain: terrain)
        }

        updateMovement(dt: dt, terrain: terrain)
        stabilize(dt: dt, terrain: terrain)

        let progress: Float
        if let actualDisplacement {
            progress = max(-1, min(1, actualDisplacement))
        } else {
            progress = 0
        }

        var reward = progress * 2.0
        reward -= abs(body.tilt) * 0.25

        if body.fallen {
            reward -= 8.0
        }

        if action == .jump && !terrain.isLandingAreaClear {
            reward -= 1.5
        }

        if action == .roll && terrain.terrain == .lowCeiling {
            reward += 0.05
        }

        if action == .crawl && terrain.terrain == .lowCeiling {
            reward += 0.05
        }

        // Existing policy interface retained.
        // For true action-level learning, move this update to the
        // confirmed action-completion point in the full implementation.
        policy.learn(
            reward: reward,
            terrain: terrain,
            body: body,
            terminal: body.fallen
        )

        output.action = action
        output.reward = reward
        output.speed = body.speed
        output.lean = max(-0.4, min(0.4, -body.tilt * 0.7))

        updateAnimation(dt: dt)

        if body.fallen {
            output.status = "Fallen — recovery needed"
        } else if !body.grounded {
            output.status = "Airborne"
        } else {
            output.status = statusText(action)
        }

        return output
    }

    // MARK: - Action Initialization

    private func beginActionIfNeeded(
        terrain: FrankensteinTerrainSample
    ) {
        switch action {
        case .roll:
            timedActionRemaining = rollDuration
            actionInProgress = true

        case .crawl:
            // Crawl is maintained as the selected low-profile gait.
            timedActionRemaining = 0.22
            actionInProgress = true

        case .stepDown:
            // A real descent requires a verified lower surface.
            if terrain.nextGroundHeight < terrain.groundHeight {
                timedActionRemaining = 0.35
                actionInProgress = true
            }

        default:
            break
        }
    }

    // MARK: - Movement

    private func updateMovement(
        dt: Float,
        terrain: FrankensteinTerrainSample
    ) {
        guard !body.fallen else {
            body.speed = 0
            return
        }

        let targetSpeed: Float

        switch action {
        case .walk:
            targetSpeed = 1.0

        case .run:
            targetSpeed = 2.2

        case .turnLeft, .turnRight:
            targetSpeed = 0.65

        case .jump:
            targetSpeed = 1.3

        case .crouch:
            targetSpeed = 0.45

        case .crawl:
            targetSpeed = crawlSpeed

        case .roll:
            targetSpeed = rollSpeed

        case .stepUp:
            targetSpeed = 0.55

        case .stepDown:
            targetSpeed = stepDownSpeed

        case .recover:
            targetSpeed = 0
        }

        body.speed +=
            (targetSpeed - body.speed) * min(1, dt * 3)

        // Initiate a jump only when there is a relevant terrain cue.
        if action == .jump &&
            !jumpInProgress &&
            body.grounded &&
            (terrain.isGroundAhead || terrain.terrain == .gap) {

            body.verticalVelocity = jumpImpulse
            body.grounded = false
            jumpInProgress = true
        }

        if !body.grounded {
            body.verticalVelocity -= gravity * dt
            body.height += body.verticalVelocity * dt

            // Provisional height-based landing only.
            // Coordinator must confirm real SceneKit ground contact.
            let landingHeight = terrain.nextGroundHeight + 1.8

            if body.height <= landingHeight &&
                body.verticalVelocity < 0 {

                body.height = landingHeight
                body.verticalVelocity = 0
                body.grounded = true
                jumpInProgress = false

                if abs(body.tilt) > maximumTilt {
                    body.fallen = true
                }
            }
        } else {
            let targetHeight = terrain.groundHeight + 1.8
            body.height +=
                (targetHeight - body.height) * min(1, dt * 8)
        }

        switch action {
        case .turnLeft:
            output.heading += dt * 1.2

        case .turnRight:
            output.heading -= dt * 1.2

        default:
            break
        }

        if !hasExternalMovementMeasurement {
            lastDistance = body.distanceTravelled
        }

        let terrainDisturbance: Float

        switch terrain.terrain {
        case .uneven:
            terrainDisturbance = sin(elapsed * 5) * 0.08

        case .slope:
            terrainDisturbance = 0.04

        default:
            terrainDisturbance = 0
        }

        let gaitDisturbance =
            sin(elapsed * 7) * body.speed * 0.025

        let recoveryStrength: Float =
            action == .recover ? 2.0 : 0.65

        body.tilt += (
            terrainDisturbance +
            gaitDisturbance -
            body.tilt * recoveryStrength
        ) * dt

        if abs(body.tilt) > maximumTilt {
            body.fallen = true
        }

        // Step-down height interpolation is only a visual/body-state
        // approximation. The coordinator must validate the landing.
        if action == .stepDown &&
            terrain.nextGroundHeight < terrain.groundHeight {

            let lowerHeight = terrain.nextGroundHeight + 1.8

            body.height +=
                (lowerHeight - body.height) * min(1, dt * 2)
        }
    }

    // MARK: - Stabilization

    private func stabilize(
        dt: Float,
        terrain: FrankensteinTerrainSample
    ) {
        guard body.grounded, !body.fallen else {
            return
        }

        let requiresCarefulMovement =
            terrain.distance < 1.0 &&
            [
                .hurdle,
                .gap,
                .lowCeiling,
                .raisedStep
            ].contains(terrain.terrain)

        if requiresCarefulMovement {
            body.speed = min(body.speed, 0.9)
        }

        if action == .crawl || action == .roll {
            body.speed = min(body.speed, rollSpeed)
        }

        body.tilt *= max(0, 1 - dt * 1.8)
    }

    // MARK: - Animation

    private func updateAnimation(dt: Float) {
        let moving = body.speed > 0.15 && !body.fallen

        let phaseSpeed = min(1.8, max(0.35, body.speed))

        if moving {
            output.walkPhase += dt * phaseSpeed * 5.5
        }

        switch action {
        case .jump:
            output.jump = min(1, output.jump + dt * 4)
            output.crouch = max(0, output.crouch - dt * 3)
            output.armLift = 0.65 + sin(output.walkPhase) * 0.08

        case .roll:
            output.crouch = min(1, output.crouch + dt * 4)
            output.jump = max(0, output.jump - dt * 5)
            output.armLift = 0.35 + sin(output.walkPhase * 2) * 0.2

        case .crawl:
            output.crouch = min(1, output.crouch + dt * 3)
            output.jump = max(0, output.jump - dt * 4)
            output.armLift = 0.10 + sin(output.walkPhase * 1.5) * 0.08

        case .crouch:
            output.crouch = min(1, output.crouch + dt * 3)
            output.jump = max(0, output.jump - dt * 4)
            output.armLift = 0.12 + sin(output.walkPhase) * 0.05

        case .stepUp:
            output.jump = min(0.45, output.jump + dt * 2)
            output.armLift = 0.28 + sin(output.walkPhase) * 0.08

        case .stepDown:
            output.jump = max(0, output.jump - dt * 4)
            output.crouch = min(0.35, output.crouch + dt * 1.5)
            output.armLift = 0.30 + sin(output.walkPhase) * 0.06

        case .recover:
            output.crouch = max(0, output.crouch - dt)
            output.armLift = 0.25

        default:
            output.crouch = max(0, output.crouch - dt * 2)
            output.jump = max(0, output.jump - dt * 3)
            output.armLift = moving
                ? 0.12 + sin(output.walkPhase) * 0.18
                : 0.04
        }

        output.stride = moving
            ? min(1, body.speed / 2.2)
            : 0

        output.headTurn =
            action == .turnLeft ? 0.3 :
            (action == .turnRight ? -0.3 : 0)

        output.mouthOpen = moving
            ? max(0, sin(elapsed * 3)) * 0.12
            : 0
    }

    // MARK: - Status

    private func statusText(
        _ action: FrankensteinAction
    ) -> String {
        switch action {
        case .walk: return "Walking"
        case .run: return "Running"
        case .turnLeft: return "Turning left"
        case .turnRight: return "Turning right"
        case .jump: return "Jumping"
        case .crouch: return "Crouching"
        case .crawl: return "Crawling"
        case .roll: return "Rolling"
        case .stepUp: return "Stepping up"
        case .stepDown: return "Stepping down"
        case .recover: return "Balancing / recovering"
        }
    }

    // MARK: - Episode Reset

    func resetEpisode() {
        body = FrankensteinBodyState()
        output = FrankensteinLocomotionOutput()

        elapsed = 0
        actionTimer = 0
        lastDistance = 0
        action = .walk

        jumpInProgress = false
        timedActionRemaining = 0
        actionInProgress = false
        hasExternalMovementMeasurement = false

        policy.resetEpisode()
    }
}
