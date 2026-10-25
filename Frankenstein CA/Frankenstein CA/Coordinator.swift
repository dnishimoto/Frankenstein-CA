
import Foundation
import SceneKit

final class Coordinator: NSObject, SCNSceneRendererDelegate {

    let character: FrankensteinCharacter
    let ca: FrankensteinCA

    var onStats: ((Int, Int) -> Void)?

    private var lastUpdateTime: TimeInterval = 0

    init(
        character: FrankensteinCharacter,
        ca: FrankensteinCA,
        onStats: ((Int, Int) -> Void)? = nil
    ) {
        self.character = character
        self.ca = ca
        self.onStats = onStats

        super.init()
    }


    func renderer(
        _ renderer: SCNSceneRenderer,
        updateAtTime time: TimeInterval
    ) {
        let deltaTime: Float

        if lastUpdateTime == 0 {
            deltaTime = 1.0 / 60.0
        } else {
            deltaTime = Float(
                min(time - lastUpdateTime, 0.05)
            )
        }

        lastUpdateTime = time

        // Advance the cellular automaton.
        let caMotion: FrankensteinMotion =
            ca.step(deltaTime: deltaTime)

        // Publish simulation statistics.
        onStats?(
            ca.generationCount,
            ca.liveCellCount
        )

        // Do not pass FrankensteinMotion directly to
        // applyLocomotion(_:), which expects FrankensteinLocomotionOutput.
        //
        // Convert caMotion into a FrankensteinLocomotionOutput
        // using the actual properties defined in your project,
        // then pass that output to character.applyLocomotion(_:).
    }


    func resetCA() {
        ca.reset()
        lastUpdateTime = 0
    }
}
