
import Foundation

/// High-level mission phases. These describe *what* Frankenstein is trying
/// to accomplish; they do not prescribe how he moves.


/// Behavior-Tree-like priority supervisor for mission sequencing.
///
/// Priority:
/// 1. Emergency/active recharge
/// 2. Deliver a letter already being carried
/// 3. Fetch the next unplaced letter
/// 4. Optional dog interaction
/// 5. Completed-letter / exploration state
///
/// The supervisor is deliberately not a movement controller. It does not
/// choose walk, turn, jump, push, lift, or place actions. Those remain under
/// FrankensteinCA and FrankensteinLocomotion.
final class FrankensteinMissionSupervisor {
    private(set) var decision: FrankensteinMissionDecision = .initial

    /// Below this percentage, charging preempts all optional mission work.
    private let rechargeThreshold: Float = 30
    /// Once charging begins, stay in the recharge phase until effectively full.
    private let rechargeReleaseThreshold: Float = 99
    private var rechargeLatched = false
    private var revision: UInt64 = 0

    @discardableResult
    func update(
        powerLevel: Float,
        maximumPower: Float,
        isRecharging: Bool,
        carryingLetter: Bool,
        hasUnplacedLetter: Bool,
        dogAvailable: Bool,
        carryingDog: Bool
    ) -> FrankensteinMissionDecision {
        let maximum = max(1, maximumPower)
        let percentage = max(0, min(100, powerLevel / maximum * 100))

        if percentage < rechargeThreshold || isRecharging {
            rechargeLatched = true
        } else if percentage >= rechargeReleaseThreshold {
            rechargeLatched = false
        }

        let nextPhase: FrankensteinMissionPhase
        let nextSubGoal: String
        let requiresRecharge: Bool

        if rechargeLatched {
            if percentage <= 12 {
                nextPhase = .emergencyRecharge
                nextSubGoal = "emergency: reach charging station"
            } else {
                nextPhase = .recharge
                nextSubGoal = isRecharging
                    ? "remain on charging station until full"
                    : "reach charging station"
            }
            requiresRecharge = true
        } else if carryingLetter {
            nextPhase = .deliverLetter
            nextSubGoal = "deliver carried letter to its matching slot"
            requiresRecharge = false
        } else if hasUnplacedLetter {
            nextPhase = .fetchLetter
            nextSubGoal = "retrieve the next letter in word order"
            requiresRecharge = false
        } else if carryingDog || dogAvailable {
            nextPhase = .dogInteraction
            nextSubGoal = carryingDog
                ? "hold dog briefly, then set it down"
                : "optional dog interaction"
            requiresRecharge = false
        } else {
            nextPhase = hasUnplacedLetter ? .fetchLetter : .lettersComplete
            nextSubGoal = hasUnplacedLetter
                ? "retrieve next letter"
                : "all available letters placed"
            requiresRecharge = false
        }

        if nextPhase != decision.phase || nextSubGoal != decision.subGoal {
            revision &+= 1
        }

        decision = FrankensteinMissionDecision(
            phase: nextPhase,
            subGoal: nextSubGoal,
            requiresRecharge: requiresRecharge,
            allowsOptionalInteraction: !requiresRecharge &&
                nextPhase != .deliverLetter &&
                nextPhase != .fetchLetter,
            revision: revision
        )
        return decision
    }

    func reset() {
        rechargeLatched = false
        revision = 0
        decision = .initial
    }
}

