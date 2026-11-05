import Foundation
import SceneKit

// MARK: - Mission Task

struct PlanTask {
    let id: UUID
    var actions: [FrankensteinAction]
    let targetNode: SCNNode?
    let description: String
    let completionCondition: ((FrankensteinCAPerception?) -> Bool)?

    init(
        actions: [FrankensteinAction] = [],
        targetNode: SCNNode? = nil,
        description: String,
        completionCondition: ((FrankensteinCAPerception?) -> Bool)? = nil
    ) {
        self.id = UUID()
        self.actions = actions
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

    // MARK: Plan Queries & Action Source of Truth

    var pendingActions: [FrankensteinAction] {
        let tacticalActions = tacticalQueue.flatMap { $0.actions }
        let goalActions = goals.flatMap { goal in
            goal.subgoals.flatMap { $0.actions }
        }
        return tacticalActions + goalActions
    }

    var isEmpty: Bool {
        pendingActions.isEmpty
    }

    var isFinished: Bool {
        goals.isEmpty && tacticalQueue.isEmpty
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
                .map { task in
                    let actionDesc = task.actions.map { "\($0)" }.joined(separator: ", ")
                    return task.actions.isEmpty ? task.description : "\(task.description) [\(actionDesc)]"
                }
                .joined(separator: " → ")

            return "\(goal.title) { \(steps.isEmpty ? "no subgoals" : steps) }"
        }
        .joined(separator: " | ")

        let tactical = tacticalQueue.reversed()
            .map { task in
                let actionDesc = task.actions.map { "\($0)" }.joined(separator: ", ")
                return task.actions.isEmpty ? task.description : "\(task.description) [\(actionDesc)]"
            }
            .joined(separator: " → ")

        let actionsList = pendingActions
            .map { "\($0)" }
            .joined(separator: " → ")

        return """
        Mission: \(missionTitle.isEmpty ? "none" : missionTitle) |
        Goals: \(goalDescriptions.isEmpty ? "none" : goalDescriptions) |
        Actions: \(actionsList.isEmpty ? "none" : actionsList) |
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
        replanCount = 0
        executedCount = 0

        onPlanEvent?("Mission started: \(title)")
    }

    // MARK: Goal Management

    func upsertGoal(
        _ goal: MissionQueueGoal,
        atFront: Bool = true
    ) {
        if let index = goals.firstIndex(where: { $0.id == goal.id }) {
            goals[index].targetNode = goal.targetNode
            if !goal.subgoals.isEmpty {
                goals[index].subgoals = goal.subgoals
            }

            if atFront && index > 0 {
                let existing = goals.remove(at: index)
                goals.insert(existing, at: 0)
            }

            onPlanEvent?("Goal updated: \(goal.title)")
            return
        }

        if atFront {
            goals.insert(goal, at: 0)
        } else {
            goals.append(goal)
        }

        onPlanEvent?("Goal added: \(goal.title) (Total Goals: \(goals.count))")
    }

    func removeGoal(id: String, reason: String) {
        guard let index = goals.firstIndex(where: {
            $0.id == id
        }) else {
            return
        }

        let removed = goals.remove(at: index)

        onPlanEvent?(
            "Goal removed: \(removed.title) — \(reason)"
        )
    }

    // MARK: Granular Action Completion

    @discardableResult
    func completeAction(
        _ action: FrankensteinAction,
        target: SCNNode?,
        because reason: String
    ) -> Bool {

        // MARK: 1. Tactical override

        if let index = tacticalQueue.indices.last {

            let taskID = tacticalQueue[index].id
            var tactical = tacticalQueue[index]

            if let frontAction = tactical.actions.first,
               frontAction == action {

                let targetMatches: Bool

                if target == nil {
                    targetMatches = true
                } else if let taskTarget = tactical.targetNode {
                    targetMatches = taskTarget === target
                } else {
                    targetMatches = false
                }

                if targetMatches {

                    tactical.actions.removeFirst()
                    executedCount += 1

                    // Verify the same task still occupies this position.
                    guard tacticalQueue.indices.contains(index),
                          tacticalQueue[index].id == taskID else {
                        return false
                    }

                    if tactical.actions.isEmpty {

                        tacticalQueue.remove(at: index)

                        onPlanEvent?(
                            "Tactical task completed: \(tactical.description) — \(reason)"
                        )

                    } else {

                        tacticalQueue[index] = tactical

                        onPlanEvent?(
                            "Tactical action completed: \(frontAction) — \(reason)"
                        )
                    }

                    return true
                }
            }
        }

        // MARK: 2. Mission task

        guard !goals.isEmpty,
              !goals[0].subgoals.isEmpty else {
            return false
        }

        var currentGoal = goals[0]
        var currentTask = currentGoal.subgoals[0]

        guard let frontAction = currentTask.actions.first,
              frontAction == action else {
            return false
        }

        let targetMatches =
            target == nil ||
            currentTask.targetNode === target

        guard targetMatches else {
            return false
        }

        currentTask.actions.removeFirst()
        executedCount += 1

        onPlanEvent?(
            "Action completed: \(frontAction) — \(reason)"
        )

        if currentTask.actions.isEmpty {

            currentGoal.subgoals.removeFirst()

            onPlanEvent?(
                "Subgoal completed: \(currentTask.description)"
            )

        } else {

            currentGoal.subgoals[0] = currentTask
        }

        if currentGoal.subgoals.isEmpty {

            goals.removeFirst()

            onPlanEvent?(
                "Goal completed: \(currentGoal.title)"
            )

        } else {

            goals[0] = currentGoal
        }

        return true
    }

    @discardableResult
    func completeCurrentMissionTask(
        because reason: String
    ) -> Bool {
        guard !goals.isEmpty,
              !goals[0].subgoals.isEmpty else {
            return false
        }

        let completed = goals[0].subgoals.removeFirst()
        executedCount += 1

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

        // MARK: 1. Tactical completion

        if let index = tacticalQueue.indices.last {

            let task = tacticalQueue[index]
            let taskID = task.id

            if let condition = task.completionCondition,
               let perception,
               condition(perception) {

                // Verify that the same task is still at the top.
                if let currentIndex = tacticalQueue.indices.last,
                   tacticalQueue[currentIndex].id == taskID {

                    tacticalQueue.remove(at: currentIndex)

                    onPlanEvent?(
                        "Tactical task completed by condition: \(task.description)"
                    )

                    return
                }
            }
        }

        // MARK: 2. Mission task completion

        guard let task = currentMissionTask,
              task.actions.isEmpty,
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
        // Prevent inserting the exact same task twice.
        guard !tacticalQueue.contains(where: { $0.id == task.id }) else {
            return
        }

        // Prevent duplicate overrides for the same object and task.
        let targetID = task.targetNode.map { ObjectIdentifier($0) }

        let alreadyQueued = tacticalQueue.contains { existing in
            let existingTargetID = existing.targetNode.map {
                ObjectIdentifier($0)
            }

            return existing.description == task.description
                && existingTargetID == targetID
        }

        guard !alreadyQueued else {
            return
        }

        // Enforce queue capacity.
        if tacticalQueue.count >= maxCapacity {
            // Remove the oldest override, preserving the active top task.
            tacticalQueue.removeFirst()
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
        guard let index = tacticalQueue.indices.last else {
            return
        }

        let task = tacticalQueue[index]

        guard task.description.hasPrefix(prefix) else {
            return
        }

        // Verify the task identity before removal.
        guard tacticalQueue.indices.contains(index),
              tacticalQueue[index].id == task.id else {
            return
        }

        tacticalQueue.remove(at: index)

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

    // MARK: Clear Entire Queue

    func reset() {
        goals.removeAll()
        tacticalQueue.removeAll()

        missionID = nil
        missionTitle = ""
        replanCount = 0
        lastReplanReason = "No plan yet"
        executedCount = 0

        onPlanEvent?("Mission queue reset")
    }
}
