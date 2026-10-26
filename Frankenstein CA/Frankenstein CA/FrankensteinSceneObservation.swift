
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

    // MARK: - Observe a Ray Hit

    static func observe(
        hit: SCNHitTestResult,
        origin: SCNVector3
    ) -> FrankensteinSceneObservation {

        let node = hit.node
        let dimensions = dimensionsOf(node)

        let terrain = classify(
            nodeName: node.name ?? "",
            dimensions: dimensions,
            node: node
        )

        let isSolid =
            (node.categoryBitMask &
             FrankensteinPhysicalBody.solidMask) != 0

        // SCNHitTestResult has no `distance` property.
        // Measure from the ray origin to the actual world-space hit point.
        let point = hit.worldCoordinates

        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let dz = point.z - origin.z

        let distance = sqrt(
            dx * dx +
            dy * dy +
            dz * dz
        )

        return FrankensteinSceneObservation(
            objectName: node.name ?? "Unnamed object",
            distance: distance,
            width: dimensions.width,
            height: dimensions.height,
            length: dimensions.length,
            terrain: terrain,
            isSolid: isSolid,
            suggestedActions: terrain.suggestedActions
        )
    }

    // MARK: - Object Dimensions

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

        // Fallback for non-box geometry.
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

    // MARK: - Terrain Classification

    private static func classify(
        nodeName: String,
        dimensions: (width: Float, height: Float, length: Float),
        node: SCNNode
    ) -> FrankensteinTerrain {

        let name = nodeName.lowercased()

        // A detected chasm or gap marker.
        if name.contains("chasm") ||
           name.contains("gap") {
            return .gap
        }

        // Objects that may require a lower posture.
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

        if name.contains("slope") {
            return .slope
        }

        if name.contains("ground") ||
           name.contains("startmarker") ||
           name.contains("finishmarker") {
            return .flat
        }

        // Do not treat an unrecognized object as safe ground.
        return .unknown
    }
}

