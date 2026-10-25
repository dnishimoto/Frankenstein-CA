
import Foundation
import SceneKit


final class FrankensteinStage1Learning {

    private(set) var lastOutcome: FrankensteinStage1Outcome?

    private var activeSkill: FrankensteinStage1Skill?
    private var startPosition: SCNVector3 = SCNVector3Zero
    private var startDistanceToGoal: Float = 0
    private var startTime: TimeInterval = 0

    private var collisionObserved = false
    private var airborneDuration: TimeInterval = 0
    private var fallObserved = false

    private let blockedDisplacementThreshold: Float = 0.025
    private let fallGracePeriod: TimeInterval = 0.75

    // Call once when the policy starts a new skill attempt.
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

    // Call from the scene update loop using measured scene observations.
    // This function records evidence; it does not update the Q-table.
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

        // Do not classify an ordinary jump or step as a fall.
        // The caller must also confirm that the character is below
        // the expected playable ground or has entered a fall state.
        if airborneDuration >= fallGracePeriod &&
            !observation.hasGroundAhead {
            fallObserved = true
        }
    }

    // Call exactly once when the skill finishes, fails, or times out.
    // progressMade is positive when distance to the goal decreases.
    @discardableResult
    func finish(
        finalPosition: SCNVector3,
        finalDistanceToGoal: Float,
        confirmedFall: Bool,
        time: TimeInterval
    ) -> FrankensteinStage1Outcome? {

        guard let skill = activeSkill else { return nil }

        let elapsed = max(0, time - startTime)

        let dx = finalPosition.x - startPosition.x
        let dy = finalPosition.y - startPosition.y
        let dz = finalPosition.z - startPosition.z

        let actualDisplacement = sqrt(dx * dx + dy * dy + dz * dz)

        // Goal progress is more informative than raw distance travelled.
        let progress = Double(
            startDistanceToGoal - finalDistanceToGoal
        )

        let blocked =
            collisionObserved &&
            actualDisplacement < blockedDisplacementThreshold

        let fell = confirmedFall || fallObserved

        var reward = 0.0

        // Reward genuine progress toward the goal.
        reward += max(-2.0, min(2.0, progress))

        // Penalize failed attempts and dangerous outcomes.
        if blocked {
            reward -= 1.0
        }

        if fell {
            reward -= 5.0
        }

        // Reward finishing a skill without a fall.
        if !fell && !blocked {
            reward += 0.25
        }

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
        activeSkill = nil

        return outcome
    }

    func reset() {
        activeSkill = nil
        lastOutcome = nil
        collisionObserved = false
        airborneDuration = 0
        fallObserved = false
    }
}

