
import Foundation
import SceneKit

// MARK: - Terrain and State

enum FrankensteinTerrain: Int, CaseIterable {
    case flat, hurdle, gap, lowCeiling, raisedStep, slope, uneven
}

struct FrankensteinTerrainSample {
    var terrain: FrankensteinTerrain = .flat
    var distance: Float = 5
    var obstacleHeight: Float = 0
    var gapWidth: Float = 0
    var groundHeight: Float = 0
    var nextGroundHeight: Float = 0
    var isGroundAhead = true
    var isLandingAreaClear = true
}

struct FrankensteinBodyState {
    var speed: Float = 0
    var tilt: Float = 0
    var verticalVelocity: Float = 0
    var height: Float = 1.8
    var grounded = true
    var fallen = false
    var distanceTravelled: Float = 0
}

enum FrankensteinAction: Int, CaseIterable {
    case walk, run, turnLeft, turnRight, jump, crouch, stepUp, recover
}

struct FrankensteinLocomotionOutput {
    var walkPhase: Float = 0
    var armLift: Float = 0
    var headTurn: Float = 0
    var mouthOpen: Float = 0

    var heading: Float = 0
    var speed: Float = 0
    var crouch: Float = 0
    var jump: Float = 0
    var lean: Float = 0
    var stride: Float = 0

    var action: FrankensteinAction = .walk
    var reward: Float = 0
    var status = "Ready"
}

// MARK: - Action-Value Learning

final class FrankensteinLearningPolicy {

    private struct State: Hashable {
        let terrain: Int
        let distanceBand: Int
        let tiltBand: Int
        let grounded: Bool
    }

    private var values: [State: [Float]] = [:]
    private var lastState: State?
    private var lastAction: FrankensteinAction?

    var learningRate: Float = 0.12
    var discount: Float = 0.9
    var exploration: Float = 0.2

    private func state(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> State {
        State(
            terrain: terrain.terrain.rawValue,
            distanceBand: terrain.distance < 0.8 ? 0 :
                (terrain.distance < 2.0 ? 1 : 2),
            tiltBand: abs(body.tilt) < 0.12 ? 0 :
                (abs(body.tilt) < 0.35 ? 1 : 2),
            grounded: body.grounded
        )
    }

    func choose(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> FrankensteinAction {
        let s = state(terrain: terrain, body: body)
        let candidates = allowedActions(terrain: terrain, body: body)
        let q = values[s] ?? Array(
            repeating: 0,
            count: FrankensteinAction.allCases.count
        )

        let action: FrankensteinAction

        if Float.random(in: 0...1) < exploration {
            action = candidates.randomElement() ?? .walk
        } else {
            action = candidates.max {
                q[$0.rawValue] < q[$1.rawValue]
            } ?? .walk
        }

        lastState = s
        lastAction = action
        return action
    }

    func learn(
        reward: Float,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool
    ) {
        guard let s = lastState, let a = lastAction else { return }

        var q = values[s] ?? Array(
            repeating: 0,
            count: FrankensteinAction.allCases.count
        )

        let next = state(terrain: terrain, body: body)
        let future = terminal ? 0 : (values[next]?.max() ?? 0)
        let target = reward + discount * future

        q[a.rawValue] += learningRate * (target - q[a.rawValue])
        values[s] = q

        exploration = max(0.03, exploration * 0.9995)

        if terminal {
            lastState = nil
            lastAction = nil
        }
    }

    private func allowedActions(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> [FrankensteinAction] {
        if body.fallen { return [.recover] }
        if !body.grounded { return [.walk, .recover] }

        switch terrain.terrain {
        case .hurdle:
            if terrain.obstacleHeight <= 0.75 {
                return [.jump, .stepUp, .turnLeft, .turnRight, .walk]
            }
            return [.turnLeft, .turnRight, .walk]

        case .gap:
            if terrain.gapWidth <= 1.8 && terrain.isLandingAreaClear {
                return [.jump, .turnLeft, .turnRight, .walk]
            }
            return [.turnLeft, .turnRight, .walk]

        case .lowCeiling:
            return [.crouch, .turnLeft, .turnRight]

        case .raisedStep:
            if terrain.nextGroundHeight - terrain.groundHeight <= 0.55 {
                return [.stepUp, .jump, .turnLeft, .turnRight, .walk]
            }
            return [.turnLeft, .turnRight, .walk]

        case .slope, .uneven:
            return [.walk, .run, .turnLeft, .turnRight, .recover]

        case .flat:
            return abs(body.tilt) > 0.35
                ? [.recover, .walk]
                : [.walk, .run, .turnLeft, .turnRight]
        }
    }

    func resetEpisode() {
        lastState = nil
        lastAction = nil
    }
}

// MARK: - Locomotion Controller

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

    func step(
        deltaTime: Float,
        terrain: FrankensteinTerrainSample
    ) -> FrankensteinLocomotionOutput {
        let dt = min(max(deltaTime, 0), 0.05)
        elapsed += dt
        actionTimer += dt

        if actionTimer >= 0.22 {
            actionTimer = 0
            action = policy.choose(terrain: terrain, body: body)
        }

        updateMovement(dt: dt, terrain: terrain)
        stabilize(dt: dt, terrain: terrain)

        let progress = body.distanceTravelled - lastDistance
        lastDistance = body.distanceTravelled

        var reward = progress * 2.0
        reward += body.grounded ? 0.08 : 0.02
        reward -= abs(body.tilt) * 0.25

        if body.fallen {
            reward -= 8
        }

        if action == .jump && !terrain.isLandingAreaClear {
            reward -= 1.5
        }

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
        case .walk: targetSpeed = 1.0
        case .run: targetSpeed = 2.2
        case .turnLeft, .turnRight: targetSpeed = 0.65
        case .jump: targetSpeed = 1.3
        case .crouch: targetSpeed = 0.45
        case .stepUp: targetSpeed = 0.55
        case .recover: targetSpeed = 0
        }

        body.speed += (targetSpeed - body.speed) * min(1, dt * 3)

        if action == .jump && body.grounded &&
            (terrain.isGroundAhead || terrain.terrain == .gap) {
            body.verticalVelocity = jumpImpulse
            body.grounded = false
        }

        if !body.grounded {
            body.verticalVelocity -= gravity * dt
            body.height += body.verticalVelocity * dt

            let landingHeight = terrain.nextGroundHeight + 1.8

            if body.height <= landingHeight && body.verticalVelocity < 0 {
                body.height = landingHeight
                body.verticalVelocity = 0
                body.grounded = true

                if abs(body.tilt) > maximumTilt {
                    body.fallen = true
                }
            }
        } else {
            let targetHeight = terrain.groundHeight + 1.8
            body.height += (targetHeight - body.height) * min(1, dt * 8)
        }

        switch action {
        case .turnLeft:
            output.heading += dt * 1.2
        case .turnRight:
            output.heading -= dt * 1.2
        default:
            break
        }

        if body.grounded {
            body.distanceTravelled += body.speed * dt
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

        let gaitDisturbance = sin(elapsed * 7) * body.speed * 0.025
        let recoveryStrength: Float = action == .recover ? 2.0 : 0.65

        body.tilt += (
            terrainDisturbance + gaitDisturbance
            - body.tilt * recoveryStrength
        ) * dt

        if abs(body.tilt) > maximumTilt {
            body.fallen = true
        }
    }

    private func stabilize(
        dt: Float,
        terrain: FrankensteinTerrainSample
    ) {
        guard body.grounded, !body.fallen else { return }

        let requiresCarefulMovement =
            terrain.distance < 1.0 &&
            [.hurdle, .gap, .lowCeiling, .raisedStep]
                .contains(terrain.terrain)

        if requiresCarefulMovement {
            body.speed = min(body.speed, 0.9)
        }

        body.tilt *= max(0, 1 - dt * 1.8)
    }

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

        case .crouch:
            output.crouch = min(1, output.crouch + dt * 3)
            output.jump = max(0, output.jump - dt * 4)
            output.armLift = 0.12 + sin(output.walkPhase) * 0.05

        case .stepUp:
            output.jump = min(0.45, output.jump + dt * 2)
            output.armLift = 0.28 + sin(output.walkPhase) * 0.08

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

        output.stride = moving ? min(1, body.speed / 2.2) : 0
        output.headTurn = action == .turnLeft ? 0.3 :
            (action == .turnRight ? -0.3 : 0)
        output.mouthOpen = moving
            ? max(0, sin(elapsed * 3)) * 0.12
            : 0
    }

    private func statusText(_ action: FrankensteinAction) -> String {
        switch action {
        case .walk: return "Walking"
        case .run: return "Running"
        case .turnLeft: return "Turning left"
        case .turnRight: return "Turning right"
        case .jump: return "Jumping"
        case .crouch: return "Crouching"
        case .stepUp: return "Stepping up"
        case .recover: return "Balancing / recovering"
        }
    }

    func resetEpisode() {
        body = FrankensteinBodyState()
        output = FrankensteinLocomotionOutput()
        elapsed = 0
        actionTimer = 0
        lastDistance = 0
        action = .walk
        policy.resetEpisode()
    }
}
