
import Foundation
import SceneKit
import simd

final class FrankensteinLocomotion {

    // MARK: - Existing project interfaces

    let policy = FrankensteinLearningPolicy()

    private(set) var body = FrankensteinBodyState()
    private(set) var output = FrankensteinLocomotionOutput()

    // MARK: - Movement configuration

    private let gravity: Float = 9.8
    private let standingHeight: Float = 1.8
    private let maximumDeltaTime: Float = 1.0 / 20.0

    private let baseJumpImpulse: Float = 5.4
    private let minimumJumpImpulse: Float = 4.5
    private let maximumJumpImpulse: Float = 9.0

    private let baseJumpSpeed: Float = 1.3
    private let minimumJumpSpeed: Float = 0.8
    private let maximumJumpSpeed: Float = 4.0

    private let jumpClearance: Float = 0.30

    // MARK: - Adaptive jump state

    private(set) var jumpImpulse: Float = 5.4
    private(set) var jumpForwardSpeed: Float = 1.3

    private(set) var jumpAttempts: Int = 0
    private(set) var successfulJumps: Int = 0
    private(set) var failedJumps: Int = 0

    private(set) var jumpInProgress = false

    private var jumpElapsed: Float = 0
    private var jumpStartHeight: Float = 0
    private var jumpTargetHeight: Float = 0
    private var jumpTargetDistance: Float = 0
    private var jumpLaunchVelocity: Float = 0

    private var verticalVelocity: Float = 0
    private var grounded = true
    private var jumpOutcomeReported = false

    private var currentAction: FrankensteinAction = .walk
    private var actionElapsed: Float = 0

    private var lastActualDisplacement: Float = 0

    // MARK: - Adaptive feedback

    /// Call once when the coordinator has confirmed the outcome
    /// of a jump. Errors are measured in world-space units.
    func reportJumpOutcome(
        success: Bool,
        forwardError: Float = 0,
        heightError: Float = 0
    ) {
        guard jumpInProgress, !jumpOutcomeReported else {
            return
        }

        jumpOutcomeReported = true
        jumpAttempts += 1

        if success {
            successfulJumps += 1

            // Gradually reduce excessive jump power after success.
            // Small adjustments avoid destabilizing a working jump.
            if abs(heightError) < 0.20 {
                jumpImpulse = max(
                    baseJumpImpulse,
                    jumpImpulse - 0.08
                )
            }

            if abs(forwardError) < 0.25 {
                jumpForwardSpeed = max(
                    baseJumpSpeed,
                    jumpForwardSpeed - 0.04
                )
            } else if forwardError < 0 {
                // The character landed short.
                jumpForwardSpeed = min(
                    maximumJumpSpeed,
                    jumpForwardSpeed + 0.15
                )
            }

        } else {
            failedJumps += 1

            // If the jump fell short, increase forward speed.
            if forwardError < -0.15 {
                jumpForwardSpeed = min(
                    maximumJumpSpeed,
                    jumpForwardSpeed + 0.25
                )
            }

            // If the jump did not reach the required height,
            // increase vertical impulse.
            if heightError > 0.10 {
                jumpImpulse = min(
                    maximumJumpImpulse,
                    jumpImpulse + 0.30
                )
            }

            // If the character overshot, reduce forward speed.
            if forwardError > 0.25 {
                jumpForwardSpeed = max(
                    minimumJumpSpeed,
                    jumpForwardSpeed - 0.20
                )
            }
        }
    }

    // MARK: - Main update

    @discardableResult
    func step(
        deltaTime: Float,
        terrain: FrankensteinTerrainSample,
        actualDisplacement: Float? = nil
    ) -> FrankensteinLocomotionOutput {

        let dt = min(max(deltaTime, 0), maximumDeltaTime)

        guard dt > 0 else {
            return output
        }

        if let actualDisplacement,
           actualDisplacement.isFinite {
            lastActualDisplacement = actualDisplacement
        }

        actionElapsed += dt

        if !jumpInProgress {
            selectMovement(for: terrain)
        }

        updateMovement(deltaTime: dt, terrain: terrain)
        updateJump(deltaTime: dt, terrain: terrain)
        updateAnimation(deltaTime: dt)
        stabilize(terrain: terrain)

        output.reward = calculateReward(terrain: terrain)
        output.status = statusDescription(terrain: terrain)

        return output
    }

    // MARK: - Action selection

    private func selectMovement(for terrain: FrankensteinTerrainSample) {
        if body.fallen {
            currentAction = .recover
            return
        }

        if terrain.terrain == .gap ||
            (terrain.terrain == .hurdle &&
             terrain.obstacleHeight > 0.35) {

            currentAction = .jump
            return
        }

        if terrain.terrain == .lowCeiling {
            currentAction = .crouch
            return
        }

        if terrain.terrain == .raisedStep {
            currentAction = .stepUp
            return
        }

        if terrain.terrain == .uneven {
            currentAction = .walk
            return
        }

        currentAction = .walk
    }

    // MARK: - Horizontal movement

    private func updateMovement(
        deltaTime dt: Float,
        terrain: FrankensteinTerrainSample
    ) {
        let requestedSpeed: Float

        switch currentAction {
        case .walk:
            requestedSpeed = 1.0

        case .run:
            requestedSpeed = 2.2

        case .turnLeft, .turnRight:
            requestedSpeed = 0.65

        case .jump:
            requestedSpeed = jumpForwardSpeed

        case .crouch:
            requestedSpeed = 0.45

        case .crawl:
            requestedSpeed = 0.35

        case .roll:
            requestedSpeed = 1.1

        case .stepUp:
            requestedSpeed = 0.55

        case .stepDown:
            requestedSpeed = 0.45

        case .recover:
            requestedSpeed = 0
        }

        var speed = requestedSpeed

        // Do not continually push into an obstacle before takeoff.
        if !jumpInProgress &&
            terrain.distance < 0.8 &&
            terrain.terrain == .hurdle {
            speed = min(speed, 0.25)
        }

        output.speed = speed
        output.action = currentAction
    }

    // MARK: - Jump planning

    private func beginJump(terrain: FrankensteinTerrainSample) {
        guard grounded, !jumpInProgress else {
            return
        }

        jumpInProgress = true
        jumpOutcomeReported = false
        jumpElapsed = 0

        jumpStartHeight = body.height

        let requiredRise = max(
            0,
            terrain.obstacleHeight
        ) + jumpClearance

        // Estimate the apex needed to clear the obstacle.
        let targetRise = min(
            3.0,
            max(0.45, requiredRise)
        )

        jumpTargetHeight = jumpStartHeight + targetRise

        // Estimate the required time to reach the target height.
        // v² = 2gh gives a physically motivated initial impulse.
        let requiredImpulse = sqrt(
            max(0, 2 * gravity * targetRise)
        )

        jumpLaunchVelocity = min(
            maximumJumpImpulse,
            max(
                jumpImpulse,
                min(maximumJumpImpulse, requiredImpulse)
            )
        )

        // Estimate a forward target from the detected obstacle.
        jumpTargetDistance = max(
            0.7,
            terrain.distance + 0.8
        )

        verticalVelocity = jumpLaunchVelocity
        grounded = false

        output.jump = 1.0
        output.speed = jumpForwardSpeed
        output.action = .jump
    }

    // MARK: - Jump physics

    private func updateJump(
        deltaTime dt: Float,
        terrain: FrankensteinTerrainSample
    ) {
        if !jumpInProgress {
            if currentAction == .jump &&
                (terrain.isGroundAhead ||
                 terrain.terrain == .gap) {
                beginJump(terrain: terrain)
            } else {
                output.jump = 0.0
            }

            return
        }

        jumpElapsed += dt

        // Ballistic vertical motion.
        verticalVelocity -= gravity * dt
        body.height += verticalVelocity * dt

        output.jump = 1.0
        output.speed = jumpForwardSpeed
        output.action = .jump

        // Keep the target height available to the character output.
        // Actual SceneKit displacement is applied by the character/
        // coordinator layer, so this model does not translate nodes.
        if body.height < jumpTargetHeight &&
            verticalVelocity > 0 {
            output.lean = 0.12
        } else {
            output.lean = -0.05
        }

        // Do not declare success from height alone.
        // The coordinator must verify actual contact with the
        // landing surface and call reportJumpOutcome(...).
        if verticalVelocity <= 0 &&
            body.height <= jumpStartHeight + standingHeight {
            finishJumpPhysics()
        }

        // Safety timeout: stop an indefinitely airborne model.
        if jumpElapsed > 3.0 {
            finishJumpPhysics()
        }
    }

    private func finishJumpPhysics() {
        jumpInProgress = false
        grounded = true
        verticalVelocity = 0

        body.height = max(
            standingHeight,
            min(body.height, jumpTargetHeight)
        )

        output.jump = 0.0
        currentAction = .walk
    }

    // MARK: - Stabilization

    private func stabilize(terrain: FrankensteinTerrainSample) {
        if !jumpInProgress {
            output.speed = min(output.speed, 2.2)
        }

        if terrain.terrain == .lowCeiling {
            output.crouch = 1.0
            output.speed = min(output.speed, 0.45)
        } else {
            output.crouch = currentAction == .crouch ? 1.0 : 0.0
        }

        if body.fallen {
            output.speed = 0
            output.jump = 0.0
            output.action = .recover
        }
    }

    // MARK: - Animation

    private func updateAnimation(deltaTime dt: Float) {
        if jumpInProgress {
            output.stride = 1.0
        } else {
            output.stride = min(1.0, max(0, output.speed / 2.2))
        }

        if currentAction == .turnLeft {
            output.heading -= 0.65 * dt
        } else if currentAction == .turnRight {
            output.heading += 0.65 * dt
        }

        output.crouch = (
            currentAction == .crouch ||
            currentAction == .crawl
        ) ? 1.0 : 0.0

        if currentAction == .recover {
            output.lean = 0
        }
    }

    // MARK: - Reward and status

    private func calculateReward(
        terrain: FrankensteinTerrainSample
    ) -> Float {
        if body.fallen {
            return -1.0
        }

        if jumpInProgress {
            return 0.05
        }

        if terrain.terrain == .flat {
            return 0.1
        }

        return 0
    }

    private func statusDescription(
        terrain: FrankensteinTerrainSample
    ) -> String {
        if body.fallen {
            return "Fallen — recovery required"
        }

        if jumpInProgress {
            return "Jumping — adaptive attempt \(jumpAttempts + 1)"
        }

        switch terrain.terrain {
        case .gap:
            return "Gap detected"

        case .hurdle:
            return "Obstacle detected"

        case .lowCeiling:
            return "Low ceiling — crouching"

        case .raisedStep:
            return "Raised step detected"

        case .slope:
            return "Slope detected"

        case .uneven:
            return "Uneven terrain"

        case .flat:
            return "Walking"
        }
    }

    // MARK: - Reset

    func resetEpisode() {
        body = FrankensteinBodyState()
        output = FrankensteinLocomotionOutput()

        jumpImpulse = baseJumpImpulse
        jumpForwardSpeed = baseJumpSpeed

        jumpAttempts = 0
        successfulJumps = 0
        failedJumps = 0

        jumpInProgress = false
        jumpOutcomeReported = false

        jumpElapsed = 0
        jumpStartHeight = 0
        jumpTargetHeight = 0
        jumpTargetDistance = 0
        jumpLaunchVelocity = 0

        verticalVelocity = 0
        grounded = true

        currentAction = .walk
        actionElapsed = 0
        lastActualDisplacement = 0

        policy.resetEpisode()
    }
}
