
//
//  FrankensteinSceneView.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 10/24/26.
//

import Foundation
import SwiftUI
import SceneKit
import UIKit

struct FrankensteinSceneView: UIViewRepresentable {

    @Binding var generation: Int
    @Binding var liveCells: Int
    @Binding var resetRequested: Bool

    // MARK: - Coordinator

    func makeCoordinator() -> Coordinator {
        let scene = SCNScene()

        let characterNode = Self.makeFrankensteinCharacter()
        let locomotion = FrankensteinLocomotion()

        let coordinator = Coordinator(
            scene: scene,
            characterNode: characterNode,
            locomotion: locomotion
        )

        coordinator.onDebugInfo = { message in
            print("[Frankenstein] \(message)")
        }

        coordinator.onDetectedObject = { object in
            if let object {
                print(
                    "[Detected] \(object.name), " +
                    "size: \(object.dimensionsText), " +
                    "distance: \(object.distanceText), " +
                    "pickupable: \(object.pickupable)"
                )
            }
        }

        coordinator.onActionChanged = { action in
            print("[Action] \(action)")
        }

        return coordinator
    }

    // MARK: - Create Scene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        let scene = SCNScene()

        view.scene = scene
        view.backgroundColor = UIColor(
            red: 0.035,
            green: 0.055,
            blue: 0.10,
            alpha: 1
        )

        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true

        // Build the existing obstacle course.
        FrankensteinTerrainScene.build(in: scene)

        // Create the articulated Frankenstein model.
        let character = Self.makeFrankensteinCharacter()
        character.position = SCNVector3(5.5, 0, 7.0)
        scene.rootNode.addChildNode(character)

        // Camera.
        let cameraNode = SCNNode()
        cameraNode.name = "MainCamera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = 200
        cameraNode.position = SCNVector3(0, 8, 17)

        let lookAt = SCNLookAtConstraint(target: character)
        lookAt.isGimbalLockEnabled = true
        cameraNode.constraints = [lookAt]

        scene.rootNode.addChildNode(cameraNode)

        // Ambient light.
        let ambientNode = SCNNode()
        ambientNode.name = "AmbientLight"
        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.intensity = 500
        scene.rootNode.addChildNode(ambientNode)

        // Directional light.
        let directionalNode = SCNNode()
        directionalNode.name = "DirectionalLight"
        directionalNode.light = SCNLight()
        directionalNode.light?.type = .directional
        directionalNode.light?.intensity = 1000
        directionalNode.eulerAngles = SCNVector3(
            -Float.pi / 3,
            Float.pi / 4,
            0
        )
        scene.rootNode.addChildNode(directionalNode)

        // Attach the actual displayed scene and character.
        context.coordinator.attach(
            scene: scene,
            characterNode: character
        )

        // The hand is nested inside the right arm pivot.
        if let hand = character.childNode(
            withName: "FrankensteinRightHand",
            recursively: true
        ) {
            context.coordinator.attachHand(hand)
        }

        view.delegate = context.coordinator
        context.coordinator.start()

        return view
    }

    // MARK: - Build Frankenstein

    private static func makeFrankensteinCharacter() -> SCNNode {
        let root = SCNNode()
        root.name = "Frankenstein"

        // Materials.
        let skin = material(
            color: UIColor(
                red: 0.28,
                green: 0.66,
                blue: 0.34,
                alpha: 1
            )
        )

        let darkSkin = material(
            color: UIColor(
                red: 0.15,
                green: 0.38,
                blue: 0.22,
                alpha: 1
            )
        )

        let shirt = material(
            color: UIColor(
                red: 0.20,
                green: 0.25,
                blue: 0.30,
                alpha: 1
            )
        )

        let pants = material(
            color: UIColor(
                red: 0.12,
                green: 0.16,
                blue: 0.22,
                alpha: 1
            )
        )

        let boots = material(color: .black)
        let hair = material(color: UIColor(white: 0.10, alpha: 1))
        let white = material(color: .white)
        let black = material(color: .black)
        let metal = material(color: .lightGray, metallic: 0.8)

        let scar = material(
            color: UIColor(
                red: 0.45,
                green: 0.18,
                blue: 0.18,
                alpha: 1
            )
        )

        // -----------------------------------------------------
        // LEGS
        //
        // Each leg is attached to a hip pivot. The entire leg,
        // knee, and boot rotate together during walking.
        // The pivot is positioned at the hip.
        // -----------------------------------------------------

        let leftLeg = SCNNode()
        leftLeg.name = "FrankensteinLeftLeg"
        leftLeg.position = SCNVector3(-0.23, 1.07, 0)
        root.addChildNode(leftLeg)

        addBox(
            to: leftLeg,
            name: "LeftLegGeometry",
            size: SCNVector3(0.29, 0.70, 0.34),
            position: SCNVector3(0, -0.35, 0),
            material: pants,
            chamfer: 0.035
        )

        addBox(
            to: leftLeg,
            name: "LeftKnee",
            size: SCNVector3(0.27, 0.16, 0.37),
            position: SCNVector3(0, -0.24, -0.015),
            material: darkSkin,
            chamfer: 0.025
        )

        addBox(
            to: leftLeg,
            name: "LeftBoot",
            size: SCNVector3(0.36, 0.20, 0.48),
            position: SCNVector3(0, -0.95, -0.045),
            material: boots,
            chamfer: 0.045
        )

        let rightLeg = SCNNode()
        rightLeg.name = "FrankensteinRightLeg"
        rightLeg.position = SCNVector3(0.23, 1.07, 0)
        root.addChildNode(rightLeg)

        addBox(
            to: rightLeg,
            name: "RightLegGeometry",
            size: SCNVector3(0.29, 0.70, 0.34),
            position: SCNVector3(0, -0.35, 0),
            material: pants,
            chamfer: 0.035
        )

        addBox(
            to: rightLeg,
            name: "RightKnee",
            size: SCNVector3(0.27, 0.16, 0.37),
            position: SCNVector3(0, -0.24, -0.015),
            material: darkSkin,
            chamfer: 0.025
        )

        addBox(
            to: rightLeg,
            name: "RightBoot",
            size: SCNVector3(0.36, 0.20, 0.48),
            position: SCNVector3(0, -0.95, -0.045),
            material: boots,
            chamfer: 0.045
        )

        // -----------------------------------------------------
        // TORSO AND NECK
        // -----------------------------------------------------

        addBox(
            to: root,
            name: "FrankensteinTorso",
            size: SCNVector3(0.88, 0.70, 0.43),
            position: SCNVector3(0, 1.28, 0),
            material: shirt,
            chamfer: 0.055
        )

        addBox(
            to: root,
            name: "Neck",
            size: SCNVector3(0.30, 0.20, 0.28),
            position: SCNVector3(0, 1.70, 0),
            material: skin,
            chamfer: 0.025
        )

        for y: Float in [1.12, 1.28, 1.44] {
            addSphere(
                to: root,
                name: "ShirtButton",
                radius: 0.025,
                position: SCNVector3(0, y, -0.222),
                material: metal
            )
        }

        // -----------------------------------------------------
        // ARMS
        //
        // Shoulder pivots carry the upper arm, forearm, hand,
        // and thumb together. This gives the arms a real swing.
        // -----------------------------------------------------

        let leftArm = SCNNode()
        leftArm.name = "FrankensteinLeftArm"
        leftArm.position = SCNVector3(-0.48, 1.53, 0)
        root.addChildNode(leftArm)

        addBox(
            to: leftArm,
            name: "LeftUpperArm",
            size: SCNVector3(0.27, 0.43, 0.31),
            position: SCNVector3(-0.11, -0.19, 0),
            material: skin,
            chamfer: 0.035
        )

        addBox(
            to: leftArm,
            name: "LeftForearm",
            size: SCNVector3(0.24, 0.38, 0.28),
            position: SCNVector3(-0.13, -0.57, -0.01),
            material: skin,
            chamfer: 0.025
        )

        addBox(
            to: leftArm,
            name: "LeftHand",
            size: SCNVector3(0.25, 0.22, 0.25),
            position: SCNVector3(-0.13, -0.83, -0.025),
            material: darkSkin,
            chamfer: 0.035
        )

        addBox(
            to: leftArm,
            name: "LeftThumb",
            size: SCNVector3(0.10, 0.13, 0.14),
            position: SCNVector3(-0.27, -0.83, -0.07),
            material: skin,
            chamfer: 0.02
        )

        let rightArm = SCNNode()
        rightArm.name = "FrankensteinRightArm"
        rightArm.position = SCNVector3(0.48, 1.53, 0)
        root.addChildNode(rightArm)

        addBox(
            to: rightArm,
            name: "RightUpperArm",
            size: SCNVector3(0.27, 0.43, 0.31),
            position: SCNVector3(0.11, -0.19, 0),
            material: skin,
            chamfer: 0.035
        )

        addBox(
            to: rightArm,
            name: "RightForearm",
            size: SCNVector3(0.24, 0.38, 0.28),
            position: SCNVector3(0.13, -0.57, -0.01),
            material: skin,
            chamfer: 0.025
        )

        // This name matches the Coordinator's automatic hand attachment.
        addBox(
            to: rightArm,
            name: "FrankensteinRightHand",
            size: SCNVector3(0.25, 0.22, 0.25),
            position: SCNVector3(0.13, -0.83, -0.025),
            material: darkSkin,
            chamfer: 0.035
        )

        addBox(
            to: rightArm,
            name: "RightThumb",
            size: SCNVector3(0.10, 0.13, 0.14),
            position: SCNVector3(0.27, -0.83, -0.07),
            material: skin,
            chamfer: 0.02
        )

        // -----------------------------------------------------
        // SQUARE HEAD
        // -----------------------------------------------------

        addBox(
            to: root,
            name: "FrankensteinHead",
            size: SCNVector3(0.66, 0.59, 0.55),
            position: SCNVector3(0, 1.99, 0),
            material: skin,
            chamfer: 0.045
        )

        addBox(
            to: root,
            name: "HairCap",
            size: SCNVector3(0.70, 0.14, 0.59),
            position: SCNVector3(0, 2.34, 0.005),
            material: hair,
            chamfer: 0.025
        )

        addBox(
            to: root,
            name: "LeftHair",
            size: SCNVector3(0.12, 0.30, 0.57),
            position: SCNVector3(-0.34, 2.18, 0),
            material: hair,
            chamfer: 0.015
        )

        addBox(
            to: root,
            name: "RightHair",
            size: SCNVector3(0.12, 0.30, 0.57),
            position: SCNVector3(0.34, 2.18, 0),
            material: hair,
            chamfer: 0.015
        )

        addBox(
            to: root,
            name: "LeftEyebrow",
            size: SCNVector3(0.23, 0.075, 0.07),
            position: SCNVector3(-0.16, 2.08, -0.285),
            material: hair,
            chamfer: 0.012
        )

        addBox(
            to: root,
            name: "RightEyebrow",
            size: SCNVector3(0.23, 0.075, 0.07),
            position: SCNVector3(0.16, 2.08, -0.285),
            material: hair,
            chamfer: 0.012
        )

        addSphere(
            to: root,
            name: "LeftEye",
            radius: 0.065,
            position: SCNVector3(-0.16, 1.99, -0.292),
            material: white
        )

        addSphere(
            to: root,
            name: "RightEye",
            radius: 0.065,
            position: SCNVector3(0.16, 1.99, -0.292),
            material: white
        )

        addSphere(
            to: root,
            name: "LeftPupil",
            radius: 0.030,
            position: SCNVector3(-0.16, 1.99, -0.348),
            material: black
        )

        addSphere(
            to: root,
            name: "RightPupil",
            radius: 0.030,
            position: SCNVector3(0.16, 1.99, -0.348),
            material: black
        )

        addBox(
            to: root,
            name: "Nose",
            size: SCNVector3(0.13, 0.15, 0.13),
            position: SCNVector3(0, 1.91, -0.32),
            material: darkSkin,
            chamfer: 0.015
        )

        addBox(
            to: root,
            name: "Mouth",
            size: SCNVector3(0.27, 0.055, 0.035),
            position: SCNVector3(0, 1.79, -0.292),
            material: black,
            chamfer: 0.005
        )

        for x: Float in [-0.09, -0.03, 0.03, 0.09] {
            addBox(
                to: root,
                name: "MouthStitch",
                size: SCNVector3(0.012, 0.07, 0.015),
                position: SCNVector3(x, 1.79, -0.315),
                material: metal,
                chamfer: 0.002
            )
        }

        addBox(
            to: root,
            name: "ForeheadScar",
            size: SCNVector3(0.18, 0.025, 0.018),
            position: SCNVector3(-0.12, 2.22, -0.285),
            material: scar,
            chamfer: 0.003
        )

        // -----------------------------------------------------
        // NECK BOLTS
        // -----------------------------------------------------

        addBolt(
            to: root,
            name: "LeftNeckBolt",
            position: SCNVector3(-0.40, 1.82, 0)
        )

        addBolt(
            to: root,
            name: "RightNeckBolt",
            position: SCNVector3(0.40, 1.82, 0)
        )

        return root
    }

    // MARK: - Geometry Helpers

    @discardableResult
    private static func addBox(
        to parent: SCNNode,
        name: String,
        size: SCNVector3,
        position: SCNVector3,
        material: SCNMaterial,
        chamfer: CGFloat = 0
    ) -> SCNNode {
        let geometry = SCNBox(
            width: CGFloat(size.x),
            height: CGFloat(size.y),
            length: CGFloat(size.z),
            chamferRadius: chamfer
        )

        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = name
        node.position = position

        parent.addChildNode(node)
        return node
    }

    private static func addSphere(
        to parent: SCNNode,
        name: String,
        radius: CGFloat,
        position: SCNVector3,
        material: SCNMaterial
    ) {
        let geometry = SCNSphere(radius: radius)
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = name
        node.position = position

        parent.addChildNode(node)
    }

    private static func addBolt(
        to parent: SCNNode,
        name: String,
        position: SCNVector3
    ) {
        let boltMaterial = material(
            color: .darkGray,
            metallic: 0.9
        )

        let cylinder = SCNCylinder(
            radius: 0.075,
            height: 0.20
        )
        cylinder.materials = [boltMaterial]

        let bolt = SCNNode(geometry: cylinder)
        bolt.name = name
        bolt.position = position
        bolt.eulerAngles.z = Float.pi / 2
        parent.addChildNode(bolt)

        let capGeometry = SCNCylinder(
            radius: 0.085,
            height: 0.035
        )
        capGeometry.materials = [
            material(color: .lightGray, metallic: 0.9)
        ]

        let cap = SCNNode(geometry: capGeometry)
        cap.name = "\(name)Cap"

        cap.position = SCNVector3(
            position.x < 0 ? position.x - 0.105 : position.x + 0.105,
            position.y,
            position.z
        )

        cap.eulerAngles.z = Float.pi / 2
        parent.addChildNode(cap)
    }

    private static func material(
        color: UIColor,
        metallic: CGFloat = 0,
        roughness: CGFloat = 0.8
    ) -> SCNMaterial {
        let result = SCNMaterial()
        result.diffuse.contents = color
        result.metalness.contents = metallic
        result.roughness.contents = roughness
        result.lightingModel = .physicallyBased
        return result
    }

    // MARK: - Update Scene

    func updateUIView(
        _ uiView: SCNView,
        context: Context
    ) {
        guard resetRequested else { return }

        if let character = uiView.scene?.rootNode.childNode(
            withName: "Frankenstein",
            recursively: true
        ) {
            character.position = SCNVector3(5.5, 0, 7.0)
            character.eulerAngles = SCNVector3Zero
            character.scale = SCNVector3(1, 1, 1)

            for name in [
                "FrankensteinLeftLeg",
                "FrankensteinRightLeg",
                "FrankensteinLeftArm",
                "FrankensteinRightArm"
            ] {
                character.childNode(
                    withName: name,
                    recursively: true
                )?.eulerAngles = SCNVector3Zero
            }
        }

        DispatchQueue.main.async {
            self.generation = 0
            self.liveCells = 0
            self.resetRequested = false
        }
    }

    // MARK: - Cleanup

    static func dismantleUIView(
        _ uiView: SCNView,
        coordinator: Coordinator
    ) {
        uiView.isPlaying = false
        uiView.delegate = nil
        coordinator.stop()
    }
}
