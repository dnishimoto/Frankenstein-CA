import Foundation
import SceneKit

/// One executable step. A nil action means the CA chooses the best permitted
/// movement action while pursuing this step. Completion is always verified.
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

/// A goal contains an ordered list of subgoals/tasks.
struct MissionQueueGoal {
    let id: String
    let title: String
    var targetNode: SCNNode?
    var subgoals: [PlanTask]
}

/// The CA is the sole owner of mission, goal, subgoal and tactical queues.
/// Coordinator may submit plans and report verified physical outcomes.
final class MissionPlanQueue {
    private(set) var missionID: String?
    private(set) var missionTitle: String = ""
    private(set) var goals: [MissionQueueGoal] = []
    private(set) var tacticalQueue: [PlanTask] = []
    var onPlanEvent: ((String) -> Void)?

    var currentGoal: MissionQueueGoal? { goals.first }
    var currentMissionTask: PlanTask? { goals.first?.subgoals.first }
    var currentTask: PlanTask? { tacticalQueue.last ?? currentMissionTask }

    /// The active SceneKit target used by Coordinator pathfinding and interactions.
    var currentTargetNode: SCNNode? {
        if let tactical = tacticalQueue.last, let target = tactical.targetNode {
            return target
        }
        return currentMissionTask?.targetNode ?? currentGoal?.targetNode
    }

    var pendingActions: [FrankensteinAction] {
        tacticalQueue.reversed().compactMap(\.action) +
            goals.flatMap { $0.subgoals.compactMap(\.action) }
    }

    var summary: String {
        let goalDescriptions = goals.map { goal in
            let steps = goal.subgoals.map(\.description).joined(separator: " → ")
            return "\(goal.title) { \(steps) }"
        }.joined(separator: " | ")
        let tactical = tacticalQueue.reversed().map(\.description).joined(separator: " → ")
        return "Mission: \(missionTitle.isEmpty ? "none" : missionTitle) | Goals: \(goalDescriptions.isEmpty ? "none" : goalDescriptions) | Tactical: \(tactical.isEmpty ? "none" : tactical)"
    }

    func beginMission(id: String, title: String) {
        guard missionID != id else {
            missionTitle = title
            return
        }
        missionID = id
        missionTitle = title
        goals.removeAll()
        tacticalQueue.removeAll()
        onPlanEvent?("Mission started: \(title)")
    }

    /// Idempotent synchronization: an existing goal keeps its subgoal progress.
    func upsertGoal(_ goal: MissionQueueGoal, atFront: Bool = true) {
        if let index = goals.firstIndex(where: { $0.id == goal.id }) {
            goals[index].targetNode = goal.targetNode
            if atFront && index > 0 {
                let existing = goals.remove(at: index)
                goals.insert(existing, at: 0)
            }
            return
        }
        if atFront { goals.insert(goal, at: 0) } else { goals.append(goal) }
        onPlanEvent?("Goal added: \(goal.title)")
    }

    func removeGoal(id: String, reason: String) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        let removed = goals.remove(at: index)
        onPlanEvent?("Goal removed: \(removed.title) — \(reason)")
    }

    @discardableResult
    func completeCurrentMissionTask(because reason: String) -> Bool {
        guard !goals.isEmpty, !goals[0].subgoals.isEmpty else { return false }
        let completed = goals[0].subgoals.removeFirst()
        onPlanEvent?("Subgoal completed: \(completed.description) — \(reason)")
        if goals[0].subgoals.isEmpty {
            let goal = goals.removeFirst()
            onPlanEvent?("Goal completed: \(goal.title)")
        }
        return true
    }

    func completeGoal(id: String, because reason: String) {
        removeGoal(id: id, reason: reason)
    }

    func update(perception: FrankensteinCAPerception?) {
        if let tactical = tacticalQueue.last,
           let condition = tactical.completionCondition,
           let perception, condition(perception) {
            tacticalQueue.removeLast()
            onPlanEvent?("Tactical task completed: \(tactical.description)")
            return
        }
        guard let task = currentMissionTask,
              let condition = task.completionCondition,
              let perception, condition(perception) else { return }
        _ = completeCurrentMissionTask(because: "perception verified")
    }

    func pushTacticalOverride(_ task: PlanTask, reason: String) {
        if tacticalQueue.last?.description == task.description { return }
        tacticalQueue.append(task)
        onPlanEvent?("Tactical override added: \(reason)")
    }

    func completeTopTacticalTask(matchingDescriptionPrefix prefix: String, because reason: String) {
        guard let top = tacticalQueue.last,
              top.description.hasPrefix(prefix) else { return }
        tacticalQueue.removeLast()
        onPlanEvent?("Tactical override completed: \(reason)")
    }

    func clearTacticalOverrides(reason: String) {
        guard !tacticalQueue.isEmpty else { return }
        tacticalQueue.removeAll()
        onPlanEvent?("Tactical overrides cleared: \(reason)")
    }

    func reset() {
        goals.removeAll()
        tacticalQueue.removeAll()
        missionID = nil
        missionTitle = ""
        onPlanEvent?("Mission queue reset")
    }
}
