
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


    private let skin = UIColor(red: 0.35, green: 0.52, blue: 0.34, alpha: 1)
    private let skinLight = UIColor(red: 0.47, green: 0.61, blue: 0.42, alpha: 1)
    private let skinDark = UIColor(red: 0.19, green: 0.31, blue: 0.22, alpha: 1)
    private let hair = UIColor(red: 0.055, green: 0.065, blue: 0.06, alpha: 1)
    private let jacket = UIColor(red: 0.13, green: 0.14, blue: 0.13, alpha: 1)
    private let shirt = UIColor(red: 0.36, green: 0.35, blue: 0.30, alpha: 1)
    private let metal = UIColor(red: 0.62, green: 0.65, blue: 0.61, alpha: 1)

    // All body parts live under `poseNode`, which pivots about his chest so
    // that crouching, crawling and rolling can rotate and shrink him
    // without sinking through the floor. `root` stays at his feet; the
    // coordinator moves it and this class turns it to face his heading.
    private let poseNode = SCNNode()
    private let poseCenterHeight: Float = 2.4
    private var shownScale: Float = 1
    private var shownPitch: Float = 0
    private var wasRolling = false

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
        poseNode.pivot = SCNMatrix4MakeTranslation(
            0, poseCenterHeight, 0
        )
        poseNode.position = SCNVector3(0, poseCenterHeight, 0)

        for part in parts {
            part.removeFromParentNode()
            poseNode.addChildNode(part)
        }

        root.addChildNode(poseNode)
    }

    func applyLocomotion(_ motion: FrankensteinLocomotionOutput) {
        applyMotion(
            walkPhase: motion.walkPhase,
            armLift: motion.armLift,
            headTurn: motion.headTurn,
            mouthOpen: motion.mouthOpen
        )

        // Face the direction he is actually travelling (0 = toward -Z).
        root.eulerAngles.y = motion.heading

        // Posture. Visual approximations of the physical heights used by
        // the body: crouch 3.2, roll 1.7, crawl 1.3 (standing 4.8).
        var targetScale: Float = 1
        var targetPitch: Float = 0
        let rolling = motion.posture == .rolling

        switch motion.posture {
        case .standing:
            targetScale = 1
            targetPitch = 0

        case .crouching:
            targetScale = 0.8
            targetPitch = -0.35

        case .crawling:
            targetScale = 0.65
            targetPitch = -1.35

        case .rolling:
            targetScale = 0.32
            targetPitch = -2 * Float.pi * motion.rollProgress
        }

        shownScale += (targetScale - shownScale) * 0.25

        if rolling {
            // A somersault follows the roll's progress exactly.
            shownPitch = targetPitch
        } else {
            if wasRolling {
                // A full turn has been made; start upright again.
                shownPitch = 0
            }

            shownPitch += (targetPitch - shownPitch) * 0.25
        }

        wasRolling = rolling

        // Keep the lowest point of the body on the ground.
        let sine = abs(sin(shownPitch))
        let cosine = abs(cos(shownPitch))

        let centreY: Float = rolling
            ? shownScale * 2.5
            : shownScale * (2.33 * cosine + 0.4 * sine)

        poseNode.scale = SCNVector3(shownScale, shownScale, shownScale)
        poseNode.eulerAngles = SCNVector3(
            shownPitch, 0, motion.lean
        )
        poseNode.position = SCNVector3(0, centreY, 0)

        // Coordinated opposing leg swing.
        let phase = motion.walkPhase
        let stride = motion.stride

        leftHipPivot?.eulerAngles.x =
            Float(sin(phase) * 0.55 * stride)

        rightHipPivot?.eulerAngles.x =
            Float(-sin(phase) * 0.55 * stride)

        leftKneePivot?.eulerAngles.x =
            Float(max(0, -sin(phase)) * 0.65 * stride)

        rightKneePivot?.eulerAngles.x =
            Float(max(0, sin(phase)) * 0.65 * stride)
    }

    
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
        let geometry = SCNCylinder(radius: radius, height: height)
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
        add(box(size, color: color, bevel: bevel), to: parent, at: position)
    }

    // MARK: Body and clothing

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
                color: UIColor(red: 0.22, green: 0.23, blue: 0.21, alpha: 1),
                bevel: 0.025
            )
            lapel.position = SCNVector3(side * 0.28, 2.63, -0.42)
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
            add(sphere(0.035, color: metal), to: root,
                at: SCNVector3(0, y, -0.42))
        }
    }

    // MARK: Head and face

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

        // Flat black hair and side blocks.
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

        // Heavy brow ridges.
        for side: Float in [-1, 1] {
            let brow = box(
                SCNVector3(0.46, 0.16, 0.17),
                color: skinDark,
                bevel: 0.055
            )
            brow.position = SCNVector3(side * 0.255, 0.34, -0.455)
            brow.eulerAngles.z = side * 0.08
            head.addChildNode(brow)
        }

        // Eyes, irises and pupils.
        for side: Float in [-1, 1] {
            let socket = sphere(0.135, color: skinDark)
            socket.scale = SCNVector3(1.20, 0.85, 0.55)
            add(socket, to: head,
                at: SCNVector3(side * 0.255, 0.19, -0.432))

            let eye = sphere(0.083, color: .white)
            eye.scale = SCNVector3(1.1, 0.85, 0.65)
            add(eye, to: head,
                at: SCNVector3(side * 0.255, 0.19, -0.48))

            let iris = sphere(
                0.038,
                color: UIColor(red: 0.23, green: 0.20, blue: 0.13, alpha: 1)
            )
            iris.scale = SCNVector3(1, 1, 0.65)
            add(iris, to: head,
                at: SCNVector3(side * 0.255, 0.19, -0.526))

            add(sphere(0.018, color: .black), to: head,
                at: SCNVector3(side * 0.255, 0.19, -0.545))
        }

        // Nose bridge and broad tip.
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
            add(nostril, to: head,
                at: SCNVector3(side * 0.085, -0.075, -0.63))

            addBox(
                SCNVector3(0.22, 0.24, 0.12),
                color: skinLight,
                to: head,
                at: SCNVector3(side * 0.39, -0.02, -0.405),
                bevel: 0.05
            )
        }

        // Animated square jaw.
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
            color: UIColor(red: 0.13, green: 0.09, blue: 0.075, alpha: 1),
            to: jawPivot,
            at: SCNVector3(0, -0.045, -0.356),
            bevel: 0.008
        )

        // Forehead scar.
        let scar = box(
            SCNVector3(0.17, 0.035, 0.025),
            color: skinDark,
            bevel: 0.01
        )
        scar.position = SCNVector3(-0.29, 0.58, -0.453)
        scar.eulerAngles.z = -0.35
        head.addChildNode(scar)

        // Metal bolts on both sides of the neck.
        for side: Float in [-1, 1] {
            let bolt = cylinder(radius: 0.105, height: 0.25, color: metal)
            bolt.eulerAngles.z = .pi / 2
            add(bolt, to: root,
                at: SCNVector3(side * 0.40, 3.30, 0))

            addBox(
                SCNVector3(0.10, 0.15, 0.15),
                color: .darkGray,
                to: root,
                at: SCNVector3(side * 0.54, 3.30, 0),
                bevel: 0.018
            )
        }
    }

    // MARK: Arms and hands

    private func buildArms() {
        for side: Float in [-1, 1] {
            let pivot = side < 0 ? leftArmPivot : rightArmPivot
            pivot.position = SCNVector3(side * 0.82, 2.88, 0)
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
                    at: SCNVector3(-0.105 + Float(i) * 0.07, -1.16, -0.02),
                    bevel: 0.025
                )
            }

            let thumb = box(
                SCNVector3(0.09, 0.23, 0.09),
                color: skin,
                bevel: 0.035
            )
            thumb.position = SCNVector3(side * 0.20, -0.99, -0.04)
            thumb.eulerAngles.z = side * -0.48
            elbow.addChildNode(thumb)
        }
    }

    // MARK: Legs and boots

    private func buildLegs() {
        for side: Float in [-1, 1] {
            let pivot = side < 0 ? leftLegPivot : rightLegPivot
            pivot.position = SCNVector3(side * 0.39, 1.86, 0)
            root.addChildNode(pivot)

            addBox(
                SCNVector3(0.49, 0.88, 0.53),
                color: jacket,
                to: pivot,
                at: SCNVector3(0, -0.44, 0),
                bevel: 0.09
            )

            let knee = SCNNode()
            knee.position = SCNVector3(0, -0.83, 0)
            pivot.addChildNode(knee)

            addBox(
                SCNVector3(0.42, 0.75, 0.46),
                color: jacket,
                to: knee,
                at: SCNVector3(0, -0.37, 0),
                bevel: 0.075
            )

            addBox(
                SCNVector3(0.53, 0.28, 0.82),
                color: UIColor(red: 0.075, green: 0.07, blue: 0.06, alpha: 1),
                to: knee,
                at: SCNVector3(0, -0.82, -0.12),
                bevel: 0.065
            )
        }
    }

    // MARK: Motion controlled by CA

    func applyMotion(
        walkPhase: Float,
        armLift: Float,
        headTurn: Float,
        mouthOpen: Float
    ) {
        leftLegPivot.eulerAngles.x = sin(walkPhase) * 0.42
        rightLegPivot.eulerAngles.x = sin(walkPhase + .pi) * 0.42

        leftArmPivot.eulerAngles.x = -sin(walkPhase) * 0.28
        rightArmPivot.eulerAngles.x = -sin(walkPhase + .pi) * 0.28

        leftArmPivot.eulerAngles.z = armLift
        rightArmPivot.eulerAngles.z = -armLift

        headPivot.eulerAngles.y = headTurn
        jawPivot.eulerAngles.x = mouthOpen
    }
}

