
import SceneKit
import UIKit

enum FrankensteinTerrainScene {

    static func build(in scene: SCNScene) {
        let terrain = SCNNode()
        terrain.name = "ObstacleCourse"
        scene.rootNode.addChildNode(terrain)

        // MARK: - Enlarged Door and Frame

        let doorFrameColor = UIColor(
            red: 0.35,
            green: 0.20,
            blue: 0.10,
            alpha: 1
        )

        // Wider frame, scaled to match the enlarged door.
        addBox(
            to: terrain,
            name: "DoorFrameLeft",
            position: SCNVector3(5.7, 2.25, -7.0),
            size: SCNVector3(0.27, 4.5, 0.33),
            color: doorFrameColor
        )

        addBox(
            to: terrain,
            name: "DoorFrameRight",
            position: SCNVector3(8.3, 2.25, -7.0),
            size: SCNVector3(0.27, 4.5, 0.33),
            color: doorFrameColor
        )

        addBox(
            to: terrain,
            name: "DoorFrameTop",
            position: SCNVector3(7.0, 4.45, -7.0),
            size: SCNVector3(2.85, 0.27, 0.33),
            color: doorFrameColor
        )

        // Door pivot: rotate this node later to open the door.
        let door = SCNNode()
        door.name = "Door"
        door.position = SCNVector3(5.84, 0, -7.0)
        terrain.addChildNode(door)

        let doorPanel = SCNBox(
            width: 2.32,
            height: 4.20,
            length: 0.15,
            chamferRadius: 0.05
        )

        let doorMaterial = SCNMaterial()
        doorMaterial.diffuse.contents = UIColor(
            red: 0.48,
            green: 0.27,
            blue: 0.13,
            alpha: 1
        )
        doorMaterial.roughness.contents = 0.72
        doorPanel.materials = [doorMaterial]

        let doorLeaf = SCNNode(geometry: doorPanel)
        doorLeaf.name = "DoorPanel"
        doorLeaf.position = SCNVector3(1.16, 2.10, 0)
        doorLeaf.categoryBitMask = FrankensteinPhysicalBody.solidMask
        door.addChildNode(doorLeaf)

        // Enlarged metallic door handle.
        let handle = SCNCylinder(
            radius: 0.085,
            height: 0.15
        )

        let handleMaterial = SCNMaterial()
        handleMaterial.diffuse.contents = UIColor.systemYellow
        handle.materials = [handleMaterial]

        let handleNode = SCNNode(geometry: handle)
        handleNode.name = "DoorHandle"
        handleNode.position = SCNVector3(2.02, 1.98, 0.13)
        handleNode.categoryBitMask = FrankensteinPhysicalBody.solidMask
        door.addChildNode(handleNode)

        // MARK: - Enlarged Table

        let table = SCNNode()
        table.name = "Table"
        table.position = SCNVector3(5.5, 0, 1.0)
        terrain.addChildNode(table)

        // Tabletop: approximately 2.8 × 1.68 units.
        addBox(
            to: table,
            name: "TableTop",
            position: SCNVector3(0, 1.48, 0),
            size: SCNVector3(2.8, 0.22, 1.68),
            color: UIColor(
                red: 0.48,
                green: 0.29,
                blue: 0.15,
                alpha: 1
            )
        )

        // Four legs, each approximately 1.4 units tall.
        let legPositions: [SCNVector3] = [
            SCNVector3(-1.15, 0.70, -0.66),
            SCNVector3( 1.15, 0.70, -0.66),
            SCNVector3(-1.15, 0.70,  0.66),
            SCNVector3( 1.15, 0.70,  0.66)
        ]

        for (index, position) in legPositions.enumerated() {
            addBox(
                to: table,
                name: "TableLeg\(index + 1)",
                position: position,
                size: SCNVector3(0.18, 1.4, 0.18),
                color: UIColor(
                    red: 0.34,
                    green: 0.20,
                    blue: 0.11,
                    alpha: 1
                )
            )
        }

        // MARK: - Ground Platform
        // Leaves the central gap visible.

        addBox(
            to: terrain,
            name: "GroundLeft",
            position: SCNVector3(-5.5, -0.2, 0),
            size: SCNVector3(9, 0.4, 18),
            color: UIColor(
                red: 0.24,
                green: 0.30,
                blue: 0.25,
                alpha: 1
            )
        )

        addBox(
            to: terrain,
            name: "GroundRight",
            position: SCNVector3(5.5, -0.2, 0),
            size: SCNVector3(9, 0.4, 18),
            color: UIColor(
                red: 0.24,
                green: 0.30,
                blue: 0.25,
                alpha: 1
            )
        )

        // MARK: - Course Boundaries

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

        // MARK: - Hurdles

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

        // MARK: - Low Ceiling

        addBox(
            to: terrain,
            name: "LowCeiling",
            position: SCNVector3(0, 2.05, -8),
            size: SCNVector3(3.8, 0.3, 2.0),
            color: .systemPurple
        )

        // MARK: - Crawl-Only Barrier
        // Clearance of 1.45 above the ground: low enough that a roll
        // (1.7 tall) cannot pass, so only crawling (1.3 tall) clears it.

        addBox(
            to: terrain,
            name: "LowBarrier",
            position: SCNVector3(-6.5, 1.60, -4.5),
            size: SCNVector3(3.8, 0.3, 2.0),
            color: .systemPink
        )

        // MARK: - Raised Steps

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

        // MARK: - Uneven Ground

        addBox(
            to: terrain,
            name: "UnevenGround1",
            position: SCNVector3(3.0, 0.12, 1.8),
            size: SCNVector3(2.5, 0.25, 2.5),
            color: UIColor(
                red: 0.48,
                green: 0.38,
                blue: 0.22,
                alpha: 1
            )
        )

        addBox(
            to: terrain,
            name: "UnevenGround2",
            position: SCNVector3(5.5, 0.30, 3.8),
            size: SCNVector3(2.5, 0.6, 2.5),
            color: UIColor(
                red: 0.48,
                green: 0.38,
                blue: 0.22,
                alpha: 1
            )
        )

        // MARK: - Gap Warning Marker

        addBox(
            to: terrain,
            name: "GapMarkerNear",
            position: SCNVector3(0, 0.03, 0.0),
            size: SCNVector3(0.12, 0.06, 2.2),
            color: .systemRed,
            solid: false
        )

        // MARK: - Start and Finish

        addBox(
            to: terrain,
            name: "StartMarker",
            position: SCNVector3(0, 0.025, 7.5),
            size: SCNVector3(2.5, 0.05, 0.15),
            color: .systemGreen,
            solid: false
        )

        addBox(
            to: terrain,
            name: "FinishMarker",
            position: SCNVector3(0, 0.025, -9.0),
            size: SCNVector3(3.0, 0.05, 0.15),
            color: .systemGreen,
            solid: false
        )

        // MARK: - Lighting

        let light = SCNLight()
        light.type = .omni
        light.intensity = 900
        light.color = UIColor.white

        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(0, 8, 2)
        terrain.addChildNode(lightNode)
    }

    // MARK: - Box Builder

    private static func addBox(
        to parent: SCNNode,
        name: String,
        position: SCNVector3,
        size: SCNVector3,
        color: UIColor,
        solid: Bool = true
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

        // Only geometry tagged solid is visible to his sensors and
        // collision tests. Names are for labels and debugging only.
        node.categoryBitMask = solid
            ? FrankensteinPhysicalBody.solidMask
            : FrankensteinPhysicalBody.decorationMask

        parent.addChildNode(node)
    }
}
