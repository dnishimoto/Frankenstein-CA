
//  FrankensteinObjectMemory.swift
//  Frankenstein CA
//
//  Where Frankenstein last saw each object. The plan depends on objects it
//  is not always looking at (the block he is going to lift, the slot he is
//  carrying it to, the dog). Without memory, a target that leaves his field
//  of vision, or sits below the sensing rays when he is next to it, vanishes
//  from the CA's perception and the plan's lift / place actions are never
//  allowed. With memory, the plan keeps its target's last known position,
//  size and kind until it is seen again.
//

import Foundation
import simd
import SceneKit



final class FrankensteinObjectMemory {

    private(set) var objects: [String: RememberedObject] = [:]

    /// Records or refreshes an object (by its name).
    func remember(
        name: String,
        position: SIMD3<Float>,
        dimensions: SIMD3<Float>,
        pickupable: Bool,
        movable: Bool,
        time: TimeInterval
    ) {
        guard !name.isEmpty else { return }

        var entry = objects[name] ?? RememberedObject(
            name: name,
            position: position,
            dimensions: dimensions,
            pickupable: pickupable,
            movable: movable,
            lastSeen: time,
            timesSeen: 0
        )

        entry.position = position
        entry.dimensions = dimensions
        entry.pickupable = pickupable
        entry.movable = movable
        entry.lastSeen = time
        entry.timesSeen += 1

        objects[name] = entry
    }

    /// Records everything in his field of vision right now.
    func observe(
        _ seen: [DetectedObjectInfo],
        time: TimeInterval,
        isMovable: (String) -> Bool
    ) {
        for item in seen {
            remember(
                name: item.name,
                position: SIMD3<Float>(
                    Float(item.worldPosition.x),
                    Float(item.worldPosition.y),
                    Float(item.worldPosition.z)
                ),
                dimensions: SIMD3<Float>(
                    Float(item.dimensions.x),
                    Float(item.dimensions.y),
                    Float(item.dimensions.z)
                ),
                pickupable: item.pickupable,
                movable: isMovable(item.name),
                time: time
            )
        }
    }

    func recall(_ name: String?) -> RememberedObject? {
        guard let name else { return nil }
        return objects[name]
    }

    func forget(_ name: String) {
        objects[name] = nil
    }

    func clear() {
        objects.removeAll()
    }

    /// Seconds since the object was last seen, or infinity if never.
    func age(of name: String, now: TimeInterval) -> TimeInterval {
        guard let entry = objects[name] else { return .infinity }
        return max(0, now - entry.lastSeen)
    }
}
