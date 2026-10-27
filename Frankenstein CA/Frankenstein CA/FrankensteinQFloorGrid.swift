
import Foundation
import SceneKit
import UIKit

// MARK: - Q-Value Floor Grid

/// Displays the existing learning policy's Q-values on a floor grid.
///
/// Rows represent terrain types.
/// Columns represent distance bands.
/// Each tile displays the best allowed action and its Q-value.
///
/// This visualizes policy values; it is not a spatial route map.
final class FrankensteinQFloorGrid {

    // MARK: Configuration

    var isVisible = true
    var boardPosition = SCNVector3(-5.8, 0.025, -5.0)

    var tileWidth: Float = 1.35
    var tileDepth: Float = 0.95
    var tileGap: Float = 0.08

    private let boardName = "FrankensteinQFloorGrid"
    private weak var scene: SCNScene?

    private var tileNodes: [SCNNode] = []
    private var lastUpdateTime: TimeInterval = 0

    private let terrains: [TerrainDefinition] = [
        TerrainDefinition(name: "FLAT", terrain: .flat),
        TerrainDefinition(name: "HURDLE", terrain: .hurdle),
        TerrainDefinition(name: "GAP", terrain: .gap),
        TerrainDefinition(name: "LOW CEILING", terrain: .lowCeiling),
        TerrainDefinition(name: "RAISED STEP", terrain: .raisedStep),
        TerrainDefinition(name: "SLOPE", terrain: .slope),
        TerrainDefinition(name: "UNEVEN", terrain: .uneven)
    ]

    private let distanceBands: [DistanceDefinition] = [
        DistanceDefinition(name: "NEAR", distance: 0.4),
        DistanceDefinition(name: "MID", distance: 1.3),
        DistanceDefinition(name: "FAR", distance: 2.5)
    ]

    private struct TerrainDefinition {
        let name: String
        let terrain: FrankensteinTerrain
    }

    private struct DistanceDefinition {
        let name: String
        let distance: Float
    }

    // MARK: Attach

    func attach(to scene: SCNScene) {
        self.scene = scene

        if let existing = scene.rootNode.childNode(
            withName: boardName,
            recursively: false
        ) {
            existing.removeFromParentNode()
        }

        tileNodes.removeAll()

        let board = SCNNode()
        board.name = boardName
        board.position = boardPosition
        scene.rootNode.addChildNode(board)

        addTitle(to: board)
        buildTiles(on: board)

        board.isHidden = !isVisible
    }

    // MARK: Build board

    private func addTitle(to board: SCNNode) {
        let title = makeText(
            "FRANKENSTEIN Q-POLICY",
            size: 0.20,
            color: .white
        )

        title.position = SCNVector3(
            0,
            0.04,
            -tileDepth * 3.9
        )

        board.addChildNode(title)

        let subtitle = makeText(
            "TERRAIN / DISTANCE / BEST ACTION",
            size: 0.10,
            color: .lightGray
        )

        subtitle.position = SCNVector3(
            0,
            0.04,
            -tileDepth * 3.5
        )

        board.addChildNode(subtitle)
    }

    private func buildTiles(on board: SCNNode) {
        for row in terrains.indices {
            for column in distanceBands.indices {
                let tile = makeTile(
                    terrainName: terrains[row].name,
                    distanceName: distanceBands[column].name
                )

                let x = Float(column - 1) *
                    (tileWidth + tileGap)

                let z = Float(row) *
                    (tileDepth + tileGap)

                tile.position = SCNVector3(
                    x,
                    0,
                    z
                )

                board.addChildNode(tile)
                tileNodes.append(tile)
            }
        }
    }

    private func makeTile(
        terrainName: String,
        distanceName: String
    ) -> SCNNode {
        let container = SCNNode()

        let geometry = SCNBox(
            width: CGFloat(tileWidth),
            height: 0.025,
            length: CGFloat(tileDepth),
            chamferRadius: 0.035
        )

        geometry.materials = [
            makeMaterial(color: UIColor(white: 0.16, alpha: 0.96))
        ]

        let base = SCNNode(geometry: geometry)
        base.position.y = 0.0125
        container.addChildNode(base)

        let terrainText = makeText(
            terrainName,
            size: 0.105,
            color: .white
        )

        terrainText.position = SCNVector3(
            0,
            0.035,
            -0.25
        )

        container.addChildNode(terrainText)

        let distanceText = makeText(
            distanceName,
            size: 0.09,
            color: .lightGray
        )

        distanceText.position = SCNVector3(
            0,
            0.035,
            -0.09
        )

        container.addChildNode(distanceText)

        let actionText = makeText(
            "ACTION: —",
            size: 0.10,
            color: .cyan
        )

        actionText.name = "QGridAction"
        actionText.position = SCNVector3(
            0,
            0.035,
            0.08
        )

        container.addChildNode(actionText)

        let valueText = makeText(
            "Q: 0.00",
            size: 0.10,
            color: .yellow
        )

        valueText.name = "QGridValue"
        valueText.position = SCNVector3(
            0,
            0.035,
            0.25
        )

        container.addChildNode(valueText)

        return container
    }

    // MARK: Update from actual policy

    func update(
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

        for row in terrains.indices {
            for column in distanceBands.indices {
                let index =
                    row * distanceBands.count + column

                guard index < tileNodes.count else { continue }

                let tile = tileNodes[index]

                var tileSample = sample
                tileSample.terrain = terrains[row].terrain
                tileSample.distance = distanceBands[column].distance

                var tileBody = body
                tileBody.grounded = true
                tileBody.fallen = false

                let values = policy.actionValues(
                    terrain: tileSample,
                    body: tileBody
                )

                let best = values.first

                let actionName = best.map {
                    String(describing: $0.action).uppercased()
                } ?? "UNLEARNED"

                let qValue = best?.value ?? 0

                let actionNode = tile.childNode(
                    withName: "QGridAction",
                    recursively: false
                )

                let valueNode = tile.childNode(
                    withName: "QGridValue",
                    recursively: false
                )

                actionNode?.geometry = makeTextGeometry(
                    "ACTION: \(actionName)",
                    size: 0.085,
                    color: .cyan
                )

                valueNode?.geometry = makeTextGeometry(
                    String(format: "Q: %.2f", qValue),
                    size: 0.10,
                    color: qValue >= 0 ? .yellow : .orange
                )

                // Give higher-valued tiles a brighter appearance.
                let normalized = CGFloat(
                    min(1, max(0, (Double(qValue) + 2) / 6))
                )

                if let base = tile.childNodes.first,
                   let box = base.geometry as? SCNBox {
                    box.firstMaterial?.diffuse.contents =
                        UIColor(
                            red: 0.10 + 0.10 * normalized,
                            green: 0.12 + 0.45 * normalized,
                            blue: 0.18 + 0.15 * normalized,
                            alpha: 0.96
                        )
                }
            }
        }
    }

    // MARK: Text helpers

    private func makeText(
        _ string: String,
        size: CGFloat,
        color: UIColor
    ) -> SCNNode {
        let node = SCNNode(
            geometry: makeTextGeometry(
                string,
                size: size,
                color: color
            )
        )

        // SCNText lies in the local XY plane. Rotate it onto the floor.
        node.eulerAngles.x = -.pi / 2

        return node
    }

    private func makeTextGeometry(
        _ string: String,
        size: CGFloat,
        color: UIColor
    ) -> SCNText {
        let text = SCNText(
            string: string,
            extrusionDepth: 0.001
        )

        text.font = UIFont.monospacedSystemFont(
            ofSize: size,
            weight: .bold
        )

        text.flatness = 0.2
        text.alignmentMode = CATextLayerAlignmentMode.center.rawValue
        text.firstMaterial?.diffuse.contents = color
        text.firstMaterial?.isDoubleSided = true

        let (minBound, maxBound) = text.boundingBox

        text.containerFrame = CGRect(
            x: CGFloat(minBound.x),
            y: CGFloat(minBound.y),
            width: CGFloat(maxBound.x - minBound.x),
            height: CGFloat(maxBound.y - minBound.y)
        )

        return text
    }

    private func makeMaterial(
        color: UIColor
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.05
        material.roughness.contents = 0.8
        return material
    }
}
