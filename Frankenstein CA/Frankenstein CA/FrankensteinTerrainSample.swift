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

    /// Distance to the nearest detected terrain feature[cite: 5].
    var distance: Float = 5

    /// Compatibility alias for Q-learning code that reads distanceAhead[cite: 5].
    var distanceAhead: Float {
        get { distance }
        set { distance = newValue }
    }

    /// Estimated obstacle height above the current ground[cite: 5].
    var obstacleHeight: Float = 0

    /// Estimated obstacle depth along the direction of travel[cite: 5].
    var obstacleDepth: Float = 0

    /// True when the detected obstacle/platform is directly in front of Frankenstein (centered along his look vector).
    var isObstacleCentered: Bool = true

    // MARK: - Object perception

    /// Resolved name of the detected object, if any[cite: 5].
    var objectName: String = ""

    /// True when the detected object can be lifted and is within reach[cite: 5].
    var objectPickupable: Bool = false

    /// True while Frankenstein is already holding an object[cite: 5].
    var carryingObject: Bool = false

    /// True when the detected object is a movable block that can be shoved[cite: 5].
    var objectMovable: Bool = false

    /// True when the top of the detected movable block is within
    /// jump height, large enough to stand on, and has clear space above it[cite: 5].
    var canLandOnObject: Bool = false

    // MARK: - Ground measurements

    /// Height of the ground beneath Frankenstein[cite: 5].
    var groundHeight: Float = 0

    /// Height of the next detected ground or landing surface[cite: 5].
    var nextGroundHeight: Float = 0

    /// Whether usable ground exists a short distance ahead[cite: 5].
    var isGroundAhead: Bool = true

    // MARK: - Chasm measurements

    /// Estimated horizontal width of the gap[cite: 5].
    var gapWidth: Float = 0

    /// Distance from Frankenstein's reference point to the near edge[cite: 5].
    var gapNearEdgeDistance: Float = .infinity

    /// Distance from Frankenstein's reference point to the far edge[cite: 5].
    var gapFarEdgeDistance: Float = .infinity

    /// Landing surface height minus takeoff ground height[cite: 5].
    var landingHeightDelta: Float = 0

    /// Preliminary indication that a landing surface was detected[cite: 5].
    var isLandingAreaClear: Bool = false

    /// True when the path immediately ahead is safely traversable[cite: 5].
    var isTerrainCrossable: Bool = true

    // MARK: - Constants

    /// Maximum planar gap width that may be jumped or stepped across[cite: 5].
    static let maxCrossableGapWidth: Float = 1.2

    // MARK: - Derived measurements

    /// True when both gap edges have finite, valid measurements[cite: 5].
    var hasValidGapEdges: Bool {
        gapNearEdgeDistance.isFinite &&
        gapFarEdgeDistance.isFinite &&
        gapNearEdgeDistance >= 0 &&
        gapFarEdgeDistance > gapNearEdgeDistance
    }

    /// Geometric gap width inferred from the edge distances[cite: 5].
    var measuredGapWidth: Float? {
        guard hasValidGapEdges else {
            return nil
        }
        return gapFarEdgeDistance - gapNearEdgeDistance
    }

    /// True when terrain is a gap that should be routed around[cite: 5].
    var shouldDetourAroundGap: Bool {
        terrain == .gap && !isTerrainCrossable
    }

    /// Gap-specific crossability[cite: 5].
    var gapIsCrossable: Bool {
        isGapCrossable()
    }

    /// Whether the current gap fields describe a crossable chasm[cite: 5].
    func isGapCrossable(
        maximumJumpGap: Float = Self.maxCrossableGapWidth
    ) -> Bool {
        guard terrain == .gap else {
            return true
        }

        guard maximumJumpGap.isFinite, maximumJumpGap > 0 else {
            return false
        }

        guard let measuredWidth = measuredGapWidth else {
            return false
        }

        guard gapWidth.isFinite, gapWidth > 0 else {
            return false
        }

        guard abs(measuredWidth - gapWidth) <= 0.25 else {
            return false
        }

        guard measuredWidth <= maximumJumpGap else {
            return false
        }

        guard isLandingAreaClear else {
            return false
        }

        guard landingHeightDelta.isFinite else {
            return false
        }

        let maxDelta = FrankensteinPhysicalBody.maxJumpableHeight
        guard abs(landingHeightDelta) <= maxDelta else {
            return false
        }

        return true
    }

    /// Recomputes isTerrainCrossable from the current fields[cite: 5].
    mutating func updateCrossability(
        maximumJumpGap: Float = Self.maxCrossableGapWidth
    ) {
        switch terrain {
        case .gap:
            isTerrainCrossable = isGapCrossable(maximumJumpGap: maximumJumpGap)
        default:
            isTerrainCrossable = isGroundAhead
        }
    }

    // MARK: - Step measurements

    /// True when the next ground surface is within the allowed step-up height
    /// and the obstacle/platform is directly in front (centered).
    func isStepUpSafe(
            maximumHeight: Float = 0.65
        ) -> Bool {
            let rise = nextGroundHeight - groundHeight

            // Allow stepping up/positioning if centered, near the target, or preparing a throw/placement
            let isNearTarget = distance <= 1.2
            return isGroundAhead &&
                (isObstacleCentered || isNearTarget) &&
                rise.isFinite &&
                rise >= 0 &&
                rise <= maximumHeight
        }

    /// True when the detected ground drops by no more than the step-down limit[cite: 5].
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
