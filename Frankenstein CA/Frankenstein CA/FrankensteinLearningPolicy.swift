
import Foundation

// MARK: - Q-Value Store

/// Tabular Q-learning value store for Frankenstein.
///
/// The policy does NOT choose, filter or rank actions. The CA is the
/// executive controller: it reads values from here, picks an action, and
/// the locomotion controller reports what happened.
///
/// Responsibilities:
/// - Encode the situation into a state key (flat ground, hurdles, gaps,
///   steps and obstacles, each at several distances and sizes).
/// - Return stored Q-values for a state (read only).
/// - Apply one Q-update per completed action, and log it.
final class FrankensteinLearningPolicy {

    // MARK: - Encoded state

    struct State: Hashable, CustomStringConvertible {
        let terrain: Int
        let distanceBand: Int
        let heightBand: Int
        let gapBand: Int
        let landingClear: Bool
        let headingBand: Int
        let tiltBand: Int
        let grounded: Bool
        let objectKind: Int
        let pickupable: Bool
        let carrying: Bool

        var description: String {
            "T\(terrain)|D\(distanceBand)|H\(heightBand)|G\(gapBand)|L\(landingClear ? 1 : 0)|R\(headingBand)|X\(tiltBand)|\(grounded ? "ground" : "air")|O\(objectKind)|P\(pickupable ? 1 : 0)|C\(carrying ? 1 : 0)"
        }
    }

    /// One completed Q-update, kept so tests and logs can inspect learning.
    struct UpdateRecord {
        let state: String
        let action: FrankensteinAction
        let reward: Float
        let nextState: String
        let oldValue: Float
        let newValue: Float
        let terminal: Bool
    }

    // State -> action ID -> Q-value
    private var values: [State: [Int: Float]] = [:]

    // Pending decision; at most one action may await an outcome.
    private var lastState: State?
    private var lastAction: FrankensteinAction?
    private var actionPendingLearning = false

    // MARK: - Learning parameters

    var learningRate: Float = 0.12
    var discount: Float = 0.90

    /// Used by the CA/locomotion layer when it chooses to explore.
    /// The policy itself never explores or selects.
    private(set) var exploration: Float = 0.20

    private let minimumExploration: Float = 0.10
    private let explorationDecay: Float = 0.9995

    // MARK: - Diagnostics

    private(set) var updateCount: Int = 0
    private(set) var completedActionCount: Int = 0
    private(set) var updateLog: [UpdateRecord] = []
    private let maximumLogEntries = 500
    var logsUpdates = true

    var isAwaitingOutcome: Bool { actionPendingLearning }
    var learnedStateCount: Int { values.count }

    var pendingAction: FrankensteinAction? {
        actionPendingLearning ? lastAction : nil
    }

    // MARK: - State encoding

    private func makeState(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> State {

        // Distance: touching / near / mid / far / clear.
        let distance = terrain.distanceAhead
        let distanceBand: Int
        if !distance.isFinite || distance >= 3.0 {
            distanceBand = 4
        } else if distance < 0.5 {
            distanceBand = 0
        } else if distance < 1.0 {
            distanceBand = 1
        } else if distance < 1.8 {
            distanceBand = 2
        } else {
            distanceBand = 3
        }

        // Obstacle height: none / low / step / hurdle / tall.
        let height = terrain.obstacleHeight
        let heightBand: Int
        if !height.isFinite || height <= 0.05 {
            heightBand = 0
        } else if height < 0.20 {
            heightBand = 1
        } else if height < 0.45 {
            heightBand = 2
        } else if height < 0.75 {
            heightBand = 3
        } else {
            heightBand = 4
        }

        // Gap width: none / small / jumpable / too wide.
        let gap = terrain.gapWidth
        let gapBand: Int
        if !gap.isFinite || gap <= 0.05 {
            gapBand = 0
        } else if gap < 0.8 {
            gapBand = 1
        } else if gap <= 1.8 {
            gapBand = 2
        } else {
            gapBand = 3
        }

        // Heading relative to the finish: aligned / left / right.
        let error = body.headingError
        let headingBand: Int
        if !error.isFinite || abs(error) < 0.30 {
            headingBand = 0
        } else if error > 0 {
            headingBand = 1
        } else {
            headingBand = 2
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
            heightBand: heightBand,
            gapBand: gapBand,
            landingClear: terrain.isLandingAreaClear,
            headingBand: headingBand,
            tiltBand: tiltBand,
            grounded: body.grounded,
            objectKind: objectKind(for: terrain.objectName),
            pickupable: terrain.objectPickupable,
            carrying: terrain.carryingObject
        )
    }

    /// Object identity, so `lift` near a pickupable crate and `lift` near an
    /// immovable platform are learned separately.
    private func objectKind(for name: String) -> Int {
        let n = name.lowercased()
        if n.isEmpty { return 0 }
        if n.contains("table") { return 1 }
        if n.contains("door") { return 2 }
        if n.contains("platform") || n.contains("stair") || n.contains("step") { return 3 }
        if n.contains("dog") { return 4 }
        if n.contains("crate") || n.contains("box") { return 5 }
        return 6
    }

    private func terrainIndex(for terrain: FrankensteinTerrain) -> Int {
        switch terrain {
        case .flat: return 0
        case .hurdle: return 1
        case .gap: return 2
        case .lowCeiling: return 3
        case .raisedStep: return 4
        case .slope: return 5
        case .uneven: return 6
        case .unknown: return 7
        }
    }

    /// Readable state key for logs and tests.
    func stateKey(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> String {
        makeState(terrain: terrain, body: body).description
    }

    // MARK: - Q-table access

    private func qValue(for action: FrankensteinAction, in state: State) -> Float {
        values[state]?[action.rawValue] ?? 0
    }

    private func setQValue(_ value: Float, for action: FrankensteinAction, in state: State) {
        values[state, default: [:]][action.rawValue] = value
    }

    // MARK: - Read-only interface for the CA

    /// Stored Q-values for the state. Only actions that have been tried in
    /// this state appear; the CA treats a missing action as 0.
    /// This never selects an action and never changes the table.
    func learnedActionValues(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> [FrankensteinAction: Float] {
        actionValues(terrain: terrain, body: body)
    }

    func actionValues(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> [FrankensteinAction: Float] {
        let state = makeState(terrain: terrain, body: body)
        var result: [FrankensteinAction: Float] = [:]
        for (rawValue, value) in values[state] ?? [:] {
            if let action = FrankensteinAction(rawValue: rawValue) {
                result[action] = value
            }
        }
        return result
    }

    func qValue(
        for action: FrankensteinAction,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> Float {
        qValue(for: action, in: makeState(terrain: terrain, body: body))
    }

    // MARK: - Record the CA's decision

    /// Records the action the CA chose so the outcome can be credited to it.
    /// The policy does not validate or replace the CA's choice.
    @discardableResult
    func beginCAChosenAction(
        _ action: FrankensteinAction,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) -> Bool {
        guard !actionPendingLearning else { return false }

        let state = makeState(terrain: terrain, body: body)
        _ = values[state, default: [:]]   // count the state as visited
        lastState = state
        lastAction = action
        actionPendingLearning = true
        return true
    }

    /// If a safety layer changed the action that really ran, credit that one.
    @discardableResult
    func confirmExecutedAction(_ executedAction: FrankensteinAction) -> Bool {
        guard actionPendingLearning else { return false }
        lastAction = executedAction
        return true
    }

    // MARK: - Outcome-based learning

    /// Applies exactly one Q-update for the pending action, then clears it.
    /// Returns false (and changes nothing) when no action is pending, so
    /// repeated calls from the frame loop cannot update twice.
    ///
    /// `nextActions` are the actions the CA could choose in the next state;
    /// the bootstrap term uses the best of their stored values. Empty means
    /// "use every stored value for that state".
    @discardableResult
    func learn(
        reward: Float,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        nextActions: [FrankensteinAction] = [],
        terminal: Bool = false
    ) -> Bool {

        guard actionPendingLearning,
              let state = lastState,
              let action = lastAction,
              reward.isFinite else {
            return false
        }

        let oldValue = qValue(for: action, in: state)
        let nextState = makeState(terrain: terrain, body: body)

        let nextValue: Float
        if terminal {
            nextValue = 0
        } else if nextActions.isEmpty {
            nextValue = values[nextState]?.values.max() ?? 0
        } else {
            nextValue = nextActions.map { qValue(for: $0, in: nextState) }.max() ?? 0
        }

        // Q(s,a) <- Q(s,a) + alpha * (reward + gamma * max Q(s',a') - Q(s,a))
        let target = reward + (terminal ? 0 : discount * nextValue)
        let newValue = oldValue + learningRate * (target - oldValue)

        setQValue(newValue, for: action, in: state)

        updateCount += 1
        completedActionCount += 1
        exploration = max(minimumExploration, exploration * explorationDecay)

        let record = UpdateRecord(
            state: state.description,
            action: action,
            reward: reward,
            nextState: nextState.description,
            oldValue: oldValue,
            newValue: newValue,
            terminal: terminal
        )
        updateLog.append(record)
        if updateLog.count > maximumLogEntries {
            updateLog.removeFirst(updateLog.count - maximumLogEntries)
        }

        if logsUpdates {
            print(String(
                format: "[Q-Update #%d] state=%@ action=%@ reward=%.3f next=%@ old=%.4f new=%.4f terminal=%@ states=%d",
                updateCount,
                record.state,
                String(describing: action),
                reward,
                record.nextState,
                oldValue,
                newValue,
                terminal ? "yes" : "no",
                learnedStateCount
            ))
        }

        clearPendingAction()
        return true
    }

    /// Jump completion. Only credits a pending jump.
    @discardableResult
    func reportJumpOutcome(
        succeeded: Bool,
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState,
        nextActions: [FrankensteinAction] = [],
        terminal: Bool = false
    ) -> Bool {
        guard actionPendingLearning, lastAction == .jump else { return false }

        return learn(
            reward: succeeded ? 3.0 : -2.0,
            terrain: terrain,
            body: body,
            nextActions: nextActions,
            terminal: terminal
        )
    }

    private func clearPendingAction() {
        lastState = nil
        lastAction = nil
        actionPendingLearning = false
    }

    // MARK: - Diagnostics

    func printStateDiagnostics(
        terrain: FrankensteinTerrainSample,
        body: FrankensteinBodyState
    ) {
        let state = makeState(terrain: terrain, body: body)
        print("[Q State] \(state) | stored=\(values[state] ?? [:]) | states=\(learnedStateCount)")
    }

    // MARK: - Episode reset

    /// Clears the pending transition while preserving learned Q-values.
    func resetEpisode() {
        clearPendingAction()
    }
}
