import Foundation
import SceneKit



// MARK: - Mission Task

struct PlanTask {
    let id: UUID
    let action: FrankensteinAction?
    let targetNode: SCNNode?
    let description: String
    let completionCondition: ((FrankensteinCAPerception?) -> Bool)?

    init(
        action: FrankensteinAction? = nil,
        targetNode: SCNNode? = nil,
        description: String,
        completionCondition: ((FrankensteinCAPerception?) -> Bool)? = nil
    ) {
        self.id = UUID()
        self.action = action
        self.targetNode = targetNode
        self.description = description
        self.completionCondition = completionCondition
    }
}

// MARK: - Mission Goal

struct MissionQueueGoal {
    let id: String
    let title: String
    var targetNode: SCNNode?
    var subgoals: [PlanTask]
}

// MARK: - Mission Plan Queue

final class MissionPlanQueue {

    // MARK: Mission Storage

    private(set) var missionID: String?
    private(set) var missionTitle: String = ""
    private(set) var goals: [MissionQueueGoal] = []
    private(set) var tacticalQueue: [PlanTask] = []

    var onPlanEvent: ((String) -> Void)?

    // MARK: Plan Buffer Storage

    private(set) var buffer: [PlanStep] = []

    let maxCapacity = 12
    let maxCompletedKept = 3

    private(set) var replanCount = 0
    private(set) var lastReplanReason = "No plan yet"
    private(set) var executedCount = 0

    // MARK: Mission Queries

    var currentGoal: MissionQueueGoal? {
        goals.first
    }

    var currentMissionTask: PlanTask? {
        goals.first?.subgoals.first
    }

    var currentTask: PlanTask? {
        tacticalQueue.last ?? currentMissionTask
    }

    // MARK: Plan Queries

    var currentStep: PlanStep? {
        buffer.first {
            !$0.isCompleted && !$0.isFailed
        }
    }

    var pendingSteps: [PlanStep] {
        buffer.filter {
            !$0.isCompleted && !$0.isFailed
        }
    }

    var pendingActions: [FrankensteinAction] {
        if let tactical = tacticalQueue.last?.action {
            return [tactical] + pendingSteps.map(\.action)
        }

        return pendingSteps.map(\.action)
    }

    var isEmpty: Bool {
        pendingSteps.isEmpty
    }

    var isFinished: Bool {
        !buffer.isEmpty && pendingSteps.isEmpty
    }

    // MARK: Active Target

    var currentTargetNode: SCNNode? {
        if let tacticalTarget = tacticalQueue.last?.targetNode {
            return tacticalTarget
        }

        return currentMissionTask?.targetNode
            ?? currentGoal?.targetNode
    }

    // MARK: Summary

    var summary: String {
        let goalDescriptions = goals.map { goal in
            let steps = goal.subgoals
                .map(\.description)
                .joined(separator: " → ")

            return "\(goal.title) { \(steps) }"
        }
        .joined(separator: " | ")

        let tactical = tacticalQueue.reversed()
            .map(\.description)
            .joined(separator: " → ")

        let plan = pendingSteps
            .map(\.description)
            .joined(separator: " → ")

        return """
        Mission: \(missionTitle.isEmpty ? "none" : missionTitle) |
        Goals: \(goalDescriptions.isEmpty ? "none" : goalDescriptions) |
        Plan: \(plan.isEmpty ? "none" : plan) |
        Tactical: \(tactical.isEmpty ? "none" : tactical)
        """
    }

    // MARK: Begin Mission

    func beginMission(id: String, title: String) {
        guard missionID != id else {
            missionTitle = title
            return
        }

        missionID = id
        missionTitle = title

        goals.removeAll()
        tacticalQueue.removeAll()
        clearPlanBuffer()

        onPlanEvent?("Mission started: \(title)")
    }

    // MARK: Goal Management

    func upsertGoal(
        _ goal: MissionQueueGoal,
        atFront: Bool = true
    ) {
        if let index = goals.firstIndex(where: { $0.id == goal.id }) {
            goals[index].targetNode = goal.targetNode

            if atFront && index > 0 {
                let existing = goals.remove(at: index)
                goals.insert(existing, at: 0)
            }

            return
        }

        if atFront {
            goals.insert(goal, at: 0)
        } else {
            goals.append(goal)
        }

        onPlanEvent?("Goal added: \(goal.title)")
    }

    func removeGoal(id: String, reason: String) {
        guard let index = goals.firstIndex(where: {
            $0.id == id
        }) else {
            return
        }

        let removed = goals.remove(at: index)

        if index == 0 {
            clearPlanBuffer()
        }

        onPlanEvent?(
            "Goal removed: \(removed.title) — \(reason)"
        )
    }

    // MARK: Complete Mission Task

    @discardableResult
    func completeCurrentMissionTask(
        because reason: String
    ) -> Bool {

        guard !goals.isEmpty,
              !goals[0].subgoals.isEmpty else {
            return false
        }

        let completed = goals[0].subgoals.removeFirst()

        clearPlanBuffer()

        onPlanEvent?(
            "Subgoal completed: \(completed.description) — \(reason)"
        )

        if goals[0].subgoals.isEmpty {
            let goal = goals.removeFirst()

            onPlanEvent?(
                "Goal completed: \(goal.title)"
            )
        }

        return true
    }

    func completeGoal(
        id: String,
        because reason: String
    ) {
        removeGoal(id: id, reason: reason)
    }

    // MARK: Perception Verification

    func update(perception: FrankensteinCAPerception?) {

        if let tactical = tacticalQueue.last,
           let condition = tactical.completionCondition,
           let perception,
           condition(perception) {

            tacticalQueue.removeLast()

            onPlanEvent?(
                "Tactical task completed: \(tactical.description)"
            )

            return
        }

        guard let task = currentMissionTask,
              let condition = task.completionCondition,
              let perception,
              condition(perception) else {
            return
        }

        _ = completeCurrentMissionTask(
            because: "perception verified"
        )
    }

    // MARK: Tactical Overrides

    func pushTacticalOverride(
        _ task: PlanTask,
        reason: String
    ) {
        if tacticalQueue.last?.description == task.description {
            return
        }

        tacticalQueue.append(task)

        onPlanEvent?(
            "Tactical override added: \(reason)"
        )
    }

    func completeTopTacticalTask(
        matchingDescriptionPrefix prefix: String,
        because reason: String
    ) {
        guard let top = tacticalQueue.last,
              top.description.hasPrefix(prefix) else {
            return
        }

        tacticalQueue.removeLast()

        onPlanEvent?(
            "Tactical override completed: \(reason)"
        )
    }

    func clearTacticalOverrides(reason: String) {
        guard !tacticalQueue.isEmpty else {
            return
        }

        tacticalQueue.removeAll()

        onPlanEvent?(
            "Tactical overrides cleared: \(reason)"
        )
    }

    // MARK: Set Navigation Plan

    func setPlan(
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

        onPlanEvent?(
            "Navigation plan updated: \(reason)"
        )
    }

    // MARK: Adapt Existing Plan

    func adaptPlan(
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

        onPlanEvent?(
            lastReplanReason
        )
    }

    // MARK: Immediate Action

    func insertImmediateStep(
        _ step: PlanStep
    ) {
        overrideHead(
            with: step,
            reason: "Immediate action inserted"
        )
    }

    // MARK: Reconcile Fresh Search

    @discardableResult
    func reconcile(
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

        guard let current = currentStep else {
            setPlan(
                freshAllowed,
                reason: "No pending plan"
            )

            return previousHead != currentStep?.action
        }

        let currentStillAllowed =
            allowedSet.contains(current.action)

        let currentIsInFreshPlan = freshAllowed.contains {
            $0.action == current.action
        }

        let shouldReplace =
            !currentStillAllowed ||
            !currentIsInFreshPlan ||
            !headRegret.isFinite ||
            headRegret > regretMargin

        guard shouldReplace else {

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

    // MARK: Override Current Head

    func overrideHead(
        with step: PlanStep,
        reason: String = "CA action override"
    ) {

        let history = buffer.filter {
            $0.isCompleted || $0.isFailed
        }

        let remaining = pendingSteps

        let tail = remaining.count > 1
            ? Array(remaining.dropFirst())
            : []

        buffer = history + [step] + tail

        trimHistory()

        replanCount += 1
        lastReplanReason = reason

        onPlanEvent?(
            "Plan head overridden: \(reason)"
        )
    }

    // MARK: Record Executed Action

    func recordExecuted(
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

            lastReplanReason =
                "Action blocked: \(action)"
        } else {
            buffer[index].isCompleted = true

            executedCount += 1

            lastReplanReason =
                "Executed: \(action)"
        }

        trimHistory()

        onPlanEvent?(lastReplanReason)
    }

    // MARK: Explicit Completion

    func markCurrentStepCompleted() {
        guard let index = buffer.firstIndex(where: {
            !$0.isCompleted && !$0.isFailed
        }) else {
            return
        }

        buffer[index].isCompleted = true
        executedCount += 1

        lastReplanReason = "Current step completed"

        trimHistory()

        onPlanEvent?(lastReplanReason)
    }

    // MARK: Explicit Failure

    func markCurrentStepFailed() {
        guard let index = buffer.firstIndex(where: {
            !$0.isCompleted && !$0.isFailed
        }) else {
            return
        }

        buffer[index].isFailed = true

        lastReplanReason = "Current step failed"

        trimHistory()

        onPlanEvent?(lastReplanReason)
    }

    // MARK: Invalidate Plan

    func invalidate(
        reason: String = "Plan invalidated"
    ) {
        buffer = buffer.filter {
            $0.isCompleted || $0.isFailed
        }

        replanCount += 1
        lastReplanReason = reason

        trimHistory()

        onPlanEvent?(reason)
    }

    // MARK: Clear Plan Buffer

    func clearPlanBuffer() {
        buffer.removeAll()

        replanCount = 0
        lastReplanReason = "No plan yet"
        executedCount = 0
    }

    // MARK: Clear Entire Queue

    func reset() {
        goals.removeAll()
        tacticalQueue.removeAll()

        missionID = nil
        missionTitle = ""

        clearPlanBuffer()

        onPlanEvent?("Mission queue reset")
    }

    // MARK: History Management

    private func trimHistory() {

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
