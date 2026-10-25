
import SceneKit
import UIKit

enum FrankensteinTerrainScene {

    static func build(in scene: SCNScene) {
        let terrain = SCNNode()
        terrain.name = "ObstacleCourse"
        scene.rootNode.addChildNode(terrain)

        // Ground platform, leaving a visible gap in the center.
        addBox(
            to: terrain,
            name: "GroundLeft",
            position: SCNVector3(-5.5, -0.2, 0),
            size: SCNVector3(9, 0.4, 18),
            color: UIColor(red: 0.24, green: 0.30, blue: 0.25, alpha: 1)
        )

        addBox(
            to: terrain,
            name: "GroundRight",
            position: SCNVector3(5.5, -0.2, 0),
            size: SCNVector3(9, 0.4, 18),
            color: UIColor(red: 0.24, green: 0.30, blue: 0.25, alpha: 1)
        )

        // Course boundaries.
        addBox(
            to: terrain,
            name: "LeftBoundary",
            position: SCNVector3(-9.5, 0.5, 0),
            size: SCNVector3(0.35, 1, 20),
            color: .darkGray
        )

        addBox(
            to: terrain,
            name: "RightBoundary",
            position: SCNVector3(9.5, 0.5, 0),
            size: SCNVector3(0.35, 1, 20),
            color: .darkGray
        )

        // Hurdles: low barriers that can be jumped.
        addBox(
            to: terrain,
            name: "Hurdle1",
            position: SCNVector3(-2.5, 0.35, -3.0),
            size: SCNVector3(2.2, 0.7, 0.35),
            color: .systemOrange
        )

        addBox(
            to: terrain,
            name: "Hurdle2",
            position: SCNVector3(3.5, 0.45, -6.0),
            size: SCNVector3(2.2, 0.9, 0.35),
            color: .systemOrange
        )

        // Low overhead platform: crouch underneath it.
        addBox(
            to: terrain,
            name: "LowCeiling",
            position: SCNVector3(0, 2.05, -8),
            size: SCNVector3(3.8, 0.3, 2.0),
            color: .systemPurple
        )

        // Raised steps.
        addBox(
            to: terrain,
            name: "Step1",
            position: SCNVector3(-3.5, 0.25, 2.5),
            size: SCNVector3(2.0, 0.5, 1.5),
            color: .systemTeal
        )

        addBox(
            to: terrain,
            name: "Step2",
            position: SCNVector3(-3.5, 0.65, 4.0),
            size: SCNVector3(2.0, 0.8, 1.5),
            color: .systemTeal
        )

        addBox(
            to: terrain,
            name: "Step3",
            position: SCNVector3(-3.5, 1.05, 5.5),
            size: SCNVector3(2.0, 1.0, 1.5),
            color: .systemTeal
        )

        // Uneven ground patches.
        addBox(
            to: terrain,
            name: "UnevenGround1",
            position: SCNVector3(3.0, 0.12, 1.8),
            size: SCNVector3(2.5, 0.25, 2.5),
            color: UIColor(red: 0.48, green: 0.38, blue: 0.22, alpha: 1)
        )

        addBox(
            to: terrain,
            name: "UnevenGround2",
            position: SCNVector3(5.5, 0.30, 3.8),
            size: SCNVector3(2.5, 0.6, 2.5),
            color: UIColor(red: 0.48, green: 0.38, blue: 0.22, alpha: 1)
        )

        // Gap warning markers on either side of the gap.
        addBox(
            to: terrain,
            name: "GapMarkerNear",
            position: SCNVector3(0, 0.03, 0.0),
            size: SCNVector3(0.12, 0.06, 2.2),
            color: .systemRed
        )

        // Starting position and finish marker.
        addBox(
            to: terrain,
            name: "StartMarker",
            position: SCNVector3(0, 0.025, 7.5),
            size: SCNVector3(2.5, 0.05, 0.15),
            color: .systemGreen
        )

        addBox(
            to: terrain,
            name: "FinishMarker",
            position: SCNVector3(0, 0.025, -9.0),
            size: SCNVector3(3.0, 0.05, 0.15),
            color: .systemGreen
        )

        // Directional course lighting.
        let light = SCNLight()
        light.type = .omni
        light.intensity = 900
        light.color = UIColor.white

        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(0, 8, 2)
        terrain.addChildNode(lightNode)
    }

    private static func addBox(
        to parent: SCNNode,
        name: String,
        position: SCNVector3,
        size: SCNVector3,
        color: UIColor
    ) {
        let geometry = SCNBox(
            width: CGFloat(size.x),
            height: CGFloat(size.y),
            length: CGFloat(size.z),
            chamferRadius: 0.06
        )

        let material = SCNMaterial()
        material.diffuse.contents = color
        material.roughness.contents = 0.85
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = name
        node.position = position
        parent.addChildNode(node)
    }
}

