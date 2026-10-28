

import Foundation
import SceneKit
import simd


final class FrankensteinLocomotion {

    private let recoveryDuration: Float = 0.6

    // MARK: - Learning

    let policy = FrankensteinLearningPolicy()

    // MARK: - Cellular Automaton Controller

    private var ca: FrankensteinCA?

    func attachCA(_ ca: FrankensteinCA) {
        self.ca = ca
    }

    var attachedCAGeneration: Int { ca?.generation ?? 0 }
    var attachedCALiveCellCount: Int { ca?.liveCellCount ?? 0 }

    private(set) var caCommandName = "Walk"
    private(set) var lastSafetyOverride = ""
    private(set) var caLeftActivity = 0
    private(set) var caRightActivity = 0
    private(set) var caCenterActivity = 0

    private var lastCACommand: FrankensteinCACommand = .walk

    // MARK: - Primary Goal: Charging Station on Red Platform

    private(set) var goalStage: FrankensteinGoalStage = .exploreRoom

    private(set) var goalDescription =
        "Explore the room and find an object that can help reach the red platform."

    private(set) var usefulObjectName: String?
    private(set) var usefulObjectMoved = false
    private(set) var objectPlacedAsStep = false
    private(set) var redPlatformReached = false
    private(set) var chargingStationReached = false

    /// Perception calls this when a useful object has been identified.
    func reportUsefulObjectDetected(name: String) {
        let cleanedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !cleanedName.isEmpty,
              !chargingStationReached else {
            return
        }

        usefulObjectName = cleanedName
        goalStage = .moveObjectToPlatform
        goalDescription =
            "Move \(cleanedName) into a useful position for reaching the red platform."

        print("[Goal] Useful object detected: \(cleanedName)")
    }

    /// Call only after the Coordinator confirms actual object movement.
    @discardableResult
    func reportUsefulObjectMoved(
        name: String,
        succeeded: Bool
    ) -> Bool {
        guard !chargingStationReached else {
            return false
        }

        guard succeeded else {
            goalDescription =
                "Continue moving \(name) into a useful position."
            print("[Goal] Object movement failed: \(name)")
            return false
        }

        usefulObjectName = name
        usefulObjectMoved = true
        goalStage = .useObjectAsStep
        goalDescription =
            "Use \(name) as a step to climb toward the red platform."

        print("[Goal] Object moved into useful position: \(name)")
        return true
    }

    /// Call when the Coordinator verifies the object can be used as a step.
    @discardableResult
    func reportObjectPlacedAsStep(succeeded: Bool) -> Bool {
        guard usefulObjectMoved,
              !chargingStationReached else {
            return false
        }

        guard succeeded else {
            goalDescription =
                "Adjust the object so it provides a usable step."
            return false
        }

        objectPlacedAsStep = true
        goalStage = .climbToRedPlatform
        goalDescription =
            "Climb from the object onto the red platform."

        print("[Goal] Object is positioned as a step.")
        return true
    }

    /// Call after the Coordinator verifies that the character is
    /// physically standing on the red platform.
    @discardableResult
    func reportRedPlatformReached() -> Bool {
        guard objectPlacedAsStep,
              !chargingStationReached else {
            return false
        }

        redPlatformReached = true
        goalStage = .reachChargingStation
        goalDescription =
            "Move across the red platform to the recharging station."

        print("[Goal] Red platform reached.")
        return true
    }

    /// Call after the Coordinator verifies contact with the actual station.
    @discardableResult
    func reportChargingStationReached() -> Bool {
        guard redPlatformReached,
              !chargingStationReached else {
            return false
        }

        chargingStationReached = true
        goalStage = .rechargeComplete
        goalDescription = "Charging station reached. Recharge the battery."

        print("[Goal] Charging station reached.")
        return true
    }

    // MARK: - CA Command

    private func readCACommand() -> FrankensteinCACommand {
        guard let ca else {
            caCommandName = "Walk — CA not attached"
            return .walk
        }

        var left = 0
        var right = 0
        var center = 0

        for y in 0..<ca.size {
            for x in 0..<ca.size {
                guard ca.isActive(x, y) else { continue }

                if x < ca.size / 3 {
                    left += 1
                } else if x >= (ca.size * 2) / 3 {
                    right += 1
                } else {
                    center += 1
                }
            }
        }

        caLeftActivity = left
        caRightActivity = right
        caCenterActivity = center

        let difference = left - right
        let turnThreshold = max(4, ca.size / 2)

        let command: FrankensteinCACommand

        if difference >= turnThreshold {
            command = .turnLeft
        } else if difference <= -turnThreshold {
            command = .turnRight
        } else if center >= 15 {
            command = .run
        } else {
            command = .walk
        }

        lastCACommand = command

        switch command {
        case .walk:
            caCommandName = "Walk"
        case .run:
            caCommandName = "Run"
        case .turnLeft:
            caCommandName = "Turn left"
        case .turnRight:
            caCommandName = "Turn right"
        }

        return command
    }

    // MARK: - State

    private(set) var body = FrankensteinBodyState()
    private(set) var output = FrankensteinLocomotionOutput()

    var activeActionName: String {
        String(describing: currentAction)
    }

    // MARK: - Walking Animation State

    private(set) var gaitPhase: Float = 0
    private(set) var gaitSwing: Float = 0
    private(set) var isWalking = false

    // MARK: - Movement Configuration
    // Existing movement parameters preserved.

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

    // MARK: - Step Movement

    private let maximumStepUpHeight: Float = 0.45
    private let maximumStepDownHeight: Float = 0.60

    private let stepUpSpeed: Float = 0.55
    private let stepDownSpeed: Float = 0.45
    private let stepTransitionSpeed: Float = 2.0

    private var stepStartHeight: Float = 0
    private var stepTargetHeight: Float = 0
    private var stepTransitionProgress: Float = 1

    private(set) var stepUpInProgress = false
    private(set) var stepDownInProgress = false

    private var stepTransitionLatched = false

    // MARK: - Adaptive Jump State

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

    // MARK: - Perception from Coordinator

    private var perceivedAllowedActions: [FrankensteinAction] = [.walk]
    private var perceivedQValues: [FrankensteinAction: Float] = [:]

    func receivePerception(
        allowedActions: [FrankensteinAction],
        qValues: [FrankensteinAction: Float]
    ) {
        perceivedAllowedActions = allowedActions
        perceivedQValues = qValues
    }

    private var actionElapsed: Float = 0
    private var recoveryElapsed: Float = 0
    private var lastActualDisplacement: Float = 0
    private var actionDisplacement: Float = 0
    private var lastLoggedDecision = ""

    // MARK: - Episode State

    private(set) var pendingEpisodeEnd: FrankensteinEpisodeEnd?

    private(set) var episodes = 0
    private(set) var actionsCompleted = 0
    private(set) var collisions = 0
    private(set) var falls = 0
    private(set) var goalsReached = 0

    func completeEpisode(_ result: FrankensteinEpisodeEnd) {
        guard pendingEpisodeEnd == nil else { return }

        pendingEpisodeEnd = result
        episodes += 1

        switch result {
        case .reachedGoal:
            goalsReached += 1
        case .fell:
            falls += 1
            body.fallen = true
        }
    }

    // MARK: - Energy

    private(set) var energy: Float = 1.0

    /// Refills energy only after station contact has been verified.
    @discardableResult
    func reportRecharge() -> Bool {
        guard chargingStationReached,
              energy < 0.6 else {
            return false
        }

        let reward: Float = 5.0 * (1.0 - energy) + 1.0
        energy = 1.0

        print("[Energy] Recharged: reward \(reward)")

        _ = completePendingAction(
            reward: reward,
            terrain: currentTerrainForFeedback,
            terminal: false,
            reason: "recharge"
        )

        completeEpisode(.reachedGoal)
        return true
    }

    // MARK: - Object Action Feedback

    @discardableResult
    func reportObjectActionOutcome(
        _ action: FrankensteinAction,
        reward: Float
    ) -> Bool {
        guard policy.pendingAction == action else {
            return false
        }

        return completePendingAction(
            reward: reward,
            terrain: currentTerrainForFeedback,
            terminal: false,
            reason: "\(action)"
        )
    }

    // MARK: - Pickup Feedback

    @discardableResult
    func reportPickupOutcome(succeeded: Bool) -> Bool {
        guard policy.pendingAction == .liftObject else {
            return false
        }

        let reward: Float = succeeded ? 2.0 : -0.5

        print(
            "[Learning] Pickup " +
            (succeeded ? "succeeded: reward +2.0" : "failed: reward -0.5")
        )

        return completePendingAction(
            reward: reward,
            terrain: currentTerrainForFeedback,
            terminal: false,
            reason: "pickup"
        )
    }

    // MARK: - Collision Feedback

    func reportCollision() {
        collisions += 1

        _ = completePendingAction(
            reward: -1.0,
            terrain: currentTerrainForFeedback,
            terminal: false,
            reason: "collision"
        )
    }

    // MARK: - Futility Feedback

    /// Call this when the Coordinator detects that the character has
    /// returned to a previously visited position without useful progress.
    ///
    /// The policy checks that the reported action is still pending.
    /// A successful report performs one negative Q-update.
    @discardableResult
    func reportFutility(
        for executedAction: FrankensteinAction,
        repetitions: Int = 1
    ) -> Bool {
        return policy.reportFutility(
            for: executedAction,
            repetitions: repetitions,
            terrain: currentTerrainForFeedback,
            body: body,
            nextActions: perceivedAllowedActions
        )
    }

    // MARK: - Single Learning Path

    @discardableResult
    private func completePendingAction(
        reward: Float,
        terrain: FrankensteinTerrainSample,
        terminal: Bool,
        reason: String
    ) -> Bool {
        guard policy.isAwaitingOutcome else {
            return false
        }

        let learned = policy.learn(
            reward: reward,
            terrain: terrain,
            body: body,
            nextActions: perceivedAllowedActions,
            terminal: terminal
        )

        if learned {
            actionElapsed = 0
            actionDisplacement = 0
            actionsCompleted += 1
            print("[Learning] Completed \(reason), reward=\(reward)")
        }

        return learned
    }

    private var currentTerrainForFeedback = FrankensteinTerrainSample()

    private func logDecision(
        caGeneration: Int,
        liveCells: Int,
        caRequestedAction: String,
        qLearningAction: String,
        finalAction: String,
        safetyOverride: String
    ) {
        let signature =
            "\(caRequestedAction)|\(finalAction)|\(safetyOverride)"

        guard signature != lastLoggedDecision else { return }
        lastLoggedDecision = signature

        print("[CA] Generation: \(caGeneration), Live cells: \(liveCells)")
        print("[CA] Requested action: \(caRequestedAction)")
        print("[Q-Learning] Suggested action: \(qLearningAction)")
        print("[Safety] Override: \(safetyOverride)")
        print("[Movement] Applied action: \(finalAction)")
    }

    // MARK: - Adaptive Jump Feedback

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

        // The policy receives the jump result through the same Q-learning
        // path used by other actions.
        _ = policy.reportJumpOutcome(
            succeeded: success,
            terrain: currentTerrainForFeedback,
            body: body,
            nextActions: perceivedAllowedActions,
            terminal: false
        )

        actionElapsed = 0
        actionDisplacement = 0
    }

    // MARK: - Main Update

    @discardableResult
    func step(
        deltaTime: Float,
        terrain: FrankensteinTerrainSample,
        actualDisplacement: Float? = nil
    ) -> FrankensteinLocomotionOutput {

        let dt = min(max(deltaTime, 0), maximumDeltaTime)
        guard dt > 0 else { return output }

        // Stop movement when the episode has ended.
        guard pendingEpisodeEnd == nil else {
            output.speed = 0
            output.jump = 0
            output.stride = 0
            gaitSwing = 0
            isWalking = false

            logDecision(
                caGeneration: ca?.generation ?? 0,
                liveCells: ca?.liveCellCount ?? 0,
                caRequestedAction: "none — episode ended",
                qLearningAction: "not selected",
                finalAction: "stop",
                safetyOverride: "movement stopped — episode ended"
            )

            return output
        }

        // Accumulate measured movement, not just commanded movement.
        if let actualDisplacement,
           actualDisplacement.isFinite {
            lastActualDisplacement = actualDisplacement
            actionDisplacement += actualDisplacement

            if jumpInProgress {
                actualJumpDistance += max(0, actualDisplacement)
            }
        }

        currentTerrainForFeedback = terrain
        actionElapsed += dt
        energy = max(0, energy - 0.004 * dt)

        if terrain.terrain != .raisedStep {
            stepTransitionLatched = false
        }

        if !jumpInProgress &&
           !stepUpInProgress &&
           !stepDownInProgress {
            selectMovement(for: terrain)
        }

        updateMovement(deltaTime: dt, terrain: terrain)
        updateJump(deltaTime: dt, terrain: terrain)
        updateStepTransition(deltaTime: dt)
        updateAnimation(deltaTime: dt)
        stabilize(terrain: terrain)

        output.reward = calculateReward(terrain: terrain)

        if actionElapsed >= 0.35,
           policy.isAwaitingOutcome,
           !jumpInProgress,
           !stepUpInProgress,
           !stepDownInProgress,
           output.reward.isFinite {
            let completedReward = output.reward +
                min(0.5, max(-0.5, actionDisplacement * 1.5))

            _ = completePendingAction(
                reward: completedReward,
                terrain: terrain,
                terminal: false,
                reason: "\(currentAction)"
            )
        }

        if !output.status.hasPrefix("Gap detected —") &&
           !output.status.hasPrefix("Jump failed —") {
            output.status = statusDescription(terrain: terrain)
        }

        if body.fallen || currentAction == .recover {
            currentAction = .recover

            output.action = .recover
            output.speed = 0
            output.jump = 0

            recoveryElapsed += dt

            if recoveryElapsed >= recoveryDuration {
                performRecovery()
            }

            return output
        }

        logDecision(
            caGeneration: ca?.generation ?? 0,
            liveCells: ca?.liveCellCount ?? 0,
            caRequestedAction: caCommandName,
            qLearningAction: policy.pendingAction.map {
                String(describing: $0)
            } ?? "Q-values advisory only",
            finalAction: String(describing: output.action),
            safetyOverride: lastSafetyOverride
        )

        return output
    }

    // MARK: - Recovery

    private func performRecovery() {
        body.fallen = false

        verticalVelocity = 0
        grounded = true

        jumpInProgress = false
        jumpOutcomeReported = true
        jumpElapsed = 0
        actualJumpDistance = 0

        stepUpInProgress = false
        stepDownInProgress = false
        stepTransitionProgress = 1
        stepTransitionLatched = false

        recoveryElapsed = 0
        actionElapsed = 0
        actionDisplacement = 0
        currentAction = .walk

        output.action = .walk
        output.speed = 0
        output.jump = 0
        output.stride = 0
        output.crouch = 0
        output.lean = 0

        gaitSwing = 0
        isWalking = false

        lastSafetyOverride = "recovery complete"
        output.status = "Recovery complete"

        print("[Recovery] Fallen state cleared; locomotion reset.")
    }

    private func diagnosticActionDescription() -> String {
        if output.jump > 0 {
            return "jump"
        }

        if output.speed <= 0 {
            return "stop"
        }

        return "moving (speed: \(output.speed), stride: \(output.stride))"
    }

    // MARK: - Coordinator Feedback Adapter

    @discardableResult
    func step(
        deltaTime: Float,
        terrain: FrankensteinTerrainSample,
        feedback: FrankensteinMotionFeedback
    ) -> FrankensteinLocomotionOutput {

        var measuredDisplacement: Float?

        if hasPreviousPosition {
            let dx = feedback.position.x - previousPosition.x
            let dz = feedback.position.z - previousPosition.z

            let heading = output.heading
            let forwardX = -sin(heading)
            let forwardZ = -cos(heading)

            let displacement = dx * forwardX + dz * forwardZ

            if displacement.isFinite {
                measuredDisplacement = displacement
            }
        }

        previousPosition = feedback.position
        hasPreviousPosition = true

        let result = step(
            deltaTime: deltaTime,
            terrain: terrain,
            actualDisplacement: measuredDisplacement
        )

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

        return result
    }

    // MARK: - Action Selection

    private func selectMovement(
        for terrain: FrankensteinTerrainSample
    ) {
        lastSafetyOverride = "none"

        guard !body.fallen else {
            currentAction = .recover
            lastSafetyOverride = "recovery required"
            caCommandName = "Recover"
            return
        }

        // Keep the action until its outcome has been learned.
        if policy.isAwaitingOutcome,
           let pending = policy.pendingAction {
            currentAction = pending
            return
        }

        let allowedActions = perceivedAllowedActions.isEmpty
            ? [FrankensteinAction.walk]
            : perceivedAllowedActions

        let proposedAction: FrankensteinAction

        if let ca {
            proposedAction = ca.decideAction(
                terrain: terrain,
                body: body,
                allowedActions: allowedActions,
                qValues: perceivedQValues,
                exploration: policy.exploration
            )
        } else {
            proposedAction = fallbackCAAction(for: terrain)
            lastSafetyOverride = "CA not attached — fallback action"
        }

        let chosen = allowedActions.contains(proposedAction)
            ? proposedAction
            : fallbackCAAction(from: allowedActions)

        currentAction = chosen
        caCommandName = String(describing: chosen)

        _ = policy.beginCAChosenAction(
            chosen,
            terrain: terrain,
            body: body
        )

        actionElapsed = 0
        actionDisplacement = 0

        print(
            "[CA] Selected action: \(chosen) | " +
            "Q=\(perceivedQValues[chosen] ?? 0) | " +
            "Goal=\(goalStage.rawValue)"
        )
    }

    private func fallbackCAAction(
        for terrain: FrankensteinTerrainSample
    ) -> FrankensteinAction {
        switch terrain.terrain {
        case .gap, .hurdle:
            return terrain.isLandingAreaClear ? .jump : .walk
        case .lowCeiling:
            return .crouch
        case .raisedStep:
            return terrain.obstacleHeight > 0.45 ? .jump : .stepUp
        default:
            return .walk
        }
    }

    private func fallbackCAAction(
        from candidates: [FrankensteinAction]
    ) -> FrankensteinAction {
        if candidates.contains(.walk) { return .walk }
        if candidates.contains(.turnLeft) { return .turnLeft }
        if candidates.contains(.turnRight) { return .turnRight }
        return candidates.first ?? .walk
    }

    // MARK: - Horizontal Movement

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
            requestedSpeed = 0.15
        case .jump:
            requestedSpeed = jumpForwardSpeed
        case .crouch:
            requestedSpeed = 0.45
        case .crawl:
            requestedSpeed = 0.35
        case .roll:
            requestedSpeed = 1.1
        case .stepUp:
            requestedSpeed = stepUpSpeed
        case .stepDown:
            requestedSpeed = stepDownSpeed
        case .recover:
            requestedSpeed = 0
        case .backward:
            requestedSpeed = 0.6
        case .stepForward:
            requestedSpeed = 0.5
        case .liftObject, .placeObject, .throwObject:
            requestedSpeed = 0
        }

        output.speed = requestedSpeed
        output.action = currentAction
        output.moveDirection = currentAction == .backward ? -1 : 1

        output.liftRequested = currentAction == .liftObject
        output.placeRequested = currentAction == .placeObject
        output.throwRequested = currentAction == .throwObject

        if currentAction == .jump && !jumpInProgress {
            beginJump(terrain: terrain)
        }

        if currentAction == .stepUp &&
           !stepUpInProgress &&
           !stepDownInProgress &&
           !stepTransitionLatched {
            let rise = terrain.obstacleHeight

            if rise > 0 && rise <= maximumStepUpHeight {
                beginStepTransition(to: body.height + rise)
                stepTransitionLatched = true
            }
        }

        if currentAction == .stepDown &&
           !stepUpInProgress &&
           !stepDownInProgress &&
           !stepTransitionLatched {
            let drop = terrain.groundHeight - terrain.nextGroundHeight

            if terrain.isStepDownSafe(), drop > 0.02 {
                beginStepTransition(to: body.height - drop)
                stepTransitionLatched = true
            }
        }
    }

    // MARK: - Step Transitions

    private func beginStepTransition(to targetHeight: Float) {
        guard targetHeight.isFinite else { return }

        stepStartHeight = body.height
        stepTargetHeight = targetHeight
        stepTransitionProgress = 0

        stepUpInProgress = targetHeight > body.height
        stepDownInProgress = targetHeight < body.height

        if stepUpInProgress {
            currentAction = .stepUp
            output.action = .stepUp
            output.speed = stepUpSpeed
            output.status = "Stepping up"
        } else if stepDownInProgress {
            currentAction = .stepDown
            output.action = .stepDown
            output.speed = stepDownSpeed
            output.status = "Stepping down"
        }
    }

    private func updateStepTransition(deltaTime dt: Float) {
        guard stepUpInProgress || stepDownInProgress else {
            return
        }

        stepTransitionProgress = min(
            1,
            stepTransitionProgress + stepTransitionSpeed * dt
        )

        let t = stepTransitionProgress
        let smoothT = t * t * (3 - 2 * t)

        body.height = stepStartHeight +
            (stepTargetHeight - stepStartHeight) * smoothT

        if stepTransitionProgress >= 1 {
            body.height = stepTargetHeight
            stepUpInProgress = false
            stepDownInProgress = false
            output.status = "Step transition complete"
            actionsCompleted += 1
        }
    }

    func requestStepDown(dropHeight: Float) {
        guard !body.fallen,
              !jumpInProgress,
              !stepUpInProgress,
              !stepDownInProgress,
              dropHeight.isFinite,
              dropHeight > 0,
              dropHeight <= maximumStepDownHeight else {
            return
        }

        beginStepTransition(
            to: max(0, body.height - dropHeight)
        )
    }

    // MARK: - Jump Planning

    private func beginJump(terrain: FrankensteinTerrainSample) {
        guard grounded,
              !jumpInProgress,
              !body.fallen else {
            return
        }

        if terrain.terrain == .hurdle {
            guard terrain.isLandingAreaClear else {
                currentAction = .walk
                output.action = .walk
                output.speed = 0
                output.jump = 0
                output.status = "Jump blocked — landing not verified"
                return
            }
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
        jumpStartPosition = previousPosition

        let requiredRise = max(0, terrain.obstacleHeight) + jumpClearance
        let targetRise = min(3.0, max(0.45, requiredRise))

        jumpTargetHeight = jumpStartHeight + targetRise

        let requiredImpulse = sqrt(2 * gravity * targetRise)

        jumpLaunchVelocity = min(
            maximumJumpImpulse,
            max(minimumJumpImpulse, max(jumpImpulse, requiredImpulse))
        )

        if terrain.terrain == .hurdle ||
           terrain.terrain == .raisedStep {
            jumpTargetDistance = max(
                0.7,
                terrain.distance +
                    max(0.3, min(terrain.obstacleDepth, 1.2) * 0.5) +
                    0.2
            )
        } else {
            jumpTargetDistance = max(
                0.7,
                terrain.distance + terrain.gapWidth + 0.8
            )
        }

        verticalVelocity = jumpLaunchVelocity
        grounded = false

        currentAction = .jump
        output.jump = 1
        output.speed = jumpForwardSpeed
        output.action = .jump
        output.status = "Jump initiated"
    }

    // MARK: - Jump Physics

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
                heightError: max(0, jumpTargetHeight - body.height)
            )
        }
    }

    // MARK: - Jump Landing

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

        let forwardError = jumpTargetDistance - actualForwardDistance
        let heightError = jumpTargetHeight - actualHeight

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

    @discardableResult
    func confirmJumpFailure(
        forwardError: Float = 0,
        heightError: Float = 0
    ) -> Bool {
        guard jumpInProgress, !jumpOutcomeReported else {
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

    private func stabilize(terrain: FrankensteinTerrainSample) {
        if !jumpInProgress {
            output.speed = min(output.speed, 2.2)
        }

        output.crouch = (
            currentAction == .crouch ||
            currentAction == .crawl
        ) ? 1.0 : 0.0

        if body.fallen {
            output.speed = 0
            output.jump = 0
            output.action = .recover
        }
    }

    // MARK: - Animation and Turning

    private func updateAnimation(deltaTime dt: Float) {
        let movingSpeed = max(0, output.speed)
        output.stride = min(1.0, movingSpeed / 2.2)

        isWalking = movingSpeed > 0.05 &&
            !body.fallen &&
            currentAction != .recover

        if isWalking {
            let gaitFrequency: Float

            switch currentAction {
            case .crawl:
                gaitFrequency = 3.0
            case .crouch:
                gaitFrequency = 3.5
            case .run:
                gaitFrequency = 9.0
            case .roll:
                gaitFrequency = 2.0
            case .jump:
                gaitFrequency = 7.0
            default:
                gaitFrequency = 6.0
            }

            let speedScale = max(0.5, movingSpeed / 1.0)
            gaitPhase += gaitFrequency * speedScale * dt

            let fullCycle = 2.0 * Float.pi
            if gaitPhase >= fullCycle {
                gaitPhase.formTruncatingRemainder(dividingBy: fullCycle)
            }
        } else {
            output.stride = 0
        }

        gaitSwing = isWalking ? sin(gaitPhase) : 0

        // Forward is (-sin h, -cos h), so increasing heading turns left.
        if currentAction == .turnLeft {
            output.heading += 0.90 * dt
        } else if currentAction == .turnRight {
            output.heading -= 0.90 * dt
        }

        output.crouch = (
            currentAction == .crouch ||
            currentAction == .crawl
        ) ? 1.0 : 0.0

        if currentAction == .recover {
            output.lean = 0
        }
    }

    // MARK: - Reward and Status

    private func calculateReward(
        terrain: FrankensteinTerrainSample
    ) -> Float {
        if body.fallen { return -1.0 }
        if jumpInProgress { return 0.05 }
        if stepUpInProgress || stepDownInProgress { return 0.1 }

        var reward: Float = -0.05

        let isTurning =
            currentAction == .turnLeft ||
            currentAction == .turnRight

        let pathOpen =
            terrain.terrain == .flat ||
            terrain.terrain == .slope ||
            terrain.terrain == .uneven

        if isTurning && pathOpen {
            reward -= 0.15
        }

        if currentAction == .backward && pathOpen {
            reward -= 0.10
        }

        return reward
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
        if stepUpInProgress {
            return "Stepping up"
        }
        if stepDownInProgress {
            return "Stepping down"
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
            return "CA: \(caCommandName)"
        default:
            return "Unknown terrain — assessing environment"
        }
    }

    // MARK: - Policy Feedback Adapter

    func reportJumpOutcome(
        succeeded: Bool,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool = false
    ) {
        _ = policy.reportJumpOutcome(
            succeeded: succeeded,
            terrain: terrain,
            body: body,
            nextActions: perceivedAllowedActions,
            terminal: terminal
        )
    }

    // MARK: - Reset

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
        actionDisplacement = 0
        lastActualDisplacement = 0

        gaitPhase = 0
        gaitSwing = 0
        isWalking = false

        stepStartHeight = 0
        stepTargetHeight = 0
        stepTransitionProgress = 1
        stepUpInProgress = false
        stepDownInProgress = false
        stepTransitionLatched = false

        caCommandName = "Walk"
        caLeftActivity = 0
        caRightActivity = 0
        caCenterActivity = 0
        lastCACommand = .walk

        // Reset objective progress for a new episode.
        goalStage = .exploreRoom
        goalDescription =
            "Explore the room and find an object that can help reach the red platform."

        usefulObjectName = nil
        usefulObjectMoved = false
        objectPlacedAsStep = false
        redPlatformReached = false
        chargingStationReached = false

        recoveryElapsed = 0
        lastSafetyOverride = ""
        lastLoggedDecision = ""

        // Deliberately preserve learned policy Q-values.
    }
}
