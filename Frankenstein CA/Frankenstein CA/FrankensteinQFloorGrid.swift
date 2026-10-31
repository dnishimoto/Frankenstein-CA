import Foundation
import SceneKit
import UIKit

// MARK: - Q-Value Floor Grid

/// A heat map of learned Q-values laid over the whole floor.
///
/// The floor is divided into square cells. Each time the Q-policy completes
/// an update, the cell Frankenstein is standing in records the object name,
/// its new Q-value and the visit count. Each cell shows that object name
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
        var objectName: String = "FLOOR"
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
                material.diffuse.contents = emptyColor(isDirty: false)
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
    /// Frankenstein was standing, and `objectName` names the local object/terrain.
    func record(
        position: SCNVector3,
        action: FrankensteinAction, // Kept in signature for compatibility with Coordinator loop
        newValue: Float,
        objectName: String? = nil
    ) {
        guard let i = index(forX: Float(position.x), z: Float(position.z)) else {
            return
        }

        cells[i].value = newValue
        cells[i].visits += 1
        
        if let name = objectName, !name.isEmpty {
            cells[i].objectName = name
        }
        
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
            draw(cell: i, isDirty: true)
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
        if let best = values.max(by: { $0.value < $1.value }) {
            let labelName = sample.objectName.isEmpty ? "FLOOR" : sample.objectName.uppercased()
            let comboKey = "\(labelName)_\(best.value)"
            if markerIndex != i || markerText != comboKey {
                markerIndex = i
                markerText = comboKey
                marker.geometry?.firstMaterial?.diffuse.contents =
                    image(
                        top: labelName,
                        bottom: String(format: "%.2f", best.value),
                        background: UIColor.yellow.withAlphaComponent(0.55),
                        textColor: .black,
                        borderColor: UIColor.red,
                        borderWidth: 4
                    )
            }
        }
    }

    /// Marks the floor grid cells falling within Frankenstein's field of view as visible.
    func markVisible(position: SCNVector3, heading: Float, halfAngle: Float, range: Float) {
        for row in 0..<rows {
            for col in 0..<columns {
                let cellWorldPosition = worldPosition(forRow: row, col: col)
                
                let dx = Float(cellWorldPosition.x - position.x)
                let dz = Float(cellWorldPosition.z - position.z)
                let distance = sqrt(dx * dx + dz * dz)
                
                if distance <= range {
                    let angleToCell = atan2(-dx, -dz)
                    var angleDiff = angleToCell - heading
                    
                    while angleDiff > .pi { angleDiff -= 2.0 * .pi }
                    while angleDiff < -.pi { angleDiff += 2.0 * .pi }
                    
                    if abs(angleDiff) <= halfAngle {
                        // Cell within field of view
                    }
                }
            }
        }
    }
     
    private func worldPosition(forRow row: Int, col: Int) -> SCNVector3 {
        centerOfCell(column: col, row: row)
    }

    private func emptyColor(isDirty: Bool) -> UIColor {
        isDirty ? UIColor(white: 0.18, alpha: 1) : UIColor(white: 0.12, alpha: 1)
    }

    private func draw(cell i: Int, isDirty: Bool) {
            let cell = cells[i]
            // ... color calculations ...

            let labelName = cell.objectName.uppercased()

            tiles[i].geometry?.firstMaterial?.diffuse.contents = image(
                top: labelName, // Displays the object name
                bottom: String(format: "%.2f", cell.value),
                background: UIColor.systemBackground,
                textColor: .white,
                borderColor: isDirty ? .red : UIColor(white: 1, alpha: 0.25),
                borderWidth: isDirty ? 5 : 3
            )
        }

    private func image(
        top: String,
        bottom: String,
        background: UIColor,
        textColor: UIColor,
        borderColor: UIColor,
        borderWidth: CGFloat
    ) -> UIImage {
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            borderColor.setStroke()
            context.cgContext.setLineWidth(borderWidth)
            context.cgContext.stroke(CGRect(origin: .zero, size: size).insetBy(dx: borderWidth / 2, dy: borderWidth / 2))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let small: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 18, weight: .bold),
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]
            let large: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 34, weight: .heavy),
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]

            (top as NSString).draw(
                in: CGRect(x: 4, y: 24, width: size.width - 8, height: 30),
                withAttributes: small
            )
            (bottom as NSString).draw(
                in: CGRect(x: 0, y: 62, width: size.width, height: 44),
                withAttributes: large
            )
        }
    }
}
