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
    /// Creates a stable, distinct list from the field-of-view ray hits and
    /// scores objects for planning without replacing the CA's action decision.
    func assess(
        detections: [DetectedObjectInfo],
        characterPosition: SCNVector3,
        forward: SIMD3<Float>
    ) -> FrankensteinPerceptionFrame {
        let objects = deduplicate(detections)
        let nearest = objects.min { $0.distance < $1.distance }

        let target = objects.min { lhs, rhs in
            score(lhs, characterPosition: characterPosition, forward: forward)
                < score(rhs, characterPosition: characterPosition, forward: forward)
        }

        let risk = riskForNearestObject(nearest)
        let summary: String
        if let nearest {
            let dimensions = nearest.dimensions
            let targetName = target?.name ?? nearest.name
            summary = String(
                format: "Perception: %d object(s); nearest %@ at %.2f m (%.2f × %.2f × %.2f m); target %@; risk %.2f",
                objects.count,
                nearest.name,
                nearest.distance,
                dimensions.x,
                dimensions.y,
                dimensions.z,
                targetName,
                risk
            )
        } else {
            summary = "Perception: clear field within current scan range."
        }

        return FrankensteinPerceptionFrame(
            visibleObjects: objects,
            nearestObstacle: nearest,
            planningTarget: target,
            summary: summary,
            immediateRisk: risk
        )
    }

    private func deduplicate(_ detections: [DetectedObjectInfo]) -> [DetectedObjectInfo] {
        var bestByKey: [String: DetectedObjectInfo] = [:]
        for item in detections {
            let p = item.worldPosition
            let key = [
                item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                String(Int((Float(p.x) * 2).rounded())),
                String(Int((Float(p.y) * 2).rounded())),
                String(Int((Float(p.z) * 2).rounded()))
            ].joined(separator: "|")
            if let previous = bestByKey[key] {
                if item.distance < previous.distance { bestByKey[key] = item }
            } else {
                bestByKey[key] = item
            }
        }
        return bestByKey.values.sorted { $0.distance < $1.distance }
    }

    private func score(
        _ object: DetectedObjectInfo,
        characterPosition: SCNVector3,
        forward: SIMD3<Float>
    ) -> Float {
        let dx = Float(object.worldPosition.x - characterPosition.x)
        let dz = Float(object.worldPosition.z - characterPosition.z)
        let length = max(0.001, sqrt(dx * dx + dz * dz))
        let directionDot = max(-1, min(1, (dx * forward.x + dz * forward.z) / length))
        let offAxisPenalty = (1 - directionDot) * 0.7
        let name = object.name.lowercased()
        var utilityBonus: Float = 0

        if object.pickupable { utilityBonus += 0.8 }
        if name.contains("box") || name.contains("crate") || name.contains("block") ||
            name.contains("stool") || name.contains("table") {
            utilityBonus += 0.45
        }
        if name.contains("recharge") || name.contains("chargingstation") || name.contains("station") {
            utilityBonus += 1.0
        }

        // A very close obstacle should not be ignored merely because it is useful.
        let urgencyPenalty = object.distance < 0.65 ? 0.9 : 0
        return object.distance + offAxisPenalty - utilityBonus + Float(urgencyPenalty)
    }

    private func riskForNearestObject(_ object: DetectedObjectInfo?) -> Float {
        guard let object else { return 0 }
        let distanceRisk = max(0, min(1, (1.5 - object.distance) / 1.5))
        let heightRisk: Float = object.dimensions.y > 0.9 ? 0.25 : 0.08
        return min(1, distanceRisk * 0.8 + heightRisk)
    }
}

