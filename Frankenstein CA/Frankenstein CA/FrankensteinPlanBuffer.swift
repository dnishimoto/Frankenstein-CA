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

struct FrankensteinPlanBuffer {
    private var steps: [PlanStep] = []

    var isEmpty: Bool { steps.isEmpty }
    var currentStep: PlanStep? {
        steps.first(where: { !$0.isCompleted && !$0.isFailed })
    }
    var isFinished: Bool {
        !steps.isEmpty && steps.allSatisfy { $0.isCompleted || $0.isFailed }
    }

    mutating func setPlan(_ newSteps: [PlanStep]) {
        steps = newSteps
    }

    mutating func adaptPlan(with newSteps: [PlanStep]) {
        steps = newSteps
    }

    mutating func insertImmediateStep(_ step: PlanStep) {
        steps.insert(step, at: 0)
    }

    mutating func markCurrentStepCompleted() {
        if let index = steps.firstIndex(where: { !$0.isCompleted && !$0.isFailed }) {
            steps[index].isCompleted = true
        }
    }

    mutating func markCurrentStepFailed() {
        if let index = steps.firstIndex(where: { !$0.isCompleted && !$0.isFailed }) {
            steps[index].isFailed = true
        }
    }
}

