import Foundation

// MARK: - Terrain Sample

/// Environmental observations supplied to Frankenstein's perception,
/// Q-learning, locomotion, and safety systems.
///

import Foundation

/// Distances and dimensions are expressed in SceneKit world units,
/// normally meters when the scene uses a meter-based scale.
///
/// `isLandingAreaClear` is preliminary sensor evidence, not a guarantee
/// that a jump is safe. The locomotion controller must recheck safety.

struct FrankensteinTerrainSample {

    // MARK: - Terrain classification

    var terrain: FrankensteinTerrain = .flat

    // MARK: - General measurements

    /// Distance to the nearest detected terrain feature.
    var distance: Float = 5

    /// Compatibility alias for Q-learning code that reads distanceAhead.
    var distanceAhead: Float {
        get { distance }
        set { distance = newValue }
    }

    /// Estimated obstacle height above the current ground.
    var obstacleHeight: Float = 0

    /// Estimated obstacle depth along the direction of travel.
    var obstacleDepth: Float = 0

    // MARK: - Object perception

    /// Resolved name of the detected object, if any.
    var objectName: String = ""

    /// True when the detected object can be lifted and is within reach.
    var objectPickupable: Bool = false

    /// True while Frankenstein is already holding an object.
    var carryingObject: Bool = false

    /// True when the detected object is a movable block that can be shoved.
    var objectMovable: Bool = false

    /// True when the top of the detected movable block is within
    /// jump height, large enough to stand on, and has clear space above it.
    ///
    /// This is preliminary geometric evidence, not permission to jump.
    var canLandOnObject: Bool = false

    // MARK: - Ground measurements

    /// Height of the ground beneath Frankenstein.
    var groundHeight: Float = 0

    /// Height of the next detected ground or landing surface.
    var nextGroundHeight: Float = 0

    /// Whether usable ground exists a short distance ahead.
    var isGroundAhead: Bool = true

    // MARK: - Chasm measurements

    /// Estimated horizontal width of the gap.
    var gapWidth: Float = 0

    /// Distance from Frankenstein's reference point to the near edge.
    var gapNearEdgeDistance: Float = .infinity

    /// Distance from Frankenstein's reference point to the far edge.
    var gapFarEdgeDistance: Float = .infinity

    /// Landing surface height minus takeoff ground height.
    /// Negative means the landing surface is lower.
    var landingHeightDelta: Float = 0

    /// Preliminary indication that a landing surface was detected.
    /// Defaults to false so missing sensor data cannot authorize a jump.
    var isLandingAreaClear: Bool = false

    /// True when the path immediately ahead is safely traversable
    /// according to the current terrain measurements.
    var isTerrainCrossable: Bool = true

    // MARK: - Constants

    /// Maximum planar gap width that may be jumped or stepped across.
    static let maxCrossableGapWidth: Float = 1.2

    // MARK: - Derived measurements

    /// True when both gap edges have finite, valid measurements.
    var hasValidGapEdges: Bool {
        gapNearEdgeDistance.isFinite &&
        gapFarEdgeDistance.isFinite &&
        gapNearEdgeDistance >= 0 &&
        gapFarEdgeDistance > gapNearEdgeDistance
    }

    /// Geometric gap width inferred from the edge distances.
    /// Returns nil if the edge measurements are invalid.
    var measuredGapWidth: Float? {
        guard hasValidGapEdges else {
            return nil
        }

        return gapFarEdgeDistance - gapNearEdgeDistance
    }

    /// True when terrain is a gap that should be routed around,
    /// rather than crossed.
    var shouldDetourAroundGap: Bool {
        terrain == .gap && !isTerrainCrossable
    }

    /// Gap-specific crossability.
    var gapIsCrossable: Bool {
        isGapCrossable()
    }

    /// Whether the current gap fields describe a crossable chasm.
    func isGapCrossable(
        maximumJumpGap: Float = Self.maxCrossableGapWidth
    ) -> Bool {

        guard terrain == .gap else {
            return true
        }

        guard maximumJumpGap.isFinite,
              maximumJumpGap > 0 else {
            return false
        }

        // Prefer geometry measured from both gap edges.
        guard let measuredWidth = measuredGapWidth else {
            return false
        }

        // Reject inconsistent or invalid measurements.
        guard gapWidth.isFinite,
              gapWidth > 0 else {
            return false
        }

        // Require the reported and geometrically measured widths
        // to agree within a small sensor tolerance.
        guard abs(measuredWidth - gapWidth) <= 0.25 else {
            return false
        }

        guard measuredWidth <= maximumJumpGap else {
            return false
        }

        // A detected landing surface is necessary but not sufficient.
        guard isLandingAreaClear else {
            return false
        }

        guard landingHeightDelta.isFinite else {
            return false
        }

        let maxDelta =
            FrankensteinPhysicalBody.maxJumpableHeight

        guard abs(landingHeightDelta) <= maxDelta else {
            return false
        }

        return true
    }

    /// Recomputes isTerrainCrossable from the current fields.
    /// Call from the Coordinator after probes are filled.
    mutating func updateCrossability(
        maximumJumpGap: Float = Self.maxCrossableGapWidth
    ) {

        switch terrain {

        case .gap:
            isTerrainCrossable = isGapCrossable(
                maximumJumpGap: maximumJumpGap
            )

        default:
            isTerrainCrossable = isGroundAhead
        }
    }

    // MARK: - Step measurements

    /// True when the next ground surface is within the allowed
    /// step-up height. This is a measurement helper, not an
    /// independent movement authorization.
    func isStepUpSafe(
        maximumHeight: Float = 0.55
    ) -> Bool {

        let rise = nextGroundHeight - groundHeight

        return isGroundAhead &&
            rise.isFinite &&
            rise > 0 &&
            rise <= maximumHeight
    }

    /// True when the detected ground drops by no more than
    /// the supplied step-down limit.
    func isStepDownSafe(
        maximumDrop: Float = 0.60
    ) -> Bool {

        let drop = groundHeight - nextGroundHeight

        return isGroundAhead &&
            drop.isFinite &&
            drop >= 0 &&
            drop <= maximumDrop
    }
}
