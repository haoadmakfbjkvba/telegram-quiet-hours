import Foundation
import UIKit
import Display

/// Keyframes that start after `delay` and hold their first value until then and their last one after.
public func quietHoursAddKeyframes(_ layer: CALayer, keyPath: String, values: [Any], keyTimes: [NSNumber], duration: Double, delay: Double, timing: CAMediaTimingFunctionName = .easeInEaseOut) {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = values
    animation.keyTimes = keyTimes
    animation.duration = duration
    animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
    animation.fillMode = .both
    animation.isRemovedOnCompletion = false
    animation.timingFunction = CAMediaTimingFunction(name: timing)
    layer.add(animation, forKey: keyPath)
}

/// A message has just gone without sound: a soft ring closes in on its moon (the sound folding away) and three small
/// sparkles drift out of it and fade, as on a quiet night. Drawn over `view` around `point`, then removed.
public func quietHoursPlayHush(in view: UIView, at point: CGPoint, color: UIColor, delay: Double = 0.3) {
    guard !UIAccessibility.isReduceMotionEnabled else {
        return
    }
    let container = UIView(frame: CGRect(origin: CGPoint(), size: CGSize(width: 1.0, height: 1.0)))
    container.isUserInteractionEnabled = false
    container.center = point
    view.addSubview(container)

    // Two rings close in on the moon, one after the other.
    for (index, radius) in [CGFloat(22.0), 15.0].enumerated() {
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(arcCenter: CGPoint(), radius: radius, startAngle: 0.0, endAngle: .pi * 2.0, clockwise: true).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 1.2
        ring.opacity = 0.0
        container.layer.addSublayer(ring)
        let ringDelay = delay + Double(index) * 0.12
        quietHoursAddKeyframes(ring, keyPath: "opacity", values: [0.0, 0.55, 0.0], keyTimes: [0.0, 0.3, 1.0], duration: 0.55, delay: ringDelay, timing: .easeOut)
        quietHoursAddKeyframes(ring, keyPath: "transform.scale", values: [1.0, 0.15], keyTimes: [0.0, 1.0], duration: 0.55, delay: ringDelay, timing: .easeIn)
    }

    // Three sparkles drift up and away.
    let sparkles: [(angle: CGFloat, distance: CGFloat, size: CGFloat)] = [(-2.3, 20.0, 7.0), (-1.35, 24.0, 5.5), (-0.55, 18.0, 6.0)]
    for (index, sparkle) in sparkles.enumerated() {
        let layer = CAShapeLayer()
        let rect = CGRect(x: -sparkle.size * 0.5, y: -sparkle.size * 0.5, width: sparkle.size, height: sparkle.size)
        layer.path = quietHoursSparklePath(in: rect).cgPath
        layer.fillColor = color.cgColor
        layer.opacity = 0.0
        container.layer.addSublayer(layer)
        let sparkleDelay = delay + 0.45 + Double(index) * 0.08
        let target = CGPoint(x: cos(sparkle.angle) * sparkle.distance, y: sin(sparkle.angle) * sparkle.distance)
        quietHoursAddKeyframes(layer, keyPath: "opacity", values: [0.0, 1.0, 1.0, 0.0], keyTimes: [0.0, 0.2, 0.6, 1.0], duration: 0.9, delay: sparkleDelay)
        quietHoursAddKeyframes(layer, keyPath: "position", values: [NSValue(cgPoint: CGPoint()), NSValue(cgPoint: target)], keyTimes: [0.0, 1.0], duration: 0.9, delay: sparkleDelay, timing: .easeOut)
        quietHoursAddKeyframes(layer, keyPath: "transform.scale", values: [0.2, 1.2, 0.9, 0.5], keyTimes: [0.0, 0.3, 0.7, 1.0], duration: 0.9, delay: sparkleDelay)
        quietHoursAddKeyframes(layer, keyPath: "transform.rotation.z", values: [-0.8, 0.4], keyTimes: [0.0, 1.0], duration: 0.9, delay: sparkleDelay, timing: .easeOut)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.6, execute: { [weak container] in
        container?.removeFromSuperview()
    })
}
