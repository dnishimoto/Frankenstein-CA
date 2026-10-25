

import Foundation
import SceneKit



final class FrankensteinWorldProbe {

    private typealias B = FrankensteinPhysicalBody

    /// The scene's root node. Set by the coordinator once the scene exists.
    var root: SCNNode?

    /// Count of segment tests since the last reset (for diagnostics).
    private(set) var rayCount = 0

    // MARK: Raw queries

    private let hitOptions: [SCNHitTestOption: Any] = [
        .categoryBitMask: FrankensteinPhysicalBody.solidMask,
        .searchMode: SCNHitTestSearchMode.all.rawValue,
        .sortResults: true
    ]

    private func firstSolidHit(
        from a: SCNVector3,
        to b: SCNVector3
    ) -> SCNHitTestResult? {
        guard let root = root else { return nil }

        rayCount += 1

        let hitOptions: [String: Any] = [
            SCNHitTestOption.categoryBitMask.rawValue:
                FrankensteinPhysicalBody.solidMask,
            SCNHitTestOption.searchMode.rawValue:
                SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.sortResults.rawValue: true
        ]
        
        let hits = root.hitTestWithSegment(
            from: a,
            to: b,
            options: hitOptions
        )

        // Do not rely on the option alone to filter.
        return hits.first {
            $0.node.categoryBitMask & B.solidMask != 0
        }
    }

    /// Height of the highest solid surface below (x, z), starting the ray at
    /// `fromY`. Nil when nothing solid lies within `depth`.
    func surfaceHeight(
        x: Float,
        z: Float,
        fromY: Float,
        depth: Float = 14
    ) -> Float? {
        firstSolidHit(
            from: SCNVector3(x, fromY, z),
            to: SCNVector3(x, fromY - depth, z)
        )?.worldCoordinates.y
    }

    /// Height of the underside of a solid above (x, z), if any.
    func ceilingHeight(
        x: Float,
        z: Float,
        fromY: Float,
        rise: Float
    ) -> Float? {
        firstSolidHit(
            from: SCNVector3(x, fromY, z),
            to: SCNVector3(x, fromY + rise, z)
        )?.worldCoordinates.y
    }

    /// Horizontal distance to the first solid surface along a ray.
    func horizontalHit(
        from start: SCNVector3,
        dirX: Float,
        dirZ: Float,
        length: Float
    ) -> Float? {
        guard length > 1e-5 else { return nil }

        let end = SCNVector3(
            start.x + dirX * length,
            start.y,
            start.z + dirZ * length
        )

        guard let hit = firstSolidHit(from: start, to: end) else {
            return nil
        }

        let dx = hit.worldCoordinates.x - start.x
        let dz = hit.worldCoordinates.z - start.z
        return sqrt(dx * dx + dz * dz)
    }

    // MARK: Classification from measurements

    private enum FeatureKind {
        case gap, obstacle, ceiling
    }

    func sense(pose: FrankensteinWorldPose) -> FrankensteinTerrainSample {
        rayCount = 0

        let fx = -sin(pose.heading)
        let fz = -cos(pose.heading)

        let radius = B.radius
        let spacing = B.profileSpacing
        let samples = Int(B.lookAhead / spacing)
        let groundY = pose.referenceY
        let lateral: [Float] = [-0.8 * radius, 0, 0.8 * radius]

        // Lateral unit vector (to his left when facing forward).
        let sx = -fz
        let sz = fx

        // 1. Ground profile ahead: the surface he could stand on. Index i
        // is the point (i + 1) * spacing in front of his centre.
        let probeY = pose.feetY + B.groundProbeRise
        var surface: [Float?] = []
        surface.reserveCapacity(samples)

        for i in 0..<samples {
            let d = Float(i + 1) * spacing

            surface.append(
                surfaceHeight(
                    x: pose.x + fx * d,
                    z: pose.z + fz * d,
                    fromY: probeY
                )
            )
        }

        var hazardIndex: Int?

        for i in 0..<samples {
            guard let h = surface[i] else {
                hazardIndex = i
                break
            }

            if h < groundY - B.maxSafeDrop {
                hazardIndex = i
                break
            }
        }

        // 2. Obstacles straight ahead: horizontal rays at body heights.
        var wallCentreDistance: Float?
        var wallOffset: Float = 0

        for height in B.bodyRayHeights(bodyHeight: pose.bodyHeight) {
            for offset in lateral {
                let start = SCNVector3(
                    pose.x + sx * offset,
                    pose.feetY + height,
                    pose.z + sz * offset
                )

                if let hit = horizontalHit(
                    from: start,
                    dirX: fx,
                    dirZ: fz,
                    length: B.lookAhead
                ) {
                    if wallCentreDistance == nil ||
                        hit < wallCentreDistance! {
                        wallCentreDistance = hit
                        wallOffset = offset
                    }
                }
            }
        }

        // Measure the obstacle's height and thickness from above.
        var obstacleHeight: Float = 0
        var obstacleDepth: Float = 0
        var landingHeight: Float?

        if let wall = wallCentreDistance {
            let topY = pose.feetY + B.tallProbeRise
            let step: Float = 0.25
            var distance = wall + 0.08
            var count = 0

            while count < 12 {
                // Measure along the line that actually hit the obstacle,
                // which may be off to one side of his centre.
                let top = surfaceHeight(
                    x: pose.x + fx * distance + sx * wallOffset,
                    z: pose.z + fz * distance + sz * wallOffset,
                    fromY: topY,
                    depth: B.tallProbeRise + 14
                )

                if count == 0 {
                    obstacleHeight = (top ?? pose.feetY) - pose.feetY
                }

                if let t = top, t > pose.feetY + 0.15 {
                    count += 1
                    distance += step
                } else {
                    landingHeight = top
                    break
                }
            }

            obstacleDepth = Float(count) * step
        }

        // 3. Overhead clearance ahead: vertical rays upward.
        var ceilingDistance: Float?
        var ceilingClearance = Float.greatestFiniteMagnitude
        var c = 0

        while c < samples {
            let d = Float(c + 1) * spacing
            var lowest = Float.greatestFiniteMagnitude

            for offset in lateral {
                if let under = ceilingHeight(
                    x: pose.x + fx * d + sx * offset,
                    z: pose.z + fz * d + sz * offset,
                    fromY: pose.feetY + B.ceilingProbeRise,
                    rise: B.standingHeight + 0.3
                ) {
                    lowest = min(lowest, under - pose.feetY)
                }
            }

            if lowest < B.standingHeight + 0.05 {
                ceilingDistance = d
                ceilingClearance = lowest
                break
            }

            c += 3
        }

        // 4. Choose the nearest feature.
        var best: (kind: FeatureKind, distance: Float)?

        func consider(_ kind: FeatureKind, _ distance: Float) {
            let value = max(0, distance)

            if best == nil || value < best!.distance - 0.001 {
                best = (kind, value)
            }
        }

        if let h = hazardIndex {
            let edge = Float(h + 1) * spacing - spacing * 0.5
            consider(.gap, edge - radius)
        }

        if let wall = wallCentreDistance {
            consider(.obstacle, wall - radius)
        }

        if let d = ceilingDistance {
            consider(.ceiling, d - radius)
        }

        // Ground a short way ahead, used to judge whether he can keep walking.
        let nearIndex = min(2, samples - 1)
        var groundAhead = false

        if let h = surface[nearIndex] {
            groundAhead = h >= groundY - B.maxSafeDrop
        }

        var sample = FrankensteinTerrainSample()
        sample.groundHeight = groundY
        sample.nextGroundHeight = groundY
        sample.isGroundAhead = groundAhead
        sample.distance = B.lookAhead - radius

        guard let feature = best else {
            return sample
        }

        sample.distance = feature.distance

        switch feature.kind {

        case .gap:
            let start = hazardIndex ?? 0
            var landing: Int?
            var j = start

            while j < samples {
                if let h = surface[j], h >= groundY - B.maxSafeDrop {
                    landing = j
                    break
                }

                j += 1
            }

            sample.terrain = .gap
            sample.isGroundAhead = false

            if let l = landing, let landed = surface[l] {
                sample.gapWidth = Float(l - start) * spacing
                sample.nextGroundHeight = landed
                sample.isLandingAreaClear = true
            } else {
                // No far side within sensing range.
                sample.gapWidth = Float(samples - start) * spacing + 1.0
                sample.nextGroundHeight = groundY - B.maxSafeDrop
                sample.isLandingAreaClear = false
            }

        case .obstacle:
            sample.obstacleHeight = obstacleHeight
            sample.obstacleDepth = obstacleDepth

            if obstacleHeight <= B.maxStepHeight + 0.01 {
                sample.terrain = .raisedStep
                sample.nextGroundHeight = pose.feetY + obstacleHeight

            } else if obstacleHeight <= B.maxJumpableHeight {
                if obstacleDepth <= 1.0 {
                    sample.terrain = .hurdle
                    sample.nextGroundHeight = landingHeight ?? groundY
                    sample.isLandingAreaClear = landingHeight != nil
                } else {
                    // A platform to hop up onto.
                    sample.terrain = .raisedStep
                    sample.nextGroundHeight = pose.feetY + obstacleHeight
                }

            } else {
                // Too tall to climb or jump: a wall or a closed door.
                sample.terrain = .uneven
                sample.isLandingAreaClear = false
            }

        case .ceiling:
            sample.terrain = .lowCeiling
            sample.obstacleHeight = ceilingClearance
        }

        return sample
    }
}

