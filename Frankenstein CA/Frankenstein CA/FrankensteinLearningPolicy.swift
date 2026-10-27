import Foundation

// MARK: - Q-Learning Policy

/// Tabular Q-learning policy for Frankenstein.
///
/// Responsibilities:
/// - Encode the current environment and body state.
/// - Select an allowed action using Q-values and exploration.
/// - Provide learned Q-values to the CA; learn from the CA-selected executed action.
/// - Preserve one pending decision until its outcome is learned.
/// - Learn from the action actually executed.
/// - Expose diagnostics for state diversity and learning progress.
///
/// Environmental safety must also be enforced by FrankensteinLocomotion
/// immediately before an action is executed.
final class FrankensteinLearningPolicy {

    // MARK: - Encoded state

    private struct State: Hashable {
        let terrain: Int
        let distanceBand: Int
        let tiltBand: Int
        let grounded: Bool
    }

    // State -> action ID -> Q-value
    private var values: [State: [Int: Float]] = [:]

    // Pending decision; at most one action may await an outcome.
    private var lastState: State?
    private var lastAction: FrankensteinAction?
    private var pendingAllowedActions: Set<FrankensteinAction> = []
    private var actionPendingLearning = false

    // MARK: - Learning parameters

    var learningRate: Float = 0.12
    var discount: Float = 0.90
    var exploration: Float = 0.20

    /// Legacy compatibility weight for callers that still use choose(preferredAction:).
    /// The executive path uses learnedActionValues and lets the CA make the final choice.
    var caPreferenceWeight: Float = 0.15

    private let minimumExploration: Float = 0.03
    private let explorationDecay: Float = 0.999

    // MARK: - Diagnostics

    private(set) var updateCount: Int = 0
    private(set) var completedActionCount: Int = 0

    var isAwaitingOutcome: Bool {
        actionPendingLearning
    }

    var learnedStateCount: Int {
        values.count
    }

    var pendingAction: FrankensteinAction? {
        guard actionPendingLearning else { return nil }
        return lastAction
    }

    // MARK: - State encoding

    private func makeState(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> State {

        let distance = terrain.distanceAhead
        let distanceBand: Int

        if !distance.isFinite || distance < 0.8 {
            distanceBand = 0
        } else if distance < 2.0 {
            distanceBand = 1
        } else {
            distanceBand = 2
        }

        let tilt = abs(body.tilt)
        let tiltBand: Int

        if !tilt.isFinite || tilt < 0.12 {
            tiltBand = 0
        } else if tilt < 0.35 {
            tiltBand = 1
        } else {
            tiltBand = 2
        }

        return State(
            terrain: terrainIndex(for: terrain.terrain),
            distanceBand: distanceBand,
            tiltBand: tiltBand,
            grounded: body.grounded
        )
    }

    private func terrainIndex(
        for terrain: FrankensteinTerrain
    ) -> Int {
        switch terrain {
        case .flat:
            return 0
        case .hurdle:
            return 1
        case .gap:
            return 2
        case .lowCeiling:
            return 3
        case .raisedStep:
            return 4
        case .slope:
            return 5
        case .uneven:
            return 6
        case .unknown:
            return 7
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

    // MARK: - CA executive-controller interface

    /// Q-values are advice to the CA. This method does not select or execute an action.
    func learnedActionValues(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> [FrankensteinAction: Float] {
        actionValues(terrain: terrain, body: body)
    }

    /// Starts a learning transition for the action the CA actually chose.
    /// The Q-policy records the CA decision, rather than replacing it.
    @discardableResult
    func beginCAChosenAction(
        _ action: FrankensteinAction,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> Bool {
        guard !actionPendingLearning else {
            print("[Q-Learning] Cannot begin CA action: previous action still awaits its outcome.")
            return false
        }
        let state = makeState(terrain: terrain, body: body)
        let allowed = allowedActions(terrain: terrain, body: body)
        guard allowed.contains(action) else {
            print("[Q-Learning] CA action rejected by policy constraints: \(action)")
            return false
        }
        _ = values[state, default: [:]]
        lastState = state
        lastAction = action
        pendingAllowedActions = Set(allowed)
        actionPendingLearning = true
        print("[Q-Learning] Learning target set by CA: \(action)")
        return true
    }

    // MARK: - Action selection

    /// Existing API: preserves compatibility with callers that do
    /// not supply a CA preference.
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

    /// Selects an action using Q-values, exploration, and optional
    /// CA preference. The selected action stays pending until its
    /// outcome has been recorded.
    func choose(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        preferredAction: FrankensteinAction?
    ) -> FrankensteinAction {

        // Never replace a pending decision with a new decision.
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
            // Defensive fallback. The movement controller must
            // still decide whether stopping or recovering is safe.
            let fallback: FrankensteinAction = .walk

            lastState = state
            lastAction = fallback
            pendingAllowedActions = [fallback]
            actionPendingLearning = true

            _ = values[state, default: [:]]

            print("[Q-Learning] Selected fallback: \(fallback)")
            return fallback
        }

        // Create the table entry so a newly encountered state is
        // counted even before its first reward update.
        _ = values[state, default: [:]]

        let selected: FrankensteinAction

        if Double.random(in: 0.0..<1.0) < Double(exploration) {
            // Exploration only considers allowed actions.
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
        pendingAllowedActions = Set(candidates)
        actionPendingLearning = true

        print("[Q-Learning] Selected action: \(selected)")
        print("[Q-Learning] CA preference: \(String(describing: preferredAction))")
        print("[Q-Learning] Terrain ID: \(state.terrain)")
        print("[Q-Learning] Distance band: \(state.distanceBand)")
        print("[Q-Learning] Tilt band: \(state.tiltBand)")
        print("[Q-Learning] Grounded: \(state.grounded)")
        print("[Q-Learning] Distinct states: \(learnedStateCount)")
        print("[Q-Learning] Updates: \(updateCount)")
        print("[Q-Learning] Awaiting outcome: true")

        return selected
    }

    /// Scores an action. The CA provides a small preference bonus;
    /// it cannot add an action that is absent from the allowed set.
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

    // MARK: - Confirm actual execution

    /// Call after the controller has applied its safety checks and
    /// decided which action will actually execute.
    ///
    /// Returns false if there is no pending decision or the executed
    /// action was not in the pending decision's allowed-action set.
    ///
    /// If the controller performs a safety override, that executed
    /// action becomes the action evaluated by the learning update.
    @discardableResult
    func confirmExecutedAction(
        _ executedAction: FrankensteinAction
    ) -> Bool {

        guard actionPendingLearning,
              let selectedAction = lastAction else {
            print("[Q-Learning] Execution confirmation failed: no pending decision.")
            return false
        }

        guard pendingAllowedActions.contains(executedAction) else {
            print("[Q-Learning] Execution confirmation failed: action was not in the allowed set.")
            print("[Q-Learning] Selected: \(selectedAction)")
            print("[Q-Learning] Reported executed: \(executedAction)")
            return false
        }

        if selectedAction != executedAction {
            print("[Q-Learning] Execution override: \(selectedAction) -> \(executedAction)")
        } else {
            print("[Q-Learning] Execution confirmed: \(executedAction)")
        }

        lastAction = executedAction
        return true
    }

    // MARK: - Outcome-based learning

    /// Records one outcome for the pending action.
    ///
    /// Returns false if no action is awaiting an outcome. This guard
    /// prevents repeated frame-loop calls from updating the same
    /// completed action multiple times.
    @discardableResult
    func learn(
        reward: Float,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool = false
    ) -> Bool {

        guard actionPendingLearning,
              let state = lastState,
              let action = lastAction else {
            print("[Q-Learning] Ignored outcome: no pending action.")
            return false
        }

        let oldValue = qValue(
            for: action,
            in: state
        )

        let nextState = makeState(
            terrain: terrain,
            body: body
        )

        let nextValue: Float

        if terminal {
            nextValue = 0
        } else {
            let nextActions = allowedActions(
                terrain: terrain,
                body: body
            )

            nextValue = nextActions
                .map { qValue(for: $0, in: nextState) }
                .max() ?? 0
        }

        // Q-learning update:
        // Q(s,a) <- Q(s,a) + alpha * (target - Q(s,a))
        let target = reward + (terminal ? 0 : discount * nextValue)

        let updatedValue =
            oldValue + learningRate * (target - oldValue)

        setQValue(
            updatedValue,
            for: action,
            in: state
        )

        updateCount += 1
        completedActionCount += 1

        exploration = max(
            minimumExploration,
            exploration * explorationDecay
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

    /// Compatibility API used by the existing locomotion adapter.
  

    /// Use for jump completion instead of also recording the same
    /// jump through the ordinary completion path.
    @discardableResult
    func reportJumpOutcome(
        succeeded: Bool,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        terminal: Bool = false
    ) -> Bool {

        guard actionPendingLearning,
              lastAction == .jump else {
            print("[Q-Learning] Ignored jump outcome: pending action is not jump.")
            return false
        }

        return learn(
            reward: succeeded ? 3.0 : -2.0,
            terrain: terrain,
            body: body,
            terminal: terminal
        )
    }

    private func clearPendingAction() {
        lastState = nil
        lastAction = nil
        pendingAllowedActions.removeAll()
        actionPendingLearning = false
    }

    // MARK: - Diagnostics

    func qValue(
        for action: FrankensteinAction,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> Float {

        let state = makeState(
            terrain: terrain,
            body: body
        )

        return qValue(
            for: action,
            in: state
        )
    }

    func preferredAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> FrankensteinAction? {

        let state = makeState(
            terrain: terrain,
            body: body
        )

        let candidates = allowedActions(
            terrain: terrain,
            body: body
        )

        return candidates.max {
            qValue(for: $0, in: state) <
            qValue(for: $1, in: state)
        }
    }

    func actionValues(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> [FrankensteinAction: Float] {

        let state = makeState(
            terrain: terrain,
            body: body
        )

        var result: [FrankensteinAction: Float] = [:]

        for action in allowedActions(
            terrain: terrain,
            body: body
        ) {
            result[action] = qValue(
                for: action,
                in: state
            )
        }

        return result
    }

    /// Prints the actual encoded state so a stuck state count can
    /// be investigated against the terrain sensor's output.
    func printStateDiagnostics(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) {

        let state = makeState(
            terrain: terrain,
            body: body
        )

        print("[Q State] Terrain ID: \(state.terrain)")
        print("[Q State] Distance band: \(state.distanceBand)")
        print("[Q State] Tilt band: \(state.tiltBand)")
        print("[Q State] Grounded: \(state.grounded)")
        print("[Q State] Distinct states: \(learnedStateCount)")
    }

    // MARK: - Allowed actions

    /// This is a policy-side constraint, not a replacement for
    /// collision checks and real-time safety in the controller.
    func allowedActions(
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

        switch terrain.terrain {

        case .gap:
            // Jump only when the gap is within range and
            // the landing area has been verified as clear.
            if terrain.gapWidth > 0,
               terrain.gapWidth <= 1.8,
               terrain.isLandingAreaClear,
               terrain.gapNearEdgeDistance.isFinite,
               terrain.gapFarEdgeDistance.isFinite,
               terrain.gapNearEdgeDistance >= 0,
               terrain.gapFarEdgeDistance > terrain.gapNearEdgeDistance {

                return [.jump, .turnLeft, .turnRight]
            }

            // Do not walk forward into an unverified gap.
            return [.turnLeft, .turnRight]

        case .hurdle:
            if terrain.obstacleHeight > 0,
               terrain.obstacleHeight <= 0.75,
               terrain.isLandingAreaClear {

                return [.jump, .stepUp, .turnLeft, .turnRight, .walk]
            }

            return [.turnLeft, .turnRight, .walk]

        case .lowCeiling:
            return [.crouch, .turnLeft, .turnRight]

        case .raisedStep:
            if terrain.obstacleHeight > 0,
               terrain.obstacleHeight <= 0.55,
               terrain.isGroundAhead {

                return [.stepUp, .jump, .turnLeft, .turnRight, .walk]
            }

            return [.turnLeft, .turnRight, .walk]

        case .flat, .slope, .uneven:
            return [.walk, .run, .turnLeft, .turnRight]

        case .unknown:
            // Unknown terrain should not trigger forward movement.
            return [.turnLeft, .turnRight]
        }
    }

    // MARK: - Episode reset

    /// Clears the pending transition while preserving learned Q-values.
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
        return choose(
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
        learn(
            reward: reward,
            terrain: terrain,
            body: body,
            terminal: terminal
        )
    }
}
