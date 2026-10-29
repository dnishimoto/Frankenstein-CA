

import Foundation
import XCTest
@testable import Frankenstein_CA

final class FrankensteinQIntegrationTests: XCTestCase {

    private var policy: FrankensteinLearningPolicy!
    private var ca: FrankensteinCA!
    private var terrain: FrankensteinTerrainSample!
    private var bodyState: FrankensteinBodyState!

    override func setUp() {
        super.setUp()

        policy = FrankensteinLearningPolicy()
        ca = FrankensteinCA()

        terrain = FrankensteinTerrainSample()
        terrain.terrain = .flat
        terrain.distance = 5
        terrain.isGroundAhead = true
        terrain.isLandingAreaClear = true

        bodyState = FrankensteinBodyState()
        bodyState.grounded = true
        bodyState.fallen = false

        print("\n========== Q-LEARNING TEST SETUP ==========")
        print("[TEST] Terrain: \(terrain.terrain)")
        print("[TEST] Distance ahead: \(terrain.distance)")
        print("[TEST] Grounded: \(bodyState.grounded)")
        print("[TEST] Initial update count: \(policy.updateCount)")
        print("===========================================\n")
    }

    override func tearDown() {
        print("\n========== Q-LEARNING TEST TEARDOWN ========")
        print("[TEST] Final update count: \(policy?.updateCount ?? -1)")
        print("============================================\n")

        policy = nil
        ca = nil
        terrain = nil
        bodyState = nil

        super.tearDown()
    }

    // MARK: 1. Verify that positive feedback changes Q-values.

    func testPositiveRewardIncreasesLearnedQValue() {
        print("\n[TEST 1] Positive reward should increase walk Q-value.")

        let before = policy.qValue(
            for: .walk,
            terrain: terrain,
            body: bodyState
        )

        let updatesBefore = policy.updateCount

        print("[TEST 1] Walk Q before learning: \(before)")
        print("[TEST 1] Update count before: \(updatesBefore)")

        let began = policy.beginCAChosenAction(
            .walk,
            terrain: terrain,
            body: bodyState
        )

        print("[TEST 1] beginCAChosenAction returned: \(began)")

        guard began else {
            XCTFail(
                """
                LEARNING FAILED TO START.
                The policy rejected .walk or did not register it as pending.
                Terrain: \(terrain.terrain)
                Grounded: \(bodyState.grounded)
                Update count: \(policy.updateCount)
                """
            )
            return
        }

        let updated = policy.learn(
            reward: 1.0,
            terrain: terrain,
            body: bodyState,
            terminal: true
        )

        print("[TEST 1] learn returned: \(updated)")

        guard updated else {
            XCTFail(
                """
                LEARNING UPDATE FAILED.
                The action was registered, but learn() returned false.
                Check whether the pending action was cleared or rejected.
                Update count before: \(updatesBefore)
                Update count after: \(policy.updateCount)
                """
            )
            return
        }

        let after = policy.qValue(
            for: .walk,
            terrain: terrain,
            body: bodyState
        )

        let updatesAfter = policy.updateCount

        print("[TEST 1] Walk Q after learning: \(after)")
        print("[TEST 1] Q-value change: \(after - before)")
        print("[TEST 1] Update count after: \(updatesAfter)")

        XCTAssertGreaterThan(
            after,
            before,
            """
            Q-VALUE DID NOT INCREASE.
            Before: \(before)
            After: \(after)
            Reward: 1.0
            """
        )

        XCTAssertGreaterThan(
            updatesAfter,
            updatesBefore,
            """
            UPDATE COUNTER DID NOT INCREASE.
            Before: \(updatesBefore)
            After: \(updatesAfter)
            """
        )
    }

    // MARK: 2. Verify that the policy exposes Q-values.

    func testLearnedQValuesAreProvidedToCA() {
        print("\n[TEST 2] Checking policy action values.")

        let values = policy.learnedActionValues(
            terrain: terrain,
            body: bodyState
        )

        print("[TEST 2] Values returned by policy: \(values)")

        XCTAssertFalse(
            values.isEmpty,
            "POLICY RETURNED NO ACTION VALUES for the current state."
        )

        guard !values.isEmpty else { return }

        XCTAssertNotNil(
            values[.walk],
            "POLICY DID NOT PROVIDE A WALK Q-VALUE. Values: \(values)"
        )

        XCTAssertNotNil(
            values[.run],
            "POLICY DID NOT PROVIDE A RUN Q-VALUE. Values: \(values)"
        )
    }

    // MARK: 3. Verify that the CA responds to supplied Q-values.

    func testCASelectsActionFavoredByQValues() {
        print("\n[TEST 3] Checking CA response to supplied Q-values.")

        let allowedActions: [FrankensteinAction] = [.walk, .run]

        let qValues: [FrankensteinAction: Float] = [
            .walk: 0.0,
            .run: 10.0
        ]

        print("[TEST 3] Allowed actions: \(allowedActions)")
        print("[TEST 3] Q-values supplied to CA: \(qValues)")

        let selected = ca.decideAction(
            terrain: terrain,
            body: bodyState,
            allowedActions: allowedActions,
            qValues: qValues
        )

        print("[TEST 3] CA selected: \(selected)")
        print("[TEST 3] CA decision description: \(ca.lastDecisionDescription)")

        XCTAssertEqual(
            selected,
            .run,
            """
            CA DID NOT FAVOR THE ACTION WITH THE HIGHER Q-VALUE.
            Selected: \(selected)
            Expected: run
            Supplied Q-values: \(qValues)
            CA diagnostic: \(ca.lastDecisionDescription)
            """
        )

        XCTAssertTrue(
            ca.lastDecisionDescription.contains("Q=10.0"),
            """
            CA DIAGNOSTIC DOES NOT SHOW THE EXPECTED Q-VALUE.
            Expected Q=10.0
            Actual description: \(ca.lastDecisionDescription)
            """
        )
    }

    // MARK: 4. Verify that a learned value reaches the CA decision.

    func testLearnedQValuesReachCADecision() {
        print("\n[TEST 4] Checking policy-to-CA Q-value flow.")

        let updatesBefore = policy.updateCount

        let began = policy.beginCAChosenAction(
            .run,
            terrain: terrain,
            body: bodyState
        )

        guard began else {
            XCTFail(
                "POLICY FAILED TO REGISTER .run before the integration test."
            )
            return
        }

        let learned = policy.learn(
            reward: 100.0,
            terrain: terrain,
            body: bodyState,
            terminal: true
        )

        guard learned else {
            XCTFail(
                "POLICY FAILED TO UPDATE .run after receiving its reward."
            )
            return
        }

        let values = policy.learnedActionValues(
            terrain: terrain,
            body: bodyState
        )

        print("[TEST 4] Policy values after learning: \(values)")
        print("[TEST 4] Update count: \(updatesBefore) -> \(policy.updateCount)")

        guard
            let runValue = values[.run],
            let walkValue = values[.walk]
        else {
            XCTFail(
                "POLICY VALUES ARE MISSING. Expected both .run and .walk. Values: \(values)"
            )
            return
        }

        XCTAssertGreaterThan(
            runValue,
            walkValue,
            """
            LEARNING DID NOT FAVOR RUN IN THIS STATE.
            Run Q: \(runValue)
            Walk Q: \(walkValue)
            """
        )

        let allowedActions: [FrankensteinAction] = [.walk, .run]

        // Pass the policy's actual learned values, not a fabricated test dictionary.
        let selected = ca.decideAction(
            terrain: terrain,
            body: bodyState,
            allowedActions: allowedActions,
            qValues: values
        )

        let description = ca.lastDecisionDescription

        print("[TEST 4] Q-values passed to CA: \(values)")
        print("[TEST 4] CA selected: \(selected)")
        print("[TEST 4] CA diagnostic: \(description)")

        let selectedValue = values[selected]

        XCTAssertNotNil(
            selectedValue,
            """
            CA SELECTED AN ACTION WITH NO Q-VALUE IN THE POLICY DICTIONARY.
            Selected: \(selected)
            Values: \(values)
            """
        )

        if let selectedValue {
            XCTAssertTrue(
                description.contains("Q=\(selectedValue)"),
                """
                CA DIAGNOSTIC DOES NOT MATCH THE SELECTED ACTION'S Q-VALUE.
                Selected action: \(selected)
                Selected Q-value: \(selectedValue)
                CA description: \(description)
                """
            )
        }

        XCTAssertGreaterThan(
            policy.updateCount,
            updatesBefore,
            "POLICY UPDATE COUNT DID NOT INCREASE during the integration test."
        )
    }
}
