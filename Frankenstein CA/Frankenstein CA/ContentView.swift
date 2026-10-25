import SwiftUI
import SceneKit
import UIKit
    
    struct ContentView: View {
        @State private var isRunning = true
        @State private var generation = 0
        @State private var liveCells = 0
        
        var body: some View {
            ZStack {
                Color(red: 0.07, green: 0.08, blue: 0.09)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("FRANKENSTEIN")
                                .font(.system(size: 23, weight: .heavy, design: .rounded))
                                .tracking(2)
                            
                            Text("CELLULAR AUTOMATON")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(2)
                                .foregroundStyle(.green)
                        }
                        
                        Spacer()
                        
                        Circle()
                            .fill(isRunning ? .green : .orange)
                            .frame(width: 10, height: 10)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                    
                    FrankensteinSceneView(
                        isRunning: isRunning,
                        onStats: { newGeneration, newLiveCells in
                            generation = newGeneration
                            liveCells = newLiveCells
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 12)
                    
                    HStack(spacing: 24) {
                        statView(title: "GENERATION", value: "\(generation)")
                        statView(title: "LIVE CELLS", value: "\(liveCells)")
                        statView(title: "GRID", value: "18 × 18")
                    }
                    .padding(.vertical, 18)
                    
                    HStack(spacing: 12) {
                        Button {
                            isRunning.toggle()
                        } label: {
                            Label(
                                isRunning ? "Pause" : "Resume",
                                systemImage: isRunning ? "pause.fill" : "play.fill"
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.green.opacity(0.20))
                            .foregroundStyle(.green)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        
                        Button {
                            NotificationCenter.default.post(
                                name: .frankensteinReset,
                                object: nil
                            )
                            generation = 0
                            liveCells = 0
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(.white.opacity(0.08))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
            }
            .preferredColorScheme(.dark)
        }
        
        private func statView(title: String, value: String) -> some View {
            VStack(spacing: 5) {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                
                Text(title)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity)
        }
    }
    
    extension Notification.Name {
        static let frankensteinReset = Notification.Name("frankensteinReset")
    }
    
    struct FrankensteinSceneView: UIViewRepresentable {
        var isRunning: Bool
        var onStats: (Int, Int) -> Void
        
        func makeCoordinator() -> Coordinator {
            Coordinator(onStats: onStats)
        }
        
    
        func makeUIView(context: Context) -> SCNView {
            let view = SCNView()
            let scene = SCNScene()
            let character = FrankensteinCharacter()
            let ca = FrankensteinCA()

            // Add Frankenstein once.
            scene.rootNode.addChildNode(character.root)

            // Add the visible obstacle course.
            FrankensteinTerrainScene.build(in: scene)

            context.coordinator.character = character
            context.coordinator.ca = ca

            view.scene = scene
            view.backgroundColor = UIColor(
                red: 0.12, green: 0.14, blue: 0.15, alpha: 1
            )
            view.allowsCameraControl = true
            view.autoenablesDefaultLighting = false
            view.antialiasingMode = .multisampling4X
            view.isPlaying = true
            view.delegate = context.coordinator

            // Camera
            let camera = SCNCamera()
            camera.fieldOfView = 55
            camera.zNear = 0.1
            camera.zFar = 150

            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(10, 10, -19)
            cameraNode.look(at: SCNVector3(0, 1, 0))
            scene.rootNode.addChildNode(cameraNode)

            // Lighting
            addLight(
                to: scene,
                position: SCNVector3(-4, 7, -5),
                intensity: 1000,
                color: .white
            )

            addLight(
                to: scene,
                position: SCNVector3(4, 4, -3),
                intensity: 500,
                color: .white
            )

            addLight(
                to: scene,
                position: SCNVector3(0, 5, 4),
                intensity: 700,
                color: UIColor(
                    red: 0.55, green: 0.75, blue: 0.58, alpha: 1
                )
            )

            // IMPORTANT:
            // Do not add an infinite SCNFloor here.
            // The obstacle course supplies its own ground surfaces.

            return view
        }

        
        private func addLight(
            to scene: SCNScene,
            position: SCNVector3,
            intensity: CGFloat,
            color: UIColor
        ) {
            let light = SCNLight()
            light.type = .omni
            light.intensity = intensity
            light.color = color
            
            let node = SCNNode()
            node.light = light
            node.position = position
            scene.rootNode.addChildNode(node)
        }
        
        func updateUIView(_ uiView: SCNView, context: Context) {
            context.coordinator.isRunning = isRunning
        }
        
    

       
    }

