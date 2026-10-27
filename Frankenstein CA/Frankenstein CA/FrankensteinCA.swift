import Foundation
import Combine



/// 18 x 18 cellular automaton and executive action controller.
/// The CA owns the final action choice. Q-learning contributes learned values,
/// while terrain constraints and the locomotion safety layer restrict candidates.
final class FrankensteinCA: ObservableObject {
    let size = 18
    @Published private(set) var generation: Int = 0
    @Published private(set) var isRunning = false
    @Published private(set) var liveCellCount: Int = 0
    @Published private(set) var lastDecisionDescription = "Waiting for perception"

    private var grid: [[Bool]]
    private var nextGrid: [[Bool]]

    init() {
        grid = Array(repeating: Array(repeating: false, count: size), count: size)
        nextGrid = grid
        randomize()
        liveCellCount = countLiveCells()
    }

    func isActive(_ x: Int, _ y: Int) -> Bool {
        guard (0..<size).contains(x), (0..<size).contains(y) else { return false }
        return grid[y][x]
    }

    func start() { isRunning = true }
    func stop() { isRunning = false }
    func tick() { guard isRunning else { return }; update() }
    func step() { update() }

    func reset() {
        generation = 0
        randomize()
        liveCellCount = countLiveCells()
        lastDecisionDescription = "Reset"
    }

    func update() {
        for y in 0..<size {
            for x in 0..<size {
                let neighbors = countLiveNeighbors(x: x, y: y)
                nextGrid[y][x] = (grid[y][x] && (neighbors == 2 || neighbors == 3)) ||
                    (!grid[y][x] && neighbors == 3)
            }
        }
        swap(&grid, &nextGrid)
        generation += 1
        liveCellCount = countLiveCells()
    }

    /// Executive decision. The CA combines its live spatial pattern with learned
    /// Q-values, but only selects from actions permitted by the current state.
    func decideAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        allowedActions: [FrankensteinAction],
        qValues: [FrankensteinAction: Float]
    ) -> FrankensteinAction {
        guard !allowedActions.isEmpty else {
            lastDecisionDescription = "No permitted action"
            return .walk
        }

        let left = activity(in: 0..<(size / 3))
        let center = activity(in: (size / 3)..<((size * 2) / 3))
        let right = activity(in: ((size * 2) / 3)..<size)
        let leftBias = Float(left - right) / Float(max(1, size * size))
        let centerBias = Float(center) / Float(max(1, size * size))

        // The CA's own spatial state creates action-specific preferences.
        // Q-values are learned evidence, not an independent controller.
        func caBias(_ action: FrankensteinAction) -> Float {
            switch action {
            case .turnLeft: return leftBias * 3.0
            case .turnRight: return -leftBias * 3.0
            case .run: return centerBias * 1.5
            case .walk: return 0.15
            case .jump:
                return (terrain.terrain == .gap || terrain.terrain == .hurdle || terrain.terrain == .raisedStep) ? 0.35 : -0.1
            case .stepUp:
                return terrain.terrain == .raisedStep ? 0.35 : 0
            case .crouch:
                return terrain.terrain == .lowCeiling ? 0.5 : 0
            case .recover:
                return body.fallen ? 1.0 : -1.0
            default: return 0
            }
        }

        let selected = allowedActions.max { lhs, rhs in
            let l = (qValues[lhs] ?? 0) + caBias(lhs)
            let r = (qValues[rhs] ?? 0) + caBias(rhs)
            return l < r
        } ?? allowedActions[0]

        lastDecisionDescription = "\(selected) | Q=\(qValues[selected] ?? 0), CA activity L/C/R=\(left)/\(center)/\(right)"
        print("[CA] Executive selected: \(selected)")
        print("[CA] Q-policy advice: \(qValues)")
        print("[CA] Generation=\(generation), live cells=\(liveCellCount)")
        return selected
    }

    private func activity(in columns: Range<Int>) -> Int {
        var total = 0
        for y in 0..<size {
            for x in columns where grid[y][x] { total += 1 }
        }
        return total
    }

    private func countLiveNeighbors(x: Int, y: Int) -> Int {
        var count = 0
        for dy in -1...1 {
            for dx in -1...1 {
                if dx == 0 && dy == 0 { continue }
                let nx = (x + dx + size) % size
                let ny = (y + dy + size) % size
                if grid[ny][nx] { count += 1 }
            }
        }
        return count
    }

    private func countLiveCells() -> Int {
        grid.reduce(0) { $0 + $1.filter { $0 }.count }
    }

    private func randomize() {
        for y in 0..<size {
            for x in 0..<size { grid[y][x] = Bool.random() }
        }
    }
}
