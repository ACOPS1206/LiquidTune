// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

struct RibbonBandFrame {
    let time: Double
    let low: Float
    let mid: Float
    let high: Float
    let epoch: Int
}

// The audio tap is the only writer. The player UI is the only reader.
// Release/acquire publishes each slot before the reader can touch it.
final class RibbonBandBuffer: @unchecked Sendable {
    private static let capacity = 512
    private let slots: UnsafeMutablePointer<RibbonBandFrame>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let captureEpoch = Atomic<Int>(0)

    init() {
        slots = .allocate(capacity: Self.capacity)
        slots.initialize(repeating: RibbonBandFrame(time: -1, low: 0, mid: 0, high: 0, epoch: 0),
                         count: Self.capacity)
    }

    deinit {
        slots.deinitialize(count: Self.capacity)
        slots.deallocate()
    }

    var epoch: Int { captureEpoch.load(ordering: .acquiring) }

    @MainActor
    func setEnabled(_ enabled: Bool) {
        let current = epoch
        guard enabled != (current > 0) else { return }
        let next = abs(current) + 1
        captureEpoch.store(enabled ? next : -next, ordering: .releasing)
        consumed.store(written.load(ordering: .acquiring), ordering: .releasing)
    }

    func append(_ frame: RibbonBandFrame) {
        let index = written.load(ordering: .relaxed)
        guard index - consumed.load(ordering: .acquiring) < Self.capacity else { return }
        slots[index % Self.capacity] = frame
        written.store(index + 1, ordering: .releasing)
    }

    @MainActor
    func drain(at seconds: Double) -> [[Float]] {
        let end = written.load(ordering: .acquiring)
        var index = consumed.load(ordering: .relaxed)
        guard index < end else { return [] }
        let epoch = self.epoch
        var frames: [[Float]] = []
        while index < end, frames.count < 12 {
            let frame = slots[index % Self.capacity]
            if frame.epoch == epoch {
                // AVPlayer can render a block ahead of the playhead.
                if frame.time >= 0, frame.time > seconds + 0.012 { break }
                if frame.time < 0 || frame.time >= seconds - 0.20 {
                    frames.append([frame.low, frame.mid, frame.high])
                }
            }
            index += 1
        }
        consumed.store(index, ordering: .releasing)
        return frames
    }
}

struct RibbonBandMeter {
    // Match Ribbon v10: 150 Hz and 2.4 kHz one-pole filters with per-channel RMS.
    private struct Channel {
        var lowPass: Float = 0
        var midPass: Float = 0
        var lowEnergy: Float = 0
        var midEnergy: Float = 0
        var highEnergy: Float = 0

        mutating func record(_ input: Float, lowFactor: Float, midFactor: Float) {
            let sample = input.isFinite ? input : 0
            lowPass += (sample - lowPass) * lowFactor
            midPass += (sample - midPass) * midFactor
            let mid = midPass - lowPass
            let high = sample - midPass
            lowEnergy += lowPass * lowPass
            midEnergy += mid * mid
            highEnergy += high * high
        }

        mutating func clearEnergy() {
            lowEnergy = 0
            midEnergy = 0
            highEnergy = 0
        }
    }

    private var left = Channel()
    private var right = Channel()
    private var epoch = 0
    private var count = 0
    private let size: Int
    private let lowFactor: Float
    private let midFactor: Float

    init(rate: Double) {
        size = max(1, Int((rate / 100).rounded()))
        lowFactor = Float(1 - exp(-2 * Double.pi * 150 / rate))
        midFactor = Float(1 - exp(-2 * Double.pi * 2_400 / rate))
    }

    mutating func begin(epoch: Int) {
        guard self.epoch != epoch else { return }
        self.epoch = epoch
        left = Channel()
        right = Channel()
        count = 0
    }

    mutating func record(_ l: Float, _ r: Float, time: Double, into output: RibbonBandBuffer) {
        left.record(l, lowFactor: lowFactor, midFactor: midFactor)
        right.record(r, lowFactor: lowFactor, midFactor: midFactor)
        count += 1
        guard count == size else { return }

        let n = Float(size)
        output.append(RibbonBandFrame(
            time: time,
            low: ((left.lowEnergy / n).squareRoot() + (right.lowEnergy / n).squareRoot()) * 0.5,
            mid: ((left.midEnergy / n).squareRoot() + (right.midEnergy / n).squareRoot()) * 0.5,
            high: ((left.highEnergy / n).squareRoot() + (right.highEnergy / n).squareRoot()) * 0.5,
            epoch: epoch
        ))
        count = 0
        left.clearEnergy()
        right.clearEnergy()
    }
}
