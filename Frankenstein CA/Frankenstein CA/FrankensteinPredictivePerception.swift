import Foundation

/// Small online action-outcome model. It is intentionally an estimate, not a
/// physics engine: SceneKit and measured scene feedback remain authoritative.

final class FrankensteinPredictivePerception {
    private(set) var predictionCount = 0
    private(set) var observationCount = 0
    private(set) var meanAbsoluteError: Float = 0

    // Online calibration factor. If the model repeatedly over/under-predicts,
    // adjust expected movement gradually rather than changing physics itself.
    private var movementScale: Float = 1

    /// Learned success rate per object action, updated from real outcomes.
    private var interactionRate: [String: (rate: Float, count: Int)] = [:]

    /// Predicts every permitted action before the CA chooses one.
    func predictAll(
        actions: [FrankensteinAction],
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation?
    ) -> [FrankensteinAction: FrankensteinPredictedOutcome] {
        var result: [FrankensteinAction: FrankensteinPredictedOutcome] = [:]
        for action in actions {
            result[action] = estimate(
                actionName: String(describing: action),
                terrain: terrain,
                body: body,
                objectObservation: objectObservation
            )
        }
        predictionCount += actions.count
        return result
    }

    /// Calibrates object-action predictions from what really happened.
    func observeInteraction(action: FrankensteinAction, succeeded: Bool) {
        let key = String(describing: action)
        let old = interactionRate[key] ?? (rate: 0.5, count: 0)
        let alpha = max(0.1, 1 / Float(old.count + 1))
        interactionRate[key] = (
            rate: old.rate + alpha * ((succeeded ? 1 : 0) - old.rate),
            count: old.count + 1
        )
    }

    func predict(
        actionName: String,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation?
    ) -> FrankensteinPredictedOutcome {
        predictionCount += 1
        return estimate(
            actionName: actionName,
            terrain: terrain,
            body: body,
            objectObservation: objectObservation
        )
    }

    private func estimate(
        actionName: String,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation?
    ) -> FrankensteinPredictedOutcome {
        let action = actionName.lowercased()
        var distance: Float = 0
        var collision: Float = 0.05
        var fall: Float = 0.02
        var confidence: Float = 0.55

        if action.contains("run") {
            distance = 0.12
            confidence = 0.62
        } else if action.contains("walk") {
            distance = 0.055
            confidence = 0.70
        } else if action.contains("jump") {
            distance = 0.065
            confidence = terrain.terrain == .gap ? 0.42 : 0.58
        } else if action.contains("crawl") || action.contains("crouch") {
            distance = 0.025
            confidence = 0.56
        } else if action.contains("stepup") || action.contains("stepdown") {
            distance = 0.025
            confidence = 0.52
        } else if action.contains("turn") || action.contains("recover") {
            distance = 0
            confidence = 0.65
        } else if action.contains("lift") || action.contains("place") || action.contains("throw") {
            distance = 0
            confidence = objectObservation == nil ? 0.25 : 0.5
        }

        if terrain.terrain == .gap {
            collision = 0.10
            fall = terrain.isLandingAreaClear ? 0.35 : 0.85
            if !action.contains("jump") && !action.contains("turn") && !action.contains("recover") {
                distance *= 0.2
            }
        } else if terrain.terrain == .hurdle || terrain.terrain == .raisedStep {
            collision = 0.25
            fall = 0.08
            if !action.contains("jump") && !action.contains("step") && !action.contains("turn") {
                distance *= 0.35
            }
        } else if terrain.terrain == .lowCeiling {
            collision = (action.contains("crawl") || action.contains("crouch")) ? 0.08 : 0.55
            if action.contains("crawl") || action.contains("crouch") { distance *= 0.7 }
        }

        if let object = objectObservation, object.distance < 0.55 {
            if !action.contains("turn") && !action.contains("jump") &&
                !action.contains("crawl") && !action.contains("lift") &&
                !action.contains("place") && !action.contains("throw") {
                collision = min(0.98, collision + 0.35)
                distance *= 0.15
            }
        }
        if body.fallen {
            distance = 0
            fall = 1
            confidence = 0.95
        }

        // MARK: Object interaction and likelihood of failure

        let reach: Float = 1.3
        let name = objectObservation?.name.lowercased() ?? ""
        let objectNear = (objectObservation?.distance ?? .infinity) <= reach
        let volume = (objectObservation?.width ?? 0) *
            (objectObservation?.height ?? 0) *
            (objectObservation?.depth ?? 0)
        let heavy = volume > 0.5
        let movable = terrain.objectMovable || name.contains("crate") ||
            name.contains("movable") || name.contains("box") || name.contains("block")
        let pickupable = objectObservation?.pickupable ?? terrain.objectPickupable
        let carrying = terrain.carryingObject
        let blocking = terrain.terrain == .hurdle || terrain.terrain == .raisedStep ||
            (objectObservation?.distance ?? .infinity) < 0.8

        var success: Float = max(0, 1 - max(collision, fall))
        var clears: Float = 0
        var objectShift: Float = 0

        if action.contains("push") {
            success = (objectNear && movable) ? (heavy ? 0.45 : 0.75) : 0.05
            objectShift = success > 0.1 ? (heavy ? 0.15 : 0.4) : 0
            clears = blocking ? success : success * 0.5
        } else if action.contains("kick") {
            let letter = name.contains("letter")
            success = (objectNear && movable && !letter) ? (heavy ? 0.3 : 0.65) : 0.05
            objectShift = success > 0.1 ? 1.5 : 0
            clears = blocking ? success : 0
        } else if action.contains("lift") {
            let tall = (objectObservation?.height ?? 0) > 0.9
            success = (objectNear && pickupable && !carrying) ? (tall ? 0.3 : 0.85) : 0.05
            clears = blocking ? success : 0
        } else if action.contains("place") {
            success = carrying ? 0.75 : 0.05
        } else if action.contains("throw") {
            success = carrying ? 0.6 : 0.05
            objectShift = carrying ? 2.0 : 0
            clears = carrying && blocking ? 0.3 : 0
        } else if action.contains("jump") {
            if terrain.canLandOnObject {
                success = 0.75
                clears = 0.6
            } else if (terrain.terrain == .hurdle || terrain.terrain == .raisedStep),
                      terrain.obstacleHeight > 0.6 {
                success = 0.15
            }
        } else if distance * movementScale <= 0.01 &&
                    !(action.contains("turn") || action.contains("recover")) {
            // A movement that is expected to go nowhere is expected to fail.
            success = min(success, 0.2)
        }

        // Blend with what actually happened the last few times.
        if let learned = interactionRate[actionName], learned.count >= 3 {
            success = 0.6 * success + 0.4 * learned.rate
        }

        success = min(1, max(0, success))

        return FrankensteinPredictedOutcome(
            actionName: actionName,
            expectedForwardDisplacement: max(0, distance * movementScale),
            collisionRisk: min(1, max(0, collision)),
            fallRisk: min(1, max(0, fall)),
            expectedGoalProgress: max(0, distance * (1 - fall)),
            confidence: min(1, max(0, confidence)),
            successProbability: success,
            failureRisk: 1 - success,
            expectedObjectDisplacement: objectShift,
            clearsObstruction: min(1, max(0, clears))
        )
    }

    /// Returns prediction error (actual - predicted) and calibrates the model.
    @discardableResult
    func observe(
        prediction: FrankensteinPredictedOutcome,
        actualForwardDisplacement: Float,
        terrain: FrankensteinTerrainSample
    ) -> Float {
        guard actualForwardDisplacement.isFinite else { return 0 }
        let actual = max(0, actualForwardDisplacement)
        let error = actual - prediction.expectedForwardDisplacement
        observationCount += 1
        meanAbsoluteError += (abs(error) - meanAbsoluteError) / Float(observationCount)

        // Bounded, slow adaptation avoids letting one noisy raycast dominate.
        if prediction.expectedForwardDisplacement > 0.01 {
            let ratio = min(1.5, max(0.5, actual / prediction.expectedForwardDisplacement))
            movementScale = min(1.5, max(0.5, movementScale * (1 + 0.04 * (ratio - 1))))
        }
        return error
    }
}
