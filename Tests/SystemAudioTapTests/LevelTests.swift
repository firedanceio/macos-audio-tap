// Copyright 2026 Firedance Multimedia LLC
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import SystemAudioTap

final class LevelTests: XCTestCase {
    private func level(_ samples: [Float32]) -> Double {
        samples.withUnsafeBufferPointer { SystemAudioTap.dbfs(of: $0) }
    }

    func testFullScaleSquareWaveIsZeroDBFS() {
        XCTAssertEqual(level([1, -1, 1, -1]), 0, accuracy: 1e-9)
    }

    func testHalfScaleIsMinusSixDBFS() {
        XCTAssertEqual(level([0.5, -0.5, 0.5, -0.5]), 20 * log10(0.5), accuracy: 1e-9)
    }

    func testFullScaleSineIsMinusThreeDBFS() {
        let sine = (0..<48_000).map { Float32(sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        XCTAssertEqual(level(sine), -3.0103, accuracy: 0.01)
    }

    func testSilenceAndEmptyAreMinusInfinity() {
        XCTAssertEqual(level([0, 0, 0]), -.infinity)
        XCTAssertEqual(level([]), -.infinity)
    }
}
