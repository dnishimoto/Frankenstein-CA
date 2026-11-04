import Foundation
import SceneKit



/// Defines all possible high-level and tactical behaviors for Frankenstein in the simulation.
enum CharacterAction: String, CaseIterable, Codable {
    case idle                  // Standing by or waiting for task assignment
    case walk                  // General movement toward a coordinate or waypoint
    case fetchLetter           // Navigating to acquire a letter block
    case deliverLetter         // Transporting and placing a letter block into its target slot
    case dogInteraction        // Engaging or pathing toward the companion dog
    case stepAroundObstacle    // Tactical avoidance maneuver to clear blocking geometry
    case realignHeading        // Correcting orientation or heading angle toward a goal
    case recharge              // Navigating to or utilizing the recharge station
    case explore               // Autonomous wandering or environment patrolling
}
struct PlanTask {
    let action: CharacterAction
    let targetNode: SCNNode?
    let completionCondition: (SCNNode?) -> Bool // Evaluated against character position or current target state
}

class MissionPlanQueue {
    private var queue: [PlanTask] = []
    
    // The bottom-most mission anchor (e.g., Deliver Letter, Fetch Letter, Recharge)
    var missionAnchor: PlanTask? {
        didSet {
            // Optional: Log or trigger reset when mission changes
        }
    }
    
    /// Push a temporary tactical action onto the top of the stack (e.g., obstacle avoidance, realigning heading)
    func pushTacticalOverride(_ task: PlanTask) {
        queue.append(task)
    }
    
    /// Clear all temporary tactical overrides, falling back immediately to the mission anchor
    func clearTacticalOverrides() {
        queue.removeAll()
    }
    
    /// Evaluates completion conditions of the active top task and pops it if finished
    func update(with characterNode: SCNNode?) {
        guard let currentTask = queue.last else { return }
        
        // If the top tactical task's completion condition is met, pop it off the stack
        if currentTask.completionCondition(characterNode) {
            queue.removeLast()
        }
    }
    
    /// Returns the currently active action, checking temporary tactical overrides first, then falling back to the mission anchor
    var activeAction: CharacterAction? {
        return queue.last?.action ?? missionAnchor?.action
    }
    
    /// Returns the active target node associated with the current top task or mission anchor
    var activeTargetNode: SCNNode? {
        return queue.last?.targetNode ?? missionAnchor?.targetNode
    }
    
    /// Indicates whether the agent is currently executing a tactical override vs. baseline mission
    var hasActiveTacticalOverride: Bool {
        return !queue.isEmpty
    }
}
