//
//  ZPasses_Tests.swift
//  StratumCAM
//

import Testing
@testable import StratumCAM

// Covers `calculateZPasses`: exact pass counts for evenly and unevenly divisible
// depth/stepdown pairs, plus the two single-pass edge cases.

struct ZPasses_Tests {

    @Test("An evenly divisible depth produces exactly the right pass count, no extra pass")
    func testEvenDivisionProducesExactPassCount() {
        let passes = EngineTools.calculateZPasses(targetDepth: -1.0, stepdown: 0.1)
        #expect(passes.count == 10, "Test Failed: expected exactly 10 passes, got \(passes.count)")
        #expect(passes.last == -1.0, "Test Failed: final pass should land exactly on target depth")
    }

    @Test("An unevenly divisible depth rounds up and still ends exactly on target")
    func testUnevenDivisionRoundsUpAndEndsAtTarget() {
        let passes = EngineTools.calculateZPasses(targetDepth: -1.0, stepdown: 0.3)
        // 1.0 / 0.3 -> 3.33... -> rounds up to 4 passes (0.3, 0.6, 0.9, 1.0).
        #expect(passes.count == 4, "Test Failed: expected 4 passes, got \(passes.count)")
        #expect(passes.last == -1.0, "Test Failed: final pass should land exactly on target depth")

        // Depths should be strictly increasing in magnitude, no duplicate/overshoot pass.
        for i in 1..<passes.count {
            #expect(passes[i] < passes[i - 1], "Test Failed: passes should get monotonically deeper")
        }
    }

    @Test("A stepdown larger than the target depth produces a single pass")
    func testStepdownLargerThanTargetProducesSinglePass() {
        let passes = EngineTools.calculateZPasses(targetDepth: -1.0, stepdown: 5.0)
        #expect(passes == [-1.0], "Test Failed: expected a single pass at full target depth")
    }

    @Test("A zero stepdown produces a single pass at full target depth")
    func testZeroStepdownProducesSinglePass() {
        let passes = EngineTools.calculateZPasses(targetDepth: -2.0, stepdown: 0.0)
        #expect(passes == [-2.0], "Test Failed: expected a single pass at full target depth")
    }

    @Test("A remainder smaller than stepdown is absorbed into a shorter final pass")
    func testRemainderIsAbsorbedIntoFinalPass() {
        let passes = EngineTools.calculateZPasses(targetDepth: -1.05, stepdown: 0.1)

        // 10 full 0.1mm passes, then a final 0.05mm pass to land exactly on -1.05 --
        // not 11 full-depth passes, and not stopping short at -1.0.
        #expect(passes.count == 11, "Test Failed: expected 11 passes, got \(passes.count)")
        #expect(passes.last == -1.05, "Test Failed: final pass must land exactly on target depth")

        // The final step should be smaller than stepdown (the leftover remainder),
        // not another full 0.1mm step.
        let finalStepSize = abs(passes[10] - passes[9])
        #expect(abs(finalStepSize - 0.05) < 1e-9, "Test Failed: final step should be the 0.05mm remainder, got \(finalStepSize)")

        // Every pass up to the second-to-last should be a full, monotonically deeper 0.1mm step.
        for i in 1..<(passes.count - 1) {
            #expect(abs((passes[i] - passes[i - 1]) - (-0.1)) < 1e-9, "Test Failed: intermediate step \(i) should be a full 0.1mm pass")
        }
    }
}
