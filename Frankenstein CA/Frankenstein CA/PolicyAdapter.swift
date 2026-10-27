
import Foundation

final class FrankensteinLearningPolicy {

    // MARK: - Q-Learning State

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

    // Alleya CA learning diagnostics.
    private(set) var updateCount: Int = 0

    private var actionCount: Int {
        FrankensteinAction.allCases.count
    }

    private func emptyQValues() -> [Float] {
        Array(repeating: 0, count: actionCount)
    }

    // MARK: - State Encoding

    private func state(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> State {
        State(
            terrain: terrainID(terrain.terrain.rawValue),
            distanceBand: terrain.distance < 0.8 ? 0 :
                (terrain.distance < 2.0 ? 1 : 2),
            tiltBand: abs(body.tilt) < 0.12 ? 0 :
                (abs(body.tilt) < 0.35 ? 1 : 2),
            grounded: body.grounded
        )
    }
    
    private func terrainID(_ name: String) -> Int {
        switch name {
        case "flat":       return 0
        case "hurdle":     return 1
        case "gap":        return 2
        case "lowCeiling": return 3
        case "raisedStep": return 4
        case "slope":      return 5
        case "uneven":     return 6
        case "unknown":    return 7
        default:           return 8
        }
    }
    // MARK: - Q-Value Visualization

    func actionValues(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> [(action: FrankensteinAction, value: Float)] {
        let currentState = state(
            terrain: terrain,
            body: body
        )

        let q = values[currentState] ?? emptyQValues()

        return allowedActions(
            terrain: terrain,
            body: body
        )
        .filter { q.indices.contains($0.rawValue) }
        .map { action in
            (action: action, value: q[action.rawValue])
        }
        .sorted { $0.value > $1.value }
    }

    func choose(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> FrankensteinAction {

        // Keep the active action until its outcome is recorded.
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

    // MARK: - Learning From a Completed Action

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

        let index = action.rawValue

        guard q.indices.contains(index) else {
            clearPendingAction()
            return
        }

        let nextState = state(
            terrain: terrain,
            body: body
        )

        let futureValue: Float

        if terminal {
            futureValue = 0
        } else {
            let nextQ = values[nextState] ?? emptyQValues()

            let nextActions = allowedActions(
                terrain: terrain,
                body: body
            )

            futureValue = nextActions
                .filter { nextQ.indices.contains($0.rawValue) }
                .map { nextQ[$0.rawValue] }
                .max() ?? 0
        }

        let target = reward + discount * futureValue

        q[index] += learningRate * (target - q[index])
        values[previousState] = q

        // Count actual Q-learning updates, not rendered frames.
        updateCount += 1

        // Decay exploration after each completed learning update.
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

    // MARK: - Action Constraints

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
                    .jump,
                    .stepUp,
                    .turnLeft,
                    .turnRight,
                    .walk
                ]
            }

            return [
                .turnLeft,
                .turnRight,
                .walk
            ]

        case .gap:
            if terrain.gapWidth <= 1.8 &&
                terrain.isLandingAreaClear {
                return [
                    .jump,
                    .turnLeft,
                    .turnRight
                ]
            }

            return [
                .turnLeft,
                .turnRight,
                .walk
            ]

        case .lowCeiling:
            return [
                .crouch,
                .turnLeft,
                .turnRight
            ]

        case .raisedStep:
            if terrain.nextGroundHeight -
                terrain.groundHeight <= 0.55 {
                return [
                    .stepUp,
                    .jump,
                    .turnLeft,
                    .turnRight,
                    .walk
                ]
            }

            return [
                .turnLeft,
                .turnRight,
                .walk
            ]

        case .slope, .uneven:
            return [
                .walk,
                .run,
                .turnLeft,
                .turnRight,
                .recover
            ]

        case .flat:
            return abs(body.tilt) > 0.35
                ? [.recover, .walk]
                : [.walk, .run, .turnLeft, .turnRight]

        default:
            // Safe fallback for an unclassified terrain case,
            // including .unknown if the terrain enum defines it.
            return [
                .turnLeft,
                .turnRight,
                .walk
            ]
        }
    }

    // MARK: - Episode Management

    func resetEpisode() {
        clearPendingAction()
    }

    // MARK: - Alleya CA Diagnostics

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
        let currentState = state(
            terrain: terrain,
            body: body
        )

        let q = values[currentState] ?? emptyQValues()

        guard q.indices.contains(action.rawValue) else {
            return 0
        }

        return q[action.rawValue]
    }

    func preferredAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> (action: FrankensteinAction, value: Float)? {

        let currentState = state(
            terrain: terrain,
            body: body
        )

        let q = values[currentState] ?? emptyQValues()

        let candidates = allowedActions(
            terrain: terrain,
            body: body
        )

        guard let best = candidates.max(by: {
            q[$0.rawValue] < q[$1.rawValue]
        }) else {
            return nil
        }

        return (
            action: best,
            value: q[best.rawValue]
        )
    }
}

// MARK: - Alleya CA Policy Adapter Protocol

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

// MARK: - Connect Adapter to the Existing Policy

extension FrankensteinLearningPolicy:
    FrankensteinStage1PolicyAdapter {

    func chooseAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> FrankensteinAction {
        choose(
            terrain: terrain,
            body: body
        )
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
    
    // MARK: - Jump Outcome Reporting

    func reportJumpOutcome(
        succeeded: Bool,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool = false
    ) {
        guard actionPendingLearning,
              lastAction == .jump else {
            return
        }

        let reward: Float = succeeded ? 3.0 : -2.0

        learn(
            reward: reward,
            terrain: terrain,
            body: body,
            terminal: terminal
        )
    }

}
