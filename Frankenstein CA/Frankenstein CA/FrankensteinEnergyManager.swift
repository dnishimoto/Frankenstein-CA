//
//  File.swift
//  Frankenstein CA
//
//  Created by David Nishimoto on 10/31/26.
//

import Foundation
import Combine

final class FrankensteinEnergyManager: ObservableObject {
    @Published var powerLevel: Float = 100.0
    @Published var maxPower: Float = 100.0
    @Published var isRecharging: Bool = false
    
    let targetWord = "FRANKENSTEIN"
    @Published var placedLetters: [Character?] = Array(repeating: nil, count: 12)
    
    func consumeEnergy(for action: FrankensteinAction, dt: Float) {
        guard !isRecharging else { return }
        
        let costPerSecond: Float
        switch action {
        case .run: costPerSecond = 6.0
        case .jump, .pushObject, .liftObject, .throwObject: costPerSecond = 8.5
        case .walk, .stepUp, .stepDown: costPerSecond = 2.5
        case .crouch, .crawl, .roll: costPerSecond = 3.5
        case .turnLeft, .turnRight, .stepForward, .backward: costPerSecond = 1.0
        case .recover: costPerSecond = 0.5
        case .placeObject: costPerSecond = 2.0
        }
        
        powerLevel = max(0.0, powerLevel - (costPerSecond * dt))
    }
    
    func recharge(dt: Float) {
        isRecharging = true
        powerLevel = min(maxPower, powerLevel + (30.0 * dt))
    }
    
    func reset() {
        powerLevel = 100.0
        isRecharging = false
        placedLetters = Array(repeating: nil, count: 12)
    }
}


