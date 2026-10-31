//
//  FrankensteinGoal.swift
//  Frankenstein CA
//
//  The goal the CA is pursuing, as an explicit input to planning and to the
//  policy's Q-values: Q(s, a, g). The overall goal survives replanning; only
//
//  FrankensteinGoal.swift
//  Frankenstein CA
//
//  The goal the CA is pursuing, as an explicit input to planning and to the
//  policy's Q-values: Q(s, a, g). The overall goal survives replanning; only
//  the plan for the current sub-goal is thrown away when a sub-goal changes.
//

import Foundation

/// The overall goal plus where he is within it.
struct FrankensteinGoalContext {
    private(set) var goal: FrankensteinGoal
    private(set) var currentSubGoal: String?
    private(set) var completedSubGoals: [String] = []
    private(set) var isComplete = false

    init(goal: FrankensteinGoal = .recharge) {
        self.goal = goal
    }

    /// Transitions to a follow-up plan once recharge is complete.
    mutating func advanceToNextGoal() {
        if isComplete && goal.category == "recharge" {
            // Switch to a new objective after successful recharge
            self.goal = .reachPosition
            self.currentSubGoal = "Explore remaining sectors"
            self.isComplete = false
            self.completedSubGoals.removeAll()
        }
    }

    /// Brings the context in line with the latest perception.
    /// - Returns: a reason when the plan for the old sub-goal must be dropped
    ///   (the overall goal or the sub-goal changed), otherwise nil.
    mutating func observe(
        goal newGoal: FrankensteinGoal,
        subGoal: String?,
        goalReached: Bool
    ) -> String? {
        var reason: String?

        if newGoal != goal {
            reason = "goal changed to \(newGoal.summary)"
            goal = newGoal
            currentSubGoal = nil
            completedSubGoals = []
            isComplete = false
        }

        if subGoal != currentSubGoal {
            if let finished = currentSubGoal, !finished.isEmpty,
               !completedSubGoals.contains(finished) {
                completedSubGoals.append(finished)
            }

            if reason == nil {
                reason = "sub-goal changed to \(subGoal ?? "none")"
            }

            currentSubGoal = subGoal
        }

        if goalReached && !isComplete {
            isComplete = true
        } else if !goalReached && isComplete {
            isComplete = false
        }

        return reason
    }

    var summary: String {
        var text = "Goal: \(goal.summary)"

        if let sub = currentSubGoal, !sub.isEmpty, sub != "none" {
            text += " | sub-goal: \(sub)"
        }

        if isComplete {
            text += " | reached"
        }

        return text
    }
}
