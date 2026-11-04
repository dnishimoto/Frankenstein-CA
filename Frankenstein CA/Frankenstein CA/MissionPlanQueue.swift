import Foundation
import SceneKit

/// The high-level and tactical behaviours Frankenstein's mission can be in.
/// The mission anchor is always one of the first group; tactical overrides
/// are the second group.
enum CharacterAction: String, CaseIterable, Codable {
    // Mission anchors (what the supervisor's phase asks for)
    case idle                  // No mission target
    case fetchLetter           // Go to a letter block and pick it up
    case deliverLetter         // Carry the letter block to its slot and place it
    case dogInteraction        // Go to the dog
    case recharge              // Go to the recharge station
    case explore               // Autonomous wandering

    // Tactical overrides (discovered on the way, never replace the anchor)
    case stepAroundObstacle    // Go around a platform he cannot climb
    case clearObstacle         // Kick or throw a table / loose block off the route
    case realignHeading        // Turn back toward the goal
}

/// One plan: an action, the node it concerns (held weakly), why it exists,
/// and when it lapses if nothing completes it first.
struct PlanTask {
    let action: CharacterAction
    weak var targetNode: SCNNode?
    let reason: String
    let expiresAt: TimeInterval?

    init(
        action: CharacterAction,
        targetNode: SCNNode? = nil,
        reason: String = "",
        expiresAt: TimeInterval? = nil
    ) {
        self.action = action
        self.targetNode = targetNode
        self.reason = reason
        self.expiresAt = expiresAt
    }
}

/// Manages every plan discovered while Frankenstein finds letter blocks and
/// delivers them to their slots.
///
/// - The mission anchor is the one plan that decides WHERE he is going. It
///   comes only from the supervisor's phase.
/// - Tactical overrides are short-lived plans found on the way (go around a
///   platform, clear the table). They are stacked on top of the anchor, never
///   replace its target, and lapse when completed, expired or their target is
///   gone.
/// - A change of anchor drops every override: they belonged to the old plan.
final class MissionPlanQueue {

    private(set) var missionAnchor: PlanTask?
    private var overrides: [PlanTask] = []
    private let maximumOverrides = 3

    /// Recent plan events, newest last (for the debug panel).
    private(set) var history: [String] = []
    private let maximumHistory = 12

    /// Called for each plan event so the Coordinator can publish it.
    var onEvent: ((String) -> Void)?

    // MARK: - Anchor

    /// Sets the mission anchor. A different action or target replaces the
    /// anchor and drops all overrides; the same one is left untouched.
    func setAnchor(action: CharacterAction, target: SCNNode?, reason: String) {
        if let current = missionAnchor,
           current.action == action,
           current.targetNode === target {
            return
        }
        let hadOverrides = !overrides.isEmpty
        overrides.removeAll()
        missionAnchor = PlanTask(action: action, targetNode: target, reason: reason)
        record("anchor \(action.rawValue) -> \(target?.name ?? "none")"
               + (hadOverrides ? " (overrides dropped)" : "")
               + (reason.isEmpty ? "" : ": \(reason)"))
    }

    /// The node the mission is heading for. Overrides never change it.
    var anchorTarget: SCNNode? {
        guard let node = missionAnchor?.targetNode, node.parent != nil else { return nil }
        return node
    }

    // MARK: - Tactical overrides

    /// Adds a tactical plan unless the same action on the same target is
    /// already queued (then only its expiry is extended).
    func push(
        _ action: CharacterAction,
        target: SCNNode? = nil,
        reason: String,
        expiresAt: TimeInterval?
    ) {
        if let index = overrides.firstIndex(where: {
            $0.action == action && $0.targetNode === target
        }) {
            let old = overrides[index]
            overrides[index] = PlanTask(
                action: action,
                targetNode: target,
                reason: old.reason,
                expiresAt: expiresAt
            )
            return
        }
        if overrides.count >= maximumOverrides {
            overrides.removeFirst()
        }
        overrides.append(
            PlanTask(action: action, targetNode: target, reason: reason, expiresAt: expiresAt)
        )
        record("push \(action.rawValue)\(target.map { " (\($0.name ?? "node"))" } ?? ""): \(reason)")
    }

    /// Ends every queued plan of this action.
    func finish(_ action: CharacterAction, because why: String = "done") {
        let before = overrides.count
        overrides.removeAll { $0.action == action }
        if overrides.count != before {
            record("finish \(action.rawValue): \(why)")
        }
    }

    /// Drops overrides that have expired or whose target has left the scene.
    func update(now: TimeInterval) {
        let before = overrides
        overrides.removeAll { task in
            if let expiry = task.expiresAt, now >= expiry { return true }
            if task.action == .clearObstacle,
               task.targetNode == nil || task.targetNode?.parent == nil { return true }
            return false
        }
        for task in before where !overrides.contains(where: {
            $0.action == task.action && $0.targetNode === task.targetNode
        }) {
            record("lapse \(task.action.rawValue)")
        }
    }

    // MARK: - Reading

    /// The active behaviour: the top override, else the anchor.
    var activeAction: CharacterAction? {
        overrides.last?.action ?? missionAnchor?.action
    }

    var hasActiveTacticalOverride: Bool {
        !overrides.isEmpty
    }

    /// One line for the debug panel.
    var summary: String {
        let anchor = missionAnchor.map {
            "\($0.action.rawValue) -> \($0.targetNode?.name ?? "none")"
        } ?? "none"
        let tactical = overrides.map { $0.action.rawValue }.joined(separator: " > ")
        return tactical.isEmpty ? anchor : "\(anchor) | \(tactical)"
    }

    // MARK: - Events

    private func record(_ message: String) {
        history.append(message)
        if history.count > maximumHistory { history.removeFirst() }
        onEvent?(message)
    }
}
