
//
// Frankenstein_CATests.swift
// Frankenstein CATests
//

import Testing
@testable import Frankenstein_CA

struct Frankenstein_CATests {

    // MARK: - Helpers

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

    /// Test-only candidate actions.
    /// This deliberately does not depend on FrankensteinActionConstraints.
    private func candidates(
        terrain: FrankensteinTerrainSample,
        body _: FrankensteinBodyState
    ) -> [FrankensteinAction] {
        switch terrain.terrain {
        case .hurdle:
            return [
                .jump,
                .stepUp,
                .walk,
                .turnLeft,
                .turnRight
            ]

        default:
            return [
                .walk,
                .run,
                .turnLeft,
                .turnRight,
                .jump
            ]
        }
    }

    // MARK: - CA network state

    @Test
    func caInitializesWithAn18By18Network() {
        let ca = FrankensteinCA()

        #expect(ca.size == 18)
        #expect(ca.networkQGrid.count == 18)
        #expect(ca.networkQGrid.allSatisfy { $0.count == 18 })
        #expect(ca.generation == 0)
    }

    @Test
    func qValuesAreStoredInTheirActionNetworkCells() {
        let ca = FrankensteinCA()
        let terrain = hurdle()
        let body = FrankensteinBodyState()
        let allowed = candidates(terrain: terrain, body: body)

        let values: [FrankensteinAction: Float] = [
            .jump: 3.0,
            .stepUp: 0.5,
            .walk: -1.0,
            .turnLeft: -0.2,
            .turnRight: -0.2
        ]

        _ = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: allowed,
            qValues: values
        )

        // Jump maps to (x: 8, y: 2).
        #expect(ca.qValue(atX: 8, y: 2) == 3.0)

        // Walk maps to (x: 8, y: 8).
        #expect(ca.qValue(atX: 8, y: 8) == -1.0)

        // Turn left maps to (x: 4, y: 8).
        #expect(ca.qValue(atX: 4, y: 8) == -0.2)
    }

    @Test
    func missingQValuesResetNetworkCellsToZero() {
        let ca = FrankensteinCA()
        let terrain = hurdle()
        let body = FrankensteinBodyState()
        let allowed = candidates(terrain: terrain, body: body)

        _ = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: allowed,
            qValues: [.jump: 4.0]
        )

        #expect(ca.qValue(atX: 8, y: 2) == 4.0)

        _ = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: allowed,
            qValues: [:]
        )

        #expect(ca.qValue(atX: 8, y: 2) == 0.0)
    }

    @Test
    func invalidNetworkCoordinatesReturnZero() {
        let ca = FrankensteinCA()

        #expect(ca.qValue(atX: -1, y: 0) == 0.0)
        #expect(ca.qValue(atX: 18, y: 0) == 0.0)
        #expect(ca.qValue(atX: 0, y: 18) == 0.0)
    }

    // MARK: - CA action selection

    @Test
    func caSelectsAnAllowedAction() {
        let ca = FrankensteinCA()
        let body = FrankensteinBodyState()
        let terrain = hurdle()
        let allowed = candidates(terrain: terrain, body: body)

        let values: [FrankensteinAction: Float] = [
            .jump: 3.0,
            .stepUp: 0.5,
            .walk: -1.0,
            .turnLeft: -0.2,
            .turnRight: -0.2
        ]

        let action = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: allowed,
            qValues: values
        )

        #expect(allowed.contains(action))
    }

    @Test
    func highestQValueWinsWhenItsActionIsPermitted() {
        let ca = FrankensteinCA()
        let body = FrankensteinBodyState()
        let terrain = hurdle()

        let allowed: [FrankensteinAction] = [
            .jump,
            .walk,
            .turnLeft
        ]

        let values: [FrankensteinAction: Float] = [
            .jump: 3.0,
            .walk: -1.0,
            .turnLeft: -0.2
        ]

        let action = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: allowed,
            qValues: values
        )

        #expect(action == .jump)
        #expect(ca.qValue(atX: 8, y: 2) == 3.0)
    }

    @Test
    func disallowedActionCannotWinWithHighestQValue() {
        let ca = FrankensteinCA()
        let body = FrankensteinBodyState()
        let terrain = hurdle()

        // Jump has the highest Q-value but is not permitted.
        let allowed: [FrankensteinAction] = [
            .walk,
            .turnLeft
        ]

        let values: [FrankensteinAction: Float] = [
            .jump: 100.0,
            .walk: 1.0,
            .turnLeft: 0.0
        ]

        let action = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: allowed,
            qValues: values
        )

        #expect(action == .walk)
        #expect(allowed.contains(action))
    }

    @Test
    func caHandlesAnEmptyAllowedActionList() {
        let ca = FrankensteinCA()
        let body = FrankensteinBodyState()
        let terrain = hurdle()

        let action = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: [],
            qValues: [.jump: 100.0]
        )

        #expect(action == .walk)
        #expect(ca.lastDecisionDescription == "No permitted action")
    }

    // MARK: - CA cellular updates

    @Test
    func caStepAdvancesOneGeneration() {
        let ca = FrankensteinCA()

        ca.step()

        #expect(ca.generation == 1)
    }

    @Test
    func caCanAdvanceWithoutSelectingAnAction() {
        let ca = FrankensteinCA()
        let initialGeneration = ca.generation
        let initialQGrid = ca.networkQGrid

        ca.step()

        #expect(ca.generation == initialGeneration + 1)
        #expect(ca.networkQGrid == initialQGrid)
    }

    @Test
    func resetClearsNetworkQValuesAndGeneration() {
        let ca = FrankensteinCA()
        let terrain = hurdle()
        let body = FrankensteinBodyState()

        _ = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: [.jump, .walk],
            qValues: [
                .jump: 3.0,
                .walk: 1.0
            ]
        )

        ca.step()
        ca.reset()

        #expect(ca.generation == 0)
        #expect(
            ca.networkQGrid.allSatisfy { row in
                row.allSatisfy { $0 == 0.0 }
            }
        )
        #expect(ca.lastDecisionDescription == "Reset")
    }
}
