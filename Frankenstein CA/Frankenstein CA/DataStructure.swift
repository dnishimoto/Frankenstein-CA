///
//  DataStructure.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 10/24/26.
//

import Foundation
import SwiftUI
import SceneKit

// MARK: - Feedback

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
        case .standing:
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
enum FrankensteinPosture: Int {
    case standing
    case crouching
    case crawling
    case rolling
}

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
}

struct FrankensteinLocomotionOutput {
    var walkPhase: Float = 0
    var armLift: Float = 0
    var headTurn: Float = 0
    var mouthOpen: Float = 0
    var heading: Float = 0
    var speed: Float = 0
    var crouch: Float = 0
    var jump: Float = 0
    var lean: Float = 0
    var stride: Float = 0
    var action: FrankensteinAction = .walk
    var reward: Float = 0
    var status = "Ready"

    /// True for exactly one frame when a jump should leave the ground.
    var jumpRequested = false

    /// Posture the body should take.
    var posture: FrankensteinPosture = .standing

    /// Progress through a roll, from `0` to `1`.
    var rollProgress: Float = 0
}

// MARK: - Stage 1 Learning

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
