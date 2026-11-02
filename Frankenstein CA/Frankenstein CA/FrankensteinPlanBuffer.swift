
//
//  FrankensteinPlanBuffer.swift
//  Frankenstein CA
//
//  The CA's buffered plan for the current sub-goal.
//
//  Responsibilities:
//  - Retain a useful sequence of planned actions.
//  - Reconcile an existing plan with a fresh CA search.
//  - Allow the CA to override the current action.
//  - Advance the plan only after an action has executed.
//  - Mark blocked actions as failed.
//  - Preserve a short history of completed and failed steps.
//
//  Plain state used from the render thread.
//

import Foundation

struct FrankensteinPlanBuffer {

    // MARK: - Storage

    private(set) var buffer: [PlanStep] = []

    let maxCapacity = 12
    let maxCompletedKept = 3

    private(set) var replanCount = 0
    private(set) var lastReplanReason = "No plan yet"
    private(set) var executedCount = 0

    // MARK: - Queries

    var currentStep: PlanStep? {
        buffer.first(where: {
            !$0.isCompleted && !$0.isFailed
        })
    }

    var pendingSteps: [PlanStep] {
        buffer.filter {
            !$0.isCompleted && !$0.isFailed
        }
    }

    var pendingActions: [FrankensteinAction] {
        pendingSteps.map { $0.action }
    }

    var isEmpty: Bool {
        pendingSteps.isEmpty
    }

    var isFinished: Bool {
        !buffer.isEmpty && pendingSteps.isEmpty
    }

    // MARK: - Set Plan

    mutating func setPlan(
        _ steps: [PlanStep],
        reason: String = "new plan"
    ) {
        let history = buffer.filter {
            $0.isCompleted || $0.isFailed
        }

        buffer = history + Array(steps.prefix(maxCapacity))
        trimHistory()

        replanCount += 1
        lastReplanReason = reason
    }

    // MARK: - Adapt Existing Plan

    mutating func adaptPlan(
        with actions: [FrankensteinAction]
    ) {
        guard !actions.isEmpty else {
            return
        }

        let history = buffer.filter {
            $0.isCompleted || $0.isFailed
        }

        let newSteps = actions.prefix(maxCapacity).map {
            PlanStep(
                action: $0,
                description: "Adapted plan: \($0)"
            )
        }

        buffer = history + newSteps
        trimHistory()

        replanCount += 1
        lastReplanReason = "Adapted existing plan"
    }

    // MARK: - Immediate Action

    mutating func insertImmediateStep(
        _ step: PlanStep
    ) {
        overrideHead(
            with: step,
            reason: "Immediate action inserted"
        )
    }

    // MARK: - Reconcile Fresh Search

    /// Keeps the current head when it is still permitted and
    /// its regret is within the supplied threshold.
    ///
    /// Returns true when the current head was replaced.
    mutating func reconcile(
        fresh: [PlanStep],
        headRegret: Float,
        allowed: [FrankensteinAction],
        regretMargin: Float
    ) -> Bool {

        let previousHead = currentStep?.action

        guard !fresh.isEmpty else {
            return false
        }

        let allowedSet = Set(allowed)

        let freshAllowed = fresh.filter {
            allowedSet.contains($0.action)
        }

        guard !freshAllowed.isEmpty else {
            return false
        }

        // No existing plan: accept the fresh search.
        guard let current = currentStep else {
            setPlan(
                freshAllowed,
                reason: "No pending plan"
            )
            return previousHead != freshAllowed.first?.action
        }

        let currentStillAllowed = allowedSet.contains(
            current.action
        )

        let currentIsInFreshPlan = freshAllowed.contains {
            $0.action == current.action
        }

        let shouldReplace =
            !currentStillAllowed ||
            !currentIsInFreshPlan ||
            !headRegret.isFinite ||
            headRegret > regretMargin

        guard shouldReplace else {
            // Preserve the existing head, but refresh its tail.
            let history = buffer.filter {
                $0.isCompleted || $0.isFailed
            }

            let freshTail = freshAllowed.dropFirst().map {
                PlanStep(
                    action: $0.action,
                    description: $0.description
                )
            }

            buffer = history + [current] +
                Array(freshTail.prefix(maxCapacity - 1))

            trimHistory()
            return false
        }

        setPlan(
            freshAllowed,
            reason: "Fresh CA search replaced buffered plan"
        )

        return previousHead != currentStep?.action
    }

    // MARK: - Override Current Head

    mutating func overrideHead(
        with step: PlanStep,
        reason: String = "CA action override"
    ) {
        let history = buffer.filter {
            $0.isCompleted || $0.isFailed
        }

        let remaining = pendingSteps

        let tail: [PlanStep]

        if remaining.isEmpty {
            tail = []
        } else if remaining.count > 1 {
            tail = Array(remaining.dropFirst())
        } else {
            tail = []
        }

        buffer = history + [step] + tail
        buffer = Array(buffer.prefix(
            maxCapacity + maxCompletedKept
        ))

        trimHistory()

        replanCount += 1
        lastReplanReason = reason
    }

    // MARK: - Record Executed Action

    /// Advances the plan only when the executed action matches
    /// the current pending step.
    ///
    /// If blocked is true, the step is marked failed.
    mutating func recordExecuted(
        action: FrankensteinAction,
        blocked: Bool
    ) {
        guard let index = buffer.firstIndex(where: {
            !$0.isCompleted && !$0.isFailed
        }) else {
            return
        }

        guard buffer[index].action == action else {
            return
        }

        if blocked {
            buffer[index].isFailed = true
            lastReplanReason = "Action blocked: \(action)"
        } else {
            buffer[index].isCompleted = true
            executedCount += 1
            lastReplanReason = "Executed: \(action)"
        }

        trimHistory()
    }

    // MARK: - Explicit Completion

    mutating func markCurrentStepCompleted() {
        guard let index = buffer.firstIndex(where: {
            !$0.isCompleted && !$0.isFailed
        }) else {
            return
        }

        buffer[index].isCompleted = true
        executedCount += 1

        lastReplanReason = "Current step completed"

        trimHistory()
    }

    // MARK: - Explicit Failure

    mutating func markCurrentStepFailed() {
        guard let index = buffer.firstIndex(where: {
            !$0.isCompleted && !$0.isFailed
        }) else {
            return
        }

        buffer[index].isFailed = true

        lastReplanReason = "Current step failed"

        trimHistory()
    }

    // MARK: - Invalidate

    mutating func invalidate(
        reason: String = "Plan invalidated"
    ) {
        let history = buffer.filter {
            $0.isCompleted || $0.isFailed
        }

        buffer = history

        replanCount += 1
        lastReplanReason = reason

        trimHistory()
    }

    // MARK: - Clear

    mutating func clear() {
        buffer.removeAll()

        replanCount = 0
        lastReplanReason = "No plan yet"
        executedCount = 0
    }

    // MARK: - History Management

    private mutating func trimHistory() {
        let completed = buffer.filter {
            $0.isCompleted || $0.isFailed
        }

        let pending = buffer.filter {
            !$0.isCompleted && !$0.isFailed
        }

        let retainedHistory = Array(
            completed.suffix(maxCompletedKept)
        )

        let retainedPending = Array(
            pending.prefix(maxCapacity)
        )

        buffer = retainedHistory + retainedPending
    }
}
