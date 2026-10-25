
import Foundation

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

    // Prevent repeated learning updates for one completed action.
    private var actionPendingLearning = false

    var learningRate: Float = 0.12
    var discount: Float = 0.9
    var exploration: Float = 0.2

    private var actionCount: Int {
        FrankensteinAction.allCases.count
    }

    private func emptyQValues() -> [Float] {
        Array(repeating: 0, count: actionCount)
    }

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

    func learn(
        reward: Float,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool
    ) {
        guard actionPendingLearning,
              let previousState = lastState,
              let action = lastAction else {
            return
        }

        var q = values[previousState] ?? emptyQValues()

        let nextState = state(
            terrain: terrain,
            body: body
        )

        let futureValue: Float

        if terminal {
            futureValue = 0
        } else {
            futureValue = values[nextState]?.max() ?? 0
        }

        let target = reward + discount * futureValue

        let index = action.rawValue

        guard q.indices.contains(index) else {
            clearPendingAction()
            return
        }

        q[index] += learningRate * (target - q[index])
        values[previousState] = q

        // Decay exploration per completed learning update,
        // not per rendered frame.
        exploration = max(0.03, exploration * 0.9995)

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

        case .hurdle:
            if terrain.obstacleHeight <= 0.75 {
                return [
                    .jump, .stepUp,
                    .turnLeft, .turnRight, .walk
                ]
            }

            return [.turnLeft, .turnRight, .walk]

        case .gap:
            if terrain.gapWidth <= 1.8 &&
                terrain.isLandingAreaClear {
                return [
                    .jump, .turnLeft, .turnRight
                ]
            }

            return [.turnLeft, .turnRight, .walk]

        case .lowCeiling:
            return [.crouch, .turnLeft, .turnRight]

        case .raisedStep:
            if terrain.nextGroundHeight -
                terrain.groundHeight <= 0.55 {
                return [
                    .stepUp, .jump,
                    .turnLeft, .turnRight, .walk
                ]
            }

            return [.turnLeft, .turnRight, .walk]

        case .slope, .uneven:
            return [
                .walk, .run,
                .turnLeft, .turnRight, .recover
            ]

        case .flat:
            return abs(body.tilt) > 0.35
                ? [.recover, .walk]
                : [.walk, .run, .turnLeft, .turnRight]
        }
    }

    // MARK: - Episode management

    func resetEpisode() {
        clearPendingAction()
    }

    // Read-only diagnostics for the coordinator or UI.
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
