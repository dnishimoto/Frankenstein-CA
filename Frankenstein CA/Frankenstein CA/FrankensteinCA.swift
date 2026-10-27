
import Foundation
import Combine

/// An 18 × 18 cellular automaton used as an animation signal source.
/// The CA controls animation signals only. Actual movement and learning
/// belong to the locomotion and learning systems.
final class FrankensteinCA: ObservableObject {

    // MARK: - Configuration

    let size = 18

    private let survivalNeighbors = 2...3
    private let birthNeighbors = 3

    // MARK: - Published State

    @Published private(set) var grid: [[Bool]] = []
    @Published private(set) var generation: Int = 0
    @Published private(set) var isRunning: Bool = false

    @Published private(set) var walkPhase: Float = 0
    @Published private(set) var armLift: Float = 0
    @Published private(set) var headTurn: Float = 0
    @Published private(set) var mouthOpen: Float = 0

    // MARK: - Working Buffer

    private var nextGrid: [[Bool]] = []

    // MARK: - Initialization

    init(randomizeOnStart: Bool = true) {
        grid = Self.makeEmptyGrid(size: size)
        nextGrid = Self.makeEmptyGrid(size: size)

        if randomizeOnStart {
            randomize()
        } else {
            seedDefaultPattern()
        }

        refreshAnimationSignals()
    }

    private static func makeEmptyGrid(size: Int) -> [[Bool]] {
        Array(
            repeating: Array(repeating: false, count: size),
            count: size
        )
    }

    // MARK: - Run Controls

    func start() {
        guard !isRunning else { return }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
    }

    func toggleRunning() {
        isRunning.toggle()
    }

    /// Advances exactly one generation, even when stopped.
    func step() {
        update()
    }

    /// Advances only when continuous running is enabled.
    func tick() {
        guard isRunning else { return }
        update()
    }

    // MARK: - Cellular Automaton

    func update() {
        guard grid.count == size,
              grid.allSatisfy({ $0.count == size }) else {
            grid = Self.makeEmptyGrid(size: size)
            nextGrid = Self.makeEmptyGrid(size: size)
            generation = 0
            refreshAnimationSignals()
            return
        }

        for y in 0..<size {
            for x in 0..<size {
                let neighbors = countLiveNeighbors(x: x, y: y)
                let currentlyAlive = grid[y][x]

                if currentlyAlive {
                    nextGrid[y][x] =
                        survivalNeighbors.contains(neighbors)
                } else {
                    nextGrid[y][x] =
                        neighbors == birthNeighbors
                }
            }
        }

        swap(&grid, &nextGrid)

        // Every successful update increments generation.
        generation += 1
        refreshAnimationSignals()
    }

    // MARK: - Cell Access

    func isActive(_ x: Int, _ y: Int) -> Bool {
        guard (0..<size).contains(x),
              (0..<size).contains(y) else {
            return false
        }

        return grid[y][x]
    }

    func setActive(_ active: Bool, x: Int, y: Int) {
        guard (0..<size).contains(x),
              (0..<size).contains(y) else {
            return
        }

        grid[y][x] = active
        refreshAnimationSignals()
    }

    func toggleCell(x: Int, y: Int) {
        guard (0..<size).contains(x),
              (0..<size).contains(y) else {
            return
        }

        grid[y][x].toggle()
        refreshAnimationSignals()
    }

    // MARK: - Neighbor Counting

    private func countLiveNeighbors(x: Int, y: Int) -> Int {
        var count = 0

        for dy in -1...1 {
            for dx in -1...1 {
                if dx == 0 && dy == 0 {
                    continue
                }

                // Wrapping boundaries.
                let nx = (x + dx + size) % size
                let ny = (y + dy + size) % size

                if grid[ny][nx] {
                    count += 1
                }
            }
        }

        return count
    }

    // MARK: - Reset and Seeding

    func reset() {
        isRunning = false
        generation = 0
        grid = Self.makeEmptyGrid(size: size)
        nextGrid = Self.makeEmptyGrid(size: size)
        seedDefaultPattern()
        refreshAnimationSignals()
    }

    func randomize() {
        for y in 0..<size {
            for x in 0..<size {
                grid[y][x] = Bool.random()
            }
        }

        nextGrid = Self.makeEmptyGrid(size: size)
        generation = 0
        refreshAnimationSignals()
    }

    func seedDefaultPattern() {
        grid = Self.makeEmptyGrid(size: size)
        nextGrid = Self.makeEmptyGrid(size: size)

        let glider: [(Int, Int)] = [
            (2, 1), (3, 2), (1, 3), (2, 3), (3, 3)
        ]

        let blinker: [(Int, Int)] = [
            (8, 8), (8, 9), (8, 10)
        ]

        let oscillator: [(Int, Int)] = [
            (13, 12), (14, 12), (15, 12),
            (14, 13), (14, 14)
        ]

        for (x, y) in glider + blinker + oscillator {
            if (0..<size).contains(x),
               (0..<size).contains(y) {
                grid[y][x] = true
            }
        }

        generation = 0
        refreshAnimationSignals()
    }

    // MARK: - Statistics

    var liveCellCount: Int {
        grid.reduce(0) { total, row in
            total + row.filter { $0 }.count
        }
    }

    var liveCellFraction: Float {
        let total = size * size
        guard total > 0 else { return 0 }
        return Float(liveCellCount) / Float(total)
    }

    // MARK: - Animation Signals

    private func refreshAnimationSignals() {
        walkPhase = isActive(8, 8) ? 1.0 : 0.0
        armLift = isActive(4, 4) ? 1.0 : 0.0
        headTurn = isActive(2, 2) ? 1.0 : 0.0
        mouthOpen = isActive(10, 10) ? 1.0 : 0.0
    }

    var animationSignals: FrankensteinMotion {
        FrankensteinMotion(
            walkPhase: walkPhase,
            armLift: armLift,
            headTurn: headTurn,
            mouthOpen: mouthOpen
        )
    }
}


