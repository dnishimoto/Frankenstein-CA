//
//  DataStructure.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 10/24/26.
//

import Foundation
import Combine

enum FrankensteinTerrain: Int, CaseIterable {
    case flat, hurdle, gap, lowCeiling, raisedStep, slope, uneven
}

struct FrankensteinTerrainSample {
    var terrain: FrankensteinTerrain = .flat
    var distance: Float = 5
    var obstacleHeight: Float = 0
    var gapWidth: Float = 0
    var groundHeight: Float = 0
    var nextGroundHeight: Float = 0
    var isGroundAhead = true
    var isLandingAreaClear = true
}

struct FrankensteinBodyState {
    var speed: Float = 0
    var tilt: Float = 0
    var verticalVelocity: Float = 0
    var height: Float = 1.8
    var grounded = true
    var fallen = false
    var distanceTravelled: Float = 0
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
    case wait
}

// MARK: - What Frankenstein senses

struct FrankensteinStage1Observation {
    var distanceToGoal: Float
    var obstacleDistance: Float
    var obstacleHeight: Float
    var gapWidth: Float

    var hasGroundAhead: Bool
    var isGrounded: Bool
    var hasCollision: Bool
    var landingAreaIsClear: Bool

    var currentHeight: Float
    var terrainType: String

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
        terrainType: String = "unknown"
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
    }
}

// MARK: - Outcome of one completed skill attempt

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

// MARK: - Available actions

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
}

// MARK: - Environmental observations

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

    // A stable object identifier lets the learner remember
    // encounters with the same object across multiple frames.
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
        ].joined(separator: "|")
    }
}

// MARK: - Learning memory

struct FrankensteinLearningMemory {
    var actionValues: [FrankensteinLearningAction: Float] = [:]
    var attempts: [FrankensteinLearningAction: Int] = [:]
    var successes: [FrankensteinLearningAction: Int] = [:]

    func value(for action: FrankensteinLearningAction) -> Float {
        actionValues[action, default: 0]
    }
}

// MARK: - Cellular automaton and learner
