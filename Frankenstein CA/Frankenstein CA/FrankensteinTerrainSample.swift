

import Foundation

struct FrankensteinTerrainSample {

    // MARK: - Terrain classification

    var terrain: FrankensteinTerrain = .flat

    // MARK: - General measurements

    /// Distance to the nearest detected terrain feature.
    var distance: Float = 5

    /// Estimated obstacle height above the current ground.
    var obstacleHeight: Float = 0

    /// Estimated obstacle depth along the direction of travel.
    var obstacleDepth: Float = 0

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
}
