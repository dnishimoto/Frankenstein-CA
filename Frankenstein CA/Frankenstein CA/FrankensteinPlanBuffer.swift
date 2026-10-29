//
//  File.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 10/29/26.
//

import Foundation
import SwiftUI
import Combine

final class FrankensteinPlanBuffer: ObservableObject {
    @Published private(set) var buffer: [PlanStep] = []
    
    /// Maximum capacity of the plan buffer to prevent over-allocation.
    let maxCapacity = 20

    var currentStep: PlanStep? {
        buffer.first(where: { !$0.isCompleted && !$0.isFailed })
    }

    var isEmpty: Bool {
        buffer.isEmpty || currentStep == nil
    }

    /// Overwrites or sets a completely new plan buffer.
    func setPlan(_ steps: [PlanStep]) {
        buffer = Array(steps.prefix(maxCapacity))
    }

    /// Dynamically appends a step to the end of the buffer.
    func appendStep(_ step: PlanStep) {
        if buffer.count >= maxCapacity {
            buffer.removeFirst()
        }
        buffer.append(step)
    }

    /// Inserts a high-priority emergency/evasion step immediately next.
    func insertImmediateStep(_ step: PlanStep) {
        if let index = buffer.firstIndex(where: { !$0.isCompleted }) {
            buffer.insert(step, at: index)
        } else {
            buffer.insert(step, at: 0)
        }
    }

    /// Modifies or replaces upcoming uncompleted steps based on new environmental input.
    func adaptPlan(with newSteps: [PlanStep]) {
        let completedSteps = buffer.filter { $0.isCompleted }
        buffer = completedSteps + newSteps.prefix(maxCapacity - completedSteps.count)
    }

    /// Marks the active step as completed and advances the buffer pointer.
    func markCurrentStepCompleted() {
        if let index = buffer.firstIndex(where: { !$0.isCompleted && !$0.isFailed }) {
            buffer[index].isCompleted = true
        }
    }

    /// Marks the active step as failed, triggering an immediate buffer re-evaluation.
    func markCurrentStepFailed() {
        if let index = buffer.firstIndex(where: { !$0.isCompleted && !$0.isFailed }) {
            buffer[index].isFailed = true
        }
    }

    func clear() {
        buffer.removeAll()
    }
}
