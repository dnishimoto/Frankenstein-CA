
import Foundation
import SceneKit
import simd

// MARK: - Episode result

enum FrankensteinEpisodeEnd {
    case reachedGoal
    case fell
}

final class FrankensteinLocomotion {

    // MARK: - Existing project interfaces

    let policy = FrankensteinLearningPolicy()

    private(set) var body = FrankensteinBodyState()
    private(set) var output = FrankensteinLocomotionOutput()

    var activeActionName: String {
        String(describing: currentAction)
    }

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
    private let maximumJumpDuration: Float = 3.0

    // MARK: - Adaptive jump state

    private(set) var jumpImpulse: Float = 5.4
    private(set) var jumpForwardSpeed: Float = 1.3

    private(set) var jumpAttempts = 0
    private(set) var successfulJumps = 0
    private(set) var failedJumps = 0

    private(set) var jumpInProgress = false

    private var jumpElapsed: Float = 0
    private var jumpStartHeight: Float = 0
    private var jumpTargetHeight: Float = 0
    private var jumpTargetDistance: Float = 0
    private var jumpLaunchVelocity: Float = 0

    private var jumpStartPosition = SCNVector3Zero
    private var previousPosition = SCNVector3Zero
    private var hasPreviousPosition = false
    private var actualJumpDistance: Float = 0

    private var verticalVelocity: Float = 0
    private var grounded = true
    private var jumpOutcomeReported = false

    private var currentAction: FrankensteinAction = .walk
    private var actionElapsed: Float = 0
    private var lastActualDisplacement: Float = 0

    // MARK: - Episode state

    private(set) var pendingEpisodeEnd: FrankensteinEpisodeEnd?

    private(set) var episodes = 0
    private(set) var actionsCompleted = 0
    private(set) var collisions = 0
    private(set) var falls = 0
    private(set) var goalsReached = 0

    // MARK: - Episode completion

    /// Records a terminal result once. Recoverable jump failures should
    /// not call this unless the entire episode has ended.
    func completeEpisode(_ result: FrankensteinEpisodeEnd) {
        guard pendingEpisodeEnd == nil else {
            return
        }

        pendingEpisodeEnd = result

        switch result {
        case .reachedGoal:
            goalsReached += 1

        case .fell:
            falls += 1
        }
    }

    // MARK: - Adaptive feedback

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

            if abs(heightError) < 0.20 {
                jumpImpulse = max(
                    baseJumpImpulse,
                    jumpImpulse - 0.08
                )
            } else if heightError > 0.20 {
                jumpImpulse = min(
                    maximumJumpImpulse,
                    jumpImpulse + 0.10
                )
            }

            if forwardError < -0.25 {
                jumpForwardSpeed = max(
                    minimumJumpSpeed,
                    jumpForwardSpeed - 0.10
                )
            } else if forwardError > 0.25 {
                jumpForwardSpeed = min(
                    maximumJumpSpeed,
                    jumpForwardSpeed + 0.15
                )
            }
        } else {
            failedJumps += 1

            if forwardError > 0.15 {
                jumpForwardSpeed = min(
                    maximumJumpSpeed,
                    jumpForwardSpeed + 0.25
                )
            } else if forwardError < -0.25 {
                jumpForwardSpeed = max(
                    minimumJumpSpeed,
                    jumpForwardSpeed - 0.20
                )
            }

            if heightError > 0.10 {
                jumpImpulse = min(
                    maximumJumpImpulse,
                    jumpImpulse + 0.30
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

        guard pendingEpisodeEnd == nil else {
            output.speed = 0
            output.jump = 0
            return output
        }

        if let actualDisplacement,
           actualDisplacement.isFinite {
            lastActualDisplacement = actualDisplacement

            if jumpInProgress {
                actualJumpDistance += max(0, actualDisplacement)
            }
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

        if !output.status.hasPrefix("Gap detected —") &&
            !output.status.hasPrefix("Jump failed —") {
            output.status = statusDescription(terrain: terrain)
        }

        return output
    }

    // MARK: - Coordinator feedback adapter

    @discardableResult
    func step(
        deltaTime: Float,
        terrain: FrankensteinTerrainSample,
        feedback: FrankensteinMotionFeedback
    ) -> FrankensteinLocomotionOutput {

        if hasPreviousPosition {
            let dx = feedback.position.x - previousPosition.x
            let dz = feedback.position.z - previousPosition.z

            let heading = output.heading
            let forwardX = -sin(heading)
            let forwardZ = -cos(heading)

            let displacement = dx * forwardX + dz * forwardZ

            if displacement.isFinite {
                lastActualDisplacement = displacement

                if jumpInProgress {
                    actualJumpDistance += max(0, displacement)
                }
            }
        }

        previousPosition = feedback.position
        hasPreviousPosition = true

        if jumpInProgress && feedback.grounded {
            if terrain.isLandingAreaClear &&
                !body.fallen &&
                actualJumpDistance > 0 {

                _ = confirmJumpLanding(
                    actualForwardDistance: actualJumpDistance,
                    actualHeight: feedback.feetHeight,
                    landingAreaIsClear: terrain.isLandingAreaClear
                )
            }
        }

        return step(
            deltaTime: deltaTime,
            terrain: terrain,
            actualDisplacement: nil
        )
    }

    // MARK: - Action selection

    private func selectMovement(
        for terrain: FrankensteinTerrainSample
    ) {
        if body.fallen {
            currentAction = .recover
            return
        }

        if terrain.terrain == .gap {
            currentAction = .jump
            return
        }

        if terrain.terrain == .hurdle &&
            terrain.obstacleHeight > 0.35 {
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

        if !jumpInProgress &&
            terrain.distance < 0.8 &&
            terrain.terrain == .hurdle {
            speed = min(speed, 0.25)
        }

        if !jumpInProgress &&
            terrain.terrain == .gap &&
            (!terrain.isLandingAreaClear ||
             terrain.gapWidth <= 0) {
            speed = 0
        }

        output.speed = speed
        output.action = currentAction

        if currentAction == .jump && !jumpInProgress {
            beginJump(terrain: terrain)
        }
    }

    // MARK: - Jump planning

    private func beginJump(
        terrain: FrankensteinTerrainSample
    ) {
        guard grounded,
              !jumpInProgress,
              !body.fallen else {
            return
        }

        if terrain.terrain == .gap {
            guard terrain.gapWidth > 0,
                  terrain.isLandingAreaClear,
                  terrain.gapNearEdgeDistance.isFinite,
                  terrain.gapFarEdgeDistance.isFinite,
                  terrain.gapNearEdgeDistance >= 0,
                  terrain.gapFarEdgeDistance >
                    terrain.gapNearEdgeDistance else {

                currentAction = .walk
                output.action = .walk
                output.speed = 0
                output.jump = 0
                output.status = "Gap detected — landing not verified"
                return
            }
        }

        jumpInProgress = true
        jumpOutcomeReported = false
        jumpElapsed = 0
        actualJumpDistance = 0

        jumpStartHeight = body.height

        let requiredRise = max(
            0,
            terrain.obstacleHeight
        ) + jumpClearance

        let targetRise = min(
            3.0,
            max(0.45, requiredRise)
        )

        jumpTargetHeight = jumpStartHeight + targetRise

        let requiredImpulse = sqrt(
            2 * gravity * targetRise
        )

        jumpLaunchVelocity = min(
            maximumJumpImpulse,
            max(
                minimumJumpImpulse,
                max(jumpImpulse, requiredImpulse)
            )
        )

        jumpTargetDistance = max(
            0.7,
            terrain.distance + terrain.gapWidth + 0.8
        )

        verticalVelocity = jumpLaunchVelocity
        grounded = false

        currentAction = .jump

        output.jump = 1
        output.speed = jumpForwardSpeed
        output.action = .jump
        output.status = "Jump initiated"
    }

    // MARK: - Jump physics

    private func updateJump(
        deltaTime dt: Float,
        terrain: FrankensteinTerrainSample
    ) {
        guard jumpInProgress else {
            if currentAction != .jump {
                output.jump = 0
            }
            return
        }

        jumpElapsed += dt

        verticalVelocity -= gravity * dt
        body.height += verticalVelocity * dt

        output.jump = 1
        output.speed = jumpForwardSpeed
        output.action = .jump
        output.lean = verticalVelocity > 0 ? 0.12 : -0.05

        if jumpElapsed > maximumJumpDuration {
            _ = confirmJumpFailure(
                forwardError: jumpTargetDistance - actualJumpDistance,
                heightError: max(
                    0,
                    jumpTargetHeight - body.height
                )
            )
        }
    }

    // MARK: - Confirm actual landing

    @discardableResult
    func confirmJumpLanding(
        actualForwardDistance: Float,
        actualHeight: Float,
        landingAreaIsClear: Bool
    ) -> Bool {
        guard jumpInProgress,
              !jumpOutcomeReported,
              actualForwardDistance.isFinite,
              actualHeight.isFinite,
              landingAreaIsClear else {
            return false
        }

        let forwardError =
            jumpTargetDistance - actualForwardDistance

        let heightError =
            jumpTargetHeight - actualHeight

        reportJumpOutcome(
            success: true,
            forwardError: forwardError,
            heightError: heightError
        )

        body.height = max(standingHeight, actualHeight)
        body.fallen = false

        finishJumpPhysics(fell: false)

        return true
    }

    // MARK: - Confirm failed landing

    @discardableResult
    func confirmJumpFailure(
        forwardError: Float = 0,
        heightError: Float = 0
    ) -> Bool {
        guard jumpInProgress,
              !jumpOutcomeReported else {
            return false
        }

        reportJumpOutcome(
            success: false,
            forwardError: forwardError,
            heightError: heightError
        )

        body.fallen = true

        finishJumpPhysics(fell: true)

        return true
    }

    // MARK: - End jump physics

    private func finishJumpPhysics(fell: Bool) {
        jumpInProgress = false
        grounded = !fell
        verticalVelocity = 0

        if fell {
            body.fallen = true
            output.status = "Jump failed — recovery required"
        } else {
            body.height = max(standingHeight, body.height)
            output.status = "Landing detected"
            actionsCompleted += 1
        }

        output.jump = 0
        output.speed = 0
        output.action = fell ? .recover : .walk

        currentAction = fell ? .recover : .walk
    }

    // MARK: - Stabilization

    private func stabilize(
        terrain: FrankensteinTerrainSample
    ) {
        if !jumpInProgress {
            output.speed = min(output.speed, 2.2)
        }

        if terrain.terrain == .lowCeiling {
            output.crouch = 1.0
            output.speed = min(output.speed, 0.45)
        } else {
            output.crouch =
                currentAction == .crouch ? 1.0 : 0.0
        }

        if body.fallen {
            output.speed = 0
            output.jump = 0
            output.action = .recover
        }
    }

    // MARK: - Animation

    private func updateAnimation(deltaTime dt: Float) {
        if jumpInProgress {
            output.stride = 1.0
        } else {
            output.stride = min(
                1.0,
                max(0, output.speed / 2.2)
            )
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

    /// Resets the current episode state.
    /// The learned policy itself is deliberately preserved.
    func resetEpisode() {
        pendingEpisodeEnd = nil

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

        jumpStartPosition = SCNVector3Zero
        previousPosition = SCNVector3Zero
        hasPreviousPosition = false
        actualJumpDistance = 0

        verticalVelocity = 0
        grounded = true

        currentAction = .walk
        actionElapsed = 0
        lastActualDisplacement = 0

        // Keep policy learning intact across episodes.
    }
}
