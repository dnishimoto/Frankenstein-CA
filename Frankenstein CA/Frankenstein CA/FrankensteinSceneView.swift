
//
//  FrankensteinSceneView.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 10/24/26.
//

import Foundation
import SwiftUI
import SceneKit

struct FrankensteinSceneView: UIViewRepresentable {

    @Binding var generation: Int
    @Binding var liveCells: Int
    @Binding var resetRequested: Bool

    // MARK: - Coordinator

    func makeCoordinator() -> Coordinator {
        // The actual SCNScene and character node are created in makeUIView.
        // Store a temporary scene and character node here so the initializer
        // matches the current Coordinator API.
        let scene = SCNScene()
        let characterNode = SCNNode()
        characterNode.name = "Frankenstein"

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
                    "distance: \(object.distanceText)"
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
            alpha: 1.0
        )

        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true

        // Build the obstacle course.
        FrankensteinTerrainScene.build(in: scene)

        // Create the character's visual root.
        let characterNode = SCNNode()
        characterNode.name = "Frankenstein"
        characterNode.position = SCNVector3(5.5, 0, 7.0)

        // Add a simple visible placeholder if the character model is not
        // already supplied by another character-building component.
        let bodyGeometry = SCNCapsule(
            capRadius: 0.35,
            height: 1.8
        )
        bodyGeometry.firstMaterial?.diffuse.contents = UIColor(
            red: 0.25,
            green: 0.65,
            blue: 0.35,
            alpha: 1
        )

        let bodyNode = SCNNode(geometry: bodyGeometry)
        bodyNode.position = SCNVector3(0, 0.9, 0)
        bodyNode.name = "FrankensteinBody"
        characterNode.addChildNode(bodyNode)

        scene.rootNode.addChildNode(characterNode)

        // Camera.
        let cameraNode = SCNNode()
        cameraNode.name = "MainCamera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = 200
        cameraNode.position = SCNVector3(0, 8, 17)

        let lookAt = SCNLookAtConstraint(target: characterNode)
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

        // IMPORTANT:
        // The current Coordinator keeps weak references to its scene and
        // character node. It must be initialized with the same scene and
        // character node used by this view. See the note below.
        view.delegate = context.coordinator

        return view
    }

    // MARK: - Update Scene

    func updateUIView(
        _ uiView: SCNView,
        context: Context
    ) {
        guard resetRequested else {
            return
        }

        // Reset the character node in the active scene.
        if let characterNode = uiView.scene?.rootNode
            .childNode(withName: "Frankenstein", recursively: true) {
            characterNode.position = SCNVector3(5.5, 0, 7.0)
        }

        // Reset the displayed CA statistics.
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
