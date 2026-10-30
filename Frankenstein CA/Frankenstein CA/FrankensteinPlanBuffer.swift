
import Foundation
import SwiftUI
import Combine

//
//  FrankensteinPlanBuffer.swift
//  Frankenstein CA
//
//  The CA's buffered plan toward the goal.
//
//  Each decision the CA searches short action sequences against the routed
//  path. The best sequence is kept here as a queue of upcoming actions, so
//  the CA commits to a plan instead of choosing from scratch every frame.
//  The queue is changed as he goes:
//
//  - reconcile(...)  refreshes the queue from the latest search. The head is
//                    kept while it is still permitted and still close to the
//                    best choice; otherwise the whole queue is replaced.
//  - recordExecuted  advances the queue when the CA's action has really been
//                    executed for an outcome window (about 4 per second), and
//                    marks the step failed when the body was blocked.
//
//  This is plain state used from the render thread. It is deliberately not an
//  ObservableObject: nothing in the UI observes it, and publishing from the
//  render thread is not allowed.
//

import Foundation

final class FrankensteinPlanBuffer {

    private(set) var buffer: [PlanStep] = []

    /// Upper bound on stored steps (recent history plus the queue).
    let maxCapacity = 12

    /// How many finished steps are kept for display.
    let maxCompletedKept = 3

    private(set) var replanCount = 0
    private(set) var lastReplanReason = "No plan yet"
    private(set) var executedCount = 0

    // MARK: Queries

    var currentStep: PlanStep? {
        buffer.first(where: { !$0.isCompleted && !$0.isFailed })
    }

    /// Steps still to execute, head first.
    var pendingSteps: [PlanStep] {
        buffer.filter { !$0.isCompleted && !$0.isFailed }
    }

    var pendingActions: [FrankensteinAction] {
        pendingSteps.map { $0.action }
    }

    var isEmpty: Bool {
        currentStep == nil
    }

    func adaptPlan(with newSteps: [PlanStep]) {
        let completedSteps = buffer.filter { $0.isCompleted }
        buffer = completedSteps + newSteps.prefix(maxCapacity - completedSteps.count)
    }

    /// Replaces the queue with a new plan. Recent history is kept.
    func setPlan(_ steps: [PlanStep], reason: String = "new plan") {
        let history = recentHistory()

        buffer = history + steps.prefix(max(0, maxCapacity - history.count))
        replanCount += 1
        lastReplanReason = reason
    }

    /// Brings the queue in line with a freshly searched sequence.
    ///
    /// - Parameters:
    ///   - fresh: the best sequence from the CA's latest search, head first.
    ///   - headRegret: how much worse the buffered head is than the best
    ///     first action in that search (zero or more, same units as the
    ///     search values).
    ///   - allowed: actions permitted right now.
    ///   - regretMargin: regret up to which the buffered head is kept.
    /// - Returns: true when the buffered head was replaced.
    @discardableResult
    func reconcile(
        fresh: [PlanStep],
        headRegret: Float,
        allowed: [FrankensteinAction],
        regretMargin: Float
    ) -> Bool {
        let history = recentHistory()

        guard !fresh.isEmpty else {
            // Nothing to search with (no route, or at the goal). Keep what
            // is already queued while it is permitted.
            if let head = currentStep, allowed.contains(head.action) {
                return false
            }

            buffer = history
            return false
        }

        if let head = currentStep, allowed.contains(head.action) {
            if head.action == fresh[0].action {
                // Same intention: keep the head, refresh everything after it.
                let tail = Array(fresh.dropFirst())

                buffer = history + [head] + tail.prefix(max(0, maxCapacity - history.count - 1))
                return false
            }

            if headRegret <= regretMargin {
                // A different first action scores slightly better, but not
                // enough to abandon the plan. Keep the head; the tail is
                // taken from the new search.
                buffer = history + [head] + fresh.prefix(max(0, maxCapacity - history.count - 1))
                return false
            }

            setPlan(
                fresh,
                reason: "replanned: \(fresh[0].action) beats \(head.action) by \(String(format: "%.2f", Double(headRegret)))"
            )
            return true
        }

        let previousHead = currentStep

        let reason = previousHead == nil
            ? "planned a new route"
            : "replanned: \(previousHead?.action ?? .walk) is no longer permitted"

        setPlan(fresh, reason: reason)
        return previousHead != nil
    }

    /// The CA's scoring chose something other than the buffered head (for
    /// safety, learned values or being stuck). The queue now starts with what
    /// he will actually do.
    func overrideHead(with step: PlanStep, reason: String) {
        let history = recentHistory()
        var pending = pendingSteps

        if !pending.isEmpty {
            pending.removeFirst()
        }

        buffer = history + [step] + pending.prefix(max(0, maxCapacity - history.count - 1))
        replanCount += 1
        lastReplanReason = reason
    }

    /// Called when `action` has been executed for one outcome window.
    func recordExecuted(action: FrankensteinAction, blocked: Bool) {
        guard let index = buffer.firstIndex(where: { !$0.isCompleted && !$0.isFailed }),
              buffer[index].action == action else {
            return
        }

        executedCount += 1

        if blocked {
            buffer[index].isFailed = true
            lastReplanReason = "blocked while trying to \(action)"
        } else {
            buffer[index].isCompleted = true
        }

        trimHistory()
    }

    func markCurrentStepCompleted() {
        if let index = buffer.firstIndex(where: { !$0.isCompleted && !$0.isFailed }) {
            buffer[index].isCompleted = true
            trimHistory()
        }
    }

    func markCurrentStepFailed() {
        if let index = buffer.firstIndex(where: { !$0.isCompleted && !$0.isFailed }) {
            buffer[index].isFailed = true
            trimHistory()
        }
    }

    /// Drops the queue because the situation changed (for example a new
    /// sub-goal), keeping recent history for display.
    func invalidate(reason: String) {
        buffer = recentHistory()
        replanCount += 1
        lastReplanReason = reason
    }

    func clear() {
        buffer.removeAll()
        replanCount = 0
        executedCount = 0
        lastReplanReason = "No plan yet"
    }

    // MARK: History

    private func recentHistory() -> [PlanStep] {
        Array(
            buffer
                .filter { $0.isCompleted }
                .suffix(maxCompletedKept)
        )
    }

    private func trimHistory() {
        let finished = buffer.filter { $0.isCompleted || $0.isFailed }

        guard finished.count > maxCompletedKept else { return }

        let keep = Set(finished.suffix(maxCompletedKept).map { $0.id })

        buffer.removeAll {
            ($0.isCompleted || $0.isFailed) && !keep.contains($0.id)
        }
    }
}
