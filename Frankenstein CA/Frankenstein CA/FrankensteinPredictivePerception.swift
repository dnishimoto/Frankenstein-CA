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

    func predict(
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

        predictionCount += 1
        return FrankensteinPredictedOutcome(
            actionName: actionName,
            expectedForwardDisplacement: max(0, distance * movementScale),
            collisionRisk: min(1, max(0, collision)),
            fallRisk: min(1, max(0, fall)),
            expectedGoalProgress: max(0, distance * (1 - fall)),
            confidence: min(1, max(0, confidence))
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
