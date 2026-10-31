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
    
    private(set) var learnedPerceivedActionValues:
        [FrankensteinAction: Float] = [:]

    init(loadSavedLearning: Bool = true) {
        if loadSavedLearning {
            _ = loadLearning()
        }
    }

    // MARK: - Encoded state

    private struct State: Hashable, Codable {
        let terrain: Int
        let distanceBand: Int
        let tiltBand: Int
        let grounded: Bool
        let objectCategory: Int
        let objectDistanceBand: Int
        let objectHeightBand: Int
        let objectDepthBand: Int
        let objectPickupable: Bool

        /// The goal category g in Q(s, a, g).
        let goal: String
    }

    /// The goal the CA is pursuing now (see FrankensteinGoal.category). Part
    /// of every state, so learned values are conditioned on the goal. Set by
    /// the Coordinator each frame from the CA's goal context.
    var currentGoalCategory = "recharge"

    // State -> action ID -> Q-value
    private var values: [State: [Int: Float]] = [:]

    // MARK: - Dirty Q-values (field of vision)
    //
    // Whatever Frankenstein can see in his field of vision (the terrain and
    // object state ahead of him, and every object seen) has its Q-values
    // marked dirty. A learning update may only change a dirty Q-value; the
    // update for a Q-value that is not dirty is skipped, so the table the CA
    // reads only changes where he has actually been looking. A mark expires
    // after `dirtyLifetime` seconds if it is not seen again, and is cleared
    // once its value has been updated.

    private struct QKey: Hashable {
        let state: State
        let action: Int
    }

    private var dirtyKeys: [QKey: TimeInterval] = [:]

    /// Simulation time, set by the Coordinator every frame.
    var visionTime: TimeInterval = 0

    /// How long a dirty mark survives without being seen again.
    var dirtyLifetime: TimeInterval = 0.5

    /// Learning updates skipped because their Q-value was not dirty.
    private(set) var skippedCleanCount = 0

    var dirtyCount: Int { dirtyKeys.count }


    /// Marks the Q-values for every object in his field of vision as dirty
    /// (the terrain ahead is shared; each object gives its own state).
    func markVisibleDirty(
        objects: [FrankensteinObjectObservation],
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) {
        for object in objects {
            markVisibleDirty(
                terrain: terrain,
                body: body,
                objectObservation: object
            )
        }
    }

    /// Updated to produce a FrankensteinQDisplayCell per visible object,
    /// reporting the object's name and the highest learned Q-value over all actions for its state.
    /// Reading this does not mark anything dirty.
    func qDisplaySnapshot(
        objectsInView: [FrankensteinObjectObservation],
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> [FrankensteinQDisplayCell] {

        // Dictionary to track highest Q-value per unique object name with unique ID
        // (assuming object name and unique id concatenated forms unique id)
        var bestQValuesByObjectID: [String: (name: String, value: Float, dirty: Bool)] = [:]

        for object in objectsInView {
            let state = makeState(
                terrain: terrain,
                body: body,
                objectObservation: object
            )
            // Find highest Q-value over all actions in that state
            let bestValue = values[state]?.values.max() ?? 0

            // Dirty when any Q-value of this state is in his field of vision.
            let isDirty = FrankensteinAction.allCases.contains {
                dirtyKeys[QKey(state: state, action: $0.rawValue)] != nil
            }

            // Use object's unique identifier as id; if none available use name
            // Since FrankensteinObjectObservation has name, but no explicit id,
            // we use name plus distance plus height plus depth as compound id to distinguish objects

            // Compose a unique id string for object
            let objectID = "\(object.name)-d\(object.distance)-h\(object.height)-dep\(object.depth)"

            if let currentBest = bestQValuesByObjectID[objectID] {
                if bestValue > currentBest.value {
                    bestQValuesByObjectID[objectID] = (object.name, bestValue, isDirty || currentBest.dirty)
                }
            } else {
                bestQValuesByObjectID[objectID] = (object.name, bestValue, isDirty)
            }
        }

        // Map best Q-values to FrankensteinQDisplayCell array
        return bestQValuesByObjectID.map { id, info in
            FrankensteinQDisplayCell(
                objectName: info.name,
                value: info.value,
                id: id,
                isDirty: info.dirty
            )
        }
    }

    private func expireDirtyKeys() {
        let cutoff = visionTime - dirtyLifetime
        let pending: QKey? = actionPendingLearning
            ? lastState.flatMap { state in
                lastAction.map { QKey(state: state, action: $0.rawValue) }
            }
            : nil

        dirtyKeys = dirtyKeys.filter { $0.value >= cutoff || $0.key == pending }
    }

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
    private let persistenceKey = "FrankensteinLearningPolicy.QTable.v3.goal"

    // MARK: - Diagnostics

    private(set) var updateCount: Int = 0
    private(set) var completedActionCount: Int = 0
    private(set) var qUpdateRecords: [FrankensteinQUpdateRecord] = []

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

    /// A compact status string for the Coordinator UI/debug panel.
    var updateLog: String {
        "Q updates: \(updateCount) | dirty: \(dirtyCount) | skipped clean: \(skippedCleanCount) | states: \(learnedStateCount) | completed: \(completedActionCount) | ε: \(String(format: "%.3f", exploration)) | pending: \(pendingAction.map(String.init(describing:)) ?? "none")"
    }

    // MARK: - State encoding

    private func makeState(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil
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

        let objectCategory = objectObservation?.categoryIndex ?? 0
        let objectDistance = objectObservation?.distance ?? .infinity
        let objectDistanceBand: Int
        if objectObservation == nil {
            objectDistanceBand = 0
        } else if !objectDistance.isFinite || objectDistance < 0.8 {
            objectDistanceBand = 1
        } else if objectDistance < 2.0 {
            objectDistanceBand = 2
        } else {
            objectDistanceBand = 3
        }

        let objectHeight = objectObservation?.height ?? 0
        let objectHeightBand = objectObservation == nil ? 0 :
            (objectHeight < 0.4 ? 1 : (objectHeight < 1.0 ? 2 : 3))
        let objectDepth = objectObservation?.depth ?? 0
        let objectDepthBand = objectObservation == nil ? 0 :
            (objectDepth < 0.3 ? 1 : (objectDepth < 1.0 ? 2 : 3))

        return State(
            terrain: terrainIndex(for: terrain.terrain),
            distanceBand: distanceBand,
            tiltBand: tiltBand,
            grounded: body.grounded,
            objectCategory: objectCategory,
            objectDistanceBand: objectDistanceBand,
            objectHeightBand: objectHeightBand,
            objectDepthBand: objectDepthBand,
            objectPickupable: objectObservation?.pickupable ?? false,
            goal: currentGoalCategory
        )
    }
    func updatePerceivedActionValues(
        allowedActions: [FrankensteinAction],
        qValues: [FrankensteinAction: Float]
    ) {
        var updatedValues: [FrankensteinAction: Float] = [:]

        for action in Set(allowedActions) {
            guard let value = qValues[action],
                  value.isFinite else {
                continue
            }

            updatedValues[action] = value
        }

        learnedPerceivedActionValues = updatedValues
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

    /// Marks the Q-values of the state he sees right now as dirty.
    func markVisibleDirty(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil
    ) {
        let state = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation
        )

        // Every action's Q-value for a state he sees is marked dirty, not
        // only the permitted ones, so the grid shows exactly what is in view.
        for action in FrankensteinAction.allCases {
            dirtyKeys[QKey(state: state, action: action.rawValue)] = visionTime
        }

        expireDirtyKeys()
    }
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
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil
    ) -> [FrankensteinAction: Float] {
        // Reading the values for what he sees marks them dirty.
        markVisibleDirty(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation
        )

        return actionValues(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation
        )
    }

    /// Starts a learning transition for the action the CA actually chose.
    /// The Q-policy records the CA decision, rather than replacing it.
    @discardableResult
    func beginCAChosenAction(
        _ action: FrankensteinAction,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil,
        hasCarriedObject: Bool = false
    ) -> Bool {
        guard !actionPendingLearning else {
            print("[Q-Learning] Cannot begin CA action: previous action still awaits its outcome.")
            return false
        }
        let state = makeState(terrain: terrain, body: body, objectObservation: objectObservation)
        let allowed = allowedActions(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: hasCarriedObject
        )
        guard allowed.contains(action) else {
            print("[Q-Learning] CA action rejected by policy constraints: \(action)")
            return false
        }
        _ = values[state, default: [:]]
        dirtyKeys[QKey(state: state, action: action.rawValue)] = visionTime
        lastState = state
        lastAction = action
        pendingAllowedActions = Set(allowed)
        actionPendingLearning = true
        print("[Q-Learning] Learning target set by CA: \(action)")
        return true
    }

    /// Object-aware constraints used by the CA executive. A push is permitted
    /// only for a named movable block in front, at a reachable distance, while
    /// grounded and not carrying another object. This makes pushObject a real
    /// candidate rather than an enum case the executive can never select.
    func allowedActions(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation?,
        hasCarriedObject: Bool = false
    ) -> [FrankensteinAction] {
        var actions = allowedActions(terrain: terrain, body: body)

        guard !body.fallen,
              body.grounded,
              !hasCarriedObject,
              let object = objectObservation,
              isMovableObjectName(object.name),
              object.distance.isFinite,
              object.distance >= 0.12,
              object.distance <= 1.0,
              terrain.objectMovable else {
            return actions
        }

        if !actions.contains(.pushObject) {
            actions.append(.pushObject)
        }
        return actions
    }

    private func isMovableObjectName(_ name: String) -> Bool {
        let value = name.lowercased()
        return value.contains("movable") ||
            value.contains("block") ||
            value.contains("crate") ||
            value.contains("box") ||
            value.contains("pickup")
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
            preferredAction: nil,
            objectObservation: nil
        )
    }

    /// Object-aware overload for callers with fresh raycast perception.
    func choose(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation?
    ) -> FrankensteinAction {
        choose(
            terrain: terrain,
            body: body,
            preferredAction: nil,
            objectObservation: objectObservation
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
        choose(
            terrain: terrain,
            body: body,
            preferredAction: preferredAction,
            objectObservation: nil
        )
    }

    func choose(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        preferredAction: FrankensteinAction?,
        objectObservation: FrankensteinObjectObservation?
    ) -> FrankensteinAction {

        // Never replace a pending decision with a new decision.
        if actionPendingLearning, let lastAction {
            return lastAction
        }

        let state = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation
        )

        let candidates = allowedActions(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: false
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

        // The caller must invoke this only AFTER its live safety checks.
        // An override may legitimately be outside the policy's original
        // candidate set; attribute learning to the action actually executed.
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
        terminal: Bool = false,
        objectObservation: FrankensteinObjectObservation? = nil
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
            body: body,
            objectObservation: objectObservation
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

        // Only a dirty Q-value (seen in his field of vision) may change.
        let key = QKey(state: state, action: action.rawValue)

        guard dirtyKeys[key] != nil else {
            skippedCleanCount += 1
            print("[Q-Learning] Skipped update: Q-value for \(action) is not dirty (not in view).")
            clearPendingAction()
            return true
        }

        dirtyKeys[key] = nil

        setQValue(
            updatedValue,
            for: action,
            in: state
        )

        updateCount += 1
        completedActionCount += 1
        qUpdateRecords.append(
            FrankensteinQUpdateRecord(
                action: action,
                newValue: updatedValue
            )
        )

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
        saveLearning()

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
        terminal: Bool = false,
        objectObservation: FrankensteinObjectObservation? = nil
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
            terminal: terminal,
            objectObservation: objectObservation
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
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil
    ) -> Float {

        let state = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation
        )

        return qValue(
            for: action,
            in: state
        )
    }

    func preferredAction(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil
    ) -> FrankensteinAction? {

        let state = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation
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
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil
    ) -> [FrankensteinAction: Float] {

        let state = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation
        )

        var result: [FrankensteinAction: Float] = [:]

        for action in allowedActions(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation,
            hasCarriedObject: false
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
        body: FrankensteinBodyState,
        objectObservation: FrankensteinObjectObservation? = nil
    ) {

        let state = makeState(
            terrain: terrain,
            body: body,
            objectObservation: objectObservation
        )

        print("[Q State] Terrain ID: \(state.terrain)")
        print("[Q State] Distance band: \(state.distanceBand)")
        print("[Q State] Tilt band: \(state.tiltBand)")
        print("[Q State] Grounded: \(state.grounded)")
        print("[Q State] Object category: \(state.objectCategory)")
        print("[Q State] Object distance band: \(state.objectDistanceBand)")
        print("[Q State] Object height/depth bands: \(state.objectHeightBand)/\(state.objectDepthBand)")
        print("[Q State] Object pickupable: \(state.objectPickupable)")
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
            // A recognized movable block is also a valid stepping surface
            // when its measured height is jumpable and its top is clear.
            if terrain.objectMovable,
               terrain.canLandOnObject,
               terrain.obstacleHeight > 0,
               terrain.obstacleHeight <= 1.0 {
                return [.jump, .stepUp, .turnLeft, .turnRight, .walk]
            }

            if terrain.obstacleHeight > 0,
               terrain.obstacleHeight <= 0.75,
               terrain.isLandingAreaClear {
                return [.jump, .stepUp, .turnLeft, .turnRight, .walk]
            }

            return [.turnLeft, .turnRight, .walk]

        case .lowCeiling:
            return [.crouch, .turnLeft, .turnRight]

        case .raisedStep:
            if terrain.objectMovable,
               terrain.canLandOnObject,
               terrain.obstacleHeight > 0,
               terrain.obstacleHeight <= 1.0 {
                return [.jump, .stepUp, .turnLeft, .turnRight, .walk]
            }

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

    // MARK: - Persistence

    private struct PersistedLearning: Codable {
        var values: [State: [Int: Float]]
        var updateCount: Int
        var completedActionCount: Int
        var exploration: Float
    }

    /// Saves learned values and counters. Pending transitions are never persisted.
    func saveLearning() {
        let snapshot = PersistedLearning(
            values: values,
            updateCount: updateCount,
            completedActionCount: completedActionCount,
            exploration: exploration
        )
        guard let data = try? JSONEncoder().encode(snapshot) else {
            print("[Q-Learning] Could not encode learning snapshot.")
            return
        }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    /// Loads prior experience once during initialization or when explicitly requested.
    @discardableResult
    func loadLearning() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let snapshot = try? JSONDecoder().decode(PersistedLearning.self, from: data) else {
            return false
        }
        values = snapshot.values
        updateCount = snapshot.updateCount
        completedActionCount = snapshot.completedActionCount
        exploration = min(1, max(minimumExploration, snapshot.exploration))
        clearPendingAction()
        print("[Q-Learning] Restored \(learnedStateCount) states and \(updateCount) updates.")
        return true
    }

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
