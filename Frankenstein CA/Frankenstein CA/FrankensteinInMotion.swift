
import Foundation
import SceneKit
import simd





// MARK: - Locomotion

final class FrankensteinLocomotion {
    
    private let recoveryDuration: Float = 0.6

    // MARK: - Learning

    let policy = FrankensteinLearningPolicy()

    // MARK: - Cellular Automaton Controller
 
    private var ca: FrankensteinCA?

    /// Attach the exact CA instance used by FrankensteinSceneView.
    func attachCA(_ ca: FrankensteinCA) {
        self.ca = ca
    }

    /// Diagnostics for the active CA-derived movement command.
    private(set) var caCommandName = "Walk"
    private(set) var lastSafetyOverride = ""
    private(set) var caLeftActivity = 0
    private(set) var caRightActivity = 0
    private(set) var caCenterActivity = 0

    private var lastCACommand: FrankensteinCACommand = .walk

    /// Convert the live CA grid into a movement command.
    ///
    /// Left-side activity biases left turns.
    /// Right-side activity biases right turns.
    /// Concentrated center activity can request running.
    /// Environmental hazard rules take precedence over these commands.
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

        // Require a meaningful imbalance so tiny differences
        // do not cause constant direction changes.
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
    private(set) var isWalking: Bool = false

    // MARK: - Movement Configuration

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
    private var actionElapsed: Float = 0
    private var recoveryElapsed: Float = 0
    private var lastActualDisplacement: Float = 0

    // MARK: - Episode State

    private(set) var pendingEpisodeEnd: FrankensteinEpisodeEnd?

    private(set) var episodes = 0
    private(set) var actionsCompleted = 0
    private(set) var collisions = 0
    private(set) var falls = 0
    private(set) var goalsReached = 0

    // MARK: - Episode Completion

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

    // MARK: - Collision Feedback

    func reportCollision() {
        collisions += 1

        // Let the learner receive negative feedback for a collision.
        policy.recordCompletedAction(
            reward: -1.0,
            terrain: currentTerrainForFeedback,
            body: body,
            terminal: false
        )
    }
    // MARK: - Movement Diagnostics

    private func logDecision(
        caGeneration: Int,
        liveCells: Int,
        caRequestedAction: String,
        qLearningAction: String,
        finalAction: String,
        safetyOverride: String
    ) {
        print("[CA] Generation: \(caGeneration), Live cells: \(liveCells)")
        print("[CA] Requested action: \(caRequestedAction)")
        print("[Q-Learning] Suggested action: \(qLearningAction)")
        print("[Safety] Override: \(safetyOverride)")
        print("[Movement] Applied action: \(finalAction)")
    }
    private var currentTerrainForFeedback = FrankensteinTerrainSample()

    // MARK: - Adaptive Jump Feedback

    func reportJumpOutcome(
        success: Bool,
        forwardError: Float = 0,
        heightError: Float = 0
    ) {
        guard jumpInProgress, !jumpOutcomeReported else { return }

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

        policy.recordCompletedAction(
            reward: success ? 3.0 : -2.0,
            terrain: currentTerrainForFeedback,
            body: body,
            terminal: false
        )
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

        currentTerrainForFeedback = terrain

        // Stop if the episode has ended.
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

        if !jumpInProgress &&
           !stepUpInProgress &&
           !stepDownInProgress {
            selectMovement(for: terrain)
        }
        
        // Record actual displacement.
        if let actualDisplacement,
           actualDisplacement.isFinite {
            lastActualDisplacement = actualDisplacement

            if jumpInProgress {
                actualJumpDistance += max(0, actualDisplacement)
            }
        }

        actionElapsed += dt

        if terrain.terrain != .raisedStep {
            stepTransitionLatched = false
        }

        // Select movement unless a jump or step transition is active.
        if !jumpInProgress &&
           !stepUpInProgress &&
           !stepDownInProgress {
            selectMovement(for: terrain)
        }

        // Update locomotion and animation.
        updateMovement(deltaTime: dt, terrain: terrain)
        updateJump(deltaTime: dt, terrain: terrain)
        updateStepTransition(deltaTime: dt)
        updateAnimation(deltaTime: dt)
        stabilize(terrain: terrain)

        // Calculate and record reward.
        output.reward = calculateReward(terrain: terrain)

        if output.reward.isFinite {
            policy.recordCompletedAction(
                reward: output.reward,
                terrain: terrain,
                body: body,
                terminal: false
            )
        }

        // Preserve important failure statuses.
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
                performRecovery()  // Called here
            }

            return output
        }
        

        let caActionName = caCommandName
        let qLearningActionName = String(describing: currentAction)
        let safetyOverrideName = lastSafetyOverride
        let finalActionName = String(describing: output.action)

        logDecision(
            caGeneration: ca?.generation ?? 0,
            liveCells: ca?.liveCellCount ?? 0,
            caRequestedAction: caActionName,
            qLearningAction: qLearningActionName,
            finalAction: finalActionName,
            safetyOverride: safetyOverrideName
        )

        return output
    }
   
    // MARK: - Horizontal Movement

    private func updateMovement(
        deltaTime dt: Float,
        terrain: FrankensteinTerrainSample
    ) {
        guard dt.isFinite, dt > 0 else {
            output.speed = 0
            output.action = currentAction
            return
        }

        // Keep movement output synchronized with the final selected action.
        var executedAction = currentAction
        var speed: Float = 0

        // 1. Safety validation before applying movement.
        switch terrain.terrain {

        case .gap:
            let safeGap =
                terrain.gapWidth > 0 &&
                terrain.gapWidth <= 1.8 &&
                terrain.isLandingAreaClear &&
                terrain.gapNearEdgeDistance.isFinite &&
                terrain.gapFarEdgeDistance.isFinite &&
                terrain.gapNearEdgeDistance >= 0 &&
                terrain.gapFarEdgeDistance >
                    terrain.gapNearEdgeDistance

            if !safeGap && !jumpInProgress {
                // Never allow a walk/run command to cross an
                // unverified gap.
                if executedAction != .turnLeft &&
                    executedAction != .turnRight {
                    executedAction = .turnLeft
                    lastSafetyOverride =
                        "unsafe gap — forward movement blocked"
                }
            }

        case .hurdle:
            let height = terrain.obstacleHeight

            if !jumpInProgress &&
                height > 0.35 &&
                (height > 0.75 ||
                 !terrain.isLandingAreaClear) {
                // Do not walk or jump into an unsafe hurdle.
                if executedAction != .turnLeft &&
                    executedAction != .turnRight {
                    executedAction = .turnLeft
                    lastSafetyOverride =
                        "unsafe hurdle — forward movement blocked"
                }
            }

        case .lowCeiling:
            if executedAction != .turnLeft &&
                executedAction != .turnRight {
                executedAction = .crouch
                lastSafetyOverride = "low ceiling — crouching"
            }

        case .raisedStep:
            let validStep =
                terrain.obstacleHeight > 0 &&
                terrain.obstacleHeight <= maximumStepUpHeight

            if executedAction == .stepUp && !validStep {
                executedAction = .turnLeft
                lastSafetyOverride =
                    "invalid step height — step-up blocked"
            }

        case .flat, .slope, .uneven:
            break

        default:
            // Unknown terrain must not allow blind forward movement.
            if executedAction == .walk ||
                executedAction == .run ||
                executedAction == .jump {
                executedAction = .turnLeft
                lastSafetyOverride =
                    "unknown terrain — forward movement blocked"
            }
        }

        // 2. Determine speed from the action that will actually run.
        switch executedAction {
        case .walk:
            speed = 1.0

        case .run:
            speed = 2.2

        case .turnLeft, .turnRight:
            speed = 0.65

        case .jump:
            speed = jumpForwardSpeed

        case .crouch:
            speed = 0.45

        case .crawl:
            speed = 0.35

        case .roll:
            speed = 1.1

        case .stepUp:
            speed = stepUpSpeed

        case .stepDown:
            speed = stepDownSpeed

        case .recover:
            speed = 0
        }

        // Stop forward movement at unsafe gaps, but preserve
            // turning speed so Frankenstein can turn away.
            if !jumpInProgress &&
                terrain.terrain == .gap {

                let safeGap =
                    terrain.gapWidth > 0 &&
                    terrain.gapWidth <= 1.8 &&
                    terrain.isLandingAreaClear &&
                    terrain.gapNearEdgeDistance.isFinite &&
                    terrain.gapFarEdgeDistance.isFinite &&
                    terrain.gapNearEdgeDistance >= 0 &&
                    terrain.gapFarEdgeDistance >
                        terrain.gapNearEdgeDistance

                let isForwardAction =
                    executedAction == .walk ||
                    executedAction == .run ||
                    executedAction == .jump

                if !safeGap && isForwardAction {
                    speed = 0
                }
            }
        
       

        // 4. Final gap guard. A walk/run action must never move
        // forward when the landing or gap measurements are unsafe.
        if !jumpInProgress &&
            terrain.terrain == .gap {

            let safeGap =
                terrain.gapWidth > 0 &&
                terrain.gapWidth <= 1.8 &&
                terrain.isLandingAreaClear &&
                terrain.gapNearEdgeDistance.isFinite &&
                terrain.gapFarEdgeDistance.isFinite &&
                terrain.gapNearEdgeDistance >= 0 &&
                terrain.gapFarEdgeDistance >
                    terrain.gapNearEdgeDistance

            if !safeGap {
                speed = 0
            }

            if executedAction == .walk ||
                executedAction == .run {
                speed = 0
            }
        }

        // 5. Commit action and speed together so diagnostics report
        // the action used to calculate the movement output.
        currentAction = executedAction
        output.action = executedAction
        output.speed = max(0, speed)

        // 6. Start jump physics only when the final action is jump.
        if executedAction == .jump && !jumpInProgress {
            if terrain.terrain == .gap {
                let safeGap =
                    terrain.gapWidth > 0 &&
                    terrain.gapWidth <= 1.8 &&
                    terrain.isLandingAreaClear &&
                    terrain.gapNearEdgeDistance.isFinite &&
                    terrain.gapFarEdgeDistance.isFinite &&
                    terrain.gapNearEdgeDistance >= 0 &&
                    terrain.gapFarEdgeDistance >
                        terrain.gapNearEdgeDistance

                if safeGap {
                    beginJump(terrain: terrain)
                } else {
                    currentAction = .turnLeft
                    output.action = .turnLeft
                    output.speed = 0
                    lastSafetyOverride =
                        "unsafe gap — jump cancelled"
                }
            } else if terrain.terrain == .hurdle {
                if terrain.obstacleHeight > 0.35 &&
                    terrain.obstacleHeight <= 0.75 &&
                    terrain.isLandingAreaClear {
                    beginJump(terrain: terrain)
                } else {
                    currentAction = .turnLeft
                    output.action = .turnLeft
                    output.speed = 0
                    lastSafetyOverride =
                        "unsafe hurdle — jump cancelled"
                }
            } else {
                beginJump(terrain: terrain)
            }
        }

        // 7. Start a step transition only for a valid raised step.
        if executedAction == .stepUp &&
            !stepUpInProgress &&
            !stepDownInProgress &&
            !stepTransitionLatched &&
            terrain.terrain == .raisedStep {

            let rise = terrain.obstacleHeight

            if rise > 0 &&
                rise <= maximumStepUpHeight {
                beginStepTransition(to: body.height + rise)
                stepTransitionLatched = true
            } else {
                currentAction = .turnLeft
                output.action = .turnLeft
                output.speed = 0
                lastSafetyOverride =
                    "invalid step height — transition cancelled"
            }
        }

        print("[Movement] Applied action: \(output.action)")
        print("[Movement] Applied speed: \(output.speed)")
        print("[Safety] Override: \(lastSafetyOverride)")
    }

    private func performRecovery() {
        // Clear the fallen condition using the actual body property.
        body.fallen = false

        // Stop vertical movement using locomotion's own physics state.
        verticalVelocity = 0
        grounded = true

        // End any unfinished jump.
        jumpInProgress = false
        jumpOutcomeReported = true
        jumpElapsed = 0
        actualJumpDistance = 0

        // Cancel unfinished step transitions.
        stepUpInProgress = false
        stepDownInProgress = false
        stepTransitionProgress = 1
        stepTransitionLatched = false

        // Reset recovery timing and prepare for normal movement.
        recoveryElapsed = 0
        actionElapsed = 0
        currentAction = .walk

        // Clear residual movement output.
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
            let forwardX = sin(heading)
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
    //
    // Environmental safety takes priority. The CA controls ordinary
    // movement decisions on safe terrain.

 
    // MARK: - Action Selection
    //
    // One decision per call:
    // 1. Apply mandatory safety rules.
    // 2. Read the CA command.
    // 3. Pass the CA preference into Q-learning.
    // 4. Validate the selected action.
    // 5. Assign the final action to currentAction.
    //
    // The caller must not invoke this method twice for the same
    // decision cycle.

    private func selectMovement(
        for terrain: FrankensteinTerrainSample
    ) {
        lastSafetyOverride = "none"

        // 1. Recovery always takes priority.
        if body.fallen {
            currentAction = .recover
            lastSafetyOverride = "recovery required"
            return
        }

        // Do not interrupt an active jump or step transition.
        if jumpInProgress ||
            stepUpInProgress ||
            stepDownInProgress {
            return
        }

        // 2. Determine whether this terrain requires mandatory
        // safety handling before ordinary movement is selected.
        switch terrain.terrain {

        case .gap:
            let gapIsVerified =
                terrain.gapWidth > 0 &&
                terrain.gapWidth <= 1.8 &&
                terrain.isLandingAreaClear &&
                terrain.gapNearEdgeDistance.isFinite &&
                terrain.gapFarEdgeDistance.isFinite &&
                terrain.gapNearEdgeDistance >= 0 &&
                terrain.gapFarEdgeDistance >
                    terrain.gapNearEdgeDistance

            if !gapIsVerified {
                // Never walk or run into an unverified gap.
                let turn = policy.choose(
                    terrain: terrain,
                    body: body
                )

                currentAction =
                    turn == .turnRight ? .turnRight : .turnLeft

                lastSafetyOverride =
                    "unsafe gap — forward movement blocked"
                return
            }

            // The policy can choose jump or a safe turn.
            let selected = policy.choose(
                terrain: terrain,
                body: body
            )

            if selected == .jump ||
                selected == .turnLeft ||
                selected == .turnRight {
                currentAction = selected
            } else {
                currentAction = .turnLeft
                lastSafetyOverride =
                    "gap — rejected unsafe action \(selected)"
            }
            return

        case .hurdle:
            let height = terrain.obstacleHeight

            if height <= 0 || height > 0.75 {
                // Do not jump over an invalid or oversized hurdle.
                let selected = policy.choose(
                    terrain: terrain,
                    body: body
                )

                if selected == .turnLeft ||
                    selected == .turnRight {
                    currentAction = selected
                } else {
                    currentAction = .turnLeft
                }

                lastSafetyOverride =
                    "hurdle outside safe jump height"
                return
            }

            if height > 0.35 &&
                !terrain.isLandingAreaClear {
                currentAction = .turnLeft
                lastSafetyOverride =
                    "landing not clear — jump blocked"
                return
            }

            // Small hurdles may be walked over; taller permitted
            // hurdles require a jump or a deliberate turn.
            let selected = policy.choose(
                terrain: terrain,
                body: body
            )

            if height > 0.35 {
                if selected == .turnLeft ||
                    selected == .turnRight {
                    currentAction = selected
                } else {
                    currentAction = .jump
                }
            } else {
                currentAction = selected
            }
            return

        case .lowCeiling:
            let selected = policy.choose(
                terrain: terrain,
                body: body
            )

            if selected == .turnLeft ||
                selected == .turnRight {
                currentAction = selected
            } else {
                currentAction = .crouch
            }

            if currentAction == .crouch {
                lastSafetyOverride = "low ceiling — crouching"
            }
            return

        case .raisedStep:
            let height = terrain.obstacleHeight

            if height <= 0 ||
                height > maximumStepUpHeight ||
                !terrain.isGroundAhead {
                let selected = policy.choose(
                    terrain: terrain,
                    body: body
                )

                if selected == .turnLeft ||
                    selected == .turnRight {
                    currentAction = selected
                } else {
                    currentAction = .walk
                }

                lastSafetyOverride =
                    "step-up conditions not satisfied"
                return
            }

            if stepTransitionLatched {
                currentAction = .walk
                return
            }

            let selected = policy.choose(
                terrain: terrain,
                body: body
            )

            if selected == .stepUp ||
                selected == .jump ||
                selected == .turnLeft ||
                selected == .turnRight {
                currentAction = selected
            } else {
                currentAction = .stepUp
            }
            return

        case .unknown:
            // Unknown terrain must never inherit a CA run/walk
            // command without a verified path.
            let selected = policy.choose(
                terrain: terrain,
                body: body
            )

            currentAction =
                selected == .turnRight ? .turnRight : .turnLeft

            lastSafetyOverride =
                "unknown terrain — forward movement blocked"
            return

        case .flat, .slope, .uneven:
            break
        }

        // 3. Read the live CA and translate its command into a
        // preference understood by the Q-learning policy.
        let caCommand = readCACommand()

        let preferredAction: FrankensteinAction

        switch caCommand {
        case .walk:
            preferredAction = .walk
        case .run:
            preferredAction = .run
        case .turnLeft:
            preferredAction = .turnLeft
        case .turnRight:
            preferredAction = .turnRight
        }

        // 4. The policy now receives the CA preference as input.
        let selectedAction = policy.choose(
            terrain: terrain,
            body: body,
            preferredAction: preferredAction
        )

        // 5. Validate the action against the policy's allowed set.
        let allowed = policy.allowedActions(
            terrain: terrain,
            body: body
        )

        if allowed.contains(selectedAction) {
            currentAction = selectedAction
        } else {
            // Safe fallback: do not execute a rejected action.
            currentAction = .turnLeft
            lastSafetyOverride =
                "policy action rejected: \(selectedAction)"
        }

        print("[CA] Requested action: \(caCommand)")
        print("[Q-Learning] Selected action: \(selectedAction)")
        print("[Safety] Override: \(lastSafetyOverride)")
        print("[Movement] Final action: \(currentAction)")
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
        guard stepUpInProgress || stepDownInProgress else { return }

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
        guard grounded, !jumpInProgress, !body.fallen else { return }
        
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
        guard jumpInProgress, !jumpOutcomeReported else { return false }

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

        if terrain.terrain == .lowCeiling {
            output.crouch = 1.0
            output.speed = min(output.speed, 0.45)
        } else {
            output.crouch = currentAction == .crouch ? 1.0 : 0.0
        }

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

        // A CA-selected turn changes the heading that the Coordinator
        // reads when it computes the next frame's forward vector.
        if currentAction == .turnLeft {
            output.heading -= 0.90 * dt
        } else if currentAction == .turnRight {
            output.heading += 0.90 * dt
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
        if terrain.terrain == .flat { return 0.1 }
        return 0
    }

    private func statusDescription(
        terrain: FrankensteinTerrainSample
    ) -> String {
        if body.fallen { return "Fallen — recovery required" }
        if jumpInProgress { return "Jumping — adaptive attempt \(jumpAttempts + 1)" }
        if stepUpInProgress { return "Stepping up" }
        if stepDownInProgress { return "Stepping down" }

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
        let reward: Float = succeeded ? 3.0 : -2.0

        policy.recordCompletedAction(
            reward: reward,
            terrain: terrain,
            body: body,
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

        // Keep learned policy data across episode resets.
    }
}
