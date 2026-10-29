
import Foundation

final class FrankensteinLearningPolicy {

    // MARK: - Encoded state

    private(set) var updateLog: [FrankensteinQUpdateRecord] = []
    private(set) var updateCount: Int = 0
    private(set) var completedActionCount: Int = 0

    // Retained for compatibility with callers that provide perceived values.
    private var learnedActionValues: [FrankensteinAction: Float] = [:]

    private struct State: Hashable {
        let terrain: Int
        let distanceBand: Int
        let tiltBand: Int
        let grounded: Bool
        let fallen: Bool

        let obstacleHeightBand: Int
        let obstacleDepthBand: Int
        let groundAhead: Bool
        let landingAreaClear: Bool

        let objectCategory: Int
        let objectDistanceBand: Int
        let objectHeightBand: Int
        let objectDepthBand: Int
        let objectPickupable: Bool
        let carryingObject: Bool
    }

    // State -> action ID -> Q-value
    private var values: [State: [Int: Float]] = [:]

    // One pending transition at a time.
    private var lastState: State?
    private var lastAction: FrankensteinAction?
    private var actionPendingLearning = false

    // MARK: - Learning parameters

    var learningRate: Float = 0.12
    var discount: Float = 0.90
    var exploration: Float = 0.20

    /// Used only by the legacy policy-owned action-selection API.
    /// It does not affect the CA's executive decision.
    var caPreferenceWeight: Float = 0.15

    private let minimumExploration: Float = 0.03
    private let explorationDecay: Float = 0.999

    // MARK: - Diagnostics

    var isAwaitingOutcome: Bool {
        actionPendingLearning
    }

    var pendingAction: FrankensteinAction? {
        guard actionPendingLearning else { return nil }
        return lastAction
    }

    var learnedStateCount: Int {
        values.count
    }

    // MARK: - Perceived action values

    /// Retains finite values supplied by an upstream caller.
    /// These values do not overwrite the learned Q-table.
    func updatePerceivedActionValues(
        allowedActions: [FrankensteinAction],
        qValues: [FrankensteinAction: Float]
    ) {
        learnedActionValues.removeAll(keepingCapacity: true)

        for action in Set(allowedActions) {
            guard let value = qValues[action], value.isFinite else {
                continue
            }

            learnedActionValues[action] = value
        }
    }

    // MARK: - State encoding

    private func makeState(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil,
        hasCarriedObject: Bool = false
    ) -> State {

        let distance = terrain.distanceAhead

        let distanceBand: Int
        if !distance.isFinite || distance < 0 {
            distanceBand = 3
        } else if distance < 0.8 {
            distanceBand = 0
        } else if distance < 2.0 {
            distanceBand = 1
        } else {
            distanceBand = 2
        }

        let tilt = abs(body.tilt)

        let tiltBand: Int
        if !tilt.isFinite {
            tiltBand = 3
        } else if tilt < 0.12 {
            tiltBand = 0
        } else if tilt < 0.35 {
            tiltBand = 1
        } else {
            tiltBand = 2
        }

        let obstacleHeight = terrain.obstacleHeight
        let obstacleHeightBand: Int

        if !obstacleHeight.isFinite || obstacleHeight <= 0 {
            obstacleHeightBand = 0
        } else if obstacleHeight < 0.4 {
            obstacleHeightBand = 1
        } else if obstacleHeight < 1.0 {
            obstacleHeightBand = 2
        } else {
            obstacleHeightBand = 3
        }

        let obstacleDepth = terrain.obstacleDepth
        let obstacleDepthBand: Int

        if !obstacleDepth.isFinite || obstacleDepth <= 0 {
            obstacleDepthBand = 0
        } else if obstacleDepth < 0.3 {
            obstacleDepthBand = 1
        } else if obstacleDepth < 1.0 {
            obstacleDepthBand = 2
        } else {
            obstacleDepthBand = 3
        }

        let objectCategory = objectObservation?.categoryIndex ?? 0
        let objectDistance = objectObservation?.distance ?? .infinity

        let objectDistanceBand: Int

        if objectObservation == nil {
            objectDistanceBand = 0
        } else if !objectDistance.isFinite || objectDistance < 0 {
            objectDistanceBand = 4
        } else if objectDistance < 0.8 {
            objectDistanceBand = 1
        } else if objectDistance < 2.0 {
            objectDistanceBand = 2
        } else {
            objectDistanceBand = 3
        }

        let objectHeight = objectObservation?.height ?? 0

        let objectHeightBand: Int
        if objectObservation == nil {
            objectHeightBand = 0
        } else if !objectHeight.isFinite || objectHeight < 0 {
            objectHeightBand = 4
        } else if objectHeight < 0.4 {
            objectHeightBand = 1
        } else if objectHeight < 1.0 {
            objectHeightBand = 2
        } else {
            objectHeightBand = 3
        }

        let objectDepth = objectObservation?.depth ?? 0

        let objectDepthBand: Int
        if objectObservation == nil {
            objectDepthBand = 0
        } else if !objectDepth.isFinite || objectDepth < 0 {
            objectDepthBand = 4
        } else if objectDepth < 0.3 {
            objectDepthBand = 1
        } else if objectDepth < 1.0 {
            objectDepthBand = 2
        } else {
            objectDepthBand = 3
        }

        return State(
            terrain: terrainIndex(for: terrain.terrain),
            distanceBand: distanceBand,
            tiltBand: tiltBand,
            grounded: body.grounded,
            fallen: body.fallen,
            obstacleHeightBand: obstacleHeightBand,
            obstacleDepthBand: obstacleDepthBand,
            groundAhead: terrain.isGroundAhead,
            landingAreaClear: terrain.isLandingAreaClear,
            objectCategory: objectCategory,
            objectDistanceBand: objectDistanceBand,
            objectHeightBand: objectHeightBand,
            objectDepthBand: objectDepthBand,
            objectPickupable: objectObservation?.pickupable ?? false,
            carryingObject: hasCarriedObject
        )
    }

    private func terrainIndex(
        for terrain: FrankensteinTerrain
    ) -> Int {
        switch terrain {
        case .flat:       return 0
        case .hurdle:     return 1
        case .gap:        return 2
        case .lowCeiling: return 3
        case .raisedStep: return 4
        case .slope:      return 5
        case .uneven:     return 6
        case .unknown:    return 7
        }
    }

    // MARK: - Q-table access

    private func qValue(
        for action: FrankensteinAction,
        in state: State
    ) -> Float {
        values[state]?[action.rawValue] ?? 0
    }

    private func setQValue(
        _ value: Float,
        for action: FrankensteinAction,
        in state: State
    ) {
        values[state, default: [:]][action.rawValue] = value
    }

    // MARK: - CA executive interface

    /// Returns learned Q-values for the current observation.
    /// The CA uses these values as advice and selects the action.
    func learnedActionValues(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil,
        hasCarriedObject: Bool = false
    ) -> [FrankensteinAction: Float] {

        actionValues(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: hasCarriedObject
        )
    }

    /// Records the action selected by the CA.
    ///
    /// The CA is the final decision-maker. This method does not
    /// reject an action because it is absent from the policy's
    /// suggested action set.
    ///
    /// Returns false only if a previous transition is still pending.
    @discardableResult
    func beginCAChosenAction(
        _ action: FrankensteinAction,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil,
        hasCarriedObject: Bool = false
    ) -> Bool {

        guard !actionPendingLearning else {
            print(
                "[Q-Learning] Cannot record CA decision: " +
                "previous action still awaits its outcome."
            )
            return false
        }

        let state = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: hasCarriedObject
        )

        _ = values[state, default: [:]]

        lastState = state
        lastAction = action
        actionPendingLearning = true

        print("[Q-Learning] CA selected action: \(action)")
        print("[Q-Learning] Learning state recorded.")
        print("[Q-Learning] Awaiting movement outcome: true")

        return true
    }

    // MARK: - Legacy action selection

    /// Compatibility API for callers that still ask the policy
    /// to choose an action. The CA executive path should not use this
    /// method to replace its own decision.
    func choose(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> FrankensteinAction {
        choose(
            terrain: terrain,
            body: body,
            preferredAction: nil
        )
    }

    func choose(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        preferredAction: FrankensteinAction?
    ) -> FrankensteinAction {

        if actionPendingLearning, let lastAction {
            return lastAction
        }

        let state = makeState(
            terrain: terrain,
            body: body
        )

        let candidates = allowedActions(
            terrain: terrain,
            body: body
        )

        guard !candidates.isEmpty else {
            let fallback: FrankensteinAction = .walk

            lastState = state
            lastAction = fallback
            actionPendingLearning = true

            _ = values[state, default: [:]]

            print("[Q-Learning] Legacy fallback selected: \(fallback)")
            return fallback
        }

        _ = values[state, default: [:]]

        let selected: FrankensteinAction

        if Double.random(in: 0.0..<1.0) < Double(
            min(max(exploration, 0), 1)
        ) {
            selected = candidates.randomElement() ?? .walk
        } else {
            selected = candidates.max { lhs, rhs in
                selectionScore(
                    action: lhs,
                    state: state,
                    preferredAction: preferredAction
                ) < selectionScore(
                    action: rhs,
                    state: state,
                    preferredAction: preferredAction
                )
            } ?? .walk
        }

        lastState = state
        lastAction = selected
        actionPendingLearning = true

        print("[Q-Learning] Legacy policy selected: \(selected)")
        print("[Q-Learning] Distinct states: \(learnedStateCount)")
        print("[Q-Learning] Updates: \(updateCount)")

        return selected
    }

    private func selectionScore(
        action: FrankensteinAction,
        state: State,
        preferredAction: FrankensteinAction?
    ) -> Float {

        let learnedValue = qValue(
            for: action,
            in: state
        )

        guard action == preferredAction else {
            return learnedValue
        }

        return learnedValue + caPreferenceWeight
    }

    // MARK: - Execution feedback

    /// Reports the action that actually executed.
    ///
    /// The CA remains the decision-maker. If the movement controller
    /// applies a safety override, learning records the reported action.
    ///
    /// Safety checks must still be performed by the movement controller.
    @discardableResult
    func confirmExecutedAction(
        _ executedAction: FrankensteinAction
    ) -> Bool {

        guard actionPendingLearning,
              let selectedAction = lastAction else {
            print(
                "[Q-Learning] Execution confirmation failed: " +
                "no pending CA decision."
            )
            return false
        }

        if selectedAction != executedAction {
            print(
                "[Q-Learning] Executed action differs from CA decision: " +
                "\(selectedAction) -> \(executedAction)"
            )
        } else {
            print("[Q-Learning] Execution confirmed: \(executedAction)")
        }

        lastAction = executedAction
        return true
    }

    // MARK: - Outcome-based learning

    /// Applies one Q-learning update to the pending transition.
    @discardableResult
    func learn(
        reward: Float,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool = false,
        objectObservation: FrankensteinObjectObservation? = nil,
        hasCarriedObject: Bool = false
    ) -> Bool {

        guard actionPendingLearning,
              let state = lastState,
              let action = lastAction else {
            print("[Q-Learning] Ignored outcome: no pending action.")
            return false
        }

        guard reward.isFinite,
              learningRate.isFinite,
              discount.isFinite,
              (0.0...1.0).contains(learningRate),
              (0.0...1.0).contains(discount) else {
            print(
                "[Q-Learning] Rejected invalid reward or learning parameters."
            )
            return false
        }

        let oldValue = qValue(
            for: action,
            in: state
        )

        let nextState = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: hasCarriedObject
        )

        let nextValue: Float

        if terminal {
            nextValue = 0
        } else {
            let nextActions = allowedActions(
                terrain: terrain,
                body: body,
                objectObservation: objectObservation,
                hasCarriedObject: hasCarriedObject
            )

            nextValue = nextActions
                .map { qValue(for: $0, in: nextState) }
                .filter(\.isFinite)
                .max() ?? 0
        }

        let target = reward + (terminal ? 0 : discount * nextValue)

        let updatedValue =
            oldValue + learningRate * (target - oldValue)

        guard updatedValue.isFinite else {
            print("[Q-Learning] Rejected non-finite Q-value.")
            return false
        }

        setQValue(
            updatedValue,
            for: action,
            in: state
        )

        updateCount += 1
        completedActionCount += 1

        exploration = max(
            minimumExploration,
            min(max(exploration, 0), 1) * explorationDecay
        )

        print("[Q-Learning] Outcome action: \(action)")
        print("[Q-Learning] Reward: \(reward)")
        print("[Q-Learning] Q-value: \(oldValue) -> \(updatedValue)")
        print("[Q-Learning] Update count: \(updateCount)")
        print("[Q-Learning] Completed actions: \(completedActionCount)")

        clearPendingAction()

        print("[Q-Learning] Awaiting outcome: false")

        return true
    }

    // MARK: - Jump feedback

    @discardableResult
    func reportJumpOutcome(
        succeeded: Bool,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool = false,
        objectObservation: FrankensteinObjectObservation? = nil,
        hasCarriedObject: Bool = false
    ) -> Bool {

        guard actionPendingLearning,
              lastAction == .jump else {
            print(
                "[Q-Learning] Ignored jump outcome: " +
                "pending action is not jump."
            )
            return false
        }

        return learn(
            reward: succeeded ? 3.0 : -2.0,
            terrain: terrain,
            body: body,
            terminal: terminal,
            objectObservation: objectObservation,
            hasCarriedObject: hasCarriedObject
        )
    }

    private func clearPendingAction() {
        lastState = nil
        lastAction = nil
        actionPendingLearning = false
    }

    // MARK: - Diagnostics

    func qValue(
        for action: FrankensteinAction,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil,
        hasCarriedObject: Bool = false
    ) -> Float {

        let state = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: hasCarriedObject
        )

        return qValue(
            for: action,
            in: state
        )
    }

    func preferredAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil,
        hasCarriedObject: Bool = false
    ) -> FrankensteinAction? {

        let state = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: hasCarriedObject
        )

        let candidates = allowedActions(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: hasCarriedObject
        )

        return candidates.max {
            qValue(for: $0, in: state) <
            qValue(for: $1, in: state)
        }
    }

    func actionValues(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil,
        hasCarriedObject: Bool = false
    ) -> [FrankensteinAction: Float] {

        let state = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: hasCarriedObject
        )

        var result: [FrankensteinAction: Float] = [:]

        let candidates = allowedActions(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: hasCarriedObject
        )

        for action in candidates {
            result[action] = qValue(
                for: action,
                in: state
            )
        }

        return result
    }

    func printStateDiagnostics(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil,
        hasCarriedObject: Bool = false
    ) {

        let state = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: hasCarriedObject
        )

        print("[Q State] Terrain ID: \(state.terrain)")
        print("[Q State] Distance band: \(state.distanceBand)")
        print("[Q State] Tilt band: \(state.tiltBand)")
        print("[Q State] Grounded: \(state.grounded)")
        print("[Q State] Fallen: \(state.fallen)")
        print("[Q State] Obstacle height/depth bands: \(state.obstacleHeightBand)/\(state.obstacleDepthBand)")
        print("[Q State] Ground ahead: \(state.groundAhead)")
        print("[Q State] Landing area clear: \(state.landingAreaClear)")
        print("[Q State] Object category: \(state.objectCategory)")
        print("[Q State] Object distance band: \(state.objectDistanceBand)")
        print("[Q State] Object height/depth bands: \(state.objectHeightBand)/\(state.objectDepthBand)")
        print("[Q State] Object pickupable: \(state.objectPickupable)")
        print("[Q State] Carrying object: \(state.carryingObject)")
        print("[Q State] Distinct states: \(learnedStateCount)")
        print("[Q State] Update count: \(updateCount)")
    }

    // MARK: - Suggested actions

    /// This method supplies suggestions to legacy policy callers.
    /// It is NOT the authority for the CA's final decision.
    func allowedActions(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil,
        hasCarriedObject: Bool = false
    ) -> [FrankensteinAction] {

        if body.fallen {
            return [.recover]
        }

        if !body.grounded {
            return [.walk]
        }

        var actions: [FrankensteinAction]

        switch terrain.terrain {
        case .gap:
            if terrain.gapWidth > 0,
               terrain.gapWidth <= 1.8,
               terrain.isLandingAreaClear,
               terrain.gapNearEdgeDistance.isFinite,
               terrain.gapFarEdgeDistance.isFinite,
               terrain.gapNearEdgeDistance >= 0,
               terrain.gapFarEdgeDistance > terrain.gapNearEdgeDistance {
                actions = [.jump, .turnLeft, .turnRight]
            } else {
                actions = [.turnLeft, .turnRight]
            }

        case .hurdle:
            if terrain.obstacleHeight > 0,
               terrain.obstacleHeight <= 0.75,
               terrain.isLandingAreaClear {
                actions = [.jump, .stepUp, .turnLeft, .turnRight, .walk]
            } else {
                actions = [.turnLeft, .turnRight, .walk]
            }

        case .lowCeiling:
            actions = [.crouch, .crawl, .turnLeft, .turnRight]

        case .raisedStep:
            if terrain.obstacleHeight > 0,
               terrain.obstacleHeight <= 0.55,
               terrain.isGroundAhead {
                actions = [.stepUp, .jump, .turnLeft, .turnRight, .walk]
            } else {
                actions = [.turnLeft, .turnRight, .walk]
            }

        case .flat, .slope, .uneven:
            actions = [.walk, .run, .turnLeft, .turnRight]

        case .unknown:
            actions = [.turnLeft, .turnRight, .walk]
        }

        if hasCarriedObject {
            actions.append(contentsOf: [.placeObject, .throwObject])
        } else if let objectObservation,
                  objectObservation.pickupable,
                  objectObservation.distance.isFinite,
                  objectObservation.distance >= 0,
                  objectObservation.distance <= 0.95 {
            actions.append(.liftObject)
        }

        return Array(Set(actions))
    }

    // MARK: - Episode reset

    /// Clears the pending transition but preserves learned Q-values.
    func resetEpisode() {
        clearPendingAction()
    }
}

// MARK: - Policy adapter

protocol FrankensteinStage1PolicyAdapter: AnyObject {

    func chooseAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> FrankensteinAction

    func recordCompletedAction(
        reward: Float,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool
    )
}

// MARK: - Adapter conformance

extension FrankensteinLearningPolicy: FrankensteinStage1PolicyAdapter {

    func chooseAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> FrankensteinAction {
        choose(
            terrain: terrain,
            body: body
        )
    }

    func recordCompletedAction(
        reward: Float,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool
    ) {
        _ = learn(
            reward: reward,
            terrain: terrain,
            body: body,
            terminal: terminal
        )
    }
}
