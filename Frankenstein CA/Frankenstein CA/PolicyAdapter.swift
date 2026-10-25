
import Foundation

final class FrankensteinLearningPolicy {
    
    // MARK: State

    /// What he knows when he decides. Everything here comes from
    /// measurement: the kind of feature ahead, how far away it is, how big
    /// it is (height, gap width or clearance), how fast he is moving, which
    /// way he faces relative to the goal, and whether he is on the ground.
    private struct State: Hashable {
        let terrain: Int
        let distanceBand: Int
        let magnitudeBand: Int
        let speedBand: Int
        let headingBand: Int
        let grounded: Bool
    }

    private var values: [State: [Float]] = [:]
    private var visits: [State: [Int]] = [:]

    private var lastState: State?
    private var lastAction: FrankensteinAction?

    // Prevent repeated learning updates for one completed action.
    private var actionPendingLearning = false

    var learningRate: Float = 0.25
    var discount: Float = 0.9
    var exploration: Float = 0.25

    private(set) var updateCount = 0

    private var actionCount: Int {
        FrankensteinAction.allCases.count
    }

    private func emptyQValues() -> [Float] {
        Array(repeating: 0, count: actionCount)
    }

    private func emptyVisits() -> [Int] {
        Array(repeating: 0, count: actionCount)
    }

    private func state(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> State {
        let distance = terrain.distance

        let distanceBand =
            distance < 0.4 ? 0 :
            distance < 1.0 ? 1 :
            distance < 2.0 ? 2 : 3

        let magnitudeBand: Int

        switch terrain.terrain {
        case .gap:
            let w = terrain.gapWidth
            magnitudeBand =
                w < 1.5 ? 0 :
                w < 2.6 ? 1 :
                w < 3.6 ? 2 : 3

        case .lowCeiling:
            // Clearance above his feet versus his postures:
            // crawl 1.3, roll 1.7, crouch 3.2.
            let c = terrain.obstacleHeight
            magnitudeBand =
                c < 1.3 ? 0 :
                c < 1.7 ? 1 :
                c < 3.2 ? 2 : 3

        case .flat:
            magnitudeBand = 0

        default:
            let h = terrain.obstacleHeight
            magnitudeBand =
                h < 0.35 ? 0 :
                h < 0.7 ? 1 :
                h < 1.0 ? 2 :
                h < 1.5 ? 3 : 4
        }

        let speedBand =
            body.speed < 0.4 ? 0 :
            body.speed < 2.2 ? 1 : 2

        let error = body.headingError
        let headingBand =
            error < -1.0 ? 0 :
            error < -0.3 ? 1 :
            error <= 0.3 ? 2 :
            error <= 1.0 ? 3 : 4

        return State(
            terrain: terrain.terrain.rawValue,
            distanceBand: distanceBand,
            magnitudeBand: magnitudeBand,
            speedBand: speedBand,
            headingBand: headingBand,
            grounded: body.grounded
        )
    }

    // MARK: - Action selection

    func choose(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> FrankensteinAction {

        // Do not overwrite the active state/action while waiting
        // for the current skill to finish and produce its reward.
        if actionPendingLearning, let lastAction {
            return lastAction
        }

        let currentState = state(
            terrain: terrain,
            body: body
        )

        let candidates = allowedActions(
            terrain: terrain,
            body: body
        )

        guard !candidates.isEmpty else {
            lastState = currentState
            lastAction = .walk
            actionPendingLearning = true
            return .walk
        }

        let q = values[currentState] ?? emptyQValues()

        let action: FrankensteinAction

        if Float.random(in: 0...1) < exploration {
            action = candidates.randomElement() ?? .walk
        } else {
            action = candidates.max {
                q[$0.rawValue] < q[$1.rawValue]
            } ?? .walk
        }

        lastState = currentState
        lastAction = action
        actionPendingLearning = true

        return action
    }

    // MARK: - Learning from a completed action

    /// Call exactly once when the chosen action has finished. `duration` is
    /// the time the action took, so long actions discount the future more.
    func learn(
        reward: Float,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool,
        duration: Float = 0.6
    ) {
        guard actionPendingLearning,
              let previousState = lastState,
              let action = lastAction else {
            return
        }

        var q = values[previousState] ?? emptyQValues()
        var n = visits[previousState] ?? emptyVisits()

        let index = action.rawValue

        guard q.indices.contains(index) else {
            clearPendingAction()
            return
        }

        let nextState = state(
            terrain: terrain,
            body: body
        )

        // The best value among actions that are actually available next.
        // (Taking the max over every slot would let never-used, disallowed
        // actions hold the value at 0 and hide how bad a state is.)
        let futureValue: Float

        if terminal {
            futureValue = 0
        } else {
            let nextQ = values[nextState] ?? emptyQValues()
            let next = allowedActions(terrain: terrain, body: body)

            futureValue = next
                .map { nextQ[$0.rawValue] }
                .max() ?? 0
        }

        let gamma = pow(discount, max(duration, 0.1) / 0.6)
        let target = reward + gamma * futureValue

        q[index] += learningRate * (target - q[index])
        n[index] += 1

        values[previousState] = q
        visits[previousState] = n

        // Decay exploration per completed learning update,
        // not per rendered frame.
        exploration = max(0.05, exploration * 0.998)
        updateCount += 1

        // This action has now been learned from exactly once.
        clearPendingAction()

        if terminal {
            resetEpisode()
        }
    }

    private func clearPendingAction() {
        lastState = nil
        lastAction = nil
        actionPendingLearning = false
    }

    // MARK: - Action constraints

    /// Which actions make sense in a kind of situation. Whether an action
    /// actually works is not decided here: he finds out by trying it and
    /// seeing what the body does.
    private func allowedActions(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> [FrankensteinAction] {

        if body.fallen {
            return [.recover]
        }

        if !body.grounded {
            return [.recover]
        }

        switch terrain.terrain {

        case .flat, .slope:
            return [.walk, .run, .turnLeft, .turnRight]

        case .hurdle:
            return [
                .jump, .stepUp, .walk, .run,
                .turnLeft, .turnRight
            ]

        case .gap:
            return [
                .jump, .walk, .run,
                .turnLeft, .turnRight
            ]

        case .lowCeiling:
            return [
                .crouch, .roll, .crawl, .walk,
                .turnLeft, .turnRight
            ]

        case .raisedStep:
            return [
                .stepUp, .jump, .walk,
                .turnLeft, .turnRight
            ]

        case .uneven:
            return [.turnLeft, .turnRight, .walk, .jump]
        }
    }

    // MARK: - Episode management

    func resetEpisode() {
        clearPendingAction()
    }

    // MARK: - Diagnostics

    var isAwaitingOutcome: Bool {
        actionPendingLearning
    }

    var learnedStateCount: Int {
        values.count
    }

    func qValue(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        action: FrankensteinAction
    ) -> Float {
        let currentState = state(terrain: terrain, body: body)
        let q = values[currentState] ?? emptyQValues()

        guard q.indices.contains(action.rawValue) else {
            return 0
        }

        return q[action.rawValue]
    }

    /// The action he would take right now if he stopped exploring, and
    /// how many times he has tried it in this situation.
    func preferredAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> (action: FrankensteinAction, value: Float, tries: Int)? {
        let s = state(terrain: terrain, body: body)
        let q = values[s] ?? emptyQValues()
        let n = visits[s] ?? emptyVisits()

        let candidates = allowedActions(terrain: terrain, body: body)

        guard let best = candidates.max(by: {
            q[$0.rawValue] < q[$1.rawValue]
        }) else {
            return nil
        }

        return (best, q[best.rawValue], n[best.rawValue])
    }
}

// MARK: - Adapter implemented by the existing policy

protocol FrankensteinStage1PolicyAdapter {
    func chooseAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> FrankensteinAction

    func recordCompletedAction(
        reward: Float,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool
    )
}

extension FrankensteinLearningPolicy:
    FrankensteinStage1PolicyAdapter {

    func chooseAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> FrankensteinAction {
        choose(terrain: terrain, body: body)
    }

    func recordCompletedAction(
        reward: Float,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool
    ) {
        learn(
            reward: reward,
            terrain: terrain,
            body: body,
            terminal: terminal
        )
    }
}
