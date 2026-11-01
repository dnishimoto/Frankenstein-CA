//
//  File.swift
//  Frankenstein CATests
//
//  Created by David Nishimoto on 10/31/26.
//

import Foundation

import XCTest
import SceneKit
@testable import Frankenstein_CA // Replace with your actual module/app name

final class FrankensteinLetterMissionTests: XCTestCase {

    var scene: SCNScene!
    var characterNode: SCNNode!
    var locomotion: FrankensteinLocomotion!
    var energyManager: FrankensteinEnergyManager!
    var coordinator: Coordinator!
    var ca: FrankensteinCA!

    override func setUpWithError() throws {
        try super.setUpWithError()
        
        // Initialize scene and components
        scene = SCNScene()
        characterNode = SCNNode()
        characterNode.name = "FrankensteinCharacter"
        scene.rootNode.addChildNode(characterNode)
        
        locomotion = FrankensteinLocomotion()
        energyManager = FrankensteinEnergyManager()
        ca = FrankensteinCA()
        
        coordinator = Coordinator(
            scene: scene,
            characterNode: characterNode,
            locomotion: locomotion,
            energyManager: energyManager
        )
        coordinator.attach(scene: scene, characterNode: characterNode)
        coordinator.attachCA(ca)
    }

    override func tearDownWithError() throws {
        scene = nil
        characterNode = nil
        locomotion = nil
        energyManager = nil
        coordinator = nil
        ca = nil
        try super.tearDownWithError()
    }

    func testLetterFPickupAndDeliveryWorkflow() throws {
        // 1. Verify letter "F" block and slot exist in the scene
        let letterBlock = scene.rootNode.childNode(withName: "LetterBlock_F_0", recursively: true)
        let letterSlot = scene.rootNode.childNode(withName: "LetterSlot_0_F", recursively: true)
        
        XCTAssertNotNil(letterBlock, "Letter 'F' block should be spawned in the scene[cite: 32].")
        XCTAssertNotNil(letterSlot, "Letter 'F' slot placeholder should be spawned in the scene[cite: 32].")
        
        guard let block = letterBlock, let slot = letterSlot else { return }

        // 2. Position Frankenstein right next to the 'F' block to test pickup reach
        let blockPos = block.presentation.worldPosition
        characterNode.position = SCNVector3(blockPos.x, blockPos.y, blockPos.z + 0.8)
        coordinator.renderer(SCNSceneRenderer?.none!, updateAtTime: 1.0)

        // 3. Test Pickup Mechanism
        let pickupSuccess = coordinator.attemptPickup()
        XCTAssertTrue(pickupSuccess, "Frankenstein should successfully pick up the letter 'F' block when in reach[cite: 32].")
        XCTAssertNotNil(block.parent?.name?.contains("Hand") == true, "The block should now be parented to Frankenstein's hand[cite: 32].")

        // 4. Position Frankenstein next to the target slot ("LetterSlot_0_F")
        let slotPos = slot.presentation.worldPosition
        characterNode.position = SCNVector3(slotPos.x, slotPos.y, slotPos.z + 0.8)
        coordinator.renderer(SCNSceneRenderer?.none!, updateAtTime: 2.0)

        // 5. Test Placement / Drop Mechanism
        let placeSuccess = coordinator.placeCarriedObjectAhead()
        XCTAssertTrue(placeSuccess, "Frankenstein should successfully place/drop the letter block[cite: 32].")

        // 6. Simulate update loop to let the mission checker register the placement onto the slot
        coordinator.renderer(SCNSceneRenderer?.none!, updateAtTime: 2.5)

        // 7. Verify that the letter 'F' has been registered as placed in the energy manager panel
        XCTAssertEqual(energyManager.placedLetters[0], "F", "The first slot in FRANKENSTEIN should now hold the letter 'F'[cite: 32, 39].")
    }
}
