//
//  File.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 10/28/26.
//

import Foundation
import SceneKit
import simd


final class FrankensteinPerceptionLayer {
    
    static func assess(
            hits: [SCNHitTestResult],
            origin: SCNVector3,
            heading: Float,
            terrainSample: FrankensteinTerrainSample
        ) -> FrankensteinPerceptionFrame {
            var assessedObjects: [DetectedObjectInfo] = []
            var seenNames = Set<String>()

            for hit in hits {
                let node = hit.node
                guard let name = node.name,
                      !name.contains("Frankenstein"),
                      !name.contains("GroundFloor"),
                      !name.contains("TerrainRoot") else {
                    continue
                }

                // Deduplicate by node name
                guard !seenNames.contains(name) else { continue }
                seenNames.insert(name)

                let hitPoint = hit.worldCoordinates
                let dx = hitPoint.x - origin.x
                let dz = hitPoint.z - origin.z
                let distance = sqrt(dx * dx + dz * dz)
                
                // Calculate bearing relative to heading
                let angleToNode = atan2(-dx, -dz)
                var bearing = angleToNode - heading
                while bearing > .pi { bearing -= 2 * .pi }
                while bearing < -.pi { bearing += 2 * .pi }

                // Extract dimensions
                let bounds = node.boundingBox
                let dims = SCNVector3(
                    abs(bounds.max.x - bounds.min.x),
                    abs(bounds.max.y - bounds.min.y),
                    abs(bounds.max.z - bounds.min.z)
                )

                let topY = hitPoint.y + (dims.y / 2)

                // Determine affordances
                let lowerName = name.lowercased()
                let isMovable = lowerName.contains("movable") || lowerName.contains("crate")
                let isPickupable = lowerName.contains("letterblock") || lowerName.contains("pickup")

                let info = DetectedObjectInfo(
                    name: name,
                    distance: Float(distance),
                    bearing: Float(bearing),
                    dimensions: dims,
                    worldPosition: hitPoint,
                    pickupable: isPickupable,
                    movable: isMovable,
                    topY: topY
                )

                assessedObjects.append(info)
            }

            // Diagnostic debug print as requested during previous analysis
            print("========== PERCEPTION INPUT ==========")
            print("Incoming assessed objects: \(assessedObjects.count)")
            for (index, obj) in assessedObjects.enumerated() {
                print("""
                  Object \(index + 1):
                    Name: \(obj.name)
                    Distance: \(obj.distance)
                    Position: \(obj.worldPosition)
                    Dimensions: \(obj.dimensions)
                    Movable: \(obj.movable), Pickupable: \(obj.pickupable)
                """)
            }
            print("======================================")

            return FrankensteinPerceptionFrame(
                detectedObjects: assessedObjects,
                terrainSample: terrainSample
            )
        }
}

