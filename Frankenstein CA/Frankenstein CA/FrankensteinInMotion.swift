
import Foundation
import SceneKit

/// Why an attempt at the course ended.
enum FrankensteinEpisodeEnd {
    case reachedGoal
    case fell
}

/// Chooses a movement skill with the Q policy, runs it to completion against
/// the real body, judges the result from what physically happened, and
/// reports it once. The policy is the only thing that decides what to do;
/// nothing here maps a terrain type to a fixed action.
final class FrankensteinLocomotion {

    private typealias B = FrankensteinPhysicalBody

    // MARK: - Existing project interfaces

    let policy: FrankensteinLearningPolicy

    private(set) var body = FrankensteinBodyState()
    private(set) var output = FrankensteinLocomotionOutput()

    /// Measures each attempt and sends one reward to `policy`.
    let learning: FrankensteinStage1Learning

    // MARK: - Progress and statistics

    private(set) var pendingEpisodeEnd: FrankensteinEpisodeEnd?
    private(set) var episodes = 1
    private(set) var goalsReached = 0
    private(set) var falls = 0
    private(set) var collisions = 0
    private(set) var actionsCompleted = 0

    private(set) var jumpAttempts = 0
    private(set) var successfulJumps = 0
    private(set) var failedJumps = 0

    private(set) var lastActionSucceeded = false
    private(set) var lastReward: Double = 0

    var jumpInProgress: Bool { !body.grounded }

    var activeActionName: String {
        active.map { "\($0.action)" } ?? "choosing"
    }

    // MARK: - Private state

    private struct ActiveAction {
        var action: FrankensteinAction
        var startTerrain: FrankensteinTerrainSample
        var elapsed: Float = 0
        var moved: Float = 0
        var blockedTime: Float = 0
        var collided = false
        var jumpIssued = false
        var tookOff = false
        var landed = false
        var landedHorizontal: Float = 0
        var landedRise: Float = 0
        var steppedRise: Float = 0
    }

    private var active: ActiveAction?
    private var clock: TimeInterval = 0
    private var animationClock: Float = 0
    private var commandSpeed: Float = 0

    // Behaviour constants.
    private let turnRate: Float = 1.6
    private let jumpMinimumSpeed: Float = 1.2
    private let maximumDeltaTime: Float = 1.0 / 20.0

    init() {
        let sharedPolicy = FrankensteinLearningPolicy()
        policy = sharedPolicy
        learning = FrankensteinStage1Learning(policy: sharedPolicy)
    }

    // MARK: - Main update

    /// Advance one frame. `feedback` is what the body measurably did on the
    /// previous frame; without it the controller assumes it moved as asked.
    @discardableResult
    func step(
        deltaTime: Float,
        terrain: FrankensteinTerrainSample,
        actualDisplacement: Float? = nil,
        feedback: FrankensteinMotionFeedback? = nil
    ) -> FrankensteinLocomotionOutput {

        let dt = min(max(deltaTime, 0), maximumDeltaTime)

        guard dt > 0 else {
            return output
        }

        clock += TimeInterval(dt)
        animationClock += dt

        let fb = feedback ?? FrankensteinMotionFeedback.assumed(
            speed: commandSpeed,
            heading: output.heading,
            dt: dt
        )

        output.jumpRequested = false
        updateBody(with: fb, dt: dt)

        // Episode-ending events.
        var fell = false
        var reachedGoal = false

        for event in fb.events {
            switch event {
            case .fell:
                fell = true
            case .reachedGoal:
                reachedGoal = true
            case .collided:
                collisions += 1
            default:
                break
            }
        }

        let terminal = fell || reachedGoal

        // Choose a skill when none is running.
        if active == nil && !terminal {
            beginAction(terrain: terrain, fb: fb)
        }

        if var a = active {
            a.elapsed += dt
            a.moved += fb.movedDistance

            for event in fb.events {
                switch event {
                case .collided:
                    a.collided = true

                case .tookOff:
                    a.tookOff = true

                case .landed(_, let horizontal, let rise):
                    a.landed = true
                    a.landedHorizontal = horizontal
                    a.landedRise = rise

                case .steppedUp(let rise):
                    a.steppedRise = max(a.steppedRise, rise)

                default:
                    break
                }
            }

            if fb.blocked {
                a.blockedTime += dt
            } else {
                a.blockedTime = max(0, a.blockedTime - dt)
            }

            learning.observe(
                position: fb.position,
                observation: observation(
                    terrain: terrain,
                    fb: fb,
                    collided: fb.events.contains(.collided)
                ),
                deltaTime: TimeInterval(dt)
            )

            drive(&a, dt: dt, fb: fb)

            if terminal || isComplete(a, terrain: terrain, fb: fb) {
                finishAction(
                    a,
                    terrain: terrain,
                    fb: fb,
                    fell: fell,
                    reachedGoal: reachedGoal
                )
                active = nil

                // Keep the posture and speed continuous between skills.
                if !terminal {
                    beginAction(terrain: terrain, fb: fb)

                    if var next = active {
                        drive(&next, dt: 0, fb: fb)
                        active = next
                    }
                }
            } else {
                active = a
            }
        }

        if terminal {
            pendingEpisodeEnd = fell ? .fell : .reachedGoal

            if fell {
                falls += 1
            } else {
                goalsReached += 1
            }
        }

        updateAnimation(dt: dt, fb: fb)
        output.reward = fb.goalProgress
        output.status = statusDescription(fb: fb)

        return output
    }

    // MARK: - Body state

    private func updateBody(
        with fb: FrankensteinMotionFeedback,
        dt: Float
    ) {
        body.speed += (fb.speed - body.speed) * min(1, dt * 8)
        body.grounded = fb.grounded
        body.verticalVelocity = fb.verticalVelocity
        body.height = fb.bodyHeight
        body.distanceTravelled += fb.movedDistance
        body.headingError = wrap(output.heading)
    }

    private func observation(
        terrain: FrankensteinTerrainSample,
        fb: FrankensteinMotionFeedback,
        collided: Bool
    ) -> FrankensteinStage1Observation {
        FrankensteinStage1Observation(
            distanceToGoal: distanceToGoal(fb.position),
            obstacleDistance: terrain.distance,
            obstacleHeight: terrain.obstacleHeight,
            gapWidth: terrain.gapWidth,

            // Falls are confirmed by the physical body, not guessed from a
            // sensor while he is legitimately airborne over a gap.
            hasGroundAhead: true,
            isGrounded: fb.grounded,
            hasCollision: collided,
            landingAreaIsClear: terrain.isLandingAreaClear,
            currentHeight: fb.feetHeight,
            terrainType: String(describing: terrain.terrain)
        )
    }

    private func distanceToGoal(_ position: SCNVector3) -> Float {
        max(0, position.z - B.finishZ)
    }

    // MARK: - Beginning a skill

    private func beginAction(
        terrain: FrankensteinTerrainSample,
        fb: FrankensteinMotionFeedback
    ) {
        let action = policy.choose(terrain: terrain, body: body)

        active = ActiveAction(
            action: action,
            startTerrain: terrain
        )

        output.action = action

        if action == .jump {
            jumpAttempts += 1
        }

        learning.begin(
            skill: skill(for: action),
            position: fb.position,
            distanceToGoal: distanceToGoal(fb.position),
            time: clock
        )
    }

    private func skill(
        for action: FrankensteinAction
    ) -> FrankensteinStage1Skill {
        switch action {
        case .walk: return .walk
        case .run: return .run
        case .turnLeft, .turnRight: return .turn
        case .jump: return .jump
        case .crouch: return .crouch
        case .stepUp, .stepDown: return .stepUp
        case .roll: return .roll
        case .crawl: return .crawl
        case .recover: return .recover
        }
    }

    // MARK: - Driving the body

    private func drive(
        _ a: inout ActiveAction,
        dt: Float,
        fb: FrankensteinMotionFeedback
    ) {
        var targetSpeed: Float
        var posture: FrankensteinPosture = .standing

        switch a.action {
        case .walk:
            targetSpeed = B.walkSpeed

        case .run:
            targetSpeed = B.runSpeed

        case .turnLeft:
            targetSpeed = 0.8
            output.heading += turnRate * dt

        case .turnRight:
            targetSpeed = 0.8
            output.heading -= turnRate * dt

        case .jump:
            // Momentum is kept from the run-up, so how far he flies
            // depends on how fast he was going when he left the ground.
            targetSpeed = max(jumpMinimumSpeed, commandSpeed)

        case .crouch:
            targetSpeed = B.crouchSpeed
            posture = .crouching

        case .crawl:
            targetSpeed = B.crawlSpeed
            posture = .crawling

        case .roll:
            targetSpeed = B.rollSpeed
            posture = .rolling

        case .stepUp:
            targetSpeed = 1.2

        case .stepDown:
            targetSpeed = 1.0

        case .recover:
            targetSpeed = 0
        }

        if a.action == .jump && !a.jumpIssued && fb.grounded {
            output.jumpRequested = true
            a.jumpIssued = true
        }

        if a.action == .jump {
            // No steering of speed once the jump has begun.
            commandSpeed = targetSpeed
        } else {
            commandSpeed += (targetSpeed - commandSpeed) * min(1, dt * 5)
        }

        // A body that is forced low by geometry overhead keeps a low
        // posture, so the pose matches what the physics is doing.
        output.posture = effectivePosture(
            requested: posture,
            headroom: fb.headroom
        )

        output.rollProgress = a.action == .roll
            ? min(1, a.elapsed / B.rollDuration)
            : 0

        output.speed = commandSpeed
        output.action = a.action
    }

    /// A posture is only overridden when the space overhead really is too
    /// low for it. (Using the current body height here would latch him in
    /// a low posture forever after his first crawl.)
    private func effectivePosture(
        requested: FrankensteinPosture,
        headroom: Float
    ) -> FrankensteinPosture {
        if B.height(for: requested) <= headroom + 0.01 {
            return requested
        }

        return headroom >= B.crouchHeight - 0.01
            ? .crouching
            : .crawling
    }

    // MARK: - Completion

    private func isComplete(
        _ a: ActiveAction,
        terrain: FrankensteinTerrainSample,
        fb: FrankensteinMotionFeedback
    ) -> Bool {
        switch a.action {
        case .walk, .run:
            if a.elapsed >= 0.6 { return true }
            if a.blockedTime >= 0.25 { return true }

            // Decide again when a feature gets close, so a takeoff or a
            // turn happens near it and not a whole stride too early.
            let threshold = max(0.45, fb.speed * 0.3 + 0.2)

            if a.elapsed >= 0.12,
               terrain.terrain != .flat,
               terrain.distance < threshold,
               a.startTerrain.distance > threshold + 0.1 {
                return true
            }

            return false

        case .turnLeft, .turnRight:
            return a.elapsed >= 0.45 || a.blockedTime >= 0.3

        case .crouch:
            return a.elapsed >= 0.8 || a.blockedTime >= 0.3

        case .crawl:
            return a.elapsed >= 1.2 || a.blockedTime >= 0.3

        case .roll:
            return a.elapsed >= B.rollDuration || a.blockedTime >= 0.25

        case .recover:
            return a.elapsed >= 0.5

        case .stepDown:
            return a.elapsed >= 0.6

        case .stepUp:
            let rise = a.startTerrain.obstacleHeight

            if a.startTerrain.terrain == .raisedStep,
               rise > 0.1,
               a.steppedRise >= 0.8 * rise {
                return true
            }

            return a.elapsed >= 1.1 || a.blockedTime >= 0.3

        case .jump:
            if !a.tookOff {
                return a.elapsed >= 0.3
            }

            return a.landed || a.elapsed >= 3.0
        }
    }

    private func finishAction(
        _ a: ActiveAction,
        terrain: FrankensteinTerrainSample,
        fb: FrankensteinMotionFeedback,
        fell: Bool,
        reachedGoal: Bool
    ) {
        var bonus: Float = 0
        var success = false

        if reachedGoal {
            bonus = 10
            success = true
        } else if !fell {
            let result = outcome(a, terrain: terrain, fb: fb)
            bonus = result.bonus
            success = result.success
        }

        let attempt = learning.finish(
            finalPosition: fb.position,
            finalDistanceToGoal: distanceToGoal(fb.position),
            confirmedFall: fell,
            terrain: terrain,
            body: body,
            time: clock,
            bonus: Double(bonus)
        )

        lastReward = attempt?.reward ?? 0
        lastActionSucceeded = success && !(attempt?.blocked ?? false)
        actionsCompleted += 1

        if a.action == .jump {
            if success {
                successfulJumps += 1
            } else {
                failedJumps += 1
            }
        }
    }

    /// Success or failure of a finished skill, judged from what the body
    /// actually did, expressed as an extra reward on top of the measured
    /// progress, collision and fall terms.
    private func outcome(
        _ a: ActiveAction,
        terrain: FrankensteinTerrainSample,
        fb: FrankensteinMotionFeedback
    ) -> (bonus: Float, success: Bool) {
        let start = a.startTerrain
        let radius = B.radius

        switch a.action {
        case .jump:
            guard a.tookOff else { return (-0.3, false) }
            guard a.landed else { return (-0.5, false) }

            switch start.terrain {
            case .gap:
                // The centre of his body has to end up past the far edge.
                let needed = start.distance + radius + start.gapWidth

                if a.landedHorizontal >= needed - 0.1 {
                    return (3.0, true)
                }

                return (-0.3, false)

            case .hurdle:
                let needed = start.distance + radius + start.obstacleDepth

                if a.landedHorizontal >= needed - 0.1 {
                    return (2.5, true)
                }

                if a.landedRise >= 0.8 * start.obstacleHeight {
                    return (1.0, true)
                }

                return (-0.3, false)

            case .raisedStep:
                if a.landedRise >= 0.8 * start.obstacleHeight {
                    return (2.0, true)
                }

                return (-0.2, false)

            default:
                return (-0.15, false)
            }

        case .stepUp:
            if start.terrain == .raisedStep, start.obstacleHeight > 0.1 {
                return a.steppedRise >= 0.8 * start.obstacleHeight
                    ? (2.0, true)
                    : (-0.4, false)
            }

            return (-0.1, false)

        case .crouch, .roll, .crawl:
            if start.terrain == .lowCeiling {
                if a.collided {
                    return (-0.3, false)
                }

                return (0.5, true)
            }

            // A low posture where nothing is overhead only costs time.
            return (-0.1, false)

        case .turnLeft, .turnRight:
            if start.terrain != .flat && terrain.terrain == .flat {
                return (0.3, true)
            }

            return (-0.03, false)

        case .recover:
            return (0, true)

        case .walk, .run:
            return (0, !a.collided && a.moved > 0.05)

        case .stepDown:
            return (0, true)
        }
    }

    // MARK: - Animation

    private func updateAnimation(
        dt: Float,
        fb: FrankensteinMotionFeedback
    ) {
        let moving = fb.speed > 0.15 && fb.grounded
        let phaseSpeed = min(1.8, max(0.35, fb.speed / 1.6))

        if moving {
            output.walkPhase += dt * phaseSpeed * 5.5
        }

        let airborneTarget: Float = fb.grounded ? 0 : 1
        output.jump += (airborneTarget - output.jump) * min(1, dt * 10)

        let lowTarget: Float = output.posture == .standing ? 0 : 1
        output.crouch += (lowTarget - output.crouch) * min(1, dt * 8)

        output.armLift = fb.grounded
            ? (moving ? 0.12 + sin(output.walkPhase) * 0.18 : 0.04)
            : 0.65

        output.stride = moving ? min(1, fb.speed / B.runSpeed) : 0
        output.lean = 0

        switch output.action {
        case .turnLeft: output.headTurn = 0.3
        case .turnRight: output.headTurn = -0.3
        default: output.headTurn = 0
        }

        output.mouthOpen = moving
            ? max(0, sin(animationClock * 3)) * 0.12
            : 0
    }

    private func statusDescription(
        fb: FrankensteinMotionFeedback
    ) -> String {
        if !fb.grounded {
            return "Airborne"
        }

        switch output.action {
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
        case .recover: return "Recovering"
        }
    }

    // MARK: - Episodes

    private func wrap(_ angle: Float) -> Float {
        atan2(sin(angle), cos(angle))
    }

    /// Back to the start line for a fresh attempt. What he has learned is
    /// kept; only the attempt is reset.
    func resetEpisode() {
        if pendingEpisodeEnd != nil || actionsCompleted > 0 {
            episodes += 1
        }

        pendingEpisodeEnd = nil

        body = FrankensteinBodyState()
        output = FrankensteinLocomotionOutput()
        active = nil
        commandSpeed = 0
        learning.reset()
        policy.resetEpisode()
    }
}
