import Foundation
import SceneKit
import simd

final class FrankensteinLocomotion {
    
    private var goalObservation: FrankensteinGoalObservation?
    
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

    private let maximumJumpOntoRise: Float = 1.0
    private let minimumJumpSpeed_onto: Float = 0.6

    private var activeJumpSpeed: Float = 1.3

    private let pushWalkSpeed: Float = 0.5
    private var pushDisplacementReport: Float = 0
    private let maximumJumpDuration: Float = 3.0

    // MARK: - Word Spelling / Full Charge Behavior
    var isFullyCharged: Bool {
        rechargesCompleted > 0 || (ca?.outcomesObserved ?? 0) > 3
    }

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
    private(set) var rechargesCompleted = 0

    func completeEpisode(_ result: FrankensteinEpisodeEnd) {
        guard pendingEpisodeEnd == nil else { return }

        pendingEpisodeEnd = result
        episodes += 1

        switch result {
        case .reachedGoal:
            goalsReached += 1

        case .recharged:
            rechargesCompleted += 1
            goalsReached += 1

        case .fell:
            falls += 1
            body.fallen = true
        }
    }

    func reportCollision() {
        collisions += 1

        policy.learn(
            reward: -1.0,
            terrain: currentTerrainForFeedback,
            body: body,
            terminal: false,
            objectObservation: currentObjectObservation
        )
    }

    func reportPickupOutcome(succeeded: Bool) {
        guard policy.isAwaitingOutcome else { return }
        _ = policy.learn(
            reward: succeeded ? 0.8 : -0.8,
            terrain: currentTerrainForFeedback,
            body: body,
            terminal: false,
            objectObservation: currentObjectObservation
        )
    }

    func reportObjectActionOutcome(_ action: FrankensteinAction, reward: Float) {
        guard policy.isAwaitingOutcome else { return }
        let boundedReward = min(2.0, max(-2.0, reward))
        _ = policy.learn(
            reward: boundedReward,
            terrain: currentTerrainForFeedback,
            body: body,
            terminal: false,
            objectObservation: currentObjectObservation
        )
    }

    func reportRecharge() {
        guard policy.isAwaitingOutcome else { return }
        _ = policy.learn(
            reward: 2.0,
            terrain: currentTerrainForFeedback,
            body: body,
            terminal: false,
            objectObservation: currentObjectObservation
        )
    }

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
    private var currentObjectObservation: FrankensteinObjectObservation?
    private(set) var hasCarriedObject = false

    func setCarryingObject(_ carrying: Bool) {
        hasCarriedObject = carrying
    }

    func receivePerception(
        allowedActions: [FrankensteinAction],
        qValues: [FrankensteinAction: Float]
    ) {
        policy.updatePerceivedActionValues(
            allowedActions: allowedActions,
            qValues: qValues
        )
    }

    func setGoalObservation(_ observation: FrankensteinGoalObservation?) {
        goalObservation = observation
    }

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

        policy.learn(
            reward: success ? 3.0 : -2.0,
            terrain: currentTerrainForFeedback,
            body: body,
            terminal: false,
            objectObservation: currentObjectObservation
        )
    }

    @discardableResult
    func step(
        deltaTime: Float,
        terrain: FrankensteinTerrainSample,
        actualDisplacement: Float? = nil,
        objectObservation: FrankensteinObjectObservation? = nil
    ) -> FrankensteinLocomotionOutput {

        let dt = min(max(deltaTime, 0), maximumDeltaTime)
        guard dt > 0 else { return output }
        
        setGoalObservation(goalObservation)

        currentTerrainForFeedback = terrain
        currentObjectObservation = objectObservation
        
        output.liftRequested = false
        output.placeRequested = false
        output.throwRequested = false
        output.pushRequested = false

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

        if !jumpInProgress &&
           !stepUpInProgress &&
           !stepDownInProgress {
            selectMovement(for: terrain, objectObservation: objectObservation)
        }

        output.action = currentAction
        output.liftRequested = currentAction == .liftObject
        output.placeRequested = currentAction == .placeObject
        output.throwRequested = currentAction == .throwObject
        output.pushRequested = currentAction == .pushObject
        output.moveDirection = 1

        updateMovement(deltaTime: dt, terrain: terrain)
        updateJump(deltaTime: dt, terrain: terrain)
        updateStepTransition(deltaTime: dt)
        updateAnimation(deltaTime: dt)
        stabilize(terrain: terrain)

        output.reward = calculateReward(terrain: terrain)
        if actionElapsed >= 0.35, policy.isAwaitingOutcome, output.reward.isFinite {
            var completedReward = output.reward + min(0.5, max(-0.5, lastActualDisplacement * 2.0))

            if currentAction == .pushObject {
                completedReward += min(0.8, max(-0.4, pushDisplacementReport * 3.0 - 0.1))
                pushDisplacementReport = 0
            }

            _ = policy.learn(
                reward: completedReward,
                terrain: terrain,
                body: body,
                terminal: false,
                objectObservation: objectObservation
            )
            actionElapsed = 0
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
        
        // MARK: - Fully Charged Word Spelling Behavior Override
      

        let caActionName = caCommandName
        let qLearningActionName = policy.pendingAction.map { String(describing: $0) } ?? "Q-values advisory only"
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
    }

    @discardableResult
    func step(
        deltaTime: Float,
        terrain: FrankensteinTerrainSample,
        feedback: FrankensteinMotionFeedback,
        objectObservation: FrankensteinObjectObservation? = nil
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
            actualDisplacement: measuredDisplacement,
            objectObservation: objectObservation
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

    private func selectMovement(
        for terrain: FrankensteinTerrainSample,
        objectObservation: FrankensteinObjectObservation?
    ) {
        lastSafetyOverride = "none"

        if body.fallen {
            lastSafetyOverride = "recovery is the only permitted action"
        }

        let candidates: [FrankensteinAction] = body.fallen
            ? [.recover]
            : policy.allowedActions(
                terrain: terrain,
                body: body,
                objectObservation: objectObservation,
                hasCarriedObject: hasCarriedObject
            )
        let qValues = policy.learnedActionValues(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation
        )
        let proposedAction = ca?.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: candidates,
            qValues: qValues,
            exploration: 0.12
        ) ?? fallbackCAAction(from: candidates)

        caCommandName = String(describing: proposedAction)
        let chosen = candidates.contains(proposedAction) ? proposedAction : fallbackCAAction(from: candidates)
        currentAction = chosen

        if !policy.isAwaitingOutcome {
            _ = policy.beginCAChosenAction(
                chosen,
                terrain: terrain,
                body: body,
                objectObservation: objectObservation
            )
        } else if policy.pendingAction != chosen {
            if let pending = policy.pendingAction,
               candidates.contains(pending),
               actionElapsed < 0.35 {
                currentAction = pending
                lastSafetyOverride = "CA commitment held until its outcome is recorded"
            } else {
                policy.resetEpisode()
                actionElapsed = 0
                _ = policy.beginCAChosenAction(
                    chosen,
                    terrain: terrain,
                    body: body,
                    objectObservation: objectObservation
                )
                lastSafetyOverride = "CA decision replaced a commitment that was no longer permitted"
            }
        }
    }

    private func fallbackCAAction(from candidates: [FrankensteinAction]) -> FrankensteinAction {
        if candidates.contains(.walk) { return .walk }
        if candidates.contains(.turnLeft) { return .turnLeft }
        if candidates.contains(.turnRight) { return .turnRight }
        return candidates.first ?? .walk
    }

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
            requestedSpeed = 0

        case .jump:
            requestedSpeed = activeJumpSpeed

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

        case .backward:
            requestedSpeed = -0.5

        case .stepForward:
            requestedSpeed = 0.5

        case .pushObject:
            requestedSpeed = pushWalkSpeed

        case .recover,
             .liftObject,
             .placeObject,
             .throwObject:
            requestedSpeed = 0
        }

        var speed = requestedSpeed

        let validDistance =
            terrain.distance.isFinite &&
            terrain.distance >= 0

        if !jumpInProgress,
           terrain.terrain == .hurdle,
           validDistance,
           terrain.distance < 0.8,
           currentAction != .backward,
           currentAction != .turnLeft,
           currentAction != .turnRight {
            speed = min(speed, 0.25)
        }

        if terrain.terrain == .gap {
            let hasValidWidth =
                terrain.gapWidth.isFinite &&
                terrain.gapWidth > 0

            let safeLanding =
                terrain.isLandingAreaClear &&
                hasValidWidth

            let isMovingTowardGap =
                currentAction == .walk ||
                currentAction == .run ||
                currentAction == .stepForward ||
                currentAction == .crawl ||
                currentAction == .roll ||
                currentAction == .stepUp

            if !jumpInProgress &&
               isMovingTowardGap &&
               !safeLanding {
                speed = 0
            }

            if currentAction == .jump && !jumpInProgress {
                if !safeLanding {
                    speed = 0
                }
            }
        }

        if currentAction == .jump && !jumpInProgress {
            beginJump(terrain: terrain)
        }

        if currentAction == .stepUp,
           !stepUpInProgress,
           !stepDownInProgress,
           !stepTransitionLatched {

            let rise = terrain.obstacleHeight
            let validRise =
                rise.isFinite &&
                rise > 0 &&
                rise <= maximumStepUpHeight

            let obstacleIsRelevant =
                terrain.distance.isFinite &&
                terrain.distance >= 0 &&
                terrain.distance < 1.0

            if validRise && obstacleIsRelevant {
                beginStepTransition(to: body.height + rise)
                stepTransitionLatched = true
            } else {
                speed = 0
            }
        }

        if currentAction == .stepDown,
           !stepDownInProgress,
           !stepUpInProgress,
           !stepTransitionLatched {

            let drop = terrain.obstacleHeight
            let validDrop =
                drop.isFinite &&
                drop > 0 &&
                terrain.distance.isFinite &&
                terrain.distance >= 0 &&
                terrain.distance < 1.0

            if validDrop {
                beginStepTransition(
                    to: max(0, body.height - drop)
                )
                stepTransitionLatched = true
            } else {
                speed = 0
            }
        }

        output.speed = speed
        output.action = currentAction
    }

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

    private func beginJump(terrain: FrankensteinTerrainSample) {
            guard grounded, !jumpInProgress, !body.fallen else { return }
            
            // Strict landing verification check
            if terrain.terrain == .hurdle || terrain.terrain == .raisedStep {
                guard terrain.isLandingAreaClear || terrain.canLandOnObject else {
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
                      terrain.gapFarEdgeDistance > terrain.gapNearEdgeDistance else {
                    currentAction = .walk
                    output.action = .walk
                    output.speed = 0
                    output.jump = 0
                    output.status = "Gap detected — landing not verified"
                    return
                }
            }
            // ... proceeding with jump setup
        }

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
        output.speed = activeJumpSpeed
        output.action = .jump
        output.lean = verticalVelocity > 0 ? 0.12 : -0.05

        if jumpElapsed > maximumJumpDuration {
            _ = confirmJumpFailure(
                forwardError: jumpTargetDistance - actualJumpDistance,
                heightError: max(0, jumpTargetHeight - body.height)
            )
        }
    }

    var jumpIsDescending: Bool {
        jumpInProgress && verticalVelocity <= 0
    }

    var jumpTravelledDistance: Float {
        actualJumpDistance
    }

    var jumpRiseSoFar: Float {
        max(0, body.height - jumpStartHeight)
    }

    func reportPushProgress(_ metres: Float) {
        guard metres.isFinite else { return }
        pushDisplacementReport = metres
    }

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
    }
}
