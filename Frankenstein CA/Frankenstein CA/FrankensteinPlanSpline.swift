//  FrankensteinPlanSpline.swift
//  Frankenstein CA
//
//  Draws the current plan as a spline with elevation/step-up handling:
//    cyan   curve  Frankenstein -> the object/platform
//    orange curve  that object  -> where the plan wants it to go
//
//  All nodes have "Marker" in their names, so raycasts, detection and
//  physics ignore them.
//

import Foundation
import SceneKit
import UIKit
import simd

final class FrankensteinPlanSpline {

    var isVisible = true

    // Expose 3D path arrays for navigation steering (including elevation for platforms/steps)
    private(set) var approachPath: [SIMD3<Float>] = []
    private(set) var deliveryPath: [SIMD3<Float>] = []

    // Legacy 2D compatibility accessors for code expecting SIMD2
    var approachPath2D: [SIMD2<Float>] { approachPath.map { SIMD2<Float>($0.x, $0.z) } }
    var deliveryPath2D: [SIMD2<Float>] { deliveryPath.map { SIMD2<Float>($0.x, $0.z) } }

    private let rootName = "PlanSplineMarker"
    private weak var scene: SCNScene?

    private var approachNode = SCNNode()
    private var deliveryNode = SCNNode()
    private var targetRing = SCNNode()
    private var destinationRing = SCNNode()

    private let standOff: Float = 0.9
    private let samplesPerSegment = 12

    private var lastKey = ""
    private var lastUpdate: TimeInterval = 0

    // MARK: - Keep-out zones (the chasm)

    /// Rectangles (world X/Z) the path must go around, not across.
    private var keepOutZones: [(center: SIMD2<Float>, half: SIMD2<Float>)] = []
    private var keepOutLoaded = false
    /// Clearance kept between the path and the edge of a keep-out zone.
    private let keepOutMargin: Float = 0.8

    private func loadKeepOutZones() {
        guard !keepOutLoaded, let scene else { return }
        let nodes = scene.rootNode.childNodes { node, _ in
            let name = (node.name ?? "").lowercased()
            return name.contains("chasm") && node.geometry != nil
        }
        guard !nodes.isEmpty else { return }
        keepOutLoaded = true
        keepOutZones = nodes.map { node in
            let box = node.boundingBox
            let p = node.worldPosition
            return (
                SIMD2<Float>(Float(p.x), Float(p.z)),
                SIMD2<Float>(
                    Float(box.max.x - box.min.x) * 0.5,
                    Float(box.max.z - box.min.z) * 0.5
                )
            )
        }
    }

    /// True when the straight segment a->b crosses the rectangle.
    private func segmentCrosses(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>,
        center: SIMD2<Float>, half: SIMD2<Float>
    ) -> Bool {
        let lo = center - half + SIMD2<Float>(repeating: 0.01)
        let hi = center + half - SIMD2<Float>(repeating: 0.01)
        let d = b - a
        var t0: Float = 0
        var t1: Float = 1
        for axis in 0..<2 {
            if abs(d[axis]) < 1e-6 {
                if a[axis] < lo[axis] || a[axis] > hi[axis] { return false }
            } else {
                var ta = (lo[axis] - a[axis]) / d[axis]
                var tb = (hi[axis] - a[axis]) / d[axis]
                if ta > tb { swap(&ta, &tb) }
                t0 = max(t0, ta)
                t1 = min(t1, tb)
                if t0 > t1 { return false }
            }
        }
        return true
    }

    private func inside(_ p: SIMD2<Float>, center: SIMD2<Float>, half: SIMD2<Float>) -> Bool {
        abs(p.x - center.x) < half.x && abs(p.y - center.y) < half.y
    }

    /// Waypoints from a to b that go around the corners of any keep-out
    /// zone the straight line would cross. [a, b] when the way is clear.
    private func route(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> [SIMD2<Float>] {
        loadKeepOutZones()
        for zone in keepOutZones {
            let half = zone.half + SIMD2<Float>(repeating: keepOutMargin)
            guard !inside(a, center: zone.center, half: half),
                  !inside(b, center: zone.center, half: half),
                  segmentCrosses(a, b, center: zone.center, half: half) else { continue }

            // Corners of the inflated rectangle, in order around it.
            let c = zone.center
            let corners = [
                SIMD2<Float>(c.x - half.x, c.y - half.y),
                SIMD2<Float>(c.x + half.x, c.y - half.y),
                SIMD2<Float>(c.x + half.x, c.y + half.y),
                SIMD2<Float>(c.x - half.x, c.y + half.y)
            ]
            func clear(_ p: SIMD2<Float>, _ q: SIMD2<Float>) -> Bool {
                !segmentCrosses(p, q, center: zone.center, half: half)
            }
            var best: [SIMD2<Float>]?
            var bestLength = Float.greatestFiniteMagnitude
            func consider(_ via: [SIMD2<Float>]) {
                var pts = [a] + via + [b]
                var length: Float = 0
                for i in 0..<(pts.count - 1) {
                    guard clear(pts[i], pts[i + 1]) else { return }
                    length += simd_distance(pts[i], pts[i + 1])
                }
                if length < bestLength {
                    bestLength = length
                    best = pts
                }
                pts.removeAll()
            }
            for i in 0..<4 {
                consider([corners[i]])
                consider([corners[i], corners[(i + 1) % 4]])
                consider([corners[(i + 1) % 4], corners[i]])
            }
            if let best { return best }
        }
        return [a, b]
    }

    /// Adds points along each leg so the smoothing spline stays close to
    /// the corner-to-corner route instead of cutting across the zone.
    private func densify(_ points: [SIMD2<Float>], spacing: Float = 0.8) -> [SIMD2<Float>] {
        guard points.count >= 2 else { return points }
        var result: [SIMD2<Float>] = [points[0]]
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let length = simd_distance(a, b)
            let steps = max(1, Int((length / spacing).rounded(.up)))
            for step in 1...steps {
                result.append(a + (b - a) * (Float(step) / Float(steps)))
            }
        }
        return result
    }

    // MARK: - Look-Ahead Navigation (3D Elevation Aware)

    func lookAheadPoint(
        from position: SCNVector3,
        path: [SIMD3<Float>],
        distance: Float = 0.8
    ) -> SCNVector3? {
        guard path.count >= 2 else { return nil }

        let p = SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z))
        var nearestIndex = 0
        var nearestDistance = Float.greatestFiniteMagnitude

        for i in path.indices {
            let dx = p.x - path[i].x
            let dz = p.z - path[i].z
            let d = sqrt(dx * dx + dz * dz)

            if d < nearestDistance {
                nearestDistance = d
                nearestIndex = i
            }
        }

        var remaining = max(0, distance)
        var current = path[nearestIndex]

        for i in nearestIndex..<(path.count - 1) {
            let next = path[i + 1]
            let segment = next - current
            let segmentLength = simd_length(segment)

            if segmentLength <= 0.0001 {
                current = next
                continue
            }

            if remaining <= segmentLength {
                return SCNVector3(current + segment / segmentLength * remaining)
            }

            remaining -= segmentLength
            current = next
        }

        return SCNVector3(path.last!)
    }

    // MARK: Setup

    func attach(to scene: SCNScene) {
        self.scene = scene

        scene.rootNode.childNode(withName: rootName, recursively: false)?
            .removeFromParentNode()

        let root = SCNNode()
        root.name = rootName

        approachNode = SCNNode()
        approachNode.name = "PlanSplineMarker_Approach"
        deliveryNode = SCNNode()
        deliveryNode.name = "PlanSplineMarker_Delivery"

        targetRing = makeRing(color: .cyan, radius: 0.45)
        targetRing.name = "PlanSplineMarker_TargetRing"

        destinationRing = makeRing(color: .orange, radius: 0.55)
        destinationRing.name = "PlanSplineMarker_DestRing"

        for node in [approachNode, deliveryNode, targetRing, destinationRing] {
            node.isHidden = true
            root.addChildNode(node)
        }

        scene.rootNode.addChildNode(root)
    }

    private func makeRing(color: UIColor, radius: CGFloat) -> SCNNode {
        let ring = SCNTorus(ringRadius: radius, pipeRadius: 0.025)
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        ring.materials = [material]

        let node = SCNNode(geometry: ring)
        node.castsShadow = false
        return node
    }

    // MARK: Update (Elevation & Step-Up Aware)

    func update(
        time: TimeInterval,
        character: SCNVector3,
        object: SCNVector3?,
        destination: SCNVector3?,
        approachFromCharacterSide: Bool = false
    ) {
        guard isVisible, let destination else {
            hideAll()
            return
        }

        guard time - lastUpdate >= 0.1 else { return }
        lastUpdate = time

        let key = String(
            format: "%.1f,%.1f,%.1f|%@|%.1f,%.1f,%.1f|%d",
            Double(character.x), Double(character.y), Double(character.z),
            object.map { String(format: "%.1f,%.1f,%.1f", Double($0.x), Double($0.y), Double($0.z)) } ?? "-",
            Double(destination.x), Double(destination.y), Double(destination.z),
            approachFromCharacterSide ? 1 : 0
        )

        guard key != lastKey else { return }
        lastKey = key

        let start2D = SIMD2<Float>(Float(character.x), Float(character.z))
        let end2D = SIMD2<Float>(Float(destination.x), Float(destination.z))
        let startY = Float(character.y)
        let endY = Float(destination.y)

        destinationRing.isHidden = false
        destinationRing.position = SCNVector3(destination.x, destination.y + 0.02, destination.z)

        guard let object else {
            let legRoute = route(start2D, end2D)
            let curve2D = legRoute.count > 2
                ? spline2D(through: densify(legRoute))
                : spline2D(through: [start2D, (start2D + end2D) * 0.5, end2D])
            
            approachPath = curve2D.enumerated().map { index, pt in
                let t = Float(index) / Float(max(1, curve2D.count - 1))
                let y = startY + (endY - startY) * t
                return SIMD3<Float>(pt.x, y, pt.y)
            }
            deliveryPath = []
            approachNode.geometry = lineGeometry3D(approachPath, color: .cyan)
            approachNode.isHidden = false
            deliveryNode.isHidden = true
            targetRing.isHidden = true
            return
        }

        let obj2D = SIMD2<Float>(Float(object.x), Float(object.z))
        let objY = Float(object.y)

        var pushDirection = end2D - obj2D
        let pushLength = simd_length(pushDirection)
        pushDirection = pushLength > 0.001 ? pushDirection / pushLength : SIMD2<Float>(0, -1)

        var standPoint2D = obj2D - pushDirection * standOff
        if approachFromCharacterSide {
            let toObject = obj2D - start2D
            let distance = simd_length(toObject)
            if distance > standOff {
                standPoint2D = obj2D - toObject / distance * standOff
            } else {
                standPoint2D = start2D
            }
        }

        let toStand = standPoint2D - start2D
        let side = SIMD2<Float>(-toStand.y, toStand.x)
        let sideLength = simd_length(side)
        let bow = sideLength > 0.001 ? side / sideLength * min(0.5, simd_length(toStand) * 0.15) : .zero

        let approachRoute = route(start2D, standPoint2D)
        let approachVia: [SIMD2<Float>] = approachRoute.count > 2
            ? densify(approachRoute)
            : [start2D, start2D + toStand * 0.5 + bow, standPoint2D]
        
        let curveApproach2D = spline2D(through: approachVia + [obj2D])
        let fullApproach3D = curveApproach2D.enumerated().map { index, pt in
            let t = Float(index) / Float(max(1, curveApproach2D.count - 1))
            let y = startY + (objY - startY) * pow(t, 0.7)
            return SIMD3<Float>(pt.x, y, pt.y)
        }

        if approachFromCharacterSide {
            let partialCount = max(2, Int(Double(fullApproach3D.count) * 0.85))
            approachPath = Array(fullApproach3D.prefix(partialCount))
        } else {
            approachPath = fullApproach3D
        }

        let across = end2D - obj2D
        let acrossSide = SIMD2<Float>(-across.y, across.x)
        let acrossSideLength = simd_length(acrossSide)
        let acrossBow = acrossSideLength > 0.001
            ? acrossSide / acrossSideLength * min(0.4, simd_length(across) * 0.1)
            : .zero

        let deliveryRoute = route(obj2D, end2D)
        let curveDelivery2D = deliveryRoute.count > 2
            ? spline2D(through: densify(deliveryRoute))
            : spline2D(through: [obj2D, obj2D + across * 0.5 + acrossBow, end2D])
        
        deliveryPath = curveDelivery2D.enumerated().map { index, pt in
            let t = Float(index) / Float(max(1, curveDelivery2D.count - 1))
            let y = objY + (endY - objY) * t
            return SIMD3<Float>(pt.x, y, pt.y)
        }

        approachNode.geometry = lineGeometry3D(approachPath, color: .cyan)
        deliveryNode.geometry = lineGeometry3D(deliveryPath, color: .orange)
        approachNode.isHidden = false
        deliveryNode.isHidden = false

        targetRing.isHidden = false
        targetRing.position = SCNVector3(object.x, objY + 0.02, object.z)
    }

    private func hideAll() {
        approachPath = []
        deliveryPath = []
        approachNode.isHidden = true
        deliveryNode.isHidden = true
        targetRing.isHidden = true
        destinationRing.isHidden = true
        lastKey = ""
    }

    // MARK: Spline Math

    private func spline2D(through points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 2 else { return points }

        let padded = [points[0]] + points + [points[points.count - 1]]
        var result: [SIMD2<Float>] = []

        for i in 1..<(padded.count - 2) {
            let p0 = padded[i - 1]
            let p1 = padded[i]
            let p2 = padded[i + 1]
            let p3 = padded[i + 2]

            for step in 0..<samplesPerSegment {
                let t = Float(step) / Float(samplesPerSegment)
                let t2 = t * t
                let t3 = t2 * t

                let point =
                    0.5 * (
                        (2 * p1) +
                        (-p0 + p2) * t +
                        (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
                        (-p0 + 3 * p1 - 3 * p2 + p3) * t3
                    )

                result.append(point)
            }
        }

        result.append(points[points.count - 1])
        return result
    }

    private func lineGeometry3D(_ points: [SIMD3<Float>], color: UIColor) -> SCNGeometry {
        let vertices = points.map { SCNVector3($0.x, $0.y + 0.02, $0.z) }
        let source = SCNGeometrySource(vertices: vertices)

        var indices: [Int32] = []
        for i in 0..<max(0, vertices.count - 1) {
            indices.append(Int32(i))
            indices.append(Int32(i + 1))
        }

        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        geometry.materials = [material]

        return geometry
    }
}
