import Testing
@testable import Frankenstein_CA

struct FrankensteinPolicyTests {

    private func hurdle(height: Float = 0.4, distance: Float = 0.6) -> FrankensteinTerrainSample {
        var s = FrankensteinTerrainSample()
        s.terrain = .hurdle
        s.obstacleHeight = height
        s.distance = distance
        s.isLandingAreaClear = true
        return s
    }

    private func makePolicy() -> FrankensteinLearningPolicy {
        let p = FrankensteinLearningPolicy()
        p.logsUpdates = false
        return p
    }

    @Test func stateDistinguishesTerrainDistanceAndSize() {
        let policy = makePolicy()
        let body = FrankensteinBodyState()

        var flat = FrankensteinTerrainSample(); flat.terrain = .flat
        var gap = FrankensteinTerrainSample()
        gap.terrain = .gap; gap.gapWidth = 1.2; gap.distance = 0.65
        var step = FrankensteinTerrainSample()
        step.terrain = .raisedStep; step.obstacleHeight = 0.3

        let keys = Set([
            policy.stateKey(terrain: flat, body: body),
            policy.stateKey(terrain: gap, body: body),
            policy.stateKey(terrain: step, body: body),
            policy.stateKey(terrain: hurdle(height: 0.3, distance: 0.4), body: body),
            policy.stateKey(terrain: hurdle(height: 0.7, distance: 0.4), body: body),
            policy.stateKey(terrain: hurdle(height: 0.3, distance: 1.5), body: body)
        ])
        #expect(keys.count == 6)
    }

    @Test func readingValuesNeverChangesTheTable() {
        let policy = makePolicy()
        let body = FrankensteinBodyState()
        _ = policy.learnedActionValues(terrain: hurdle(), body: body)
        #expect(policy.learnedStateCount == 0)
        #expect(!policy.isAwaitingOutcome)
    }

    @Test func oneCompletedActionMakesExactlyOneUpdate() {
        let policy = makePolicy()
        let body = FrankensteinBodyState()
        let terrain = hurdle()

        #expect(policy.beginCAChosenAction(.jump, terrain: terrain, body: body))
        #expect(policy.learn(reward: 3, terrain: terrain, body: body))
        #expect(!policy.learn(reward: 3, terrain: terrain, body: body))
        #expect(policy.updateCount == 1)

        let record = policy.updateLog[0]
        #expect(record.action == .jump)
        #expect(record.oldValue == 0)
        #expect(record.newValue > 0.3 && record.newValue < 0.5)
    }

    @Test func jumpOutcomeOnlyCreditsAPendingJump() {
        let policy = makePolicy()
        let body = FrankensteinBodyState()
        _ = policy.beginCAChosenAction(.walk, terrain: hurdle(), body: body)
        #expect(!policy.reportJumpOutcome(succeeded: true, terrain: hurdle(), body: body))
        #expect(policy.updateCount == 0)
    }

    @Test func stateDistinguishesObjectIdentityPickupAndCarrying() {
        let policy = makePolicy()
        let body = FrankensteinBodyState()

        var crate = FrankensteinTerrainSample()
        crate.terrain = .hurdle; crate.obstacleHeight = 0.4; crate.distance = 0.6
        crate.objectName = "Crate"; crate.objectPickupable = true

        var platform = crate
        platform.objectName = "Platform"; platform.objectPickupable = false

        var carrying = crate
        carrying.carryingObject = true

        let keys = Set([
            policy.stateKey(terrain: crate, body: body),
            policy.stateKey(terrain: platform, body: body),
            policy.stateKey(terrain: carrying, body: body)
        ])
        #expect(keys.count == 3)
    }

    @Test func constraintsOfferNewActions() {
        var flat = FrankensteinTerrainSample()
        flat.terrain = .flat
        flat.objectPickupable = true

        let actions = FrankensteinActionConstraints.allowedActions(
            terrain: flat, body: FrankensteinBodyState()
        )
        #expect(actions.contains(.backward))
        #expect(actions.contains(.stepForward))
        #expect(actions.contains(.liftObject))

        flat.carryingObject = true
        #expect(!FrankensteinActionConstraints.allowedActions(
            terrain: flat, body: FrankensteinBodyState()
        ).contains(.liftObject))
    }

    @Test func caLearnsToJumpTheHurdle() {
        let policy = makePolicy()
        let ca = FrankensteinCA()
        let body = FrankensteinBodyState()
        let terrain = hurdle()

        func reward(_ a: FrankensteinAction) -> Float {
            switch a {
            case .jump: return 3.0
            case .stepUp: return 0.5
            case .backward: return -0.3
            default: return -0.2
            }
        }

        let candidates = FrankensteinActionConstraints.allowedActions(terrain: terrain, body: body)
        #expect(candidates.contains(.jump))

        // Deterministic exploration: try every candidate several times,
        // then let the CA choose from the learned values alone.
        let explorationEpisodes = candidates.count * 5
        let totalEpisodes = explorationEpisodes + 100
        var lateJumps = 0

        for e in 0..<totalEpisodes {
            let action: FrankensteinAction
            if e < explorationEpisodes {
                action = candidates[e % candidates.count]
            } else {
                action = ca.decideAction(
                    terrain: terrain, body: body,
                    allowedActions: candidates,
                    qValues: policy.learnedActionValues(terrain: terrain, body: body),
                    exploration: 0
                )
                if action == .jump { lateJumps += 1 }
            }

            #expect(policy.beginCAChosenAction(action, terrain: terrain, body: body))
            #expect(policy.learn(reward: reward(action), terrain: terrain, body: body, nextActions: candidates))
            ca.step()
        }

        #expect(policy.updateCount == totalEpisodes)
        #expect(policy.qValue(for: .jump, terrain: terrain, body: body) >
                policy.qValue(for: .backward, terrain: terrain, body: body))
        #expect(lateJumps == 100)
    }
}
