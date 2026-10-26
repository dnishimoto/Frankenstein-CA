
import Foundation
import SceneKit

final class FrankensteinStage1Learning {

    // MARK: - Public learning state

    private(set) var lastOutcome: FrankensteinStage1Outcome?
    private(set) var lastObservation: FrankensteinStage1Observation?
    private(set) var isSkillActive = false

    private(set) var lastEffectiveReward: Double = 0
    private(set) var totalAttempts = 0
    private(set) var totalSuccesses = 0

    private(set) var attemptsBySkill:
        [FrankensteinStage1Skill: Int] = [:]

    private(set) var successesBySkill:
        [FrankensteinStage1Skill: Int] = [:]

    private(set) var averageRewardBySkill:
        [FrankensteinStage1Skill: Double] = [:]

    private let policy: FrankensteinLearningPolicy

    // MARK: - Active attempt

    private var activeSkill: FrankensteinStage1Skill?
    private var startPosition: SCNVector3 = SCNVector3Zero
    private var startObservation: FrankensteinStage1Observation?
    private var startTime: TimeInterval = 0

    private var startGapWidth: Float = 0
    private var startLandingHeightDelta: Float = 0
    private var startLandingAreaClear = false

    private var outcomeRecorded = false

    init(policy: FrankensteinLearningPolicy) {
        self.policy = policy
    }

    // MARK: - Begin a skill

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
        finishSkill(at: position, outcome: outcome)
    }

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

        // Keep accumulated learning statistics.
    }

    // MARK: - Observation updates

    func updateObservation(
        _ observation: FrankensteinStage1Observation
    ) {
        lastObservation = observation
    }

    // MARK: - Finish and evaluate a skill

    @discardableResult
    func finishSkill(
        at position: SCNVector3,
        outcome: FrankensteinStage1Outcome
    ) -> Bool {
        guard isSkillActive,
              !outcomeRecorded,
              let skill = activeSkill else {
            return false
        }

        // Mark the attempt before learning to prevent duplicate updates.
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
            measuredDuration: measuredDuration
        )

        lastOutcome = outcome
        lastEffectiveReward = effectiveReward

        recordStatistics(for: attempt)
        applyLearning(for: attempt)

        activeSkill = nil
        isSkillActive = false

        return true
    }

    // MARK: - Alleya CA reward evaluation

    private func calculateReward(
        outcome: FrankensteinStage1Outcome,
        distanceTravelled: Float
    ) -> Double {
        var reward = outcome.reward

        // Progress is based on the reported outcome and measured movement.
        // Do not award progress for a blocked or fallen attempt.
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

    // MARK: - Record experience

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

        let count = Double(attemptsBySkill[attempt.skill] ?? 1)

        averageRewardBySkill[attempt.skill] =
            oldAverage + (attempt.effectiveReward - oldAverage) / count
    }

    // MARK: - Policy learning

    private func applyLearning(for attempt: AttemptSummary) {
        /*
         Alleya learning sequence:

         1. Observe the starting environment.
         2. Execute a skill.
         3. Measure displacement and duration.
         4. Evaluate progress, blockage, falling and completion.
         5. Record the experience and reward.
         6. Send feedback to the underlying policy where its API supports it.

         The available policy feedback API is reportJumpOutcome(...).
         A general learn(state:action:reward:nextState:) API is not
         assumed here because its signature has not been verified.
         */

        guard attempt.skill == .jump else { return }

        let successfulJump =
            attempt.outcome.completed &&
            !attempt.outcome.fell &&
            !attempt.outcome.blocked &&
            attempt.landingAreaClear

        let forwardError =
            attempt.distanceTravelled - attempt.gapWidth

        let heightError = attempt.landingHeightDelta

        policy.reportJumpOutcome(
            success: successfulJump,
            forwardError: forwardError,
            heightError: heightError
        )
    }

    // MARK: - Gap assessment

    func shouldAttemptGapJump(
        using observation: FrankensteinStage1Observation,
        maximumJumpDistance: Float,
        maximumLandingHeightDelta: Float = 1.4
    ) -> Bool {
        guard observation.terrainType.lowercased() == "gap",
              observation.gapWidth > 0,
              observation.gapWidth <= maximumJumpDistance,
              observation.landingAreaIsClear,
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

    // MARK: - Helpers

    private func distance(
        from start: SCNVector3,
        to end: SCNVector3
    ) -> Float {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z

        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    private struct AttemptSummary {
        let skill: FrankensteinStage1Skill
        let distanceTravelled: Float
        let gapWidth: Float
        let landingHeightDelta: Float
        let landingAreaClear: Bool
        let effectiveReward: Double
        let outcome: FrankensteinStage1Outcome
        let measuredDuration: TimeInterval
    }
    
}
