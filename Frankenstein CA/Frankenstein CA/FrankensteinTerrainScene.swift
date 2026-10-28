import Foundation
import SceneKit
import UIKit

enum FrankensteinTerrainScene {
    
    // MARK: - Scene Builder
    
    static func build(in scene: SCNScene) {
        let root = SCNNode()
        root.name = "TerrainRoot"
        scene.rootNode.addChildNode(root)
        
        buildLighting(in: root)
        buildFloor(in: root)
        buildStartingPlatform(in: root)
        buildGap(in: root)
        buildSteps(in: root)
        buildObstacles(in: root)
        buildPickupObjects(in: root)
        buildTable(in: root)
        buildDoor(in: root)
        buildRechargeStation(in: root)
        buildMarkers(in: root)
    }
    
    // MARK: - Lighting
    
    private static func buildLighting(in root: SCNNode) {
        let ambient = SCNNode()
        ambient.name = "SceneAmbientLight"
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        ambient.position = SCNVector3(0, 8, 0)
        root.addChildNode(ambient)
        
        let directional = SCNNode()
        directional.name = "SceneDirectionalLight"
        directional.light = SCNLight()
        directional.light?.type = .directional
        directional.light?.intensity = 750
        directional.eulerAngles = SCNVector3(
            -Float.pi / 3,
            Float.pi / 4,
            0
        )
        directional.position = SCNVector3(0, 10, 10)
        root.addChildNode(directional)
    }
    
    // MARK: - Floor
    
    private static func buildFloor(in root: SCNNode) {
        let floor = SCNNode()
        floor.name = "GroundFloor"
        
        let geometry = SCNBox(
            width: 40,
            height: 0.2,
            length: 40,
            chamferRadius: 0
        )
        
        geometry.materials = [floorMaterial()]
        floor.geometry = geometry
        floor.position = SCNVector3(0, -0.1, 0)
        
        root.addChildNode(floor)
    }
    
    private static func buildStartingPlatform(in root: SCNNode) {
        let platform = SCNNode()
        platform.name = "StartingPlatform"
        
        let geometry = SCNBox(
            width: 6,
            height: 0.3,
            length: 6,
            chamferRadius: 0
        )
        
        geometry.materials = [platformMaterial()]
        platform.geometry = geometry
        platform.position = SCNVector3(5.5, 0.15, 7.0)
        
        root.addChildNode(platform)
    }
    
    // MARK: - Gap
    
    private static func buildGap(in root: SCNNode) {
        // The main floor is intentionally split by a visible dark pit.
        // The Coordinator treats missing ground probes as a gap.
        
        let pit = SCNNode()
        pit.name = "ChasmMarker"
        
        let geometry = SCNBox(
            width: 3.0,
            height: 0.05,
            length: 3.0,
            chamferRadius: 0
        )
        
        geometry.materials = [voidMaterial()]
        pit.geometry = geometry
        pit.position = SCNVector3(0, 0.01, 0)
        
        root.addChildNode(pit)
        
        // Landing platform beyond the gap.
        let landing = SCNNode()
        landing.name = "GapLandingPlatform"
        
        let landingGeometry = SCNBox(
            width: 4,
            height: 0.3,
            length: 4,
            chamferRadius: 0
        )
        
        landingGeometry.materials = [platformMaterial()]
        landing.geometry = landingGeometry
        landing.position = SCNVector3(0, 0.15, -6.0)
        
        root.addChildNode(landing)
    }
    
    // MARK: - Steps
    
    private static func buildSteps(in root: SCNNode) {
        let stepHeights: [Float] = [0.15, 0.30, 0.45]
        
        for (index, height) in stepHeights.enumerated() {
            let step = SCNNode()
            step.name = "RaisedStep\(index + 1)"
            
            let geometry = SCNBox(
                width: 2.0,
                height: CGFloat(height),
                length: 1.0,
                chamferRadius: 0
            )
            
            geometry.materials = [stepMaterial()]
            step.geometry = geometry
            
            step.position = SCNVector3(
                -4.0,
                height / 2,
                Float(2.0 - Float(index) * 1.5)
            )
            
            root.addChildNode(step)
        }
    }
    
    // MARK: - Obstacles
    
    private static func buildObstacles(in root: SCNNode) {
        let hurdle = SCNNode()
        hurdle.name = "WoodenHurdle"
        
        let hurdleGeometry = SCNBox(
            width: 1.5,
            height: 0.8,
            length: 0.25,
            chamferRadius: 0
        )
        
        hurdleGeometry.materials = [woodMaterial()]
        hurdle.geometry = hurdleGeometry
        hurdle.position = SCNVector3(2.5, 0.4, -2.0)
        
        root.addChildNode(hurdle)
        
        let wall = SCNNode()
        wall.name = "LowWall"
        
        let wallGeometry = SCNBox(
            width: 4.0,
            height: 1.2,
            length: 0.3,
            chamferRadius: 0
        )
        
        wallGeometry.materials = [stoneMaterial()]
        wall.geometry = wallGeometry
        wall.position = SCNVector3(-2.0, 0.6, -4.0)
        
        root.addChildNode(wall)
    }
    
    // MARK: - Pickup Objects
    
    private static func buildPickupObjects(in root: SCNNode) {
        let crate1 = makeCrate(
            name: "PickupCrate1",
            position: SCNVector3(4.0, 0.25, 3.0)
        )
        
        let crate2 = makeCrate(
            name: "PickupCrate2",
            position: SCNVector3(3.0, 0.25, 1.0)
        )
        
        let movableBlock = SCNNode()
        movableBlock.name = "MovableBlock"
        
        let blockGeometry = SCNBox(
            width: 0.5,
            height: 0.5,
            length: 0.5,
            chamferRadius: 0.02
        )
        
        blockGeometry.materials = [metalMaterial()]
        movableBlock.geometry = blockGeometry
        movableBlock.position = SCNVector3(6.5, 0.25, 4.0)
        
        root.addChildNode(crate1)
        root.addChildNode(crate2)
        root.addChildNode(movableBlock)
    }
    
    private static func makeCrate(
        name: String,
        position: SCNVector3
    ) -> SCNNode {
        let crate = SCNNode()
        crate.name = name
        
        let geometry = SCNBox(
            width: 0.5,
            height: 0.5,
            length: 0.5,
            chamferRadius: 0.02
        )
        
        geometry.materials = [woodMaterial()]
        crate.geometry = geometry
        crate.position = position
        
        return crate
    }
    
    // MARK: - Table
    
    private static func buildTable(in root: SCNNode) {
        let table = SCNNode()
        table.name = "Table"
        
        let top = SCNNode()
        top.name = "TableTop"
        
        let topGeometry = SCNBox(
            width: 1.6,
            height: 0.12,
            length: 1.0,
            chamferRadius: 0
        )
        
        topGeometry.materials = [woodMaterial()]
        top.geometry = topGeometry
        top.position = SCNVector3(0, 0.75, 0)
        
        table.addChildNode(top)
        
        let legOffsets: [SCNVector3] = [
            SCNVector3(-0.65, 0.35, -0.35),
            SCNVector3(0.65, 0.35, -0.35),
            SCNVector3(-0.65, 0.35, 0.35),
            SCNVector3(0.65, 0.35, 0.35)
        ]
        
        for (index, offset) in legOffsets.enumerated() {
            let leg = SCNNode()
            leg.name = "TableLeg\(index + 1)"
            
            let legGeometry = SCNBox(
                width: 0.10,
                height: 0.70,
                length: 0.10,
                chamferRadius: 0
            )
            
            legGeometry.materials = [woodMaterial()]
            leg.geometry = legGeometry
            leg.position = offset
            
            table.addChildNode(leg)
        }
        
        table.position = SCNVector3(-5.0, 0, -1.0)
        
        root.addChildNode(table)
    }
    
    // MARK: - Door
    
    private static func buildDoor(in root: SCNNode) {
        let doorFrame = SCNNode()
        doorFrame.name = "DoorFrame"
        
        let frameGeometry = SCNBox(
            width: 1.6,
            height: 2.4,
            length: 0.2,
            chamferRadius: 0
        )
        
        frameGeometry.materials = [stoneMaterial()]
        doorFrame.geometry = frameGeometry
        doorFrame.position = SCNVector3(0, 1.2, -9.0)
        
        root.addChildNode(doorFrame)
        
        let door = SCNNode()
        door.name = "Door"
        
        let doorGeometry = SCNBox(
            width: 1.2,
            height: 2.2,
            length: 0.1,
            chamferRadius: 0
        )
        
        doorGeometry.materials = [doorMaterial()]
        door.geometry = doorGeometry
        
        // Pivot near the left edge so rotation looks like a door opening.
        door.pivot = SCNMatrix4MakeTranslation(0.6, 0, 0)
        door.position = SCNVector3(-0.6, 1.1, -9.0)
        
        root.addChildNode(door)
    }
    
    // MARK: - Recharge Station
    
    private static func buildRechargeStation(in root: SCNNode) {
        let station = SCNNode()
        station.name = "RechargeStation"
        
        let base = SCNNode()
        base.name = "RechargeStationBase"
        
        let baseGeometry = SCNBox(
            width: 1.0,
            height: 0.8,
            length: 1.0,
            chamferRadius: 0.05
        )
        
        baseGeometry.materials = [metalMaterial()]
        base.geometry = baseGeometry
        base.position = SCNVector3(0, 0.4, 0)
        
        station.addChildNode(base)
        
        let indicator = SCNNode()
        indicator.name = "RechargeStationIndicator"
        
        let indicatorGeometry = SCNCylinder(
            radius: 0.12,
            height: 0.35
        )
        
        indicatorGeometry.materials = [energyMaterial()]
        indicator.geometry = indicatorGeometry
        indicator.position = SCNVector3(0, 0.95, 0)
        
        station.addChildNode(indicator)
        
        station.position = SCNVector3(7.0, 0, -3.0)
        
        root.addChildNode(station)
    }
    
    // MARK: - Markers
    
    private static func buildMarkers(in root: SCNNode) {
        let markerPositions: [SCNVector3] = [
            SCNVector3(5.5, 0.35, 5.0),
            SCNVector3(2.0, 0.35, 0.0),
            SCNVector3(0.0, 0.35, -6.0),
            SCNVector3(-4.0, 0.55, -1.0),
            SCNVector3(7.0, 0.85, -3.0)
        ]
        
        for (index, position) in markerPositions.enumerated() {
            let marker = SCNNode()
            marker.name = "CourseMarker\(index + 1)"
            
            let geometry = SCNCylinder(
                radius: 0.08,
                height: 0.30
            )
            
            geometry.materials = [markerMaterial()]
            marker.geometry = geometry
            marker.position = position
            
            root.addChildNode(marker)
        }
    }
    
    // MARK: - Materials
    
    private static func floorMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(
            red: 0.22,
            green: 0.24,
            blue: 0.28,
            alpha: 1
        )
        return material
    }
    
    private static func platformMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(
            red: 0.30,
            green: 0.33,
            blue: 0.38,
            alpha: 1
        )
        return material
    }
    
    private static func voidMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.black
        return material
    }
    
    private static func stepMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(
            red: 0.45,
            green: 0.38,
            blue: 0.28,
            alpha: 1
        )
        return material
    }
    
    private static func woodMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(
            red: 0.55,
            green: 0.36,
            blue: 0.20,
            alpha: 1
        )
        return material
    }
    
    private static func stoneMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(
            red: 0.48,
            green: 0.50,
            blue: 0.54,
            alpha: 1
        )
        return material
    }
    
    private static func metalMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(
            red: 0.62,
            green: 0.66,
            blue: 0.72,
            alpha: 1
        )
        material.metalness.contents = 0.8
        material.roughness.contents = 0.35
        return material
    }
    
    private static func doorMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(
            red: 0.35,
            green: 0.22,
            blue: 0.12,
            alpha: 1
        )
        return material
    }
    
    private static func energyMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGreen
        material.emission.contents = UIColor.systemGreen
        return material
    }
    
    private static func markerMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemYellow
        material.emission.contents = UIColor.systemYellow
        return material
    }
}
