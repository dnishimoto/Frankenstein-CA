import Foundation
import SwiftUI
import SceneKit
import UIKit

struct FrankensteinSceneView: UIViewRepresentable {

    // MARK: - UI Bindings

    @Binding var generation: Int
    @Binding var liveCells: Int
    @Binding var resetRequested: Bool
    @Binding var seenText: String
    @Binding var planText: String
    @Binding var qCells: [FrankensteinQDisplayCell]

    // Keep one CA instance for the lifetime of this view value.
    // The coordinator and UI statistics must refer to this same instance.
    private let ca = FrankensteinCA()

    // MARK: - Coordinator

    func makeCoordinator() -> Coordinator {
        let placeholderScene = SCNScene()
        let placeholderCharacter = Self.makeFrankensteinCharacter()
        let locomotion = FrankensteinLocomotion()

        let coordinator = Coordinator(
            scene: placeholderScene,
            characterNode: placeholderCharacter,
            locomotion: locomotion
        )

        coordinator.onStats = { stats in
            print("[Frankenstein Stats]\n\(stats)")
        }

        coordinator.onDebugInfo = { message in
            print("[Frankenstein Debug] \(message)")
        }

        coordinator.onDetectedObject = { object in
            if let object {
                print(
                    """
                    [Detected Object]
                    Name: \(object.name)
                    Dimensions: \(object.dimensionsText)
                    Distance: \(object.distanceText)
                    Pickupable: \(object.pickupable)
                    """
                )
            }
        }

        coordinator.onActionChanged = { action in
            print("[Frankenstein Action] \(action)")
        }

        return coordinator
    }

    // MARK: - Create Scene View

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)

        let scene = SCNScene()
        scene.background.contents = UIColor(
            red: 0.08,
            green: 0.09,
            blue: 0.13,
            alpha: 1.0
        )

        // Build the course.
        FrankensteinTerrainScene.build(in: scene)

        // MARK: - Add Additional Moveable Blocks
        let blockMaterial = SCNMaterial()
        blockMaterial.diffuse.contents = UIColor(
            red: 0.55,
            green: 0.35,
            blue: 0.20,
            alpha: 1.0
        ) // Wood crate appearance

        let blockPositions: [SCNVector3] = [
            SCNVector3(3.5, 0.4, 4.0),
            SCNVector3(1.5, 0.4, 1.0),
            SCNVector3(-1.0, 0.4, -2.0),
            SCNVector3(2.0, 0.4, -4.5)
        ]

        for (index, position) in blockPositions.enumerated() {
            let boxGeometry = SCNBox(
                width: 0.8,
                height: 0.8,
                length: 0.8,
                chamferRadius: 0.04
            )
            boxGeometry.materials = [blockMaterial]

            let movableBlock = SCNNode(geometry: boxGeometry)
            movableBlock.name = "MovableBlock\(index + 1)"
            movableBlock.position = position
            scene.rootNode.addChildNode(movableBlock)
        }

        // Build the actual character.
        let character = Self.makeFrankensteinCharacter()
        character.name = "Frankenstein"
        character.position = SCNVector3(5.5, 0, 7.0)

        scene.rootNode.addChildNode(character)

        // Attach the actual displayed scene and character.
        context.coordinator.attach(
            scene: scene,
            characterNode: character
        )

        // Attach the same CA instance used for the displayed statistics.
        context.coordinator.attachCA(ca)

        // Publish what the robot sees, as one sentence, to SwiftUI. The
        // coordinator reports at scan rate; only changes are forwarded, and
        // at most about five times per second.
        let throttle = VisibleObjectsThrottle()

        context.coordinator.onDetectedObjects = { objects in
            guard throttle.shouldPublish(objects) else { return }

            self.seenText = DetectedObjectInfo.summary(of: objects)
        }

        // Publish what the CA is planning, in words.
        context.coordinator.onPlanText = { text in
            if self.planText != text {
                self.planText = text
            }
        }

        // Publish the Q network grid with its dirty flags.
        context.coordinator.onQGrid = { cells in
            if self.qCells != cells {
                self.qCells = cells
            }
        }

        // Publish CA generation and live-cell updates to SwiftUI.
        context.coordinator.onCAStats = { generation, liveCells in
            self.generation = generation
            self.liveCells = liveCells
        }

        // Attach the hand if the character builder created one.
        if let hand = character.childNode(
            withName: "FrankensteinRightHand",
            recursively: true
        ) {
            context.coordinator.attachHand(hand)
        }

        // MARK: Camera

        let cameraNode = SCNNode()
        cameraNode.name = "MainCamera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = 150

        cameraNode.position = SCNVector3(0, 8, 16)
        cameraNode.eulerAngles = SCNVector3(
            -Float.pi / 8,
            0,
            0
        )

        scene.rootNode.addChildNode(cameraNode)

        // MARK: Lighting

        let ambientNode = SCNNode()
        ambientNode.name = "AmbientLight"
        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.intensity = 450
        scene.rootNode.addChildNode(ambientNode)

        let directionalNode = SCNNode()
        directionalNode.name = "DirectionalLight"
        directionalNode.light = SCNLight()
        directionalNode.light?.type = .directional
        directionalNode.light?.intensity = 900
        directionalNode.eulerAngles = SCNVector3(
            -Float.pi / 3,
            Float.pi / 4,
            0
        )
        scene.rootNode.addChildNode(directionalNode)

        // MARK: Configure SCNView

        view.scene = scene
        view.pointOfView = cameraNode
        view.delegate = context.coordinator
        view.isPlaying = true
        view.rendersContinuously = true
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.backgroundColor = UIColor(
            red: 0.08,
            green: 0.09,
            blue: 0.13,
            alpha: 1.0
        )

        // Initialize the displayed counters immediately.
        generation = ca.generation
        liveCells = ca.liveCellCount

        // Start the coordinator's sensing and locomotion loop.
        context.coordinator.start()

        return view
    }

    // MARK: - Update View

    func updateUIView(
        _ uiView: SCNView,
        context: Context
    ) {
        guard resetRequested else {
            return
        }

        // Reset the character's position and orientation.
        if let character = uiView.scene?.rootNode.childNode(
            withName: "Frankenstein",
            recursively: true
        ) {
            character.position = SCNVector3(5.5, 0, 7.0)
            character.eulerAngles = SCNVector3Zero

            // Reset limb animation.
            let limbNames = [
                "FrankensteinLeftLeg",
                "FrankensteinRightLeg",
                "FrankensteinLeftArm",
                "FrankensteinRightArm",
                "FrankensteinHead"
            ]

            for name in limbNames {
                character.childNode(
                    withName: name,
                    recursively: true
                )?.eulerAngles = SCNVector3Zero
            }
        }

        // Reset the CA and update the displayed counters.
        ca.reset()

        generation = ca.generation
        liveCells = ca.liveCellCount

        // Clear the request so the reset happens only once.
        DispatchQueue.main.async {
            self.resetRequested = false
        }
    }

    // MARK: - Tear Down

    static func dismantleUIView(
        _ uiView: SCNView,
        coordinator: Coordinator
    ) {
        coordinator.stop()
        uiView.delegate = nil
        uiView.isPlaying = false
    }

    // MARK: - Frankenstein Character Builder

    private static func makeFrankensteinCharacter() -> SCNNode {
        let root = SCNNode()
        root.name = "Frankenstein"

        // Materials
        let skinMaterial = SCNMaterial()
        skinMaterial.diffuse.contents = UIColor(
            red: 0.35,
            green: 0.62,
            blue: 0.42,
            alpha: 1
        )

        let clothingMaterial = SCNMaterial()
        clothingMaterial.diffuse.contents = UIColor(
            red: 0.16,
            green: 0.20,
            blue: 0.25,
            alpha: 1
        )

        let trouserMaterial = SCNMaterial()
        trouserMaterial.diffuse.contents = UIColor(
            red: 0.12,
            green: 0.14,
            blue: 0.18,
            alpha: 1
        )

        let bootMaterial = SCNMaterial()
        bootMaterial.diffuse.contents = UIColor.darkGray

        let eyeMaterial = SCNMaterial()
        eyeMaterial.diffuse.contents = UIColor.white

        let pupilMaterial = SCNMaterial()
        pupilMaterial.diffuse.contents = UIColor.black

        // Helper to create a named box body part.
        func makeBox(
            name: String,
            width: CGFloat,
            height: CGFloat,
            length: CGFloat,
            position: SCNVector3,
            material: SCNMaterial
        ) -> SCNNode {
            let geometry = SCNBox(
                width: width,
                height: height,
                length: length,
                chamferRadius: 0.04
            )
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.name = name
            node.position = position
            return node
        }

        // MARK: Torso

        let torso = makeBox(
            name: "FrankensteinTorso",
            width: 0.72,
            height: 0.85,
            length: 0.38,
            position: SCNVector3(0, 1.20, 0),
            material: clothingMaterial
        )
        root.addChildNode(torso)

        // MARK: Neck

        let neckGeometry = SCNCylinder(
            radius: 0.13,
            height: 0.18
        )
        neckGeometry.materials = [skinMaterial]

        let neck = SCNNode(geometry: neckGeometry)
        neck.name = "FrankensteinNeck"
        neck.position = SCNVector3(0, 1.72, 0)
        root.addChildNode(neck)

        // MARK: Head

        let head = makeBox(
            name: "FrankensteinHead",
            width: 0.48,
            height: 0.48,
            length: 0.42,
            position: SCNVector3(0, 2.02, 0),
            material: skinMaterial
        )
        root.addChildNode(head)

        // Eyes on the front of the head.
        for x: Float in [-0.12, 0.12] {
            let eyeGeometry = SCNSphere(radius: 0.055)
            eyeGeometry.materials = [eyeMaterial]

            let eye = SCNNode(geometry: eyeGeometry)
            eye.name = x < 0
                ? "FrankensteinLeftEye"
                : "FrankensteinRightEye"
            eye.position = SCNVector3(x, 2.06, -0.215)
            root.addChildNode(eye)

            let pupilGeometry = SCNSphere(radius: 0.025)
            pupilGeometry.materials = [pupilMaterial]

            let pupil = SCNNode(geometry: pupilGeometry)
            pupil.name = x < 0
                ? "FrankensteinLeftPupil"
                : "FrankensteinRightPupil"
            pupil.position = SCNVector3(x, 2.06, -0.258)
            root.addChildNode(pupil)
        }

        // Mouth.
        let mouth = makeBox(
            name: "FrankensteinMouth",
            width: 0.17,
            height: 0.035,
            length: 0.025,
            position: SCNVector3(0, 1.91, -0.225),
            material: pupilMaterial
        )
        root.addChildNode(mouth)

        // MARK: Legs

        let leftLeg = makeBox(
            name: "FrankensteinLeftLeg",
            width: 0.25,
            height: 0.62,
            length: 0.28,
            position: SCNVector3(-0.20, 0.48, 0),
            material: trouserMaterial
        )
        root.addChildNode(leftLeg)

        let rightLeg = makeBox(
            name: "FrankensteinRightLeg",
            width: 0.25,
            height: 0.62,
            length: 0.28,
            position: SCNVector3(0.20, 0.48, 0),
            material: trouserMaterial
        )
        root.addChildNode(rightLeg)

        // Boots.
        let leftBoot = makeBox(
            name: "FrankensteinLeftBoot",
            width: 0.29,
            height: 0.16,
            length: 0.38,
            position: SCNVector3(-0.20, 0.10, -0.035),
            material: bootMaterial
        )
        root.addChildNode(leftBoot)

        let rightBoot = makeBox(
            name: "FrankensteinRightBoot",
            width: 0.29,
            height: 0.16,
            length: 0.38,
            position: SCNVector3(0.20, 0.10, -0.035),
            material: bootMaterial
        )
        root.addChildNode(rightBoot)

        // MARK: Arms

        let leftArm = makeBox(
            name: "FrankensteinLeftArm",
            width: 0.22,
            height: 0.67,
            length: 0.24,
            position: SCNVector3(-0.49, 1.23, 0),
            material: skinMaterial
        )
        root.addChildNode(leftArm)

        let rightArm = makeBox(
            name: "FrankensteinRightArm",
            width: 0.22,
            height: 0.67,
            length: 0.24,
            position: SCNVector3(0.49, 1.23, 0),
            material: skinMaterial
        )
        root.addChildNode(rightArm)

        // Right hand is separately named for pickup interactions.
        let handGeometry = SCNSphere(radius: 0.12)
        handGeometry.materials = [skinMaterial]

        let hand = SCNNode(geometry: handGeometry)
        hand.name = "FrankensteinRightHand"
        hand.position = SCNVector3(0.49, 0.86, -0.01)
        root.addChildNode(hand)

        // Left hand.
        let leftHandGeometry = SCNSphere(radius: 0.12)
        leftHandGeometry.materials = [skinMaterial]

        let leftHand = SCNNode(geometry: leftHandGeometry)
        leftHand.name = "FrankensteinLeftHand"
        leftHand.position = SCNVector3(-0.49, 0.86, -0.01)
        root.addChildNode(leftHand)

        return root
    }
}

// MARK: - Visible-object publishing

/// Keeps the SwiftUI object list from re-rendering at sensor rate.
final class VisibleObjectsThrottle {
    private var lastSignature = ""
    private var lastTime: TimeInterval = 0

    private let minimumInterval: TimeInterval = 0.2

    func shouldPublish(_ objects: [DetectedObjectInfo]) -> Bool {
        let signature = objects
            .map {
                "\($0.name)@\(Int(($0.distance * 10).rounded()))" +
                "/\(Int(($0.bearing * 4).rounded()))"
            }
            .joined(separator: "|")

        let now = Date.timeIntervalSinceReferenceDate

        guard signature != lastSignature,
              now - lastTime >= minimumInterval else {
            return false
        }

        lastSignature = signature
        lastTime = now

        return true
    }
}
