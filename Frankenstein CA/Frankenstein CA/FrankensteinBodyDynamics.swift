

import Foundation
import SceneKit


// MARK: - Dynamics

final class FrankensteinBodyDynamics {

    private typealias B = FrankensteinPhysicalBody

    private(set) var x: Float
    private(set) var z: Float
    private(set) var feetY: Float
    private(set) var verticalVelocity: Float = 0
    private(set) var grounded = true
    private(set) var bodyHeight: Float = B.standingHeight
    private(set) var headroom: Float = 99
    private(set) var lastSupportY: Float
    private(set) var isTerminal = false

    private var airVelocityX: Float = 0
    /// True only while airborne from an actual jump. Drifting off a ledge
    /// scrapes the ledge's side; that is not a collision.
    private var inJump = false
    private var airVelocityZ: Float = 0
    private var takeoffX: Float = 0
    private var takeoffZ: Float = 0
    private var takeoffFeetY: Float = 0
    private var stepStartY: Float?
    private var collisionCooldown: Float = 0

    init(start: SCNVector3 = FrankensteinPhysicalBody.startPosition) {
        x = start.x
        z = start.z
        feetY = start.y
        lastSupportY = start.y
    }

    var position: SCNVector3 {
        SCNVector3(x, feetY, z)
    }

    func pose(heading: Float) -> FrankensteinWorldPose {
        FrankensteinWorldPose(
            x: x,
            z: z,
            feetY: feetY,
            referenceY: grounded ? feetY : lastSupportY,
            heading: heading,
            bodyHeight: bodyHeight,
            grounded: grounded
        )
    }

    func teleport(to point: SCNVector3) {
        x = point.x
        z = point.z
        feetY = point.y
        lastSupportY = point.y
        verticalVelocity = 0
        grounded = true
        bodyHeight = B.standingHeight
        airVelocityX = 0
        airVelocityZ = 0
        stepStartY = nil
        collisionCooldown = 0
        isTerminal = false
    }

    // MARK: Advance

    func advance(
        deltaTime: Float,
        command: FrankensteinBodyCommand,
        probe: FrankensteinWorldProbe
    ) -> FrankensteinMotionFeedback {
        let dt = min(max(deltaTime, 0), 0.05)
        var feedback = FrankensteinMotionFeedback()

        guard dt > 0, !isTerminal else {
            fill(&feedback, startX: x, startZ: z, dt: max(dt, 0.0001))
            return feedback
        }

        collisionCooldown = max(0, collisionCooldown - dt)

        let startX = x
        let startZ = z
        let forwardX = -sin(command.heading)
        let forwardZ = -cos(command.heading)

        updateBodyHeight(posture: command.posture, probe: probe)

        // Take off. Needs a body tall enough to leave the ground cleanly.
        if command.jumpRequested && grounded &&
            bodyHeight >= B.crouchHeight - 0.01 {

            beginAir(
                velocityX: forwardX * max(0, command.speed),
                velocityZ: forwardZ * max(0, command.speed)
            )

            verticalVelocity = B.jumpImpulse
            inJump = true
            feedback.events.append(.tookOff)
        }

        // Horizontal motion against real geometry.
        var dirX = forwardX
        var dirZ = forwardZ
        var speed = max(0, command.speed)

        if !grounded {
            speed = sqrt(
                airVelocityX * airVelocityX +
                airVelocityZ * airVelocityZ
            )

            if speed > 1e-4 {
                dirX = airVelocityX / speed
                dirZ = airVelocityZ / speed
            }
        }

        let intended = speed * dt
        var moved: Float = 0

        if intended > 1e-5 {
            moved = moveHorizontally(
                distance: intended,
                dirX: dirX,
                dirZ: dirZ,
                probe: probe
            )

            x += dirX * moved
            z += dirZ * moved
        }

        feedback.intendedDistance = intended
        feedback.blocked = intended > 0.004 && moved < intended * 0.4

        if feedback.blocked {
            if collisionCooldown <= 0 && (grounded || inJump) {
                feedback.events.append(.collided)
                collisionCooldown = 0.3
            }

            if !grounded {
                airVelocityX = 0
                airVelocityZ = 0
            }
        }

        // Vertical motion, support, landing and falling.
        resolveVertical(
            dt: dt,
            dirX: dirX,
            dirZ: dirZ,
            speed: speed,
            probe: probe,
            feedback: &feedback
        )

        // Reached the finish line.
        if grounded && !isTerminal && z <= B.finishZ {
            feedback.events.append(.reachedGoal)
            isTerminal = true
        }

        fill(&feedback, startX: startX, startZ: startZ, dt: dt)
        return feedback
    }

    private func fill(
        _ feedback: inout FrankensteinMotionFeedback,
        startX: Float,
        startZ: Float,
        dt: Float
    ) {
        let dx = x - startX
        let dz = z - startZ
        let moved = sqrt(dx * dx + dz * dz)

        feedback.position = position
        feedback.grounded = grounded
        feedback.feetHeight = feetY
        feedback.verticalVelocity = verticalVelocity
        feedback.bodyHeight = bodyHeight
        feedback.headroom = headroom
        feedback.movedDistance = moved
        feedback.speed = moved / dt
        feedback.goalProgress = startZ - z
    }

    // MARK: Body height

    /// The body takes the height of the requested posture, but cannot stand
    /// up into geometry that is already overhead.
    private func updateBodyHeight(
        posture: FrankensteinPosture,
        probe: FrankensteinWorldProbe
    ) {
        let wanted = B.height(for: posture)
        var height = wanted
        var free: Float = 99

        if let under = probe.ceilingHeight(
            x: x,
            z: z,
            fromY: feetY + B.ceilingProbeRise,
            rise: B.standingHeight + 0.3
        ) {
            free = under - feetY - 0.02
        }

        if wanted > B.crawlHeight {
            height = max(B.crawlHeight, min(wanted, free))
        }

        headroom = free
        bodyHeight = height
    }

    // MARK: Horizontal collision

    private func moveHorizontally(
        distance: Float,
        dirX: Float,
        dirZ: Float,
        probe: FrankensteinWorldProbe
    ) -> Float {
        let radius = B.radius
        let perpX = -dirZ
        let perpZ = dirX
        let offsets: [Float] = [-0.8 * radius, 0, 0.8 * radius]

        var allowed = distance

        // Walls and low obstacles: rays at several body heights.
        for height in B.collisionRayHeights(bodyHeight: bodyHeight) {
            for lateral in offsets {
                let start = SCNVector3(
                    x + perpX * lateral,
                    feetY + height,
                    z + perpZ * lateral
                )

                if let hit = probe.horizontalHit(
                    from: start,
                    dirX: dirX,
                    dirZ: dirZ,
                    length: distance + radius
                ) {
                    allowed = min(allowed, max(0, hit - radius))
                }
            }
        }

        guard allowed > 1e-5 else { return 0 }

        // Overhead: the leading edge must have room for the whole body.
        // This is what stops a posture that is too tall from entering a
        // low space, however high the horizontal rays happen to sit.
        let newX = x + dirX * allowed
        let newZ = z + dirZ * allowed
        let headRise = bodyHeight + 0.02 - B.ceilingProbeRise

        for lateral in offsets {
            let edgeX = newX + perpX * lateral + dirX * radius
            let edgeZ = newZ + perpZ * lateral + dirZ * radius

            if probe.ceilingHeight(
                x: edgeX,
                z: edgeZ,
                fromY: feetY + B.ceilingProbeRise,
                rise: headRise
            ) != nil {
                return 0
            }
        }

        // Surfaces too tall to climb that the rays passed over or under.
        var highest = -Float.greatestFiniteMagnitude

        for lateral in offsets {
            let sampleX = newX + perpX * lateral + dirX * radius * 0.5
            let sampleZ = newZ + perpZ * lateral + dirZ * radius * 0.5

            if let surface = probe.surfaceHeight(
                x: sampleX,
                z: sampleZ,
                fromY: feetY + B.groundProbeRise
            ) {
                highest = max(highest, surface)
            }
        }

        if highest > -1e8 {
            let rise = highest - feetY

            if grounded && rise > B.maxStepHeight + 0.01 {
                return 0
            }

            if !grounded && rise > 0.12 {
                return 0
            }
        }

        return allowed
    }

    // MARK: Vertical motion

    private func beginAir(velocityX: Float, velocityZ: Float) {
        grounded = false
        verticalVelocity = 0
        airVelocityX = velocityX
        airVelocityZ = velocityZ
        takeoffX = x
        takeoffZ = z
        takeoffFeetY = feetY
        stepStartY = nil
    }

    private func resolveVertical(
        dt: Float,
        dirX: Float,
        dirZ: Float,
        speed: Float,
        probe: FrankensteinWorldProbe,
        feedback: inout FrankensteinMotionFeedback
    ) {
        var support = probe.surfaceHeight(
            x: x,
            z: z,
            fromY: feetY + B.groundProbeRise
        )

        if grounded {
            if let surface = support {
                let delta = surface - feetY

                if delta > 0.005 {
                    // Stepping up.
                    if stepStartY == nil {
                        stepStartY = feetY
                    }

                    feetY += min(delta, B.climbRate * dt)

                    if feetY >= surface - 0.005 {
                        feetY = surface

                        if let start = stepStartY, surface - start > 0.12 {
                            feedback.events.append(
                                .steppedUp(rise: surface - start)
                            )
                        }

                        stepStartY = nil
                    }

                    lastSupportY = feetY
                } else if delta < -0.12 {
                    // Walked off an edge.
                    beginAir(
                        velocityX: dirX * speed,
                        velocityZ: dirZ * speed
                    )

                    support = probe.surfaceHeight(
                        x: x,
                        z: z,
                        fromY: feetY + B.groundProbeRise
                    )
                } else {
                    feetY = surface
                    lastSupportY = feetY
                    stepStartY = nil
                }
            } else {
                beginAir(
                    velocityX: dirX * speed,
                    velocityZ: dirZ * speed
                )
            }
        }

        guard !grounded else { return }

        verticalVelocity -= B.gravity * dt
        feetY += verticalVelocity * dt

        if verticalVelocity <= 0,
           let surface = support,
           feetY <= surface + 0.001 {
            land(on: surface, feedback: &feedback)
            return
        }

        // A genuine fall: well below the last place he stood and still
        // dropping with nothing to land on. A jump apex or a short step
        // down never gets here.
        if feetY < lastSupportY - B.fallDepth {
            feedback.events.append(.fell(.void))
            isTerminal = true
        }
    }

    private func land(
        on surface: Float,
        feedback: inout FrankensteinMotionFeedback
    ) {
        let dx = x - takeoffX
        let dz = z - takeoffZ
        let horizontal = sqrt(dx * dx + dz * dz)
        let rise = surface - takeoffFeetY
        let drop = lastSupportY - surface

        feetY = surface
        verticalVelocity = 0
        grounded = true
        inJump = false
        airVelocityX = 0
        airVelocityZ = 0

        feedback.events.append(
            .landed(drop: drop, horizontal: horizontal, rise: rise)
        )

        if drop > B.maxSafeDrop {
            feedback.events.append(.fell(.hardLanding))
            isTerminal = true
        }

        lastSupportY = surface
    }
}
