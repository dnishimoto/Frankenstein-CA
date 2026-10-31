/*
 Frankenstein’s learning policy should teach him to select the most appropriate movement skill based on the terrain, obstacles, and his previous experiences. On clear, level ground, he should learn when to walk or run, with success measured by actual progress without collisions. When encountering an obstacle that can be bypassed, he should evaluate turning and walking around it, learning that the maneuver is successful when he avoids the obstacle and decreases his distance to the goal. When facing a raised step, he should evaluate stepping up or jumping, receiving a positive reward when he successfully reaches the upper surface. When approaching a gap, he should learn to jump across it when the distance and landing conditions permit, or choose a safer alternate route when jumping is too risky; success means landing safely or reaching the other side by another route. When encountering a low barrier, he should evaluate rolling or crouching, learning that the action succeeds when he passes underneath without colliding. If movement fails because he is blocked, stuck, or unable to proceed, he should evaluate turning or recovering until movement resumes and progress continues. In every situation, the policy should learn from measured outcomes rather than intended movements, rewarding successful navigation and penalizing collisions, failed maneuvers, and confirmed falls. Over repeated attempts, this feedback should help Frankenstein choose and combine walking, running, turning, stepping, jumping, rolling, and recovery to navigate the course more effectively.
 */
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
    @State private var seenText = "I have not looked around yet."
    @State private var planText = "I have not made a plan yet."
    @State private var qCells: [FrankensteinQDisplayCell] = []
 
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
                    seenText = "I have not looked around yet."
                    planText = "I have not made a plan yet."
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            FrankensteinSceneView(
                generation: $generation,
                liveCells: $liveCells,
                resetRequested: $resetRequested,
                seenText: $seenText,
                planText: $planText,
                qCells: $qCells
            )

            QNetworkGridPanel(cells: qCells)

            RobotMindPanel(seen: seenText, plan: planText)

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


// MARK: - Q network grid

/// The Q-value grid now displays Q-values for only visible objects, not actions.
///
/// Every visible object's Q-value for the state Frankenstein sees.
struct QNetworkGridPanel: View {
    let cells: [FrankensteinQDisplayCell]

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 6
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Q network grid", systemImage: "square.grid.3x3")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Spacer()

                Text("red border = dirty")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(cells, id: \.id) { cell in
                    VStack(spacing: 1) {
                        Text(cell.objectName)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)

                        Text(String(format: "%.2f", Double(cell.value)))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(color(for: cell.value))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                cell.isDirty ? Color.red : Color.clear,
                                lineWidth: 2
                            )
                    )
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private func color(for value: Float) -> Color {
        let strength = Double(min(1, abs(value) / 2)) * 0.45

        return value >= 0
            ? Color.green.opacity(strength)
            : Color.orange.opacity(strength)
    }
}


// MARK: - What Frankenstein sees and is planning

struct RobotMindPanel: View {
    let seen: String
    let plan: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            section(
                title: "Frankenstein sees",
                symbol: "eye",
                text: seen
            )

            Divider()

            section(
                title: "Frankenstein is planning",
                symbol: "point.topleft.down.curvedto.point.bottomright.up",
                text: plan
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    private func section(
        title: String,
        symbol: String,
        text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ScrollView {
                Text(text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 96)
        }
    }
}

#Preview {
    ContentView()
}
