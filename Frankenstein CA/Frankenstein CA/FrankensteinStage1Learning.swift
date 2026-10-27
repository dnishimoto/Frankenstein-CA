

import Foundation
import SceneKit

final class FrankensteinStage1Learning {

    // MARK: - Public Learning State

    private(set) var lastOutcome: FrankensteinStage1Outcome?
    private(set) var lastObservation: FrankensteinStage1Observation?
    private(set) var isSkillActive = false

    private(set) var lastEffectiveReward: Double = 0
    private(set) var totalAttempts = 0
    private(set) var totalSuccesses = 0

    private(set) var attemptsBySkill: [FrankensteinStage1Skill: Int] = [:]
    private(set) var successesBySkill: [FrankensteinStage1Skill: Int] = [:]
    private(set) var averageRewardBySkill: [FrankensteinStage1Skill: Double] = [:]

    private let policy: FrankensteinLearningPolicy

    // MARK: - Active Attempt

    private var activeSkill: FrankensteinStage1Skill?
    private var startPosition: SCNVector3 = SCNVector3Zero
    private var startObservation: FrankensteinStage1Observation?
    private var startTime: TimeInterval = 0

    private var startGapWidth: Float = 0
    private var startLandingHeightDelta: Float = 0
    private var startLandingAreaClear = false

    private var outcomeRecorded = false

    // MARK: - Initialization

    init(policy: FrankensteinLearningPolicy) {
        self.policy = policy
    }

    // MARK: - Begin a Skill

    func beginSkill(
        _ skill: FrankensteinStage1Skill,
        at position: SCNVector3,
        observation: FrankensteinStage1Observation
    ) {
        guard !isSkillActive else { return }

        activeSkill = skill
        startPosition = position
        startObservation = observation
        lastObservation = observation
        startTime = ProcessInfo.processInfo.systemUptime

        startGapWidth = observation.gapWidth
        startLandingHeightDelta = observation.landingHeightDelta
        startLandingAreaClear = observation.landingAreaIsClear

        outcomeRecorded = false
        isSkillActive = true
    }

    // MARK: - Compatibility API

    func observe(_ observation: FrankensteinStage1Observation) {
        updateObservation(observation)
    }

    func begin(
        _ skill: FrankensteinStage1Skill,
        at position: SCNVector3,
        observation: FrankensteinStage1Observation
    ) {
        beginSkill(
            skill,
            at: position,
            observation: observation
        )
    }

    @discardableResult
    func finish(
        at position: SCNVector3,
        outcome: FrankensteinStage1Outcome
    ) -> Bool {
        finishSkill(
            at: position,
            outcome: outcome
        )
    }

    // MARK: - Reset

    func reset() {
        activeSkill = nil
        isSkillActive = false
        outcomeRecorded = false

        startPosition = SCNVector3Zero
        startObservation = nil
        startTime = 0

        startGapWidth = 0
        startLandingHeightDelta = 0
        startLandingAreaClear = false

        lastObservation = nil
        lastOutcome = nil
        lastEffectiveReward = 0

        // Preserve accumulated learning statistics.
    }

    // MARK: - Observation Updates

    func updateObservation(
        _ observation: FrankensteinStage1Observation
    ) {
        lastObservation = observation
    }

    // MARK: - Finish and Evaluate a Skill

    @discardableResult
    func finishSkill(
        at position: SCNVector3,
        outcome: FrankensteinStage1Outcome,
        finalTerrain: FrankensteinTerrainSample? = nil,
        finalBody: FrankensteinBodyState? = nil
    ) -> Bool {

        guard isSkillActive,
              !outcomeRecorded,
              let skill = activeSkill else {
            return false
        }

        // Prevent duplicate outcome recording.
        outcomeRecorded = true

        let endTime = ProcessInfo.processInfo.systemUptime
        let measuredDuration = max(0, endTime - startTime)

        let distanceTravelled = distance(
            from: startPosition,
            to: position
        )

        let effectiveReward = calculateReward(
            outcome: outcome,
            distanceTravelled: distanceTravelled
        )

        let attempt = AttemptSummary(
            skill: skill,
            distanceTravelled: distanceTravelled,
            gapWidth: startGapWidth,
            landingHeightDelta: startLandingHeightDelta,
            landingAreaClear: startLandingAreaClear,
            effectiveReward: effectiveReward,
            outcome: outcome,
            measuredDuration: measuredDuration,
            finalTerrain: finalTerrain,
            finalBody: finalBody
        )

        lastOutcome = outcome
        lastEffectiveReward = effectiveReward

        recordStatistics(for: attempt)
        applyLearning(for: attempt)

        activeSkill = nil
        isSkillActive = false

        return true
    }

    // MARK: - Reward Evaluation

    private func calculateReward(
        outcome: FrankensteinStage1Outcome,
        distanceTravelled: Float
    ) -> Double {

        var reward = outcome.reward

        // Reward progress only when not blocked or fallen.
        if !outcome.blocked && !outcome.fell {
            reward += max(0, outcome.progressMade) * 2.0
            reward += Double(max(0, distanceTravelled)) * 0.25
        }

        if outcome.blocked {
            reward -= 1.5
        }

        if outcome.fell {
            reward -= 8.0
        }

        if outcome.completed {
            reward += 5.0
        }

        return reward
    }

    // MARK: - Record Experience

    private func recordStatistics(for attempt: AttemptSummary) {
        totalAttempts += 1

        attemptsBySkill[attempt.skill, default: 0] += 1

        if attempt.outcome.completed &&
            !attempt.outcome.fell &&
            !attempt.outcome.blocked {

            totalSuccesses += 1
            successesBySkill[attempt.skill, default: 0] += 1
        }

        let oldAverage =
            averageRewardBySkill[attempt.skill] ?? 0

        let count = Double(
            attemptsBySkill[attempt.skill] ?? 1
        )

        averageRewardBySkill[attempt.skill] =
            oldAverage +
            (attempt.effectiveReward - oldAverage) / count
    }

    // MARK: - Policy Learning

    private func applyLearning(for attempt: AttemptSummary) {

        // The currently connected feedback method handles jumps.
        guard attempt.skill == .jump else { return }

        let successfulJump =
            attempt.outcome.completed &&
            !attempt.outcome.fell &&
            !attempt.outcome.blocked &&
            attempt.landingAreaClear

        // Require real final state values.
        guard let finalTerrain = attempt.finalTerrain,
              let finalBody = attempt.finalBody else {
            return
        }

        policy.reportJumpOutcome(
            succeeded: successfulJump,
            terrain: finalTerrain,
            body: finalBody,
            terminal: attempt.outcome.fell ||
                      attempt.outcome.completed
        )
    }

    // MARK: - Gap Assessment

    func shouldAttemptGapJump(
        using observation: FrankensteinStage1Observation,
        maximumJumpDistance: Float,
        maximumLandingHeightDelta: Float = 1.4
    ) -> Bool {

        guard observation.terrainType.lowercased() == "gap",
              observation.gapWidth.isFinite,
              observation.gapWidth > 0,
              maximumJumpDistance.isFinite,
              maximumJumpDistance > 0,
              observation.gapWidth <= maximumJumpDistance,
              observation.landingAreaIsClear,
              observation.landingHeightDelta.isFinite,
              maximumLandingHeightDelta.isFinite,
              maximumLandingHeightDelta >= 0,
              abs(observation.landingHeightDelta)
                <= maximumLandingHeightDelta,
              observation.gapNearEdgeDistance.isFinite,
              observation.gapFarEdgeDistance.isFinite,
              observation.gapNearEdgeDistance >= 0,
              observation.gapFarEdgeDistance
                > observation.gapNearEdgeDistance else {
            return false
        }

        return true
    }

    // MARK: - Distance Helper

    private func distance(
        from start: SCNVector3,
        to end: SCNVector3
    ) -> Float {

        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z

        return sqrt(
            dx * dx +
            dy * dy +
            dz * dz
        )
    }

    // MARK: - Attempt Summary

    private struct AttemptSummary {
        let skill: FrankensteinStage1Skill
        let distanceTravelled: Float
        let gapWidth: Float
        let landingHeightDelta: Float
        let landingAreaClear: Bool
        let effectiveReward: Double
        let outcome: FrankensteinStage1Outcome
        let measuredDuration: TimeInterval

        let finalTerrain: FrankensteinTerrainSample?
        let finalBody: FrankensteinBodyState?
    }
}


