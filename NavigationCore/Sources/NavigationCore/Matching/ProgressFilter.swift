import Foundation

/// Two-state (position, speed along the route) constant-velocity Kalman filter.
/// Smooths GPS jitter in chainage and gives a stable along-route speed for thresholds and ETAs.
struct ProgressFilter: Sendable {
    private(set) var position: Double
    private(set) var speed: Double
    private(set) var time: Date
    private var p00: Double
    private var p01: Double
    private var p11: Double
    private let accelerationSigma: Double

    init(position: Double, speed: Double, positionVariance: Double, time: Date, accelerationSigma: Double = 2.5) {
        self.position = position
        self.speed = speed
        self.time = time
        self.accelerationSigma = accelerationSigma
        p00 = positionVariance
        p01 = 0
        p11 = 9   // initial speed uncertainty of 3 m/s
    }

    mutating func predict(to newTime: Date) {
        let dt = newTime.timeIntervalSince(time)
        guard dt > 0 else { return }
        position += speed * dt
        let q = accelerationSigma * accelerationSigma
        let n00 = p00 + 2 * dt * p01 + dt * dt * p11 + q * dt * dt * dt / 3
        let n01 = p01 + dt * p11 + q * dt * dt / 2
        let n11 = p11 + q * dt
        p00 = n00
        p01 = n01
        p11 = n11
        time = newTime
    }

    mutating func update(position measurement: Double, variance: Double) {
        let s = p00 + variance
        let k0 = p00 / s
        let k1 = p01 / s
        let innovation = measurement - position
        position += k0 * innovation
        speed += k1 * innovation
        let n00 = (1 - k0) * p00
        let n01 = (1 - k0) * p01
        let n11 = p11 - k1 * p01
        p00 = n00
        p01 = n01
        p11 = n11
    }

    mutating func update(speed measurement: Double, variance: Double) {
        let s = p11 + variance
        let k0 = p01 / s
        let k1 = p11 / s
        let innovation = measurement - speed
        position += k0 * innovation
        speed += k1 * innovation
        let n00 = p00 - k0 * p01
        let n01 = p01 * (1 - k1)
        let n11 = (1 - k1) * p11
        p00 = n00
        p01 = n01
        p11 = n11
    }
}
