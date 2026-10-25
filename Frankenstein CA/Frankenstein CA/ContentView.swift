/*
 Frankenstein’s learning policy should teach him to select the most appropriate movement skill based on the terrain, obstacles, and his previous experiences. On clear, level ground, he should learn when to walk or run, with success measured by actual progress without collisions. When encountering an obstacle that can be bypassed, he should evaluate turning and walking around it, learning that the maneuver is successful when he avoids the obstacle and decreases his distance to the goal. When facing a raised step, he should evaluate stepping up or jumping, receiving a positive reward when he successfully reaches the upper surface. When approaching a gap, he should learn to jump across it when the distance and landing conditions permit, or choose a safer alternate route when jumping is too risky; success means landing safely or reaching the other side by another route. When encountering a low barrier, he should evaluate rolling or crouching, learning that the action succeeds when he passes underneath without colliding. If movement fails because he is blocked, stuck, or unable to proceed, he should evaluate turning or recovering until movement resumes and progress continues. In every situation, the policy should learn from measured outcomes rather than intended movements, rewarding successful navigation and penalizing collisions, failed maneuvers, and confirmed falls. Over repeated attempts, this feedback should help Frankenstein choose and combine walking, running, turning, stepping, jumping, rolling, and recovery to navigate the course more effectively.
 */
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


#Preview {
    ContentView()
}
