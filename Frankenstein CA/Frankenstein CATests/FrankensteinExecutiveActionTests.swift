import Foundation
import Testing
@testable import Frankenstein_CA

struct FrankensteinExecutiveActionTests {

    // MARK: - Permitted actions

    @Test
    func executiveNeverSelectsAnActionOutsidePermittedActions() {
        let ca = FrankensteinCA()
        let terrain = FrankensteinTerrainSample()
        let body = FrankensteinBodyState()

        let permitted: [FrankensteinAction] = [.jump]

        let qValues: [FrankensteinAction: Float] = [
            .walk: 100,
            .run: 90,
            .jump: 1
        ]

        let action = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: permitted,
            qValues: qValues,
            exploration: 0
        )

        #expect(action == FrankensteinAction.jump)
        #expect(permitted.contains(action))
    }

    // MARK: - Q-value selection

    @Test
    func executiveSelectsHighestScoringPermittedActionWithoutExploration() {
        let ca = FrankensteinCA()
        let terrain = FrankensteinTerrainSample()
        let body = FrankensteinBodyState()

        let permitted: [FrankensteinAction] = [
            .walk, .run, .jump
        ]

        let qValues: [FrankensteinAction: Float] = [
            .walk: 1,
            .run: 3,
            .jump: 10
        ]

        let action = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: permitted,
            qValues: qValues,
            exploration: 0
        )

        #expect(action == FrankensteinAction.jump)
    }

    // MARK: - Exploration

    @Test
    func explorationCanSelectAnAlternativePermittedAction() {
        let ca = FrankensteinCA()
        let terrain = FrankensteinTerrainSample()
        let body = FrankensteinBodyState()

        let permitted: [FrankensteinAction] = [
            .walk, .run, .jump
        ]

        let qValues: [FrankensteinAction: Float] = [
            .walk: -100,
            .run: -100,
            .jump: 100
        ]

        var selectedAlternative = false

        // Exploration = 1 should select through the exploratory
        // branch if the CA uses epsilon-greedy exploration.
        for _ in 0..<100 {
            let action = ca.decideAction(
                terrain: terrain,
                body: body,
                allowedActions: permitted,
                qValues: qValues,
                exploration: 1
            )

            #expect(permitted.contains(action))

            if action != FrankensteinAction.jump {
                selectedAlternative = true
            }
        }

        #expect(
            selectedAlternative,
            "Exploration should sometimes select a permitted alternative."
        )
    }

    // MARK: - Futility penalties

    @Test
    func futilityPenaltyCanChangeTheExecutiveDecision() {
        let ca = FrankensteinCA()
        let terrain = FrankensteinTerrainSample()
        let body = FrankensteinBodyState()

        let permitted: [FrankensteinAction] = [
            .walk, .run
        ]

        let startTime: TimeInterval = 100

        // Simulate repeated walking with no measured displacement.
        for index in 0..<40 {
            ca.observeMovementForFutility(
                action: .walk,
                x: 1,
                z: 1,
                timestamp: startTime + Double(index) * 0.3
            )
        }

        #expect(ca.futilityCount > 0)

        // Walking has a better raw Q-value, but its futility
        // penalty should make running the preferred action.
        let qValues: [FrankensteinAction: Float] = [
            .walk: 2,
            .run: 0
        ]

        let action = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: permitted,
            qValues: qValues,
            exploration: 0
        )

        #expect(
            action == FrankensteinAction.run,
            "The futility penalty should overcome walking's Q-value advantage."
        )
    }

    // MARK: - Combined executive decision logic

    @Test
    func executiveCombinesQValuesExplorationAndPermittedActions() {
        let ca = FrankensteinCA()
        let terrain = FrankensteinTerrainSample()
        let body = FrankensteinBodyState()

        let permitted: [FrankensteinAction] = [
            .walk, .jump
        ]

        let qValues: [FrankensteinAction: Float] = [
            .walk: 2,
            .jump: 8,
            .run: 1000
        ]

        // Greedy choice: jump has the highest permitted Q-value.
        let greedyAction = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: permitted,
            qValues: qValues,
            exploration: 0
        )

        #expect(greedyAction == FrankensteinAction.jump)
        #expect(permitted.contains(greedyAction))

        // Exploration may change the choice, but never the constraints.
        for _ in 0..<30 {
            let exploredAction = ca.decideAction(
                terrain: terrain,
                body: body,
                allowedActions: permitted,
                qValues: qValues,
                exploration: 1
            )

            #expect(permitted.contains(exploredAction))
        }
    }
}
