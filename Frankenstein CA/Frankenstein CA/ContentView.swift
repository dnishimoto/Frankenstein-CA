
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
