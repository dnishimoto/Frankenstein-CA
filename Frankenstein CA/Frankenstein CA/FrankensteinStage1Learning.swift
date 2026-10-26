
import Foundation
import SceneKit

final class FrankensteinStage1Learning {

    private(set) var lastOutcome: FrankensteinStage1Outcome?
    private(set) var lastObservation: FrankensteinStage1Observation?
    private(set) var isSkillActive = false

    private let policy: FrankensteinLearningPolicy

    private var activeSkill: FrankensteinStage1Skill?
    private var startPosition: SCNVector3 = SCNVector3Zero

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
        lastObservation = observation

        // Read the observation directly.
        startGapWidth = observation.gapWidth
        startLandingHeightDelta = observation.landingHeightDelta
        startLandingAreaClear = observation.landingAreaIsClear

        outcomeRecorded = false
        isSkillActive = true
    }


    // MARK: - Compatibility API for FrankensteinInMotion

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

    func reset() {
        activeSkill = nil
        isSkillActive = false
        outcomeRecorded = false

        startPosition = SCNVector3Zero
        startGapWidth = 0
        startLandingHeightDelta = 0
        startLandingAreaClear = false

        lastObservation = nil
        lastOutcome = nil
    }


    func updateObservation(
        _ observation: FrankensteinStage1Observation
    ) {
        lastObservation = observation
    }

    // MARK: - Finish a skill

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

        outcomeRecorded = true
        lastOutcome = outcome

        let distanceTravelled = distance(
            from: startPosition,
            to: position
        )

        // Keep these measurements available for the policy update.
        let attempt = AttemptSummary(
            skill: skill,
            distanceTravelled: distanceTravelled,
            gapWidth: startGapWidth,
            landingHeightDelta: startLandingHeightDelta,
            landingAreaClear: startLandingAreaClear,
            outcome: outcome
        )

        applyLearning(for: attempt)

        activeSkill = nil
        isSkillActive = false

        return true
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

    // MARK: - Policy learning

    private func applyLearning(for attempt: AttemptSummary) {
        /*
         Connect this method to the existing policy learning API.

         The exact call depends on the current definitions of
         FrankensteinStage1Skill, FrankensteinStage1Outcome,
         and FrankensteinLearningPolicy.learn(...).
         */
        _ = policy
        _ = attempt
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
        let outcome: FrankensteinStage1Outcome
    }
}
