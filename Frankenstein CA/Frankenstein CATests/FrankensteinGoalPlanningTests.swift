import Foundation
import Testing
@testable import Frankenstein_CA

// Tests for: dirty Q-values (field of vision), goal-conditioned Q-values,
// the plan buffer, the goal context and Q-guided planning.
struct FrankensteinGoalPlanningTests {

    // MARK: - Helpers

    private func makePolicy() -> FrankensteinLearningPolicy {
        let policy = FrankensteinLearningPolicy(loadSavedLearning: false)
        policy.autosaveLearning = false
        return policy
    }

    private func flat() -> FrankensteinTerrainSample {
        var sample = FrankensteinTerrainSample()
        sample.terrain = .flat
        sample.distance = 5
        sample.isGroundAhead = true
        sample.isLandingAreaClear = true
        return sample
    }

    private func grounded() -> FrankensteinBodyState {
        var body = FrankensteinBodyState()
        body.grounded = true
        body.fallen = false
        return body
    }

    private func block(distance: Float = 1.5) -> FrankensteinObjectObservation {
        FrankensteinObjectObservation(
            name: "MovableBlock",
            width: 0.5,
            height: 0.5,
            depth: 0.5,
            distance: distance,
            pickupable: false
        )
    }

    private func steps(_ actions: [FrankensteinAction]) -> [PlanStep] {
        actions.map { PlanStep(action: $0, description: "\($0)") }
    }

    private func perception(
        stateKey: String = "test",
        timestamp: TimeInterval = 1
    ) -> FrankensteinCAPerception {
        var p = FrankensteinCAPerception()
        p.pathDistance = 5
        p.routeRelativeHeadings = Array(repeating: 0, count: 10)
        p.stateKey = stateKey
        p.timestamp = timestamp
        return p
    }

    // MARK: - Goal context

    @Test
    func goalContextReportsAChangeWhenTheGoalChanges() {
        var context = FrankensteinGoalContext(goal: .recharge)

        #expect(context.goal.category == "recharge")

        let reason = context.observe(
            goal: .moveObject("MovableBlock"),
            subGoal: nil,
            goalReached: false
        )

        #expect(reason != nil)
        #expect(context.goal.category == "moveObject")
    }

    @Test
    func goalContextKeepsTheGoalWhenOnlyTheSubGoalChanges() {
        var context = FrankensteinGoalContext(goal: .recharge)

        _ = context.observe(goal: .recharge, subGoal: "reach block", goalReached: false)
        let reason = context.observe(goal: .recharge, subGoal: "push block", goalReached: false)

        #expect(reason != nil)
        #expect(context.goal.category == "recharge")
        #expect(context.currentSubGoal == "push block")
        #expect(context.completedSubGoals == ["reach block"])
    }

    @Test
    func goalContextReportsNoChangeWhenNothingChanged() {
        var context = FrankensteinGoalContext(goal: .recharge)

        _ = context.observe(goal: .recharge, subGoal: "reach block", goalReached: false)
        let reason = context.observe(goal: .recharge, subGoal: "reach block", goalReached: false)

        #expect(reason == nil)
    }

    // MARK: - Plan buffer

    @Test
    func reconcileKeepsTheHeadWhenTheSearchStillAgrees() {
        var buffer = FrankensteinPlanBuffer()

        buffer.setPlan(steps([.walk, .walk, .turnLeft]))
        let headID = buffer.currentStep?.id

        let replaced = buffer.reconcile(
            fresh: steps([.walk, .turnLeft, .walk]),
            headRegret: 0,
            allowed: [.walk, .run, .turnLeft],
            regretMargin: 0.35
        )

        #expect(!replaced)
        #expect(buffer.currentStep?.id == headID)
        #expect(buffer.pendingActions == [.walk, .turnLeft, .walk])
    }

    @Test
    func reconcileReplacesTheHeadWhenAnotherActionIsMuchBetter() {
        var buffer = FrankensteinPlanBuffer()

        buffer.setPlan(steps([.walk, .walk]))

        let replaced = buffer.reconcile(
            fresh: steps([.run, .run]),
            headRegret: 2.0,
            allowed: [.walk, .run],
            regretMargin: 0.35
        )

        #expect(replaced)
        #expect(buffer.pendingActions.first == .run)
    }

    @Test
    func reconcileReplacesAHeadThatIsNoLongerPermitted() {
        var buffer = FrankensteinPlanBuffer()

        buffer.setPlan(steps([.jump, .walk]))

        buffer.reconcile(
            fresh: steps([.walk, .walk]),
            headRegret: 0,
            allowed: [.walk],
            regretMargin: 0.35
        )

        #expect(buffer.pendingActions.first == .walk)
    }

    @Test
    func planAdvancesOnlyWhenTheMatchingActionIsExecuted() {
        var buffer = FrankensteinPlanBuffer()

        buffer.setPlan(steps([.walk, .turnLeft]))

        // A different action was executed: the plan does not advance.
        buffer.recordExecuted(action: .run, blocked: false)
        #expect(buffer.pendingActions == [.walk, .turnLeft])

        buffer.recordExecuted(action: .walk, blocked: false)
        #expect(buffer.pendingActions == [.turnLeft])
    }

    @Test
    func aBlockedActionFailsItsStep() {
        var buffer = FrankensteinPlanBuffer()

        buffer.setPlan(steps([.walk, .turnLeft]))
        buffer.recordExecuted(action: .walk, blocked: true)

        #expect(buffer.pendingActions == [.turnLeft])
        #expect(buffer.lastReplanReason.contains("blocked"))
    }

    @Test
    func invalidateDropsThePendingPlan() {
        var buffer = FrankensteinPlanBuffer()

        buffer.setPlan(steps([.walk, .walk]))
        buffer.invalidate(reason: "sub-goal changed")

        #expect(buffer.isEmpty)
        #expect(buffer.lastReplanReason == "sub-goal changed")
    }

    // MARK: - Goal-conditioned Q-values

    @Test
    func learnedValuesDependOnTheGoal() {
        let policy = makePolicy()
        let terrain = flat()
        let body = grounded()

        policy.currentGoalCategory = "recharge"

        #expect(policy.beginCAChosenAction(.walk, terrain: terrain, body: body))
        #expect(policy.learn(reward: 1.0, terrain: terrain, body: body, terminal: true))

        let underRecharge = policy.qValue(for: .walk, terrain: terrain, body: body)
        #expect(underRecharge > 0)

        // The same action in the same state has no learned value for
        // another goal.
        policy.currentGoalCategory = "moveObject"
        let underMoveObject = policy.qValue(for: .walk, terrain: terrain, body: body)
        #expect(underMoveObject == 0)

        // And the original value is still there when the goal returns.
        policy.currentGoalCategory = "recharge"
        #expect(policy.qValue(for: .walk, terrain: terrain, body: body) == underRecharge)
    }

    // MARK: - Dirty Q-values

    @Test
    func qValuesInViewAreMarkedDirty() {
        let policy = makePolicy()
        let terrain = flat()
        let body = grounded()
        let object = block()

        policy.visionTime = 10
        policy.markVisibleDirty(objects: [object], terrain: terrain, body: body)

        let cells = policy.qDisplaySnapshot(
            objectsInView: [object],
            terrain: terrain,
            body: body
        )

        #expect(cells.count == 1)
        #expect(cells.first?.isDirty == true)
        #expect(policy.dirtyCount > 0)
    }

    @Test
    func dirtyMarksExpireWhenTheStateLeavesView() {
        let policy = makePolicy()
        let terrain = flat()
        let body = grounded()
        let object = block()

        policy.visionTime = 10
        policy.markVisibleDirty(objects: [object], terrain: terrain, body: body)

        // Time passes beyond the mark's lifetime, and he now looks at
        // something else.
        policy.visionTime = 10 + policy.dirtyLifetime + 1

        var gap = FrankensteinTerrainSample()
        gap.terrain = .gap
        gap.distance = 1
        policy.markVisibleDirty(terrain: gap, body: body)

        let cells = policy.qDisplaySnapshot(
            objectsInView: [object],
            terrain: terrain,
            body: body
        )

        #expect(cells.first?.isDirty == false)
    }

    @Test
    func theDisplayReportsTheLearnedValueOfAnObjectsState() {
        let policy = makePolicy()
        let terrain = flat()
        let body = grounded()
        let object = block()

        policy.visionTime = 1

        #expect(
            policy.beginCAChosenAction(
                .walk,
                terrain: terrain,
                body: body,
                objectObservation: object
            )
        )

        #expect(
            policy.learn(
                reward: 1.0,
                terrain: terrain,
                body: body,
                terminal: true,
                objectObservation: object
            )
        )

        let cells = policy.qDisplaySnapshot(
            objectsInView: [object],
            terrain: terrain,
            body: body
        )

        #expect((cells.first?.value ?? 0) > 0)
    }

    // MARK: - Q-guided planning

    @Test
    func theBestPlanFavorsActionsWithHighLearnedValues() {
        let ca = FrankensteinCA()
        let terrain = flat()
        let body = grounded()
        let allowed: [FrankensteinAction] = [.walk, .run]

        // With no learned preference, running covers more of the route.
        ca.receivePerception(perception())

        _ = ca.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: allowed,
            qValues: [.walk: 0, .run: 0],
            exploration: 0
        )

        #expect(ca.plannedSequence.first == .run)

        // When the policy has learned that walking works and running does
        // not for this goal, the searched plan starts with walking.
        let guided = FrankensteinCA()
        guided.receivePerception(perception())

        _ = guided.decideAction(
            terrain: terrain,
            body: body,
            allowedActions: allowed,
            qValues: [.walk: 10, .run: -10],
            exploration: 0
        )

        #expect(guided.plannedSequence.first == .walk)
    }

    @Test
    func thePlanBufferIsFilledFromTheCurrentSearch() {
        let ca = FrankensteinCA()

        ca.receivePerception(perception())

        let action = ca.decideAction(
            terrain: flat(),
            body: grounded(),
            allowedActions: [.walk, .run, .turnLeft, .turnRight],
            qValues: [.walk: 0, .run: 0, .turnLeft: 0, .turnRight: 0],
            exploration: 0
        )

        #expect(!ca.plannedSequence.isEmpty)
        #expect(ca.planBuffer.currentStep != nil)
        #expect(ca.planBuffer.pendingActions.contains(action))
    }

    @Test
    func theCAKeepsFollowingItsPlanUntilTheActionHasRun() {
        let ca = FrankensteinCA()
        let terrain = flat()
        let body = grounded()
        let allowed: [FrankensteinAction] = [.walk, .run]
        let values: [FrankensteinAction: Float] = [.walk: 0, .run: 0]

        ca.receivePerception(perception())

        let first = ca.decideAction(
            terrain: terrain, body: body,
            allowedActions: allowed, qValues: values, exploration: 0
        )

        // The next frame, before the action has run for an outcome window,
        // the CA is still working on the same step.
        ca.receivePerception(perception(timestamp: 1.05))

        let second = ca.decideAction(
            terrain: terrain, body: body,
            allowedActions: allowed, qValues: values, exploration: 0
        )

        #expect(second == first)

        // Once the action has been executed, the plan moves on.
        ca.reportActionOutcome(
            action: first,
            goalProgressRate: 0.5,
            windowDuration: 0.25,
            blocked: false
        )

        #expect(ca.planBuffer.executedCount == 1)
    }

    @Test
    func aChangeOfGoalDropsTheOldPlan() {
        let ca = FrankensteinCA()
        let terrain = flat()
        let body = grounded()
        let allowed: [FrankensteinAction] = [.walk, .run]
        let values: [FrankensteinAction: Float] = [.walk: 0, .run: 0]

        ca.receivePerception(perception())

        _ = ca.decideAction(
            terrain: terrain, body: body,
            allowedActions: allowed, qValues: values, exploration: 0
        )

        let replansBefore = ca.planBuffer.replanCount

        var moved = perception(timestamp: 1.05)
        moved.goal = .moveObject("MovableBlock")
        ca.receivePerception(moved)

        _ = ca.decideAction(
            terrain: terrain, body: body,
            allowedActions: allowed, qValues: values, exploration: 0
        )

        #expect(ca.goalContext.goal.category == "moveObject")
        #expect(ca.planBuffer.replanCount > replansBefore)
        #expect(ca.planBuffer.lastReplanReason.isEmpty == false)
    }
}
