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

    /// Love from his dog (0...100). Rises while he holds the dog.
    @Published var love: Float = 0
    
    let targetWord = "FRANKENSTEIN"
    @Published var placedLetters: [Character?] = Array(repeating: nil, count: 12)
    
    func consumeEnergy(for action: FrankensteinAction, dt: Float) {
            guard !isRecharging else { return }
             
            let costPerSecond: Float
            switch action {
            case .run: costPerSecond = 0.6 / 100.0
            case .jump, .pushObject, .liftObject, .throwObject: costPerSecond = 0.85 / 100.0
            case .walk, .stepUp, .stepDown: costPerSecond = 0.25 / 100.0
            case .crouch, .crawl, .roll: costPerSecond = 0.35 / 100.0
            case .turnLeft, .turnRight, .stepForward, .backward: costPerSecond = 0.1 / 100.0
            case .recover: costPerSecond = 0.05 / 100.0
            case .placeObject: costPerSecond = 0.2 / 100.0
            case .kickObject: costPerSecond = 0.85
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
        love = 0
        placedLetters = Array(repeating: nil, count: 12)
    }
}

