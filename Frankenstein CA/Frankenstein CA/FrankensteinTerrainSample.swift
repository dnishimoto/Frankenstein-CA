import Foundation

// MARK: - Terrain Sample

/// Environmental observations supplied to Frankenstein's perception,
/// Q-learning, locomotion, and safety systems.
///
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

    // MARK: - Object perception (filled in by the Coordinator)

    /// Resolved name of the detected object, if any.
    var objectName: String = ""

    /// True when the detected object can be lifted and is within reach.
    var objectPickupable: Bool = false

    /// True while Frankenstein is already holding an object.
    var carryingObject: Bool = false

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
    var isLandingAreaClear: Bool = true

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

    /// True when the next ground surface is within the allowed
    /// step-up height. This is a measurement helper, not an
    /// independent movement authorization.
    func isStepUpSafe(maximumHeight: Float = 0.55) -> Bool {
        let rise = nextGroundHeight - groundHeight

        return isGroundAhead &&
        rise > 0 &&
        rise <= maximumHeight
    }

    /// True when the detected ground drops by no more than the
    /// supplied step-down limit.
    func isStepDownSafe(maximumDrop: Float = 0.60) -> Bool {
        let drop = groundHeight - nextGroundHeight

        return isGroundAhead &&
        drop >= 0 &&
        drop <= maximumDrop
    }
}
