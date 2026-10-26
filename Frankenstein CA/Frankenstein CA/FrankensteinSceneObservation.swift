

import Foundation
import SceneKit

struct FrankensteinSceneObservation {
    let objectName: String
    let distance: Float
    let width: Float
    let height: Float
    let length: Float
    let terrain: FrankensteinTerrain
    let isSolid: Bool
    let suggestedActions: [FrankensteinLearningAction]

    static func observe(
        hit: SCNHitTestResult
    ) -> FrankensteinSceneObservation {

        let node = hit.node
        let dimensions = dimensionsOf(node)

        let terrain = classify(
            nodeName: node.name ?? "",
            dimensions: dimensions,
            node: node
        )

        let isSolid =
            node.categoryBitMask &
            FrankensteinPhysicalBody.solidMask != 0

        return FrankensteinSceneObservation(
            objectName: node.name ?? "Unnamed object",
            distance: hit.distance,
            width: dimensions.width,
            height: dimensions.height,
            length: dimensions.length,
            terrain: terrain,
            isSolid: isSolid,
            suggestedActions: terrain.suggestedActions
        )
    }

    private static func dimensionsOf(
        _ node: SCNNode
    ) -> (width: Float, height: Float, length: Float) {

        if let box = node.geometry as? SCNBox {
            return (
                Float(box.width),
                Float(box.height),
                Float(box.length)
            )
        }

        // Fallback for non-box geometry:
        // use the node's actual local geometry bounds.
        if let geometry = node.geometry {
            let bounds = geometry.boundingBox

            return (
                abs(bounds.max.x - bounds.min.x),
                abs(bounds.max.y - bounds.min.y),
                abs(bounds.max.z - bounds.min.z)
            )
        }

        return (0, 0, 0)
    }

    private static func classify(
        nodeName: String,
        dimensions: (width: Float, height: Float, length: Float),
        node: SCNNode
    ) -> FrankensteinTerrain {

        let name = nodeName.lowercased()

        // A detected chasm edge is evidence of a gap.
        if name.contains("chasm") ||
           name.contains("gap") {
            return .gap
        }

        // Overhead objects may require a lower posture.
        if name.contains("lowceiling") ||
           name.contains("lowbarrier") {
            return .lowCeiling
        }

        if name.contains("hurdle") {
            return .hurdle
        }

        if name.contains("step") {
            return .raisedStep
        }

        if name.contains("unevenground") {
            return .uneven
        }

        if name.lowercased().contains("slope") {
            return .slope
        }

        if name.contains("ground") ||
           name.contains("startmarker") ||
           name.contains("finishmarker") {
            return .flat
        }

        // Unknown objects remain unknown rather than being
        // incorrectly labeled as safe ground.
        return .unknown
    }
}
