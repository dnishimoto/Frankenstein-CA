import Foundation
import simd

// MARK: - Learner (object / goal Q-values owned by the CA layer)

/// Q-value store keyed by a CA-perceived state string.
///
/// Improvements over a plain one-step table:
/// - per-(state, action) visit counts give a decaying learning rate, so
///   early experience moves values quickly and later experience refines them;
/// - an eligibility trace (Q(lambda)-style) spreads each reward back over
///   the last few state/action pairs, so "turned toward the route" gets
///   credit when the later "walked and got closer" pays off.
import Foundation
import simd

// MARK: - Learner (object / goal Q-values owned by the CA layer)

/// Q-value store keyed by a CA-perceived state string.
///
/// Improvements over a plain one-step table:
/// - per-(state, action) visit counts give a decaying learning rate, so
///   early experience moves values quickly and later experience refines them;
/// - an eligibility trace (Q(lambda)-style) spreads each reward back over
///   the last few state/action pairs, so "turned toward the route" gets
///   credit when the later "walked and got closer" pays off.
final class FrankensteinCALearner {
    private var table: [String: [String: Float]] = [:]
    private var visits: [String: [String: Int]] = [:]

    private struct Trace {
        var key: String
        var action: String
        var weight: Float
    }

    private var traces: [Trace] = []

    let baseLearningRate: Float = 0.30
    let minimumLearningRate: Float = 0.05
    let discountFactor: Float = 0.90
    let traceDecay: Float = 0.60
    let maximumTraces = 6

    var stateCount: Int { table.count }
    
    // Exploration parameters
    var explorationRate: Float = 0.25 // Epsilon or temperature factor for alternative path exploration
    var noveltyBonusScale: Float = 0.5

    func values(for key: String) -> [String: Float] {
        return table[key] ?? [:]
    }

    func visitCount(key: String, action: String) -> Int {
        visits[key]?[action] ?? 0
    }

    func ensure(key: String, actions: [String]) {
        if table[key] == nil {
            table[key] = [:]
            visits[key] = [:]
        }
        for action in actions {
            if table[key]?[action] == nil {
                table[key]?[action] = 0.0
                visits[key]?[action] = 0
            }
        }
    }

    private func learningRate(forVisits count: Int) -> Float {
        return max(minimumLearningRate, baseLearningRate / (1 + 0.15 * Float(count)))
    }

    func reinforce(
        key: String,
        action: String,
        reward: Float,
        nextKey: String? = nil
    ) {
        guard reward.isFinite else { return }
        ensure(key: key, actions: [action])

        let current = table[key]?[action] ?? 0

        var maxNext: Float = 0
        if let nextKey, let nextActions = table[nextKey], !nextActions.isEmpty {
            maxNext = nextActions.values.max() ?? 0
        }

        // Track visit counts for novelty/exploration bonus
        let currentVisits = visits[key]?[action] ?? 0
        visits[key]?[action] = currentVisits + 1

        let noveltyBonus = noveltyBonusScale / sqrt(Float(currentVisits + 1))
        let totalReward = reward + noveltyBonus

        let delta = totalReward + discountFactor * maxNext - current

        // The newest pair always receives full credit.
        traces.removeAll { $0.key == key && $0.action == action }
        traces.append(Trace(key: key, action: action, weight: 1))

        if traces.count > maximumTraces {
            traces.removeFirst(traces.count - maximumTraces)
        }

        for index in traces.indices {
            let trace = traces[index]
            let count = visits[trace.key]?[trace.action] ?? 0
            let alpha = learningRate(forVisits: count)
            let old = table[trace.key]?[trace.action] ?? 0

            table[trace.key, default: [:]][trace.action] = old + alpha * trace.weight * delta

            traces[index].weight *= discountFactor * traceDecay
        }

        traces.removeAll { $0.weight < 0.02 }
    }

    func clearTraces() {
        traces.removeAll()
    }

    func reset() {
        table.removeAll()
        visits.removeAll()
        traces.removeAll()
    }
}



// MARK: - Executive (learning + path control under one CA owner)

final class FrankensteinCAExecutive {
    let learner = FrankensteinCALearner()
    let field = FrankensteinCAPathField()

    func reset() {
        learner.reset()
        field.reset()
    }
}

