import Foundation
import Testing
@testable import Frankenstein_CA

struct FrankensteinPolicyTests {

    /// A fresh policy that neither loads nor overwrites the app's saved Q-table.
    private func makePolicy() -> FrankensteinLearningPolicy {
        let policy = FrankensteinLearningPolicy(loadSavedLearning: false)
        policy.autosaveLearning = false
        return policy
    }

    private func hurdle(
        height: Float = 0.4,
        distance: Float = 0.6
    ) -> FrankensteinTerrainSample {
        var sample = FrankensteinTerrainSample()
        sample.terrain = .hurdle
        sample.obstacleHeight = height
        sample.distance = distance
        sample.isLandingAreaClear = true
        return sample
    }

    @Test
    func caReceivesLearnedActionValues() {
        let policy = makePolicy()
        let ca = FrankensteinCA()
        let terrain = hurdle()
        let body = FrankensteinBodyState()

        // Train the policy to prefer jumping.
        for _ in 0..<30 {
            #expect(
                policy.beginCAChosenAction(
                    .jump,
                    terrain: terrain,
                    body: body
                )
            )

            #expect(
                policy.learn(
                    reward: 3.0,
                    terrain: terrain,
                    body: body
                )
            )
        }

        let values = policy.learnedActionValues(
            terrain: terrain,
            body: body
        )

        // Verify that the CA actually receives the policy's values.
        ca.setQValues(values)

        #expect(
            ca.qValue(for: .jump) == values[.jump],
            "The CA did not receive the learned jump Q-value."
        )
    }

    @Test
    func caSelectsJumpWhenJumpHasClearlyHighestQValue() {
        let ca = FrankensteinCA()
        let terrain = hurdle()
        let body = FrankensteinBodyState()

        let candidates = FrankensteinActionConstraints.allowedActions(
            terrain: terrain,
            body: body
        )

        #expect(candidates.contains(.jump))

        var values: [FrankensteinAction: Float] = [:]

        for action in candidates {
            values[action] = action == .jump ? 10.0 : -10.0
        }

        let selected = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: candidates,
            qValues: values,
            exploration: 0
        )

        #expect(
            selected == .jump,
            "The CA ignored the highest permitted Q-value."
        )
    }

    @Test
    func explorationCanSelectAnActionOtherThanTheGreedyAction() {
        let ca = FrankensteinCA()
        let terrain = hurdle()
        let body = FrankensteinBodyState()

        let candidates = FrankensteinActionConstraints.allowedActions(
            terrain: terrain,
            body: body
        )

        #expect(candidates.count > 1)

        var values: [FrankensteinAction: Float] = [:]

        for action in candidates {
            values[action] = action == .jump ? 100.0 : -100.0
        }

        // With epsilon = 1, the CA should explore by choosing randomly
        // from the permitted candidates, rather than always choosing jump.
        var selectedNonGreedy = false

        for _ in 0..<100 {
            let selected = ca.decideAction(
                terrain: terrain,
                body: body,
                allowedActions: candidates,
                qValues: values,
                exploration: 1.0
            )

            if selected != .jump {
                selectedNonGreedy = true
                break
            }
        }

        #expect(
            selectedNonGreedy,
            "Exploration never selected a non-greedy action in 100 attempts."
        )
    }

    @Test
    func futilityDetectorPenalizesRepeatedStationaryMovement() {
        let ca = FrankensteinCA()

        // Feed actual stationary coordinates over a period long enough
        // for the detector to recognize lack of progress.
        let start = Date.timeIntervalSinceReferenceDate

        for index in 0..<20 {
            ca.observeMovementForFutility(
                action: .walk,
                x: 1.0,
                z: 1.0,
                timestamp: start + Double(index) * 0.3
            )
        }

        #expect(
            ca.futilityCount > 0,
            "The futility detector did not identify stationary movement."
        )

        #expect(
            ca.futilityPenalty(for: .walk) > 0,
            "The repeated walking action was not penalized."
        )
    }
}
