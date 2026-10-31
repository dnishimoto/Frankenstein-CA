
//
//  FrankensteinPlanSpline.swift
//  Frankenstein CA
//
//  Draws the current plan as a spline on the floor:
//
//    cyan   curve  Frankenstein -> the object the plan wants to move
//    orange curve  that object  -> where the plan wants it to go
//
//  The first curve ends at a stand-off point behind the object (the side
//  away from the destination), so it shows the approach needed to push the
//  object toward its destination. With no object in the plan, a single curve
//  runs from Frankenstein to the destination.
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

    private let rootName = "PlanSplineMarker"
    private weak var scene: SCNScene?

    private var approachNode = SCNNode()
    private var deliveryNode = SCNNode()
    private var targetRing = SCNNode()
    private var destinationRing = SCNNode()

    private let height: Float = 0.10
    private let standOff: Float = 0.9
    private let samplesPerSegment = 12

    private var lastKey = ""
    private var lastUpdate: TimeInterval = 0

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

    // MARK: Update

    /// - Parameters:
    ///   - character: where Frankenstein is (x, z are used).
    ///   - object: the object the plan wants to move, if any.
    ///   - destination: where the plan wants it (or him) to end up.
    func update(
        time: TimeInterval,
        character: SCNVector3,
        object: SCNVector3?,
        destination: SCNVector3?
    ) {
        guard isVisible, let destination else {
            hideAll()
            return
        }

        guard time - lastUpdate >= 0.1 else { return }
        lastUpdate = time

        let key = String(
            format: "%.1f,%.1f|%@|%.1f,%.1f",
            Double(character.x), Double(character.z),
            object.map { String(format: "%.1f,%.1f", Double($0.x), Double($0.z)) } ?? "-",
            Double(destination.x), Double(destination.z)
        )

        guard key != lastKey else { return }
        lastKey = key

        let start = SIMD2<Float>(Float(character.x), Float(character.z))
        let end = SIMD2<Float>(Float(destination.x), Float(destination.z))

        destinationRing.isHidden = false
        destinationRing.position = SCNVector3(end.x, height, end.y)

        guard let object else {
            // No object: one curve from Frankenstein to the destination.
            let curve = spline(through: [start, (start + end) * 0.5, end])
            approachNode.geometry = lineGeometry(curve, color: .cyan)
            approachNode.isHidden = false
            deliveryNode.isHidden = true
            targetRing.isHidden = true
            return
        }

        let obj = SIMD2<Float>(Float(object.x), Float(object.z))

        // Push direction: from the object toward the destination.
        var pushDirection = end - obj
        let pushLength = simd_length(pushDirection)
        pushDirection = pushLength > 0.001 ? pushDirection / pushLength : SIMD2<Float>(0, -1)

        // Stand behind the object, on the side away from the destination.
        let standPoint = obj - pushDirection * standOff

        // Curve 1: Frankenstein -> stand-off point -> object.
        let toStand = standPoint - start
        let side = SIMD2<Float>(-toStand.y, toStand.x)
        let sideLength = simd_length(side)
        let bow = sideLength > 0.001 ? side / sideLength * min(0.5, simd_length(toStand) * 0.15) : .zero

        let approach = spline(
            through: [start, start + toStand * 0.5 + bow, standPoint, obj]
        )

        // Curve 2: object -> destination, bowing slightly so the two curves
        // read as separate legs.
        let across = end - obj
        let acrossSide = SIMD2<Float>(-across.y, across.x)
        let acrossSideLength = simd_length(acrossSide)
        let acrossBow = acrossSideLength > 0.001
            ? acrossSide / acrossSideLength * min(0.4, simd_length(across) * 0.1)
            : .zero

        let delivery = spline(
            through: [obj, obj + across * 0.5 + acrossBow, end]
        )

        approachNode.geometry = lineGeometry(approach, color: .cyan)
        deliveryNode.geometry = lineGeometry(delivery, color: .orange)
        approachNode.isHidden = false
        deliveryNode.isHidden = false

        targetRing.isHidden = false
        targetRing.position = SCNVector3(obj.x, height, obj.y)
    }

    private func hideAll() {
        approachNode.isHidden = true
        deliveryNode.isHidden = true
        targetRing.isHidden = true
        destinationRing.isHidden = true
        lastKey = ""
    }

    // MARK: Spline

    /// Catmull-Rom spline through the points (the end points are repeated so
    /// the curve starts and ends exactly on them).
    private func spline(through points: [SIMD2<Float>]) -> [SIMD2<Float>] {
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

    private func lineGeometry(_ points: [SIMD2<Float>], color: UIColor) -> SCNGeometry {
        let vertices = points.map { SCNVector3($0.x, height, $0.y) }
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
