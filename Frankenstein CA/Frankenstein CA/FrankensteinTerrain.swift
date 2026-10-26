
import SceneKit
import UIKit

enum FrankensteinTerrainScene {

    // MARK: - Build Course

    static func build(in scene: SCNScene) {

        // Prevent duplicate course geometry.
        scene.rootNode.childNode(
            withName: "ObstacleCourse",
            recursively: false
        )?.removeFromParentNode()

        let terrain = SCNNode()
        terrain.name = "ObstacleCourse"
        scene.rootNode.addChildNode(terrain)

        // MARK: - Door and Frame

        let doorFrameColor = UIColor(
            red: 0.35, green: 0.20, blue: 0.10, alpha: 1
        )

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

        let door = SCNNode()
        door.name = "Door"
        door.position = SCNVector3(5.84, 0, -7.0)

        setMetadata(
            on: door,
            name: "Door",
            type: "door",
            size: SCNVector3(2.32, 4.20, 0.15),
            solid: true,
            canOpen: true
        )

        terrain.addChildNode(door)

        let doorPanel = SCNBox(
            width: 2.32,
            height: 4.20,
            length: 0.15,
            chamferRadius: 0.05
        )

        let doorMaterial = SCNMaterial()
        doorMaterial.diffuse.contents = UIColor(
            red: 0.48, green: 0.27, blue: 0.13, alpha: 1
        )
        doorMaterial.roughness.contents = 0.72
        doorPanel.materials = [doorMaterial]

        let doorLeaf = SCNNode(geometry: doorPanel)
        doorLeaf.name = "DoorPanel"
        doorLeaf.position = SCNVector3(1.16, 2.10, 0)
        doorLeaf.categoryBitMask =
            FrankensteinPhysicalBody.solidMask

        setMetadata(
            on: doorLeaf,
            name: "DoorPanel",
            type: "door",
            size: SCNVector3(2.32, 4.20, 0.15),
            solid: true,
            canOpen: true
        )

        addStaticPhysics(to: doorLeaf)
        door.addChildNode(doorLeaf)

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
        handleNode.categoryBitMask =
            FrankensteinPhysicalBody.solidMask

        setMetadata(
            on: handleNode,
            name: "DoorHandle",
            type: "doorHandle",
            size: SCNVector3(0.17, 0.15, 0.17),
            solid: true,
            canOpen: true
        )

        addStaticPhysics(to: handleNode)
        door.addChildNode(handleNode)

        // MARK: - Table

        let table = SCNNode()
        table.name = "Table"
        table.position = SCNVector3(5.5, 0, 1.0)

        setMetadata(
            on: table,
            name: "Table",
            type: "table",
            size: SCNVector3(2.8, 1.59, 1.68),
            solid: true,
            canCrawlUnder: true
        )

        terrain.addChildNode(table)

        addBox(
            to: table,
            name: "TableTop",
            position: SCNVector3(0, 1.48, 0),
            size: SCNVector3(2.8, 0.22, 1.68),
            color: UIColor(
                red: 0.48, green: 0.29, blue: 0.15, alpha: 1
            ),
            objectType: "tableTop",
            canCrawlUnder: true
        )

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
                    red: 0.34, green: 0.20, blue: 0.11, alpha: 1
                ),
                objectType: "tableLeg"
            )
        }

        // MARK: - Ground Platforms

        addBox(
            to: terrain,
            name: "GroundLeft",
            position: SCNVector3(-5.5, -0.2, 0),
            size: SCNVector3(9, 0.4, 18),
            color: UIColor(
                red: 0.24, green: 0.30, blue: 0.25, alpha: 1
            ),
            objectType: "ground"
        )

        addBox(
            to: terrain,
            name: "GroundRight",
            position: SCNVector3(5.5, -0.2, 0),
            size: SCNVector3(9, 0.4, 18),
            color: UIColor(
                red: 0.24, green: 0.30, blue: 0.25, alpha: 1
            ),
            objectType: "ground"
        )

        // MARK: - Chasm

        addBox(
            to: terrain,
            name: "ChasmPitFloor",
            position: SCNVector3(0, -3.5, 0),
            size: SCNVector3(1.9, 0.2, 18),
            color: UIColor(
                red: 0.12, green: 0.12, blue: 0.14, alpha: 1
            ),
            objectType: "dangerousLowerGround"
        )

        addBox(
            to: terrain,
            name: "ChasmNearEdgeMarker",
            position: SCNVector3(1.0, 0.025, 0),
            size: SCNVector3(0.08, 0.05, 18),
            color: .systemRed,
            solid: false,
            objectType: "chasmEdge"
        )

        addBox(
            to: terrain,
            name: "ChasmFarEdgeMarker",
            position: SCNVector3(-1.0, 0.025, 0),
            size: SCNVector3(0.08, 0.05, 18),
            color: .systemGreen,
            solid: false,
            objectType: "chasmEdge"
        )

        // MARK: - Course Boundaries

        addBox(
            to: terrain,
            name: "LeftBoundary",
            position: SCNVector3(-9.5, 0.5, 0),
            size: SCNVector3(0.35, 1, 20),
            color: .darkGray,
            objectType: "boundary"
        )

        addBox(
            to: terrain,
            name: "RightBoundary",
            position: SCNVector3(9.5, 0.5, 0),
            size: SCNVector3(0.35, 1, 20),
            color: .darkGray,
            objectType: "boundary"
        )

        // MARK: - Hurdles

        addBox(
            to: terrain,
            name: "Hurdle1",
            position: SCNVector3(-2.5, 0.35, -3.0),
            size: SCNVector3(2.2, 0.7, 0.35),
            color: .systemOrange,
            objectType: "hurdle"
        )

        addBox(
            to: terrain,
            name: "Hurdle2",
            position: SCNVector3(3.5, 0.45, -6.0),
            size: SCNVector3(2.2, 0.9, 0.35),
            color: .systemOrange,
            objectType: "hurdle"
        )

        // MARK: - Low Ceiling

        addBox(
            to: terrain,
            name: "LowCeiling",
            position: SCNVector3(0, 2.05, -8),
            size: SCNVector3(3.8, 0.3, 2.0),
            color: .systemPurple,
            objectType: "lowCeiling",
            canCrawlUnder: true
        )

        // MARK: - Crawl-Only Barrier

        addBox(
            to: terrain,
            name: "LowBarrier",
            position: SCNVector3(-6.5, 1.60, -4.5),
            size: SCNVector3(3.8, 0.3, 2.0),
            color: .systemPink,
            objectType: "lowBarrier",
            canCrawlUnder: true
        )

        // MARK: - Raised Steps

        addBox(
            to: terrain,
            name: "Step1",
            position: SCNVector3(-3.5, 0.25, 2.5),
            size: SCNVector3(2.0, 0.5, 1.5),
            color: .systemTeal,
            objectType: "raisedStep"
        )

        addBox(
            to: terrain,
            name: "Step2",
            position: SCNVector3(-3.5, 0.65, 4.0),
            size: SCNVector3(2.0, 0.8, 1.5),
            color: .systemTeal,
            objectType: "raisedStep"
        )

        addBox(
            to: terrain,
            name: "Step3",
            position: SCNVector3(-3.5, 1.05, 5.5),
            size: SCNVector3(2.0, 1.0, 1.5),
            color: .systemTeal,
            objectType: "raisedStep"
        )

        // MARK: - Uneven Ground

        addBox(
            to: terrain,
            name: "UnevenGround1",
            position: SCNVector3(3.0, 0.12, 1.8),
            size: SCNVector3(2.5, 0.25, 2.5),
            color: UIColor(
                red: 0.48, green: 0.38, blue: 0.22, alpha: 1
            ),
            objectType: "unevenGround"
        )

        addBox(
            to: terrain,
            name: "UnevenGround2",
            position: SCNVector3(5.5, 0.30, 3.8),
            size: SCNVector3(2.5, 0.6, 2.5),
            color: UIColor(
                red: 0.48, green: 0.38, blue: 0.22, alpha: 1
            ),
            objectType: "unevenGround"
        )

        // MARK: - Start and Finish

        addBox(
            to: terrain,
            name: "StartMarker",
            position: SCNVector3(0, 0.025, 7.5),
            size: SCNVector3(2.5, 0.05, 0.15),
            color: .systemGreen,
            solid: false,
            objectType: "startMarker"
        )

        addBox(
            to: terrain,
            name: "FinishMarker",
            position: SCNVector3(0, 0.025, -9.0),
            size: SCNVector3(3.0, 0.05, 0.15),
            color: .systemGreen,
            solid: false,
            objectType: "finishMarker"
        )

        // MARK: - Lighting

        let light = SCNLight()
        light.type = .omni
        light.intensity = 900
        light.color = UIColor.white

        let lightNode = SCNNode()
        lightNode.name = "CourseLight"
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
        solid: Bool = true,
        objectType: String? = nil,
        canOpen: Bool = false,
        canCrawlUnder: Bool = false
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

        node.categoryBitMask = solid
            ? FrankensteinPhysicalBody.solidMask
            : FrankensteinPhysicalBody.decorationMask

        let resolvedType = objectType ?? inferObjectType(name)

        setMetadata(
            on: node,
            name: name,
            type: resolvedType,
            size: size,
            solid: solid,
            canOpen: canOpen,
            canCrawlUnder: canCrawlUnder
        )

        if solid {
            addStaticPhysics(to: node)
        }

        parent.addChildNode(node)
    }

    // MARK: - Alleya CA Object Metadata

    private static func setMetadata(
        on node: SCNNode,
        name: String,
        type: String,
        size: SCNVector3,
        solid: Bool,
        canOpen: Bool = false,
        canCrawlUnder: Bool = false
    ) {
        let data = node.userData ?? NSMutableDictionary()

        data["objectName"] = name
        data["objectType"] = type

        data["width"] = NSNumber(value: Double(size.x))
        data["height"] = NSNumber(value: Double(size.y))
        data["length"] = NSNumber(value: Double(size.z))

        data["isSolid"] = NSNumber(value: solid)
        data["isTraversable"] = NSNumber(value: !solid)
        data["canOpen"] = NSNumber(value: canOpen)
        data["canCrawlUnder"] = NSNumber(value: canCrawlUnder)

        data["alleyaObservationEnabled"] = NSNumber(value: true)

        node.userData = data
    }

    // MARK: - Physics

    private static func addStaticPhysics(to node: SCNNode) {
        guard node.geometry != nil else { return }

        let body = SCNPhysicsBody.static()
        body.categoryBitMask = FrankensteinPhysicalBody.solidMask
        node.physicsBody = body
    }

    // MARK: - Object Classification

    private static func inferObjectType(_ name: String) -> String {
        let value = name.lowercased()

        if value.contains("doorhandle") {
            return "doorHandle"
        }

        if value.contains("door") {
            return "door"
        }

        if value.contains("tabletop") {
            return "tableTop"
        }

        if value.contains("tableleg") {
            return "tableLeg"
        }

        if value == "table" {
            return "table"
        }

        if value.contains("chasm") {
            return value.contains("marker")
                ? "chasmEdge"
                : "dangerousLowerGround"
        }

        if value.contains("groundleft") ||
            value.contains("groundright") {
            return "ground"
        }

        if value.contains("hurdle") {
            return "hurdle"
        }

        if value.contains("lowceiling") {
            return "lowCeiling"
        }

        if value.contains("lowbarrier") {
            return "lowBarrier"
        }

        if value.contains("step") {
            return "raisedStep"
        }

        if value.contains("uneven") {
            return "unevenGround"
        }

        if value.contains("boundary") {
            return "boundary"
        }

        if value.contains("startmarker") {
            return "startMarker"
        }

        if value.contains("finishmarker") {
            return "finishMarker"
        }

        if value.contains("doorframe") {
            return "doorFrame"
        }

        return "obstacle"
    }
}
