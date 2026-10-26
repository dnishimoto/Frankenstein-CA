
import Foundation
import Combine

/// An 18 × 18 cellular automaton used as an animation signal source.
///
/// The CA controls animation signals only. Actual walking, turning,
/// jumping, crawling, collision handling, and environmental learning
/// belong to the locomotion and learning systems.
final class FrankensteinCA: ObservableObject {

    // MARK: - Configuration

    let size = 18

    /// Conway-style survival range.
    private let survivalNeighbors = 2...3

    /// A dead cell becomes alive when exactly three neighbors are alive.
    private let birthNeighbors = 3

    // MARK: - Published State

    @Published private(set) var grid: [[Bool]] = []
    @Published private(set) var generation: Int = 0
    @Published private(set) var isRunning: Bool = false

    // MARK: - Working Buffer

    private var nextGrid: [[Bool]] = []

    // MARK: - Animation Signals

    /// These are visual signals, not physical movement commands.
    @Published private(set) var walkPhase: Float = 0
    @Published private(set) var armLift: Float = 0
    @Published private(set) var headTurn: Float = 0
    @Published private(set) var mouthOpen: Float = 0

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
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func toggleRunning() {
        isRunning.toggle()
    }

    /// Advances one generation, whether or not continuous running is enabled.
    func step() {
        update()
    }

    /// Called by a timer or display loop when continuous running is enabled.
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
            return
        }

        for y in 0..<size {
            for x in 0..<size {
                let neighbors = countLiveNeighbors(x: x, y: y)
                let currentlyAlive = grid[y][x]

                if currentlyAlive {
                    nextGrid[y][x] = survivalNeighbors.contains(neighbors)
                } else {
                    nextGrid[y][x] = neighbors == birthNeighbors
                }
            }
        }

        // Swap buffers instead of allocating a new grid every generation.
        swap(&grid, &nextGrid)

        generation += 1
        refreshAnimationSignals()
    }

    /// Returns whether a cell is alive.
    ///
    /// Coordinates outside the grid return false rather than crashing.
    func isActive(_ x: Int, _ y: Int) -> Bool {
        guard (0..<size).contains(x),
              (0..<size).contains(y) else {
            return false
        }

        return grid[y][x]
    }

    /// Sets a cell directly. Useful for tests and interactive editing.
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

    /// Uses wrapping boundaries, matching the recovered reference code.
    private func countLiveNeighbors(x: Int, y: Int) -> Int {
        var count = 0

        for dy in -1...1 {
            for dx in -1...1 {
                if dx == 0 && dy == 0 {
                    continue
                }

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

        generation = 0
        refreshAnimationSignals()
    }

    /// Creates a repeatable starter pattern with several active regions.
    func seedDefaultPattern() {
        grid = Self.makeEmptyGrid(size: size)
        nextGrid = Self.makeEmptyGrid(size: size)

        // Glider near the upper-left area.
        let glider: [(Int, Int)] = [
            (2, 1),
            (3, 2),
            (1, 3),
            (2, 3),
            (3, 3)
        ]

        // Blinker near the center.
        let blinker: [(Int, Int)] = [
            (8, 8),
            (8, 9),
            (8, 10)
        ]

        // Small oscillator toward the lower-right.
        let oscillator: [(Int, Int)] = [
            (13, 12),
            (14, 12),
            (15, 12),
            (14, 13),
            (14, 14)
        ]

        for (x, y) in glider + blinker + oscillator {
            if (0..<size).contains(x), (0..<size).contains(y) {
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

    // MARK: - Animation Signal Mapping

    /// Maps selected CA cells to bounded animation values.
    ///
    /// These values can animate FrankensteinCharacter's limbs and face.
    /// They do not move the character through the SceneKit world.
    private func refreshAnimationSignals() {
        walkPhase = isActive(8, 8) ? 1.0 : 0.0
        armLift = isActive(4, 4) ? 1.0 : 0.0
        headTurn = isActive(2, 2) ? 1.0 : 0.0
        mouthOpen = isActive(10, 10) ? 1.0 : 0.0
    }

    /// Allows an external animation system to read all four signals at once.
    var animationSignals: FrankensteinMotion {
        FrankensteinMotion(
            walkPhase: walkPhase,
            armLift: armLift,
            headTurn: headTurn,
            mouthOpen: mouthOpen
        )
    }
}

