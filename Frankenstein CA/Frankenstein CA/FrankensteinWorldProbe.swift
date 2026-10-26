
import Foundation
import SceneKit

final class FrankensteinWorldProbe {

    private typealias B = FrankensteinPhysicalBody

    /// The scene root. Assign this once the scene has been created.
    var root: SCNNode?

    /// Number of segment tests performed during the most recent sense pass.
    private(set) var rayCount = 0

    // MARK: - Raw queries

    private func firstSolidHit(
        from a: SCNVector3,
        to b: SCNVector3
    ) -> SCNHitTestResult? {
        guard let root = root else { return nil }

        rayCount += 1

        let options: [String: Any] = [
            SCNHitTestOption.categoryBitMask.rawValue:
                B.solidMask,
            SCNHitTestOption.searchMode.rawValue:
                SCNHitTestSearchMode.all.rawValue,
            SCNHitTestOption.sortResults.rawValue:
                true
        ]

        let hits = root.hitTestWithSegment(
            from: a,
            to: b,
            options: options
        )

        return hits.first {
            ($0.node.categoryBitMask & B.solidMask) != 0
        }
    }

    /// Highest solid surface found below the specified point.
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

    /// First solid surface encountered above the specified point.
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

    /// Horizontal distance to the first solid surface.
    func horizontalHit(
        from start: SCNVector3,
        dirX: Float,
        dirZ: Float,
        length: Float
    ) -> Float? {
        guard length > 0.00001 else { return nil }

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

    // MARK: - Classification

    private enum FeatureKind {
        case gap
        case obstacle
        case ceiling
    }

    func sense(
        pose: FrankensteinWorldPose
    ) -> FrankensteinTerrainSample {
        rayCount = 0

        let fx = -sin(pose.heading)
        let fz = -cos(pose.heading)

        let radius = B.radius
        let spacing = max(B.profileSpacing, 0.05)
        let samples = max(1, Int(B.lookAhead / spacing))
        let groundY = pose.referenceY

        let lateral: [Float] = [
            -0.8 * radius,
            0,
            0.8 * radius
        ]

        // Left/right direction perpendicular to forward.
        let sx = -fz
        let sz = fx

        // MARK: 1. Ground profile

        // Each entry represents the ground below a forward sample.
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

        // Treat missing ground or a dangerously low surface as a gap.
        var hazardIndex: Int?

        for i in 0..<samples {
            guard let height = surface[i] else {
                hazardIndex = i
                break
            }

            if height < groundY - B.maxSafeDrop {
                hazardIndex = i
                break
            }
        }

        // MARK: 2. Horizontal obstacle scan

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

        // Estimate obstacle height and depth.
        var obstacleHeight: Float = 0
        var obstacleDepth: Float = 0
        var obstacleLandingHeight: Float?

        if let wall = wallCentreDistance {
            let topY = pose.feetY + B.tallProbeRise
            let step: Float = 0.25
            var distance = wall + 0.08
            var occupiedSamples = 0

            for index in 0..<12 {
                let top = surfaceHeight(
                    x: pose.x + fx * distance + sx * wallOffset,
                    z: pose.z + fz * distance + sz * wallOffset,
                    fromY: topY,
                    depth: B.tallProbeRise + 14
                )

                if index == 0 {
                    obstacleHeight = max(
                        0,
                        (top ?? pose.feetY) - pose.feetY
                    )
                }

                if let top, top > pose.feetY + 0.15 {
                    occupiedSamples += 1
                    distance += step
                } else {
                    obstacleLandingHeight = top
                    break
                }
            }

            obstacleDepth = Float(occupiedSamples) * step
        }

        // MARK: 3. Overhead clearance

        var ceilingDistance: Float?
        var ceilingClearance = Float.greatestFiniteMagnitude

        // Check every profile interval so narrow overhead obstacles
        // are less likely to be skipped.
        for i in 0..<samples {
            let d = Float(i + 1) * spacing
            var lowest = Float.greatestFiniteMagnitude

            for offset in lateral {
                if let underside = ceilingHeight(
                    x: pose.x + fx * d + sx * offset,
                    z: pose.z + fz * d + sz * offset,
                    fromY: pose.feetY + B.ceilingProbeRise,
                    rise: B.standingHeight + 0.3
                ) {
                    lowest = min(
                        lowest,
                        underside - pose.feetY
                    )
                }
            }

            if lowest < B.standingHeight + 0.05 {
                ceilingDistance = d
                ceilingClearance = lowest
                break
            }
        }

        // MARK: 4. Select nearest feature

        var best: (kind: FeatureKind, distance: Float)?

        func consider(_ kind: FeatureKind, _ distance: Float) {
            let value = max(0, distance)

            if best == nil || value < best!.distance {
                best = (kind, value)
            }
        }

        if let hazard = hazardIndex {
            let firstMissingDistance = Float(hazard + 1) * spacing

            // Approximate the near edge relative to Frankenstein's centre.
            let nearEdgeDistance = max(
                0,
                firstMissingDistance - spacing * 0.5 - radius
            )

            consider(.gap, nearEdgeDistance)
        }

        if let wall = wallCentreDistance {
            consider(.obstacle, wall - radius)
        }

        if let ceiling = ceilingDistance {
            consider(.ceiling, ceiling - radius)
        }

        // Basic sample before classifying the nearest feature.
        let nearIndex = min(2, samples - 1)
        let groundAhead: Bool

        if let height = surface[nearIndex] {
            groundAhead = height >= groundY - B.maxSafeDrop
        } else {
            groundAhead = false
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
            var landingIndex: Int?

            // Continue forward until a usable landing surface is found.
            if start + 1 < samples {
                for j in (start + 1)..<samples {
                    guard let height = surface[j] else {
                        continue
                    }

                    let isUsableHeight =
                        height >= groundY - B.maxSafeDrop

                    if isUsableHeight {
                        landingIndex = j
                        break
                    }
                }
            }

            sample.terrain = .gap
            sample.isGroundAhead = false
            sample.gapNearEdgeDistance = feature.distance

            if let landingIndex,
               let landingHeight = surface[landingIndex] {
                let nearEdgeSampleDistance =
                    Float(start + 1) * spacing - spacing * 0.5

                let farEdgeSampleDistance =
                    Float(landingIndex + 1) * spacing - spacing * 0.5

                let nearEdge = max(0, nearEdgeSampleDistance)
                let farEdge = max(nearEdge, farEdgeSampleDistance)

                sample.gapNearEdgeDistance = max(
                    0,
                    nearEdge - radius
                )
                sample.gapFarEdgeDistance = farEdge
                sample.gapWidth = max(0, farEdge - nearEdge)
                sample.nextGroundHeight = landingHeight
                sample.landingHeightDelta = landingHeight - groundY

                // This is only a preliminary check: actual landing clearance
                // should also be verified during flight.
                sample.isLandingAreaClear = true
            } else {
                // No far platform found within the probe's range.
                sample.gapFarEdgeDistance = .infinity
                sample.gapWidth = .infinity
                sample.nextGroundHeight = groundY - B.maxSafeDrop
                sample.landingHeightDelta = -B.maxSafeDrop
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
                    sample.nextGroundHeight =
                        obstacleLandingHeight ?? groundY
                    sample.isLandingAreaClear =
                        obstacleLandingHeight != nil
                } else {
                    sample.terrain = .raisedStep
                    sample.nextGroundHeight =
                        pose.feetY + obstacleHeight
                }

            } else {
                // A tall wall or closed door is not a normal jumpable hurdle.
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
