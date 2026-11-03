//
//  File.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 11/3/26.
//

import Foundation

/// The authoritative supervisor governing Frankie's macro-phases, action overrides, and task safety.
/// The authoritative supervisor governing Frankie's macro-phases and task safety.
final class FrankensteinMissionSupervisor {
    private var revision: UInt64 = 0

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

        // 1. Emergency / Low Power Override
        if powerLevel <= 30.0 || isRecharging {
            let phase: FrankensteinMissionPhase = powerLevel <= 15.0 ? .emergencyRecharge : .recharge
            return FrankensteinMissionDecision(
                phase: phase,
                subGoal: powerLevel <= 15.0 ? "CRITICAL: emergency recharge required" : "recharging power reserves",
                requiresRecharge: true,
                allowsOptionalInteraction: false,
                revision: revision
            )
        }

        // 2. Delivery Phase Override (Carrying letter block)
        if carryingLetter {
            return FrankensteinMissionDecision(
                phase: .deliverLetter,
                subGoal: "carrying letter block to slot",
                requiresRecharge: false,
                allowsOptionalInteraction: false,
                revision: revision
            )
        }

        // 3. Fetch Phase (Unplaced letters remaining)
        if hasUnplacedLetter {
            return FrankensteinMissionDecision(
                phase: .fetchLetter,
                subGoal: "fetching required letter block",
                requiresRecharge: false,
                allowsOptionalInteraction: true,
                revision: revision
            )
        }

        // 4. Dog Interaction Phase
        if dogAvailable || carryingDog {
            return FrankensteinMissionDecision(
                phase: .dogInteraction,
                subGoal: carryingDog ? "giving love to dog" : "approaching dog",
                requiresRecharge: false,
                allowsOptionalInteraction: true,
                revision: revision
            )
        }

        // 5. Default Exploration / Complete
        return FrankensteinMissionDecision(
            phase: hasUnplacedLetter ? .explore : .lettersComplete,
            subGoal: "exploring environment / scanning tasks",
            requiresRecharge: false,
            allowsOptionalInteraction: true,
            revision: revision
        )
    }

    func reset() {
        revision = 0
    }
}
