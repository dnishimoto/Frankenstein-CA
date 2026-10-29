
import Foundation
import SceneKit
import UIKit

// MARK: - Q-Value Floor Grid

/// A heat map of learned Q-values laid over the whole floor.
///
/// The floor is divided into square cells. Each time the Q-policy completes
/// an update, the cell Frankenstein is standing in records the action that was
/// updated, its new Q-value and the visit count. Each cell shows that action
/// and value, colored green for positive, red for negative and dark when
/// unvisited. A yellow marker follows Frankenstein, and its cell also shows the
/// best value the policy currently stores for what he sees.
///
/// This is display only. It never selects an action and never changes the policy.
final class FrankensteinQFloorGrid {

    // MARK: Configuration

    var isVisible = true

    /// Floor extent in scene units. Matches the two ground slabs
    /// (x from -10 to 10, z from -9 to 9).
    var minX: Float = -10
    var maxX: Float = 10
    var minZ: Float = -9
    var maxZ: Float = 9

    var cellSize: Float = 1.0
    var surfaceY: Float = 0.03

    private let boardName = "FrankensteinQFloorGrid"
    private weak var scene: SCNScene?

    // MARK: Cell storage

    private struct Cell {
        var action: FrankensteinAction?
        var value: Float = 0
        var visits = 0
    }

    private var columns = 0
    private var rows = 0
    private var cells: [Cell] = []
    private var tiles: [SCNNode] = []
    private var dirty: Set<Int> = []
    private var marker: SCNNode?
    private var markerIndex: Int?
    private var markerText = ""

    // MARK: Attach

    func attach(to scene: SCNScene) {
        self.scene = scene

        scene.rootNode.childNode(withName: boardName, recursively: false)?
            .removeFromParentNode()

        columns = max(1, Int(((maxX - minX) / cellSize).rounded()))
        rows = max(1, Int(((maxZ - minZ) / cellSize).rounded()))
        cells = Array(repeating: Cell(), count: columns * rows)
        tiles = []
        dirty = []

        let board = SCNNode()
        board.name = boardName
        scene.rootNode.addChildNode(board)

        for row in 0..<rows {
            for column in 0..<columns {
                let plane = SCNPlane(
                    width: CGFloat(cellSize * 0.96),
                    height: CGFloat(cellSize * 0.96)
                )
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = emptyColor
                material.transparency = 0.82
                material.isDoubleSided = true
                plane.materials = [material]

                let tile = SCNNode(geometry: plane)
                tile.name = "QGridTile"
                tile.eulerAngles.x = -.pi / 2
                tile.position = centerOfCell(column: column, row: row)
                tile.renderingOrder = 10
                board.addChildNode(tile)
                tiles.append(tile)
            }
        }

        // Marker that follows Frankenstein.
        let markerPlane = SCNPlane(
            width: CGFloat(cellSize),
            height: CGFloat(cellSize)
        )
        let markerMaterial = SCNMaterial()
        markerMaterial.lightingModel = .constant
        markerMaterial.diffuse.contents = UIColor.yellow.withAlphaComponent(0.35)
        markerMaterial.isDoubleSided = true
        markerPlane.materials = [markerMaterial]

        let markerNode = SCNNode(geometry: markerPlane)
        markerNode.name = "QGridMarker"
        markerNode.eulerAngles.x = -.pi / 2
        markerNode.renderingOrder = 11
        markerNode.isHidden = true
        board.addChildNode(markerNode)
        marker = markerNode

        board.isHidden = !isVisible
    }

    // MARK: Cell geometry

    private func index(forX x: Float, z: Float) -> Int? {
        guard x >= minX, x < maxX, z >= minZ, z < maxZ else { return nil }
        let column = min(columns - 1, Int((x - minX) / cellSize))
        let row = min(rows - 1, Int((z - minZ) / cellSize))
        return row * columns + column
    }

    private func centerOfCell(column: Int, row: Int) -> SCNVector3 {
        SCNVector3(
            minX + (Float(column) + 0.5) * cellSize,
            surfaceY,
            minZ + (Float(row) + 0.5) * cellSize
        )
    }

    // MARK: Record a learning update

    /// Call when the policy finishes an update. `position` is where
    /// Frankenstein was standing.
    func record(
        position: SCNVector3,
        action: FrankensteinAction,
        newValue: Float
    ) {
        guard let i = index(forX: Float(position.x), z: Float(position.z)) else {
            return
        }

        cells[i].action = action
        cells[i].value = newValue
        cells[i].visits += 1
        dirty.insert(i)
    }

    // MARK: Update every frame

    func update(
        position: SCNVector3,
        policy: FrankensteinLearningPolicy,
        sample: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) {
        guard let board = scene?.rootNode.childNode(
            withName: boardName,
            recursively: false
        ) else {
            return
        }

        board.isHidden = !isVisible
        guard isVisible else { return }

        // Redraw only the cells that changed.
        for i in dirty where i < tiles.count {
            draw(cell: i)
        }
        dirty.removeAll()

        // Marker and its live value.
        guard let marker,
              let i = index(forX: Float(position.x), z: Float(position.z)) else {
            self.marker?.isHidden = true
            return
        }

        marker.isHidden = false
        marker.position = SCNVector3(
            tiles[i].position.x,
            surfaceY + 0.01,
            tiles[i].position.z
        )

        // Show what the policy stores for the state he sees right now.
        let values = policy.actionValues(terrain: sample, body: body)
        if let best = values.max(by: { $0.value < $1.value }),
           markerIndex != i || markerText != "\(best.key)\(best.value)" {
            markerIndex = i
            markerText = "\(best.key)\(best.value)"
            marker.geometry?.firstMaterial?.diffuse.contents =
                image(
                    top: "NOW \(shortName(best.key))",
                    bottom: String(format: "%.2f", best.value),
                    background: UIColor.yellow.withAlphaComponent(0.55),
                    textColor: .black
                )
        }
    }

    // MARK: Drawing

    private var emptyColor: UIColor {
        UIColor(white: 0.12, alpha: 1)
    }

    private func draw(cell i: Int) {
        let cell = cells[i]
        guard let action = cell.action else { return }

        let normalized = CGFloat(min(1, max(-1, cell.value / 3)))
        let background: UIColor
        if normalized >= 0 {
            background = UIColor(
                red: 0.10,
                green: 0.20 + 0.55 * normalized,
                blue: 0.15,
                alpha: 1
            )
        } else {
            background = UIColor(
                red: 0.20 + 0.55 * -normalized,
                green: 0.10,
                blue: 0.10,
                alpha: 1
            )
        }

        tiles[i].geometry?.firstMaterial?.diffuse.contents = image(
            top: shortName(action),
            bottom: String(format: "%.2f", cell.value),
            background: background,
            textColor: .white
        )
    }

    
    private func shortName(_ action: FrankensteinAction) -> String {
        switch action {
        case .walk:        return "WALK"
        case .run:         return "RUN"
        case .turnLeft:    return "TURN L"
        case .turnRight:   return "TURN R"
        case .jump:        return "JUMP"
        case .crouch:      return "CROUCH"
        case .stepUp:      return "STEP UP"
        case .stepDown:    return "STEP DN"
        case .roll:        return "ROLL"
        case .crawl:       return "CRAWL"
        case .recover:     return "RECOVER"
        case .backward:    return "BACK"
        case .stepForward: return "STEP FW"
        case .liftObject:  return "LIFT"
        case .placeObject: return "PLACE"
        case .throwObject: return "THROW"
        case .pushObject:  return "PUSH"
        }
    }


    private func image(
        top: String,
        bottom: String,
        background: UIColor,
        textColor: UIColor
    ) -> UIImage {
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor(white: 1, alpha: 0.25).setStroke()
            context.cgContext.setLineWidth(3)
            context.cgContext.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let small: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]
            let large: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 34, weight: .heavy),
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]

            (top as NSString).draw(
                in: CGRect(x: 0, y: 24, width: size.width, height: 30),
                withAttributes: small
            )
            (bottom as NSString).draw(
                in: CGRect(x: 0, y: 62, width: size.width, height: 44),
                withAttributes: large
            )
        }
    }
}
