///
//  DataStructure.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 10/24/26.
//

import Foundation
import SwiftUI
import SceneKit


struct FrankensteinGoalObservation {
    let distance: Float
    let bearingError: Float
    let isMovingTowardGoal: Bool
}

struct FrankensteinPerceptionFrame {
    let visibleObjects: [DetectedObjectInfo]
    let nearestObstacle: DetectedObjectInfo?
    let planningTarget: DetectedObjectInfo?
    let summary: String
    let immediateRisk: Float
}

struct FrankensteinPredictedOutcome {
    let actionName: String
    let expectedForwardDisplacement: Float
    let collisionRisk: Float
    let fallRisk: Float
    let expectedGoalProgress: Float
    let confidence: Float
}

struct FrankensteinQUpdateRecord {
    let action: FrankensteinAction
    let newValue: Float
}
struct FrankensteinObjectObservation: Hashable {
    let name: String
    let width: Float
    let height: Float
    let depth: Float
    let distance: Float
    let pickupable: Bool

    var categoryIndex: Int {
        let value = name.lowercased()
        if value.contains("table") { return 1 }
        if value.contains("door") { return 2 }
        if value.contains("stair") || value.contains("step") { return 3 }
        if value.contains("platform") { return 4 }
        if value.contains("ceiling") { return 5 }
        if value.contains("crate") || value.contains("box") { return 6 }
        if value.contains("dog") { return 7 }
        return 8 // Other measurable object
    }
}

enum AlleyaRechargeGoal: String {
    case mapRoom
    case findUsefulObject
    case approachObject
    case manipulateObject
    case verifyPlacement
    case reachRedPlatform
    case reachChargingStation
    case verifyRecharge
    case recover
    case complete
}

struct AlleyaRechargeState {
    var goal: AlleyaRechargeGoal = .mapRoom
    var generation = 0
    var successfulPlacements = 0
    var failedActions = 0
    var collisions = 0
    var falls = 0
    var rechargeVerified = false
    var lastReason = "Waiting for scene perception"
}

struct AlleyaActionOutcome {
    let goal: AlleyaRechargeGoal
    let action: String
    let reward: Float
    let success: Bool
    let evidence: String
    let generation: Int
}

final class AlleyaFrankensteinPipeline {

    private(set) var state = AlleyaRechargeState()
    private(set) var history: [AlleyaActionOutcome] = []

    /// Call only with results measured from the actual SceneKit scene.
    func observe(
        generation: Int,
        fell: Bool,
        collision: Bool,
        onRedPlatform: Bool,
        chargerDetected: Bool,
        chargerContact: Bool,
        chargeBefore: Float,
        chargeAfter: Float,
        hasUsefulMovableObject: Bool
    ) {
        state.generation = generation

        if collision {
            state.collisions += 1
        }

        if fell {
            state.falls += 1
            state.goal = .recover
            state.lastReason = "Fall detected; recover before continuing"
            return
        }

        // Success requires a measured charge increase while in contact.
        if chargerContact &&
            chargeBefore.isFinite &&
            chargeAfter.isFinite &&
            chargeAfter > chargeBefore {
            state.goal = .complete
            state.rechargeVerified = true
            state.lastReason = "Recharge verified"
            return
        }

        if !onRedPlatform {
            if hasUsefulMovableObject {
                state.goal = .findUsefulObject
                state.lastReason =
                    "Evaluate whether the object clears the route or provides a safe step"
            } else {
                state.goal = .reachRedPlatform
                state.lastReason =
                    "Proceed along a verified safe route toward the red platform"
            }
            return
        }

        if !chargerDetected {
            state.goal = .reachChargingStation
            state.lastReason = "Search the platform for the charging station"
            return
        }

        if !chargerContact {
            state.goal = .reachChargingStation
            state.lastReason = "Approach and align with the charger"
            return
        }

        state.goal = .verifyRecharge
        state.lastReason = "Contact detected; check for an actual charge increase"
    }

    func recordOutcome(
        action: String,
        success: Bool,
        fell: Bool,
        collision: Bool,
        evidence: String
    ) {
        let reward: Float

        if state.rechargeVerified {
            reward = 100
        } else if fell {
            reward = -15
        } else if collision {
            reward = -5
        } else if success {
            reward = 3
        } else {
            reward = -2
        }

        history.append(
            AlleyaActionOutcome(
                goal: state.goal,
                action: action,
                reward: reward,
                success: success,
                evidence: evidence,
                generation: state.generation
            )
        )

        if !success {
            state.failedActions += 1
        }

        // Bound the episode log.
        if history.count > 500 {
            history.removeFirst(history.count - 500)
        }
    }

    func resetEpisode(keepHistory: Bool = true) {
        let previousHistory = keepHistory ? history : []
        state = AlleyaRechargeState()
        history = previousHistory
    }
}


enum FrankensteinPosture: Equatable {
    case standing
    case walking
    case running
    case jumping
    case crouching
    case crawling
    case rolling
}


struct FrankensteinLocomotionOutput {

    // MARK: - Movement

    var heading: Float = 0
    var speed: Float = 0

    /// 1 moves forward; -1 moves backward.
    var moveDirection: Float = 1

    var stride: Float = 0
    var walkPhase: Float = 0
    var lean: Float = 0

    // MARK: - Posture and Animation

    var posture: FrankensteinPosture = .standing

    var crouch: Float = 0
    var jump: Float = 0

    /// True for exactly one frame when a jump should leave the ground.
    var jumpRequested: Bool = false

    /// Progress through a roll, from 0 to 1.
    var rollProgress: Float = 0

    var armLift: Float = 0
    var headTurn: Float = 0
    var mouthOpen: Float = 0

    // MARK: - CA Action and Learning Feedback

    var action: FrankensteinAction = .walk
    var reward: Float = 0
    var status: String = "Ready"

    // MARK: - Object Manipulation

    /// The Coordinator performs scene-object interactions.
    var liftRequested: Bool = false
    var placeRequested: Bool = false
    var throwRequested: Bool = false
}



enum FrankensteinGoalStage: String {
    case exploreRoom
    case locateUsefulObject
    case moveObjectToPlatform
    case useObjectAsStep
    case climbToRedPlatform
    case reachChargingStation
    case rechargeComplete
}


enum FrankensteinCACommand {
    case walk
    case run
    case turnLeft
    case turnRight
}
enum FrankensteinEpisodeEnd {
    case reachedGoal
    case fell
}

struct DetectedObjectInfo {
    let name: String
    let dimensions: SCNVector3
    let distance: Float
    let worldPosition: SCNVector3
    let pickupable: Bool

    /// World height of the top of the object.
    var topY: Float = 0

    var dimensionsText: String {
        String(
            format: "%.2f × %.2f × %.2f",
            Double(dimensions.x),
            Double(dimensions.y),
            Double(dimensions.z)
        )
    }

    var distanceText: String {
        String(format: "%.2f m", Double(distance))
    }
}


enum FrankensteinFallReason: Equatable {
    case void
    case hardLanding
}

enum FrankensteinWorldEvent: Equatable {
    case tookOff
    case landed(drop: Float, horizontal: Float, rise: Float)
    case steppedUp(rise: Float)
    case collided
    case fell(FrankensteinFallReason)
    case reachedGoal
}

struct FrankensteinMotionFeedback {
    var position = SCNVector3(0, 0, 0)
    var grounded = true
    var feetHeight: Float = 0
    var verticalVelocity: Float = 0
    var bodyHeight: Float = FrankensteinPhysicalBody.standingHeight

    /// Free height above his feet at his current position.
    /// Large when nothing is overhead. This, not `bodyHeight`,
    /// says whether he is forced to stay low.
    var headroom: Float = 99

    /// Horizontal distance he tried to cover this frame.
    var intendedDistance: Float = 0

    /// Horizontal distance he actually covered.
    var movedDistance: Float = 0

    /// Measured horizontal speed.
    var speed: Float = 0

    /// Distance gained toward the finish line this frame.
    /// Negative means he lost progress.
    var goalProgress: Float = 0

    var blocked = false
    var events: [FrankensteinWorldEvent] = []

    /// Optimistic feedback used only when no physical body is attached.
    static func assumed(
        speed: Float,
        heading: Float,
        dt: Float
    ) -> FrankensteinMotionFeedback {
        var feedback = FrankensteinMotionFeedback()

        let distance = max(0, speed) * dt

        feedback.intendedDistance = distance
        feedback.movedDistance = distance
        feedback.speed = speed
        feedback.goalProgress = cos(heading) * distance

        return feedback
    }
}

struct FrankensteinBodyCommand {
    var speed: Float
    var heading: Float
    var posture: FrankensteinPosture
    var jumpRequested: Bool
}

// MARK: - Physical Body

enum FrankensteinPhysicalBody {
    // The character model is about 4.9 units tall, and the course
    // — door, table, barriers — is built to that scale, so the
    // physical body uses the same scale.
    static let standingHeight: Float = 4.8
    static let crouchHeight: Float = 3.2
    static let rollHeight: Float = 1.7
    static let crawlHeight: Float = 1.3
    static let radius: Float = 0.5

    // Capabilities of the body itself, not of the policy.
    static let maxStepHeight: Float = 0.6
    static let maxJumpableHeight: Float = 1.4
    static let maxSafeDrop: Float = 2.0
    static let fallDepth: Float = 2.6
    static let gravity: Float = 9.8
    static let jumpImpulse: Float = 6.0
    static let climbRate: Float = 4.0

    static let walkSpeed: Float = 1.6
    static let runSpeed: Float = 3.4
    static let crouchSpeed: Float = 1.2
    static let crawlSpeed: Float = 1.0
    static let rollSpeed: Float = 2.6
    static let rollDuration: Float = 0.75

    // Sensing.
    static let lookAhead: Float = 4.0
    static let profileSpacing: Float = 0.2
    static let groundProbeRise: Float = FrankensteinPhysicalBody.maxStepHeight + 0.1
    static let ceilingProbeRise: Float = FrankensteinPhysicalBody.maxStepHeight + 0.05
    static let tallProbeRise: Float = 6.0

    static let startPosition = SCNVector3(5.5, 0.0, 7.0)
    static let finishZ: Float = -8.6

    // Category masks.
    // The default node category is 1, which is neither of these.
    static let solidMask: Int = 1 << 1
    static let decorationMask: Int = 1 << 3


    static func height(for posture: FrankensteinPosture) -> Float {
        switch posture {
        case .standing, .walking, .running, .jumping:
            return standingHeight

        case .crouching:
            return crouchHeight

        case .crawling:
            return crawlHeight

        case .rolling:
            return rollHeight
        }
    }


    /// Heights above the feet of the horizontal rays used for sensing.
    /// The lowest ray sits below step height so steps can be seen and
    /// measured. Overhead clearance is measured using vertical rays.
    static func bodyRayHeights(bodyHeight: Float) -> [Float] {
        [0.3] + collisionRayHeights(bodyHeight: bodyHeight)
    }

    /// Heights above the feet of the horizontal rays used for collision.
    /// The lowest ray is just above the tallest step he can climb, so a
    /// step is never treated as a wall. Steps are handled by climb logic
    /// and a rise check.
    static func collisionRayHeights(bodyHeight: Float) -> [Float] {
        var heights: [Float] = [FrankensteinPhysicalBody.maxStepHeight + 0.05]

        if bodyHeight > 1.4 {
            heights.append(1.1)
        }

        if bodyHeight > 2.6 {
            heights.append(bodyHeight * 0.5)
        }

        return heights
    }
}

// MARK: - Pose

struct FrankensteinWorldPose {
    var x: Float
    var z: Float
    var feetY: Float

    /// Height of the surface he is standing on,
    /// or the last surface he stood on.
    var referenceY: Float

    var heading: Float
    var bodyHeight: Float
    var grounded: Bool
}

enum FrankensteinTerrain: String, Codable, CaseIterable {
    case flat
    case hurdle
    case gap
    case lowCeiling
    case raisedStep
    case slope
    case uneven
    case unknown

    var suggestedActions: [FrankensteinLearningAction] {
        switch self {
        case .flat:
            return [.walk, .run, .explore]

        case .hurdle:
            return [.jump, .stepUp, .stop, .explore]

        case .gap:
            return [.stop, .jump, .explore]

        case .lowCeiling:
            return [.crawl, .roll, .stop, .explore]

        case .raisedStep:
            return [.stepUp, .jump, .explore]

        case .slope:
            return [.walk, .stop, .explore]

        case .uneven:
            return [.walk, .stop, .explore]

        case .unknown:
            return [.stop, .explore]
        }
    }
}

struct FrankensteinBodyState {
    var speed: Float = 0
    var tilt: Float = 0
    var verticalVelocity: Float = 0
    var height: Float = 1.8
    var grounded = true
    var fallen = false
    var distanceTravelled: Float = 0

    /// Heading relative to the finish direction.
    /// `0` means facing the finish.
    /// Positive means turned to his left.
    var headingError: Float = 0
}

// MARK: - Posture and Actions

/// How his body is held. Each posture has a physical height that is
/// checked against real geometry overhead.

enum FrankensteinAction: Int, CaseIterable {
    case walk
    case run
    case turnLeft
    case turnRight
    case jump
    case crouch
    case stepUp
    case stepDown
    case roll
    case crawl
    case recover
    case backward
    case stepForward
    case liftObject
    case placeObject
    case throwObject
}

enum FrankensteinStage1Skill: String, Codable, CaseIterable {
    case walk
    case run
    case turn
    case stepUp
    case jump
    case roll
    case recover
    case crouch
    case crawl
    case wait
}

struct FrankensteinStage1Observation {
    // MARK: Goal and obstacle measurements

    var distanceToGoal: Float
    var obstacleDistance: Float
    var obstacleHeight: Float
    var gapWidth: Float

    // MARK: Ground and movement state

    var hasGroundAhead: Bool
    var isGrounded: Bool
    var hasCollision: Bool
    var landingAreaIsClear: Bool

    // MARK: Character and terrain state

    var currentHeight: Float
    var terrainType: String

    // MARK: Chasm measurements

    var gapNearEdgeDistance: Float
    var gapFarEdgeDistance: Float
    var landingHeightDelta: Float

    init(
        distanceToGoal: Float,
        obstacleDistance: Float = .infinity,
        obstacleHeight: Float = 0,
        gapWidth: Float = 0,
        hasGroundAhead: Bool = true,
        isGrounded: Bool = true,
        hasCollision: Bool = false,
        landingAreaIsClear: Bool = true,
        currentHeight: Float = 0,
        terrainType: String = "unknown",
        gapNearEdgeDistance: Float = .infinity,
        gapFarEdgeDistance: Float = .infinity,
        landingHeightDelta: Float = 0
    ) {
        self.distanceToGoal = distanceToGoal
        self.obstacleDistance = obstacleDistance
        self.obstacleHeight = obstacleHeight
        self.gapWidth = gapWidth
        self.hasGroundAhead = hasGroundAhead
        self.isGrounded = isGrounded
        self.hasCollision = hasCollision
        self.landingAreaIsClear = landingAreaIsClear
        self.currentHeight = currentHeight
        self.terrainType = terrainType
        self.gapNearEdgeDistance = gapNearEdgeDistance
        self.gapFarEdgeDistance = gapFarEdgeDistance
        self.landingHeightDelta = landingHeightDelta
    }
}

/// Outcome of one completed skill attempt.
struct FrankensteinStage1Outcome: Codable {
    let skill: FrankensteinStage1Skill
    let reward: Double
    let progressMade: Double
    let blocked: Bool
    let fell: Bool
    let completed: Bool
    let duration: Double
}

struct FrankensteinMotion {
    var walkPhase: Float = 0
    var armLift: Float = 0
    var headTurn: Float = 0
    var mouthOpen: Float = 0
}

// MARK: - Learning Actions

enum FrankensteinLearningAction: String, CaseIterable {
    case explore
    case walk
    case run
    case jump
    case stepUp
    case jumpDown
    case roll
    case open
    case stop
    case crawl
}

// MARK: - Environmental Observations

struct FrankensteinObservation {
    var obstacleAhead = false
    var gapAhead = false
    var stepAhead = false
    var dropAhead = false
    var lowCeiling = false
    var objectNearby = false
    var objectCanOpen = false
    var groundSupported = true
    var pathClear = true

    /// A stable object identifier lets the learner remember encounters
    /// with the same object across multiple frames.
    var objectID: String = ""

    var stateKey: String {
        [
            obstacleAhead ? "obstacle" : "clear",
            gapAhead ? "gap" : "noGap",
            stepAhead ? "step" : "noStep",
            dropAhead ? "drop" : "noDrop",
            lowCeiling ? "low" : "high",
            objectNearby ? "object" : "noObject",
            objectCanOpen ? "openable" : "notOpenable",
            groundSupported ? "ground" : "unsupported",
            pathClear ? "clearPath" : "blockedPath"
        ]
        .joined(separator: "|")
    }
}

// MARK: - Learning Memory

struct FrankensteinLearningMemory {
    var actionValues: [FrankensteinLearningAction: Float] = [:]
    var attempts: [FrankensteinLearningAction: Int] = [:]
    var successes: [FrankensteinLearningAction: Int] = [:]

    func value(for action: FrankensteinLearningAction) -> Float {
        actionValues[action, default: 0]
    }
}

// MARK: - Cellular Automaton and Learner

