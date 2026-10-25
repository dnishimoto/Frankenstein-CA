
import Foundation

struct FrankensteinMotion {
    var walkPhase: Float = 0
    var armLift: Float = 0
    var headTurn: Float = 0
    var mouthOpen: Float = 0
}

final class FrankensteinCA {
    let rows = 18
    let columns = 18

    private var cells: [[Bool]]
    private var generation = 0
    private var time: Float = 0

    private(set) var motion = FrankensteinMotion()

    init() {
        cells = Array(
            repeating: Array(repeating: false, count: 18),
            count: 18
        )
        seedPattern()
    }

    private func seedPattern() {
        let pattern: [(Int, Int)] = [
            (1, 0), (2, 1), (0, 2), (1, 2), (2, 2)
        ]

        for (x, y) in pattern {
            cells[y + 2][x + 2] = true
        }

        for x in 0..<3 {
            cells[6][7 + x] = true
            cells[10][11 + x] = true
        }

        for y in 0..<rows {
            for x in 0..<columns {
                let value = (x * 17 + y * 31 + x * y * 3) % 23
                if value == 0 || value == 7 {
                    cells[y][x] = true
                }
            }
        }
    }

    func step(deltaTime: Float) -> FrankensteinMotion {
        let dt = min(max(deltaTime, 0), 0.05)
        time += dt

        updateCells()

        let alive = liveCellCount
        let activity = Float(alive) / Float(rows * columns)
        let intensity = min(max(activity * 3.0, 0.15), 1.0)

        motion.walkPhase += dt * (1.4 + intensity * 2.2)
        motion.armLift = sin(time * 1.2) * 0.20 + intensity * 0.18
        motion.headTurn = sin(time * 0.75) * 0.28

        let speechPulse = max(0, sin(time * 4.0))
        motion.mouthOpen = speechPulse * 0.35 * intensity

        return motion
    }

    private func updateCells() {
        var next = cells

        for y in 0..<rows {
            for x in 0..<columns {
                var neighbors = 0

                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 {
                            continue
                        }

                        let nx = x + dx
                        let ny = y + dy

                        if nx >= 0 && nx < columns &&
                           ny >= 0 && ny < rows &&
                           cells[ny][nx] {
                            neighbors += 1
                        }
                    }
                }

                if cells[y][x] {
                    next[y][x] = neighbors == 2 || neighbors == 3
                } else {
                    next[y][x] = neighbors == 3
                }
            }
        }

        cells = next
        generation += 1

        if generation % 80 == 0 {
            let x = (generation * 7) % columns
            let y = (generation * 11) % rows
            cells[y][x] = true
        }
    }

    func reset() {
        generation = 0
        time = 0
        motion = FrankensteinMotion()
        cells = Array(
            repeating: Array(repeating: false, count: columns),
            count: rows
        )
        seedPattern()
    }

    var liveCellCount: Int {
        cells.reduce(0) { total, row in
            total + row.filter { $0 }.count
        }
    }

    var generationCount: Int {
        generation
    }
}

