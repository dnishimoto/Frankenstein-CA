
import SwiftUI
import SceneKit
import UIKit

struct ContentView: View {
    @State private var generation = 0
    @State private var liveCells = 0
    @State private var resetRequested = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FRANKENSTEIN")
                        .font(.title2.bold())

                    Text("Cellular Automaton Simulation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    resetRequested.toggle()
                    generation = 0
                    liveCells = 0
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            FrankensteinSceneView(
                generation: $generation,
                liveCells: $liveCells,
                resetRequested: $resetRequested
            )

            HStack(spacing: 24) {
                VStack {
                    Text("Generation")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\(generation)")
                        .font(.title3.bold())
                        .monospacedDigit()
                }

                VStack {
                    Text("Live Cells")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\(liveCells)")
                        .font(.title3.bold())
                        .monospacedDigit()
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Label("Walking", systemImage: "figure.walk")
                    Text("Obstacle navigation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct FrankensteinSceneView: UIViewRepresentable {
    @Binding var generation: Int
    @Binding var liveCells: Int
    @Binding var resetRequested: Bool

    func makeCoordinator() -> Coordinator {
        let character = FrankensteinCharacter()
        let ca = FrankensteinCA()

        return Coordinator(
            character: character,
            ca: ca,
            onStats: { newGeneration, newLiveCells in
                DispatchQueue.main.async {
                    generation = newGeneration
                    liveCells = newLiveCells
                }
            }
        )
    }

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

        // Add the character owned by the coordinator.
        let coordinator = context.coordinator
        let character = coordinator.character

        character.root.position = SCNVector3(5.5, 0, 7.0)
        scene.rootNode.addChildNode(character.root)

        // Add a camera.
        let cameraNode = SCNNode()
        cameraNode.name = "MainCamera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = 200
        cameraNode.position = SCNVector3(0, 8, 17)

        let lookAt = SCNLookAtConstraint(target: character.root)
        lookAt.isGimbalLockEnabled = true
        cameraNode.constraints = [lookAt]
        scene.rootNode.addChildNode(cameraNode)

        // Add lighting.
        let ambientNode = SCNNode()
        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.intensity = 500
        scene.rootNode.addChildNode(ambientNode)

        let directionalNode = SCNNode()
        directionalNode.light = SCNLight()
        directionalNode.light?.type = .directional
        directionalNode.light?.intensity = 1000
        directionalNode.eulerAngles = SCNVector3(
            -Float.pi / 3,
            Float.pi / 4,
            0
        )
        scene.rootNode.addChildNode(directionalNode)

        // The coordinator updates the CA and character movement.
        view.delegate = coordinator

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let coordinator = context.coordinator

        if resetRequested {
            coordinator.resetCA()

            coordinator.character.root.position = SCNVector3(
                5.5, 0, 7.0
            )

            DispatchQueue.main.async {
                resetRequested = false
            }
        }
    }
}

#Preview {
    ContentView()
}
