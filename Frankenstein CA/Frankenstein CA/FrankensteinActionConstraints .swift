import Foundation

// MARK: - Action Constraints

/// Which actions are physically sensible in a given situation.
///
/// This used to live inside the Q-policy. It is separate now because the
/// policy only stores and reports values. The locomotion controller asks
/// this type for candidates, hands the candidates and the policy's values to
/// the CA, and the CA decides.
///
/// This is a candidate filter, not a replacement for the real-time safety
/// checks in FrankensteinLocomotion.
enum FrankensteinActionConstraints {

    static func allowedActions(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> [FrankensteinAction] {

        // Recover first if the character has fallen.
        if body.fallen {
            return [.recover, .walk]
        }

        // Do not start a new ground action while airborne.
        if !body.grounded {
            return [.walk]
        }

        var actions: [FrankensteinAction]

        // An obstacle that is still far away is approached first. Stepping or
        // jumping from several meters out would be pointless and unsafe.
        let obstacleAhead = terrain.terrain == .hurdle || terrain.terrain == .raisedStep
        if obstacleAhead, terrain.distance > 0.9 {
            actions = [.walk, .stepForward, .turnLeft, .turnRight, .backward]
            if terrain.objectPickupable, !terrain.carryingObject {
                actions.append(.liftObject)
            }
            if terrain.carryingObject {
                actions.append(contentsOf: [.placeObject, .throwObject])
            }
            return actions
        }

        switch terrain.terrain {

        case .gap:
            // Jump only when the gap is within range and the landing
            // area has been verified as clear.
            if terrain.gapWidth > 0,
               terrain.gapWidth <= 1.8,
               terrain.isLandingAreaClear,
               terrain.hasValidGapEdges {
                actions = [.jump, .turnLeft, .turnRight, .backward]
            } else {
                // Never walk forward into an unverified gap.
                actions = [.turnLeft, .turnRight, .backward]
            }

        case .hurdle:
            if terrain.obstacleHeight > 0,
               terrain.obstacleHeight <= 0.75,
               terrain.isLandingAreaClear {
                actions = [.jump, .stepUp, .turnLeft, .turnRight, .backward]
            } else {
                actions = [.turnLeft, .turnRight, .backward]
            }

        case .lowCeiling:
            actions = [.crouch, .crawl, .roll, .turnLeft, .turnRight, .backward]

        case .raisedStep:
            if terrain.obstacleHeight > 0,
               terrain.obstacleHeight <= 0.45,
               terrain.isGroundAhead {
                actions = [.stepUp, .jump, .turnLeft, .turnRight, .backward]
            } else if terrain.obstacleHeight > 0,
                      terrain.obstacleHeight <= 0.75,
                      terrain.isLandingAreaClear {
                actions = [.jump, .turnLeft, .turnRight, .backward]
            } else {
                actions = [.turnLeft, .turnRight, .backward]
            }

        case .flat, .slope, .uneven:
            actions = [.walk, .run, .stepForward, .roll, .turnLeft, .turnRight, .backward]

        case .unknown:
            // Unknown terrain should not trigger forward movement.
            actions = [.turnLeft, .turnRight, .backward]
        }

        // He can step down when the ground ahead is lower but safe.
        if terrain.isStepDownSafe(), terrain.nextGroundHeight < terrain.groundHeight {
            actions.append(.stepDown)
        }

        // Lifting needs a liftable object within reach and free hands.
        if terrain.objectPickupable, !terrain.carryingObject {
            actions.append(.liftObject)
        }

        // While carrying, he can set the object down or throw it.
        if terrain.carryingObject {
            actions.append(contentsOf: [.placeObject, .throwObject])
        }

        return actions
    }
}
