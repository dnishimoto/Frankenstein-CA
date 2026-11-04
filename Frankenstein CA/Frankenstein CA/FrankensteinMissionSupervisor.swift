//
//  FrankensteinMissionSupervisor.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 11/3/26.
//

import Foundation
import SceneKit

/// Authoritative supervisor governing macro-phases,
/// mission priorities, and task safety.
///
/// The Coordinator supplies plan assessments.
/// The Supervisor decides whether the active mission
/// should continue or change.
/// The Supervisor never selects physical actions.

final class FrankensteinMissionSupervisor {

    // MARK: - State

    private var revision: UInt64 = 0

    private(set) var latestPlanAssessment:
        FrankensteinPlanAssessment?

    private(set) var planBlocked: Bool = false

    private(set) var planFailureReason: String?

    // MARK: - Plan queue
    //
    // The supervisor owns the mission plan queue. The Coordinator provides
    // plans (the spatial target for the phase, and the tactical plans it
    // discovers on the way); the supervisor decides which are accepted, which
    // lapse, and what the mission is doing now. It never selects physical
    // actions.

    private let planQueue = MissionPlanQueue()

    /// Called for each plan event (accepted, rejected, finished, lapsed).
    var onPlanEvent: ((String) -> Void)? {
        get { planQueue.onEvent }
        set { planQueue.onEvent = newValue }
    }

    /// The node the mission is heading for. Tactical plans never change it.
    var goalTarget: SCNNode? { planQueue.anchorTarget }

    /// What is happening now: the top tactical plan, else the mission anchor.
    var activePlanAction: CharacterAction? { planQueue.activeAction }

    var planSummary: String { planQueue.summary }

    /// The Coordinator provides the spatial target for the current phase.
    /// The supervisor maps the phase to the mission anchor.
    func provideMissionTarget(
        _ target: SCNNode?,
        for decision: FrankensteinMissionDecision,
        now: TimeInterval
    ) {
        let action: CharacterAction
        switch decision.phase {
        case .emergencyRecharge, .recharge: action = .recharge
        case .fetchLetter:                  action = .fetchLetter
        case .deliverLetter:                action = .deliverLetter
        case .dogInteraction:               action = .dogInteraction
        case .lettersComplete:              action = .idle
        case .explore:                      action = .explore
        }
        planQueue.setAnchor(action: action, target: target, reason: decision.subGoal)
        planQueue.update(now: now)
    }

    /// The Coordinator offers a tactical plan it discovered on the way.
    /// Accepted only while the mission has something to head for; the
    /// anchor itself is never replaced by it.
    @discardableResult
    func submitTacticalPlan(
        _ action: CharacterAction,
        target: SCNNode? = nil,
        reason: String,
        expiresAt: TimeInterval
    ) -> Bool {
        guard planQueue.anchorTarget != nil else { return false }
        switch action {
        case .stepAroundObstacle, .clearObstacle, .realignHeading:
            planQueue.push(action, target: target, reason: reason, expiresAt: expiresAt)
            return true
        default:
            return false
        }
    }

    /// The Coordinator reports that a tactical plan is done.
    func completeTacticalPlan(_ action: CharacterAction, because why: String = "done") {
        planQueue.finish(action, because: why)
    }

    // MARK: - Mission Update

    func update(
        powerLevel: Float,
        maximumPower: Float,
        isRecharging: Bool,
        carryingLetter: Bool,
        hasUnplacedLetter: Bool,
        dogAvailable: Bool,
        carryingDog: Bool
    ) -> FrankensteinMissionDecision {

        revision += 1

        let safeMaximumPower = max(maximumPower, 0.001)
        let normalizedPower = max(
            0,
            min(100, powerLevel / safeMaximumPower * 100)
        )

        // 1. Emergency recharge always has highest priority.

        if normalizedPower <= 15 || isRecharging {

            let phase: FrankensteinMissionPhase =
                normalizedPower <= 15
                ? .emergencyRecharge
                : .recharge

            return makeDecision(
                phase: phase,
                subGoal: normalizedPower <= 15
                    ? "CRITICAL: emergency recharge required"
                    : "Recharging power reserves",
                requiresRecharge: true,
                allowsOptionalInteraction: false
            )
        }

        // 2. Low power recharge.

        if normalizedPower <= 30 {

            return makeDecision(
                phase: .recharge,
                subGoal: "Recharge power reserves",
                requiresRecharge: true,
                allowsOptionalInteraction: false
            )
        }

        // 3. Deliver any letter already being carried.

        if carryingLetter {

            return makeDecision(
                phase: .deliverLetter,
                subGoal: "Deliver carried letter to matching slot",
                requiresRecharge: false,
                allowsOptionalInteraction: false
            )
        }

        // 4. Complete required letter collection and delivery.

        if hasUnplacedLetter {

            return makeDecision(
                phase: .fetchLetter,
                subGoal: "Find and collect next required letter",
                requiresRecharge: false,
                allowsOptionalInteraction: false
            )
        }

        // 5. Optional dog interaction after required letters.

        if dogAvailable || carryingDog {

            return makeDecision(
                phase: .dogInteraction,
                subGoal: carryingDog
                    ? "Interact with dog"
                    : "Approach dog",
                requiresRecharge: false,
                allowsOptionalInteraction: true
            )
        }

        // 6. All required letters completed.

        return makeDecision(
            phase: .lettersComplete,
            subGoal: "Required letters completed",
            requiresRecharge: false,
            allowsOptionalInteraction: true
        )
    }

    // MARK: - Plan Feedback

    func evaluatePlan(
        _ assessment: FrankensteinPlanAssessment
    ) {

        latestPlanAssessment = assessment

        guard assessment.planIsValid else {

            planBlocked = true
            planFailureReason = "Coordinator generated an invalid plan"

            return
        }

        guard assessment.targetReachable else {

            planBlocked = true
            planFailureReason = "Mission target is unreachable"

            return
        }

        guard assessment.hasSafeRoute else {

            planBlocked = true
            planFailureReason = "No safe route available"

            return
        }

        guard assessment.estimatedEnergyCost >= 0 else {

            planBlocked = true
            planFailureReason = "Invalid estimated energy cost"

            return
        }

        planBlocked = false
        planFailureReason = nil
    }

    // MARK: - Plan Status

    var hasValidPlan: Bool {
        guard let assessment = latestPlanAssessment else {
            return false
        }

        return assessment.planIsValid &&
               assessment.targetReachable &&
               assessment.hasSafeRoute &&
               !planBlocked
    }

    // MARK: - Decision Creation

    private func makeDecision(
        phase: FrankensteinMissionPhase,
        subGoal: String,
        requiresRecharge: Bool,
        allowsOptionalInteraction: Bool
    ) -> FrankensteinMissionDecision {

        return FrankensteinMissionDecision(
            phase: phase,
            subGoal: subGoal,
            requiresRecharge: requiresRecharge,
            allowsOptionalInteraction: allowsOptionalInteraction,
            revision: revision
        )
    }

    // MARK: - Reset

    func reset() {

        revision = 0

        latestPlanAssessment = nil

        planBlocked = false
        planFailureReason = nil
    }
}
