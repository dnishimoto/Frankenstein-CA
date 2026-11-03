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

        let objectName = terrain.objectName.lowercased()

        let isLetterTarget =
            objectName.contains("letter") ||
            objectName.contains("fblock") ||
            objectName == "f"

        let isTable = objectName == "table"

        let hasObjectDistance =
            terrain.distance.isFinite &&
            terrain.distance >= 0

        let movableObstruction =
            !terrain.carryingObject &&
            !isLetterTarget &&
            hasObjectDistance &&
            (terrain.objectMovable || isTable) &&
            terrain.distance <= 1.8

        // PRIORITY 1:
        // Approach a movable obstruction without jumping onto it.
        if movableObstruction {

            // Approach until the object is within pushing reach.
            if terrain.distance > 1.2 {
                return [
                    .walk,
                    .stepForward,
                    .kickObject,
                    .turnLeft,
                    .turnRight,
                    .backward
                ]
            }

            // The obstruction is now close enough to move.
            // Do not offer jump or stepUp here.
            return [
                .pushObject,
                .kickObject,
                .turnLeft,
                .turnRight,
                .backward
            ]
        }

        var actions: [FrankensteinAction]

        // Approach fixed obstacles before attempting to cross them.
        let obstacleAhead =
            terrain.terrain == .hurdle ||
            terrain.terrain == .raisedStep

        if obstacleAhead, terrain.distance > 0.9 {
            actions = [
                .walk,
                .run,
                .stepForward,
                .turnLeft,
                .turnRight,
                .backward
            ]

            if terrain.objectPickupable,
               !terrain.carryingObject {
                actions.append(.liftObject)
            }

            if terrain.carryingObject {
                actions.append(contentsOf: [
                    .placeObject,
                    .throwObject
                ])
            }

            return actions
        }

        switch terrain.terrain {

        case .gap:
            // If carrying an object/letter block near a gap, mandate backing away safely
            if terrain.carryingObject {
                actions = [
                    .backward,
                    .turnLeft,
                    .turnRight,
                    .recover
                ]
            } else if terrain.gapWidth > 0,
               terrain.gapWidth <= 1.8,
               terrain.isLandingAreaClear,
               terrain.hasValidGapEdges {

                actions = [
                    .jump,
                    .turnLeft,
                    .turnRight,
                    .backward
                ]

            } else {
                actions = [
                    .turnLeft,
                    .turnRight,
                    .backward
                ]
            }

        case .hurdle:

            let canClearOver =
                terrain.obstacleHeight > 0 &&
                terrain.obstacleHeight <= 0.75 &&
                terrain.isLandingAreaClear

            let canJumpOnto =
                terrain.canLandOnObject &&
                terrain.obstacleHeight > 0 &&
                terrain.obstacleHeight <= 1.5

            if canClearOver ||
               canJumpOnto ||
               objectName.contains("recharge") {

                actions = [
                    .jump,
                    .stepUp,
                    .turnLeft,
                    .turnRight,
                    .backward
                ]

            } else {
                actions = [
                    .turnLeft,
                    .turnRight,
                    .backward
                ]
            }

        case .raisedStep:

            if terrain.obstacleHeight > 0,
               terrain.obstacleHeight <= 0.45,
               terrain.isGroundAhead {

                actions = [
                    .stepUp,
                    .jump,
                    .turnLeft,
                    .turnRight,
                    .backward
                ]

            } else if terrain.obstacleHeight > 0,
                      terrain.obstacleHeight <= 1.5,
                      (
                        terrain.isLandingAreaClear ||
                        terrain.canLandOnObject ||
                        objectName.contains("recharge")
                      ) {

                actions = [
                    .jump,
                    .stepUp,
                    .turnLeft,
                    .turnRight,
                    .backward
                ]

            } else {
                actions = [
                    .turnLeft,
                    .turnRight,
                    .backward
                ]
            }

        case .lowCeiling:

            actions = [
                .crouch,
                .crawl,
                .roll,
                .turnLeft,
                .turnRight,
                .backward
            ]

        case .flat, .slope, .uneven:

            actions = [
                .walk,
                .run,
                .stepForward,
                .roll,
                .turnLeft,
                .turnRight,
                .backward
            ]

        case .unknown:

            actions = [
                .turnLeft,
                .turnRight,
                .backward
            ]
        }

        // Add an action only if it is not already present.
        func add(_ extra: [FrankensteinAction]) {
            for action in extra where !actions.contains(action) {
                actions.append(action)
            }
        }

        // Safe step down.
        if terrain.isStepDownSafe(),
           terrain.nextGroundHeight < terrain.groundHeight {
            add([.stepDown])
        }

        // Pickupable objects remain available for collection.
        if terrain.objectPickupable,
           !terrain.carryingObject {

            add([
                .liftObject,
                .walk,
                .run
            ])
        }

        // Carrying objects permits placement or throwing.
        if terrain.carryingObject {

            add([
                .placeObject,
                .throwObject,
                .walk,
                .run
            ])
        }

        return actions
    }
}
