


import Foundation
import Testing
import SceneKit
import simd
@testable import Frankenstein_CA

struct FrankensteinPerceptionTests {

   
    private func detectedObject(
        name: String = "MovableBlock",
        distance: Float = 0.5,
        dimensions: SCNVector3 = SCNVector3(0.5, 0.5, 0.5),
        position: SCNVector3 = SCNVector3(0, 0.25, -0.5),
        pickupable: Bool = true
    ) -> DetectedObjectInfo {
        DetectedObjectInfo(
            name: name,
            dimensions: dimensions,
            distance: distance,
            worldPosition: position,
            pickupable: pickupable,
            topY: position.y + dimensions.y / 2
        )
    }


    private let characterPosition = SCNVector3Zero
    private let forward = SIMD3<Float>(0, 0, -1)

    // MARK: - Object identity

    @Test
    func perceptionPreservesDetectedObjectName() {
        let layer = FrankensteinPerceptionLayer()
        let block = detectedObject(name: "MovableBlock")

        let frame = layer.assess(
            detections: [block],
            characterPosition: characterPosition,
            forward: forward
        )

        #expect(frame.visibleObjects.count == 1)
        #expect(frame.visibleObjects.first?.name == "MovableBlock")
        #expect(frame.nearestObstacle?.name == "MovableBlock")
    }

    // MARK: - Distance measurement

    @Test
    func perceptionPreservesMeasuredDistance() {
        let layer = FrankensteinPerceptionLayer()
        let block = detectedObject(distance: 0.18)

        let frame = layer.assess(
            detections: [block],
            characterPosition: characterPosition,
            forward: forward
        )

        #expect(frame.nearestObstacle != nil)

        if let nearest = frame.nearestObstacle {
            #expect(abs(nearest.distance - 0.18) < 0.001)
        }

        #expect(frame.summary.contains("0.18 m"))
    }

    // MARK: - Dimensions

    @Test
    func perceptionPreservesObjectDimensions() {
        let layer = FrankensteinPerceptionLayer()

        let block = detectedObject(
            dimensions: SCNVector3(0.5, 0.5, 0.5)
        )    

        let frame = layer.assess(
            detections: [block],
            characterPosition: characterPosition,
            forward: forward
        )

        #expect(frame.nearestObstacle != nil)

        if let nearest = frame.nearestObstacle {
            #expect(abs(nearest.dimensions.x - 0.5) < 0.001)
            #expect(abs(nearest.dimensions.y - 0.5) < 0.001)
            #expect(abs(nearest.dimensions.z - 0.5) < 0.001)
        }

        #expect(frame.summary.contains("0.50 × 0.50 × 0.50 m"))
    }

    // MARK: - Pickup affordance

    @Test
    func perceptionPreservesPickupableAffordance() {
        let layer = FrankensteinPerceptionLayer()

        let pickupableBlock = detectedObject(pickupable: true)
        let fixedTable = detectedObject(
            name: "FixedTable",
            distance: 0.8,
            position: SCNVector3(1, 0.5, -0.8),
            pickupable: false
        )

        let frame = layer.assess(
            detections: [pickupableBlock, fixedTable],
            characterPosition: characterPosition,
            forward: forward
        )

        let block = frame.visibleObjects.first {
            $0.name == "MovableBlock"
        }

        let table = frame.visibleObjects.first {
            $0.name == "FixedTable"
        }

        #expect(block?.pickupable == true)
        #expect(table?.pickupable == false)
    }

    // MARK: - Nearest object

    @Test
    func perceptionSelectsNearestObstacleByMeasuredDistance() {
        let layer = FrankensteinPerceptionLayer()

        let farObject = detectedObject(
            name: "FarCrate",
            distance: 1.2,
            position: SCNVector3(0, 0.25, -1.2)
        )

        let nearObject = detectedObject(
            name: "NearBlock",
            distance: 0.2,
            position: SCNVector3(0, 0.25, -0.2)
        )

        let frame = layer.assess(
            detections: [farObject, nearObject],
            characterPosition: characterPosition,
            forward: forward
        )

        #expect(frame.visibleObjects.count == 2)
        #expect(frame.nearestObstacle?.name == "NearBlock")
        #expect(frame.nearestObstacle?.distance == 0.2)
    }

    // MARK: - Duplicate ray hits

    @Test
    func perceptionDeduplicatesMultipleRaysHittingSameObject() {
        let layer = FrankensteinPerceptionLayer()

        let fartherRayHit = detectedObject(
            name: "MovableBlock",
            distance: 0.18,
            position: SCNVector3(0, 0.25, -0.5)
        )

        let closerRayHit = detectedObject(
            name: "MovableBlock",
            distance: 0.12,
            position: SCNVector3(0, 0.25, -0.5)
        )

        let frame = layer.assess(
            detections: [fartherRayHit, closerRayHit],
            characterPosition: characterPosition,
            forward: forward
        )

        #expect(frame.visibleObjects.count == 1)
        #expect(frame.nearestObstacle?.name == "MovableBlock")

        if let nearest = frame.nearestObstacle {
            #expect(abs(nearest.distance - 0.12) < 0.001)
        }
    }

    // MARK: - Empty scan

    @Test
    func emptyScanReturnsNoDetectedObjects() {
        let layer = FrankensteinPerceptionLayer()

        let frame = layer.assess(
            detections: [],
            characterPosition: characterPosition,
            forward: forward
        )

        #expect(frame.visibleObjects.isEmpty)
        #expect(frame.nearestObstacle == nil)
        #expect(frame.planningTarget == nil)
        #expect(frame.immediateRisk == 0)
        #expect(
            frame.summary.contains("clear field")
        )
    }

    // MARK: - Risk estimate

    @Test
    func closerObstacleProducesHigherImmediateRisk() {
        let layer = FrankensteinPerceptionLayer()

        let nearFrame = layer.assess(
            detections: [
                detectedObject(distance: 0.2)
            ],
            characterPosition: characterPosition,
            forward: forward
        )

        let farFrame = layer.assess(
            detections: [
                detectedObject(
                    distance: 1.2,
                    position: SCNVector3(0, 0.25, -1.2)
                )
            ],
            characterPosition: characterPosition,
            forward: forward
        )

        #expect(nearFrame.immediateRisk > farFrame.immediateRisk)
    }
}

