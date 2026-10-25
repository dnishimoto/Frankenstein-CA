
import Foundation
import SceneKit

final class FrankensteinStage1Learning {

    private(set) var lastOutcome: FrankensteinStage1Outcome?

    private let policy: FrankensteinLearningPolicy

    private var activeSkill: FrankensteinStage1Skill?
    private var startPosition: SCNVector3 = SCNVector3Zero
    private var startDistanceToGoal: Float = 0
    private var startTime: TimeInterval = 0

    private var collisionObserved = false
    private var airborneDuration: TimeInterval = 0
    private var fallObserved = false

    private let blockedDisplacementThreshold: Float = 0.025
    private let fallGracePeriod: TimeInterval = 0.75

    // Inject the SAME policy instance used by locomotion.
    init(policy: FrankensteinLearningPolicy) {
        self.policy = policy
    }

    // MARK: - Begin Skill

    func begin(
        skill: FrankensteinStage1Skill,
        position: SCNVector3,
        distanceToGoal: Float,
        time: TimeInterval
    ) {
        activeSkill = skill
        startPosition = position
        startDistanceToGoal = distanceToGoal
        startTime = time

        collisionObserved = false
        airborneDuration = 0
        fallObserved = false
    }

    // MARK: - Observe Scene

    func observe(
        position: SCNVector3,
        observation: FrankensteinStage1Observation,
        deltaTime: TimeInterval
    ) {
        guard activeSkill != nil else { return }

        if observation.hasCollision {
            collisionObserved = true
        }

        if !observation.isGrounded {
            airborneDuration += max(0, deltaTime)
        } else {
            airborneDuration = 0
        }

        if airborneDuration >= fallGracePeriod &&
            !observation.hasGroundAhead {
            fallObserved = true
        }
    }

    // MARK: - Finish and Learn

    @discardableResult
    func finish(
        finalPosition: SCNVector3,
        finalDistanceToGoal: Float,
        confirmedFall: Bool,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        time: TimeInterval,
        bonus: Double = 0
    ) -> FrankensteinStage1Outcome? {

        guard let skill = activeSkill else {
            return nil
        }

        // Close the attempt before learning so this outcome cannot
        // accidentally be submitted twice.
        activeSkill = nil

        let elapsed = max(0, time - startTime)

        let dx = finalPosition.x - startPosition.x
        let dy = finalPosition.y - startPosition.y
        let dz = finalPosition.z - startPosition.z

        let actualDisplacement = sqrt(
            dx * dx + dy * dy + dz * dz
        )

        let progress = Double(
            startDistanceToGoal - finalDistanceToGoal
        )

        let blocked =
            collisionObserved &&
            actualDisplacement < blockedDisplacementThreshold

        let fell = confirmedFall || fallObserved

        var reward = 0.0

        // Reward progress toward the goal.
        reward += max(-2.0, min(2.0, progress))

        // Penalize failure and unsafe outcomes.
        if blocked {
            reward -= 1.0
        }

        if fell {
            reward -= 5.0
        }

        // A collision costs something even when he was not fully stopped.
        if collisionObserved && !blocked {
            reward -= 0.3
        }

        // Small bonus for a safe, unblocked attempt.
        if !fell && !blocked {
            reward += 0.25
        }

        // Task result measured by the caller: a jump that really cleared
        // the gap, a roll that really passed under the barrier, and so on.
        reward += bonus

        let outcome = FrankensteinStage1Outcome(
            skill: skill,
            reward: reward,
            progressMade: progress,
            blocked: blocked,
            fell: fell,
            completed: !fell && !blocked,
            duration: elapsed
        )

        lastOutcome = outcome

        // THE MISSING CONNECTION:
        // Send the completed attempt's reward to the existing policy.
        // This must happen once per attempt, not once per frame.
        policy.learn(
            reward: Float(reward),
            terrain: terrain,
            body: body,
            terminal: fell
        )

        return outcome
    }

    // MARK: - Reset

    func reset() {
        activeSkill = nil
        lastOutcome = nil
        collisionObserved = false
        airborneDuration = 0
        fallObserved = false
        startPosition = SCNVector3Zero
        startDistanceToGoal = 0
        startTime = 0
    }
}
