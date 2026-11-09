import Foundation
import QuartzCore

/// Apple's designer-facing spring parameterisation (WWDC 2018, *Designing Fluid Interfaces*):
/// `response` is how quickly the value reaches its target, `dampingRatio` controls overshoot.
/// 1.0 is critically damped — graceful, non-distracting, the right default for ambient UI.
///
/// Integrated numerically each frame so the motion is always interruptible: re-targeting keeps
/// the current value *and* velocity, which is what avoids the "brick wall" on a reversal.
struct Spring {
    var response: Double
    var dampingRatio: Double

    private(set) var value: Double
    private(set) var velocity: Double = 0
    var target: Double

    /// Below this the motion is imperceptible, so the spring snaps home and stops burning frames.
    private let restThreshold = 0.0008
    private static let maxSubstep = 1.0 / 240.0

    init(value: Double, response: Double = 0.4, dampingRatio: Double = 1.0) {
        self.value = value
        self.target = value
        self.response = response
        self.dampingRatio = dampingRatio
    }

    var isAtRest: Bool {
        abs(value - target) < restThreshold && abs(velocity) < restThreshold
    }

    /// Jumps without animating — used for the first value and for Reduce Motion.
    mutating func set(_ newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
    }

    mutating func advance(to newTarget: Double, dt: Double) {
        target = newTarget
        advance(dt: dt)
    }

    mutating func advance(dt: Double) {
        guard !isAtRest else {
            value = target
            velocity = 0
            return
        }
        // Integrated in fixed sub-steps: one explicit step as long as a frame is unstable for a
        // stiff spring, and overshot the target by several times the distance — seen on screen as
        // the tiles lurching sideways and snapping back when tracking resumed after idling.
        var remaining = min(dt, 1.0 / 15.0)
        let omega = 2 * Double.pi / response
        while remaining > 0 {
            let step = min(remaining, Self.maxSubstep)
            let acceleration = -omega * omega * (value - target) - 2 * dampingRatio * omega * velocity
            velocity += acceleration * step
            value += velocity * step
            remaining -= step
        }
    }
}
