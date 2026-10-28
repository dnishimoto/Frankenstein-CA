
import Foundation
import SceneKit
import SwiftUI



final class FrankensteinCharacter {

    let root = SCNNode()

    let headPivot = SCNNode()
    let jawPivot = SCNNode()
    let leftArmPivot = SCNNode()
    let rightArmPivot = SCNNode()
    let leftLegPivot = SCNNode()
    let rightLegPivot = SCNNode()

    var leftKneePivot: SCNNode?
    var rightKneePivot: SCNNode?
    var leftHipPivot: SCNNode?
    var rightHipPivot: SCNNode?

    private let poseNode = SCNNode()

    private var shownScale: Float = 1
    private var shownPitch: Float = 0
    private var wasRolling = false
    private var basePoseHeight: Float = 0

    private let skin = UIColor(
        red: 0.35, green: 0.52, blue: 0.34, alpha: 1
    )
    private let skinLight = UIColor(
        red: 0.47, green: 0.61, blue: 0.42, alpha: 1
    )
    private let skinDark = UIColor(
        red: 0.19, green: 0.31, blue: 0.22, alpha: 1
    )
    private let hair = UIColor(
        red: 0.055, green: 0.065, blue: 0.06, alpha: 1
    )
    private let jacket = UIColor(
        red: 0.13, green: 0.14, blue: 0.13, alpha: 1
    )
    private let shirt = UIColor(
        red: 0.36, green: 0.35, blue: 0.30, alpha: 1
    )
    private let metal = UIColor(
        red: 0.62, green: 0.65, blue: 0.61, alpha: 1
    )

    init() {
        buildBody()
        buildHead()
        buildArms()
        buildLegs()
        wrapInPoseNode()
    }

    private func wrapInPoseNode() {
        let parts = root.childNodes

        poseNode.name = "FrankensteinPose"

        for part in parts {
            part.removeFromParentNode()
            poseNode.addChildNode(part)
        }

        root.addChildNode(poseNode)
    }

    // MARK: - Locomotion

    func applyLocomotion(_ motion: FrankensteinLocomotionOutput) {
        applyMotion(
            walkPhase: motion.walkPhase,
            armLift: motion.armLift,
            headTurn: motion.headTurn,
            mouthOpen: motion.mouthOpen,
            posture: motion.posture
        )

        applyPosture(motion)
        applyGait(motion)
    }

    private func applyPosture(_ motion: FrankensteinLocomotionOutput) {
        let targetScale: Float
        let targetPitch: Float
        let targetHeight: Float

        let rolling = motion.posture == .rolling

        switch motion.posture {
        case .standing, .walking:
            targetScale = 1
            targetPitch = 0
            targetHeight = 0

        case .running:
            targetScale = 1
            targetPitch = -0.12
            targetHeight = 0

        case .jumping:
            targetScale = 1
            targetPitch = 0
            targetHeight = 0.12 * min(1, max(0, motion.jump))

        case .crouching:
            targetScale = 0.82
            targetPitch = -0.20
            targetHeight = 0

        case .crawling:
            targetScale = 0.62
            targetPitch = -Float.pi / 2
            targetHeight = 0

        case .rolling:
            targetScale = 0.48
            targetPitch = -2 * Float.pi * motion.rollProgress
            targetHeight = 0
        }

        shownScale += (targetScale - shownScale) * 0.25

        if rolling {
            shownPitch = targetPitch
        } else {
            if wasRolling {
                shownPitch = 0
            }

            shownPitch += (targetPitch - shownPitch) * 0.25
        }

        wasRolling = rolling

        let sine = abs(sin(shownPitch))
        let cosine = abs(cos(shownPitch))

        let uprightHalfHeight: Float = 2.5

        let centerY: Float

        if rolling {
            centerY = shownScale * 0.85
        } else {
            centerY = shownScale * (
                uprightHalfHeight * cosine + 0.85 * sine
            )
        }

        basePoseHeight = centerY + targetHeight

        poseNode.scale = SCNVector3(
            shownScale,
            shownScale,
            shownScale
        )

        poseNode.eulerAngles = SCNVector3(
            shownPitch,
            0,
            motion.lean
        )

        poseNode.position = SCNVector3(
            0,
            basePoseHeight,
            0
        )
    }

    private func applyGait(_ motion: FrankensteinLocomotionOutput) {
        let phase = motion.walkPhase

        let stride: Float
        let hipAmplitude: Float
        let kneeAmplitude: Float

        switch motion.posture {
        case .walking:
            stride = min(1, max(0, motion.stride))
            hipAmplitude = 0.55
            kneeAmplitude = 0.85

        case .running:
            stride = min(1, max(0, motion.stride))
            hipAmplitude = 0.85
            kneeAmplitude = 1.25

        case .jumping:
            stride = 1
            hipAmplitude = 0.35
            kneeAmplitude = 1.05

        case .crawling:
            stride = min(1, max(0, motion.stride))
            hipAmplitude = 0.45
            kneeAmplitude = 0.65

        case .rolling, .standing, .crouching:
            stride = 0
            hipAmplitude = 0
            kneeAmplitude = 0
        }

        let hipSwing = sin(phase) * hipAmplitude * stride

        leftHipPivot?.eulerAngles.x = hipSwing
        rightHipPivot?.eulerAngles.x = -hipSwing

        let leftKneeBend =
            max(0, cos(phase)) * kneeAmplitude * stride

        let rightKneeBend =
            max(0, -cos(phase)) * kneeAmplitude * stride

        leftKneePivot?.eulerAngles.x = -leftKneeBend
        rightKneePivot?.eulerAngles.x = -rightKneeBend

        // Recompute the bob from the base height every frame.
        // This prevents accumulated vertical drift.
        let walkingOrRunning =
            motion.posture == .walking ||
            motion.posture == .running

        if walkingOrRunning {
            let bobAmplitude: Float =
                motion.posture == .running ? 0.11 : 0.07

            let bob = abs(cos(phase)) * bobAmplitude * stride

            poseNode.position = SCNVector3(
                0,
                basePoseHeight + bob,
                0
            )
        } else {
            poseNode.position = SCNVector3(
                0,
                basePoseHeight,
                0
            )
        }

        // Jump tuck.
        if motion.posture == .jumping {
            let tuck = min(1, max(0, motion.jump))

            leftHipPivot?.eulerAngles.x += 0.65 * tuck
            rightHipPivot?.eulerAngles.x += 0.65 * tuck

            leftKneePivot?.eulerAngles.x -= 1.05 * tuck
            rightKneePivot?.eulerAngles.x -= 1.05 * tuck
        }

        // Crawl arm movement.
        if motion.posture == .crawling {
            let crawl = sin(phase)

            leftArmPivot.eulerAngles.x = crawl * 0.75
            rightArmPivot.eulerAngles.x = -crawl * 0.75

            leftArmPivot.eulerAngles.z = 0.35
            rightArmPivot.eulerAngles.z = -0.35
        }
    }

    // MARK: - Materials and Geometry

    private func material(
        _ color: UIColor,
        roughness: CGFloat = 0.8,
        metallic: CGFloat = 0
    ) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metallic
        m.lightingModel = .physicallyBased
        return m
    }

    private func box(
        _ size: SCNVector3,
        color: UIColor,
        bevel: CGFloat = 0.04
    ) -> SCNNode {
        let geometry = SCNBox(
            width: CGFloat(size.x),
            height: CGFloat(size.y),
            length: CGFloat(size.z),
            chamferRadius: bevel
        )

        geometry.materials = [material(color)]
        return SCNNode(geometry: geometry)
    }

    private func sphere(
        _ radius: CGFloat,
        color: UIColor
    ) -> SCNNode {
        let geometry = SCNSphere(radius: radius)
        geometry.segmentCount = 24
        geometry.materials = [material(color)]
        return SCNNode(geometry: geometry)
    }

    private func cylinder(
        radius: CGFloat,
        height: CGFloat,
        color: UIColor
    ) -> SCNNode {
        let geometry = SCNCylinder(
            radius: radius,
            height: height
        )

        geometry.radialSegmentCount = 24
        geometry.materials = [
            material(color, roughness: 0.3, metallic: 0.8)
        ]

        return SCNNode(geometry: geometry)
    }

    private func add(
        _ node: SCNNode,
        to parent: SCNNode,
        at position: SCNVector3
    ) {
        node.position = position
        parent.addChildNode(node)
    }

    private func addBox(
        _ size: SCNVector3,
        color: UIColor,
        to parent: SCNNode,
        at position: SCNVector3,
        bevel: CGFloat = 0.04
    ) {
        add(
            box(size, color: color, bevel: bevel),
            to: parent,
            at: position
        )
    }

    // MARK: - Body and Clothing

    private func buildBody() {
        addBox(
            SCNVector3(1.42, 1.30, 0.68),
            color: jacket,
            to: root,
            at: SCNVector3(0, 2.45, 0),
            bevel: 0.16
        )

        addBox(
            SCNVector3(1.78, 0.43, 0.70),
            color: jacket,
            to: root,
            at: SCNVector3(0, 2.92, 0),
            bevel: 0.16
        )

        addBox(
            SCNVector3(0.49, 0.92, 0.075),
            color: shirt,
            to: root,
            at: SCNVector3(0, 2.43, -0.365),
            bevel: 0.025
        )

        for side: Float in [-1, 1] {
            let lapel = box(
                SCNVector3(0.24, 0.70, 0.10),
                color: UIColor(
                    red: 0.22,
                    green: 0.23,
                    blue: 0.21,
                    alpha: 1
                ),
                bevel: 0.025
            )

            lapel.position = SCNVector3(
                side * 0.28,
                2.63,
                -0.42
            )

            lapel.eulerAngles.z = -side * 0.25
            root.addChildNode(lapel)
        }

        addBox(
            SCNVector3(0.57, 0.58, 0.50),
            color: skin,
            to: root,
            at: SCNVector3(0, 3.27, 0),
            bevel: 0.10
        )

        for side: Float in [-1, 1] {
            addBox(
                SCNVector3(0.09, 0.48, 0.08),
                color: skinDark,
                to: root,
                at: SCNVector3(side * 0.19, 3.27, -0.26),
                bevel: 0.035
            )
        }

        for y: Float in [2.18, 2.39, 2.60] {
            add(
                sphere(0.035, color: metal),
                to: root,
                at: SCNVector3(0, y, -0.42)
            )
        }
    }

    // MARK: - Head and Face

    private func buildHead() {
        headPivot.position = SCNVector3(0, 3.48, 0)
        root.addChildNode(headPivot)

        let head = SCNNode()
        head.position = SCNVector3(0, 0.39, 0)
        headPivot.addChildNode(head)

        addBox(
            SCNVector3(1.12, 1.24, 0.82),
            color: skin,
            to: head,
            at: SCNVector3(0, 0.15, 0),
            bevel: 0.12
        )

        addBox(
            SCNVector3(1.04, 0.35, 0.84),
            color: skinLight,
            to: head,
            at: SCNVector3(0, 0.57, -0.025),
            bevel: 0.055
        )

        addBox(
            SCNVector3(1.17, 0.27, 0.91),
            color: hair,
            to: head,
            at: SCNVector3(0, 0.88, 0.015),
            bevel: 0.045
        )

        for side: Float in [-1, 1] {
            addBox(
                SCNVector3(0.13, 0.36, 0.84),
                color: hair,
                to: head,
                at: SCNVector3(side * 0.53, 0.64, 0.02),
                bevel: 0.025
            )
        }

        for side: Float in [-1, 1] {
            let brow = box(
                SCNVector3(0.46, 0.16, 0.17),
                color: skinDark,
                bevel: 0.055
            )

            brow.position = SCNVector3(
                side * 0.255,
                0.34,
                -0.455
            )

            brow.eulerAngles.z = side * 0.08
            head.addChildNode(brow)
        }

        for side: Float in [-1, 1] {
            let socket = sphere(0.135, color: skinDark)
            socket.scale = SCNVector3(1.20, 0.85, 0.55)

            add(
                socket,
                to: head,
                at: SCNVector3(side * 0.255, 0.19, -0.432)
            )

            let eye = sphere(0.083, color: .white)
            eye.scale = SCNVector3(1.1, 0.85, 0.65)

            add(
                eye,
                to: head,
                at: SCNVector3(side * 0.255, 0.19, -0.48)
            )

            let iris = sphere(
                0.038,
                color: UIColor(
                    red: 0.23,
                    green: 0.20,
                    blue: 0.13,
                    alpha: 1
                )
            )

            iris.scale = SCNVector3(1, 1, 0.65)

            add(
                iris,
                to: head,
                at: SCNVector3(side * 0.255, 0.19, -0.526)
            )

            add(
                sphere(0.018, color: .black),
                to: head,
                at: SCNVector3(side * 0.255, 0.19, -0.545)
            )
        }

        addBox(
            SCNVector3(0.21, 0.31, 0.22),
            color: skinLight,
            to: head,
            at: SCNVector3(0, 0.055, -0.49),
            bevel: 0.07
        )

        addBox(
            SCNVector3(0.31, 0.14, 0.19),
            color: skin,
            to: head,
            at: SCNVector3(0, -0.055, -0.53),
            bevel: 0.055
        )

        for side: Float in [-1, 1] {
            let nostril = sphere(0.034, color: skinDark)
            nostril.scale = SCNVector3(1.1, 0.65, 0.4)

            add(
                nostril,
                to: head,
                at: SCNVector3(side * 0.085, -0.075, -0.63)
            )

            addBox(
                SCNVector3(0.22, 0.24, 0.12),
                color: skinLight,
                to: head,
                at: SCNVector3(side * 0.39, -0.02, -0.405),
                bevel: 0.05
            )
        }

        jawPivot.position = SCNVector3(0, -0.24, -0.15)
        head.addChildNode(jawPivot)

        addBox(
            SCNVector3(0.83, 0.38, 0.67),
            color: skin,
            to: jawPivot,
            at: SCNVector3(0, -0.12, -0.015),
            bevel: 0.09
        )

        addBox(
            SCNVector3(0.43, 0.035, 0.035),
            color: UIColor(
                red: 0.13,
                green: 0.09,
                blue: 0.075,
                alpha: 1
            ),
            to: jawPivot,
            at: SCNVector3(0, -0.045, -0.356),
            bevel: 0.008
        )

        let scar = box(
            SCNVector3(0.17, 0.035, 0.025),
            color: skinDark,
            bevel: 0.01
        )

        scar.position = SCNVector3(-0.29, 0.58, -0.453)
        scar.eulerAngles.z = -0.35
        head.addChildNode(scar)

        for side: Float in [-1, 1] {
            let bolt = cylinder(
                radius: 0.105,
                height: 0.25,
                color: metal
            )

            bolt.eulerAngles.z = .pi / 2

            add(
                bolt,
                to: root,
                at: SCNVector3(side * 0.40, 3.30, 0)
            )

            addBox(
                SCNVector3(0.10, 0.15, 0.15),
                color: .darkGray,
                to: root,
                at: SCNVector3(side * 0.54, 3.30, 0),
                bevel: 0.018
            )
        }
    }

    // MARK: - Arms and Hands

    private func buildArms() {
        for side: Float in [-1, 1] {
            let pivot = side < 0 ? leftArmPivot : rightArmPivot

            pivot.position = SCNVector3(
                side * 0.82,
                2.88,
                0
            )

            root.addChildNode(pivot)

            addBox(
                SCNVector3(0.42, 0.85, 0.52),
                color: jacket,
                to: pivot,
                at: SCNVector3(side * 0.03, -0.43, 0),
                bevel: 0.13
            )

            let elbow = SCNNode()
            elbow.position = SCNVector3(0, -0.79, 0)
            pivot.addChildNode(elbow)

            addBox(
                SCNVector3(0.38, 0.78, 0.46),
                color: jacket,
                to: elbow,
                at: SCNVector3(0, -0.39, 0),
                bevel: 0.12
            )

            addBox(
                SCNVector3(0.31, 0.34, 0.30),
                color: skin,
                to: elbow,
                at: SCNVector3(0, -0.91, -0.015),
                bevel: 0.09
            )

            for i in 0..<4 {
                addBox(
                    SCNVector3(0.065, 0.25, 0.075),
                    color: skin,
                    to: elbow,
                    at: SCNVector3(
                        -0.105 + Float(i) * 0.07,
                        -1.16,
                        -0.02
                    ),
                    bevel: 0.025
                )
            }

            let thumb = box(
                SCNVector3(0.09, 0.23, 0.09),
                color: skin,
                bevel: 0.035
            )

            thumb.position = SCNVector3(
                side * 0.20,
                -0.99,
                -0.04
            )

            thumb.eulerAngles.z = side * -0.48
            elbow.addChildNode(thumb)
        }
    }

    // MARK: - Legs and Boots

    private func buildLegs() {
        for side: Float in [-1, 1] {
            let isLeft = side < 0
            let hip = isLeft ? leftLegPivot : rightLegPivot

            hip.position = SCNVector3(
                side * 0.39,
                1.86,
                0
            )

            root.addChildNode(hip)

            if isLeft {
                leftHipPivot = hip
            } else {
                rightHipPivot = hip
            }

            addBox(
                SCNVector3(0.49, 0.88, 0.53),
                color: jacket,
                to: hip,
                at: SCNVector3(0, -0.44, 0),
                bevel: 0.09
            )

            let knee = SCNNode()
            knee.position = SCNVector3(0, -0.83, 0)
            hip.addChildNode(knee)

            if isLeft {
                leftKneePivot = knee
            } else {
                rightKneePivot = knee
            }

            addBox(
                SCNVector3(0.42, 0.75, 0.46),
                color: jacket,
                to: knee,
                at: SCNVector3(0, -0.37, 0),
                bevel: 0.075
            )

            addBox(
                SCNVector3(0.53, 0.28, 0.82),
                color: UIColor(
                    red: 0.075,
                    green: 0.07,
                    blue: 0.06,
                    alpha: 1
                ),
                to: knee,
                at: SCNVector3(0, -0.82, -0.12),
                bevel: 0.065
            )
        }
    }

    // MARK: - Upper-body Motion

    private func applyMotion(
        walkPhase: Float,
        armLift: Float,
        headTurn: Float,
        mouthOpen: Float,
        posture: FrankensteinPosture
    ) {
        let swing = sin(walkPhase)

        switch posture {
        case .standing:
            leftArmPivot.eulerAngles.x = 0
            rightArmPivot.eulerAngles.x = 0

        case .walking:
            leftArmPivot.eulerAngles.x = -swing * 0.35
            rightArmPivot.eulerAngles.x = swing * 0.35

        case .running:
            leftArmPivot.eulerAngles.x = -swing * 0.75
            rightArmPivot.eulerAngles.x = swing * 0.75

        case .jumping:
            leftArmPivot.eulerAngles.x = -1.15
            rightArmPivot.eulerAngles.x = -1.15

        case .crouching:
            leftArmPivot.eulerAngles.x = -0.45
            rightArmPivot.eulerAngles.x = -0.45

        case .crawling:
            // Crawling arm angles are set in applyGait(_:).
            break

        case .rolling:
            leftArmPivot.eulerAngles.x = -1.35
            rightArmPivot.eulerAngles.x = -1.35
        }

        if posture != .crawling {
            leftArmPivot.eulerAngles.z = armLift
            rightArmPivot.eulerAngles.z = -armLift
        }

        headPivot.eulerAngles.y = headTurn
        jawPivot.eulerAngles.x = mouthOpen
    }
}
