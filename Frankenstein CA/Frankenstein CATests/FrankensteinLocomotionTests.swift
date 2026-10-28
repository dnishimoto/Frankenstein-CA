
import XCTest
@testable import Frankenstein_CA

final class FrankensteinLocomotionTests: XCTestCase {

    private var locomotion: FrankensteinLocomotion!
    private var terrain: FrankensteinTerrainSample!

    override func setUp() {
        super.setUp()
        locomotion = FrankensteinLocomotion()
        terrain = FrankensteinTerrainSample()
        terrain.terrain = .flat
        terrain.distance = 10
        terrain.isGroundAhead = true
        terrain.isLandingAreaClear = true
    }

    override func tearDown() {
        locomotion = nil
        terrain = nil
        super.tearDown()
    }

    // MARK: - Basic movement update

    func testStepProducesFiniteMovementOutput() {
        let output = locomotion.step(
            deltaTime: 0.05,
            terrain: terrain
        )

        XCTAssertTrue(output.speed.isFinite)
        XCTAssertTrue(output.heading.isFinite)
        XCTAssertTrue(output.stride.isFinite)
        XCTAssertTrue(output.jump.isFinite)
        XCTAssertTrue(output.crouch.isFinite)
    }

    func testZeroDeltaTimeDoesNotAdvanceMovement() {
        let before = locomotion.output

        let after = locomotion.step(
            deltaTime: 0,
            terrain: terrain
        )

        XCTAssertEqual(after.speed, before.speed, accuracy: 0.0001)
        XCTAssertEqual(after.heading, before.heading, accuracy: 0.0001)
    }

    func testNegativeDeltaTimeDoesNotAdvanceMovement() {
        let before = locomotion.output

        let after = locomotion.step(
            deltaTime: -0.1,
            terrain: terrain
        )

        XCTAssertEqual(after.speed, before.speed, accuracy: 0.0001)
        XCTAssertEqual(after.heading, before.heading, accuracy: 0.0001)
    }

    // MARK: - Action output consistency

    func testOutputActionIsAssigned() {
        let output = locomotion.step(
            deltaTime: 0.05,
            terrain: terrain
        )

        XCTAssertEqual(output.action, locomotion.output.action)
    }

    func testMovementSpeedIsNonnegative() {
        for _ in 0..<20 {
            let output = locomotion.step(
                deltaTime: 0.05,
                terrain: terrain
            )

            XCTAssertGreaterThanOrEqual(
                output.speed,
                0,
                "Locomotion should not emit a negative speed."
            )
        }
    }

    // MARK: - Movement remains numerically stable

    func testRepeatedUpdatesRemainFinite() {
        for _ in 0..<100 {
            let output = locomotion.step(
                deltaTime: 0.05,
                terrain: terrain
            )

            XCTAssertTrue(output.speed.isFinite)
            XCTAssertTrue(output.heading.isFinite)
            XCTAssertTrue(output.stride.isFinite)
            XCTAssertTrue(output.jump.isFinite)
            XCTAssertTrue(output.crouch.isFinite)
        }
    }

    // MARK: - Terrain safety

    func testUnsafeGapDoesNotAllowUnrestrictedForwardSpeed() {
        var gapTerrain = FrankensteinTerrainSample()
        gapTerrain.terrain = .gap
        gapTerrain.distance = 0.3
        gapTerrain.gapWidth = 1.0
        gapTerrain.isLandingAreaClear = false
        gapTerrain.isGroundAhead = false

        let output = locomotion.step(
            deltaTime: 0.05,
            terrain: gapTerrain
        )

        // If the selected action is a normal horizontal movement action,
        // the locomotion layer should block forward movement at this gap.
        if output.action == .walk ||
            output.action == .run ||
            output.action == .turnLeft ||
            output.action == .turnRight {
            XCTAssertEqual(output.speed, 0, accuracy: 0.0001)
        }
    }
}
