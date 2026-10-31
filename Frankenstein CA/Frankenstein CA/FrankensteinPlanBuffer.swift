//
//  FrankensteinPlanBuffer.swift
//  Frankenstein CA
//
//  The CA's buffered plan for the current sub-goal.
//
//  Each decision the CA first searches action sequences (Q-guided, against
//  the goal), then reconciles this queue with the search:
//
//  - reconcile(...)      keeps the head while it is still permitted and close
//                        to the best first action; otherwise replaces the queue.
//  - overrideHead(...)   the CA's own scoring vetoed the head.
//  - recordExecuted(...) advances the queue only when an action has really
//                        run for an outcome window, and fails the step when
//                        the body was blocked.
//  - invalidate(...)     the goal or sub-goal changed; the old plan is dropped.
//
//  Plain state used from the render thread (not ObservableObject).
//

import Foundation

struct FrankensteinPlanBuffer {

    private(set) var buffer: [PlanStep] = []

    let maxCapacity = 12
    let maxCompletedKept = 3

    private(set) var replanCount = 0
    private(set) var lastReplanReason = "No plan yet"
    private(set) var executedCount = 0

    // MARK: Queries

    var currentStep: PlanStep? {
        buffer.first(where: { !$0.isCompleted && !$0.isFailed })
    }

    var pendingSteps: [PlanStep] {
        buffer.filter { !$0.isCompleted && !$0.isFailed }
    }

    var pendingActions: [FrankensteinAction] {
        pendingSteps.map { $0.action }
    }

    var isEmpty: Bool { currentStep == nil }

    var isFinished: Bool {
        !buffer.isEmpty && buffer.allSatisfy { $0.isCompleted || $0.isFailed }
    }

    // MARK: Compatibility helpers

    mutating func setPlan(_ steps: [PlanStep], reason: String = "new plan") {
        let history = recentHistory()
        buffer = history + steps.prefix(max(0, maxCapacity - history.count))
        replanCount += 1
        lastReplanReason = reason
    }

    mutating func adaptPlan(with newSteps: [PlanStep]) {
        setPlan(newSteps, reason: "adapted plan")
    }

    mutating func insertImmediateStep(_ step: PlanStep) {
        overrideHead(with: step, reason: "immediate step: \(step.action)")
    }

    // MARK: Reconciling with a fresh search

    /// - Parameters:
    ///   - fresh: best sequence from the latest search, head first.
    ///   - headRegret: how much worse the buffered head is than the best
    ///     first action in that search (zero or more).
    ///   - allowed: actions permitted right now.
    ///   - regretMargin: regret up to which the buffered head is kept.
    @discardableResult
    mutating func reconcile(
        fresh: [PlanStep],
        headRegret: Float,
        allowed: [FrankensteinAction],
        regretMargin: Float
    ) -> Bool {
        let history = recentHistory()

        guard !fresh.isEmpty else {
            if let head = currentStep, allowed.contains(head.action) {
                return false
            }
            buffer = history
            return false
        }

        if let head = currentStep, allowed.contains(head.action) {
            if head.action == fresh[0].action {
                let tail = Array(fresh.dropFirst())
                buffer = history + [head] + tail.prefix(max(0, maxCapacity - history.count - 1))
                return false
            }

            if headRegret <= regretMargin {
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
            ? "planned a route to the sub-goal"
            : "replanned: \(previousHead?.action ?? .walk) is no longer permitted"

        setPlan(fresh, reason: reason)
        return previousHead != nil
    }

    /// The CA's scoring chose something other than the buffered head.
    mutating func overrideHead(with step: PlanStep, reason: String) {
        let history = recentHistory()
        var pending = pendingSteps

        if !pending.isEmpty {
            pending.removeFirst()
        }

        buffer = history + [step] + pending.prefix(max(0, maxCapacity - history.count - 1))
        replanCount += 1
        lastReplanReason = reason
    }

    /// `action` has been executed for one outcome window.
    mutating func recordExecuted(action: FrankensteinAction, blocked: Bool) {
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

    mutating func markCurrentStepCompleted() {
        if let index = buffer.firstIndex(where: { !$0.isCompleted && !$0.isFailed }) {
            buffer[index].isCompleted = true
            trimHistory()
        }
    }

    mutating func markCurrentStepFailed() {
        if let index = buffer.firstIndex(where: { !$0.isCompleted && !$0.isFailed }) {
            buffer[index].isFailed = true
            trimHistory()
        }
    }

    /// The goal or sub-goal changed: drop the queue, keep recent history.
    mutating func invalidate(reason: String) {
        buffer = recentHistory()
        replanCount += 1
        lastReplanReason = reason
    }

    mutating func clear() {
        buffer.removeAll()
        replanCount = 0
        executedCount = 0
        lastReplanReason = "No plan yet"
    }

    // MARK: History

    private func recentHistory() -> [PlanStep] {
        Array(buffer.filter { $0.isCompleted }.suffix(maxCompletedKept))
    }

    private mutating func trimHistory() {
        let finished = buffer.filter { $0.isCompleted || $0.isFailed }
        guard finished.count > maxCompletedKept else { return }

        let keep = Set(finished.suffix(maxCompletedKept).map { $0.id })

        buffer.removeAll {
            ($0.isCompleted || $0.isFailed) && !keep.contains($0.id)
        }
    }
}
