// QPolicy.swift

import Foundation

/// A policy that provides Q-values for state-action pairs.
/// This policy does not select or execute actions.
class QPolicy {

    // Dictionary storing Q-values for state-action pairs
    private var qValues: [StateActionPair: Double]

    init(initialValues: [StateActionPair: Double] = [:]) {
        self.qValues = initialValues
    }

    /// Returns the Q-value for the given state-action pair.
    /// If no value is found, returns 0.0.
    func qValue(for stateAction: StateActionPair) -> Double {
        return qValues[stateAction] ?? 0.0
    }

    /// Sets the Q-value for the given state-action pair.
    func setQValue(_ value: Double, for stateAction: StateActionPair) {
        qValues[stateAction] = value
    }

    /// Returns the maximum Q-value for the given state across all actions.
    func maxQValue(for state: State) -> Double {
        let values = qValues.filter { $0.key.state == state }.map { $0.value }
        return values.max() ?? 0.0
    }
}

// Supporting types
struct StateActionPair: Hashable {
    let state: State
    let action: Action
}

struct State: Hashable {
    let id: Int
}

struct Action: Hashable {
    let id: Int
}
