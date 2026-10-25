//
//  DataStructure.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 10/24/26.
//

import Foundation

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
