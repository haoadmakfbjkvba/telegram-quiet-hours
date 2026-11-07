import Foundation
import UIKit
import Display

/// The colors of the night: an indigo sky, darker at the bottom.
public enum QuietHoursColors {
    public static let top = UIColor(rgb: 0x6F6CF0)
    public static let middle = UIColor(rgb: 0x5E5CE6)
    public static let bottom = UIColor(rgb: 0x4644C9)
    public static let deep = UIColor(rgb: 0x2E2D8F)
    /// The morning: a warm sun.
    public static let sun = UIColor(rgb: 0xFFB01F)
    /// The sun on a light background (a deeper amber, so that it stands out from white as much as it should: 3.7:1).
    public static let sunOnLight = UIColor(rgb: 0xC46F00)
}

// MARK: - Shapes

/// A crescent moon in `rect`: a disc with a second disc taken out of its upper right, lit on the lower left.
public func quietHoursMoonPath(in rect: CGRect) -> UIBezierPath {
    let radius = min(rect.width, rect.height) * 0.5
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let cutRadius = radius * 0.86
    let cutCenter = CGPoint(x: center.x + radius * 0.52, y: center.y - radius * 0.42)
    // The two circles meet at two points; the crescent is the outer circle's arc outside the cut and the cut's arc inside it.
    let dx = cutCenter.x - center.x
    let dy = cutCenter.y - center.y
    let distance = sqrt(dx * dx + dy * dy)
    let a = (radius * radius - cutRadius * cutRadius + distance * distance) / (2.0 * distance)
    let h = sqrt(max(0.0, radius * radius - a * a))
    let base = CGPoint(x: center.x + a * dx / distance, y: center.y + a * dy / distance)
    let p1 = CGPoint(x: base.x + h * dy / distance, y: base.y - h * dx / distance)
    let p2 = CGPoint(x: base.x - h * dy / distance, y: base.y + h * dx / distance)
    let outerStart = atan2(p1.y - center.y, p1.x - center.x)
    let outerEnd = atan2(p2.y - center.y, p2.x - center.x)
    let innerStart = atan2(p2.y - cutCenter.y, p2.x - cutCenter.x)
    let innerEnd = atan2(p1.y - cutCenter.y, p1.x - cutCenter.x)
    let path = UIBezierPath()
    path.move(to: p1)
    // The long way round the disc (through its lit lower left), then back along the cut.
    path.addArc(withCenter: center, radius: radius, startAngle: outerStart, endAngle: outerEnd, clockwise: false)
    path.addArc(withCenter: cutCenter, radius: cutRadius, startAngle: innerStart, endAngle: innerEnd, clockwise: true)
    path.close()
    return path
}

/// A four-pointed sparkle in `rect`.
public func quietHoursSparklePath(in rect: CGRect) -> UIBezierPath {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let outer = min(rect.width, rect.height) * 0.5
    let inner = outer * 0.26
    let path = UIBezierPath()
    for i in 0 ..< 8 {
        let angle = CGFloat(i) * .pi / 4.0 - .pi / 2.0
        let r = i % 2 == 0 ? outer : inner
        let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        if i == 0 {
            path.move(to: point)
        } else {
            path.addLine(to: point)
        }
    }
    path.close()
    return path
}

/// A sun in `rect`: a disc and eight short rays.
public func quietHoursDrawSun(context: CGContext, rect: CGRect, color: UIColor) {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let size = min(rect.width, rect.height)
    context.setFillColor(color.cgColor)
    context.setStrokeColor(color.cgColor)
    let discRadius = size * 0.24
    context.fillEllipse(in: CGRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2.0, height: discRadius * 2.0))
    context.setLineCap(.round)
    context.setLineWidth(max(1.0, size * 0.1))
    for i in 0 ..< 8 {
        let angle = CGFloat(i) * .pi / 4.0
        let from = size * 0.36
        let to = size * 0.47
        context.move(to: CGPoint(x: center.x + cos(angle) * from, y: center.y + sin(angle) * from))
        context.addLine(to: CGPoint(x: center.x + cos(angle) * to, y: center.y + sin(angle) * to))
    }
    context.strokePath()
}

// MARK: - Views

/// A crescent moon with two sparkles beside it. It can come in (the moon swings in, the sparkles pop one after another)
/// and the sparkles can twinkle for a while.
public final class QuietHoursMoonView: UIView {
    private let moonLayer = CAShapeLayer()
    private let sparkleLayers: [CAShapeLayer] = [CAShapeLayer(), CAShapeLayer()]
    public var showsSparkles = true {
        didSet {
            self.setNeedsLayout()
        }
    }

    public var color: UIColor = .white {
        didSet {
            self.moonLayer.fillColor = self.color.cgColor
            for layer in self.sparkleLayers {
                layer.fillColor = self.color.cgColor
            }
        }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.layer.addSublayer(self.moonLayer)
        for layer in self.sparkleLayers {
            self.layer.addSublayer(layer)
        }
        // (A property observer does not run in the initializer.)
        self.moonLayer.fillColor = UIColor.white.cgColor
        for layer in self.sparkleLayers {
            layer.fillColor = UIColor.white.cgColor
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        guard size.width > 0.0 else {
            return
        }
        let moonSize = size.width * (self.showsSparkles ? 0.74 : 1.0)
        let moonFrame = CGRect(x: 0.0, y: size.height - moonSize, width: moonSize, height: moonSize)
        self.moonLayer.frame = moonFrame
        self.moonLayer.path = quietHoursMoonPath(in: CGRect(origin: CGPoint(), size: moonFrame.size)).cgPath
        let sparkleFrames = [
            CGRect(x: size.width * 0.66, y: 0.0, width: size.width * 0.3, height: size.width * 0.3),
            CGRect(x: size.width * 0.82, y: size.width * 0.34, width: size.width * 0.18, height: size.width * 0.18)
        ]
        for (layer, frame) in zip(self.sparkleLayers, sparkleFrames) {
            layer.frame = frame
            layer.path = quietHoursSparklePath(in: CGRect(origin: CGPoint(), size: frame.size)).cgPath
            layer.isHidden = !self.showsSparkles
        }
    }

    /// The moon swings in from below the horizon and the sparkles light up after it.
    public func animateIn(delay: Double = 0.0) {
        self.layoutIfNeeded()
        let moon = self.moonLayer
        moon.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: delay)
        moon.animateSpring(from: 0.2 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.7, delay: delay, damping: 60.0)
        moon.animateSpring(from: -0.9 as NSNumber, to: 0.0 as NSNumber, keyPath: "transform.rotation.z", duration: 0.8, delay: delay, damping: 70.0)
        for (index, layer) in self.sparkleLayers.enumerated() where !layer.isHidden {
            let sparkleDelay = delay + 0.25 + Double(index) * 0.12
            layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: sparkleDelay)
            layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.55, delay: sparkleDelay, damping: 50.0)
            layer.animateSpring(from: -1.2 as NSNumber, to: 0.0 as NSNumber, keyPath: "transform.rotation.z", duration: 0.6, delay: sparkleDelay, damping: 60.0)
        }
    }

    /// The sparkles twinkle `count` times, one after the other.
    public func twinkle(delay: Double = 0.0, count: Int = 2) {
        for (index, layer) in self.sparkleLayers.enumerated() where !layer.isHidden {
            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
            animation.values = [1.0, 0.45, 1.15, 1.0].map { $0 as NSNumber }
            animation.keyTimes = [0.0, 0.35, 0.7, 1.0].map { $0 as NSNumber }
            animation.duration = 0.7
            animation.repeatCount = Float(count)
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay + Double(index) * 0.3
            animation.fillMode = .backwards
            layer.add(animation, forKey: "twinkle")
        }
    }

    /// A gentle sway, as if the moon were hanging in the sky.
    public func sway(delay: Double = 0.0) {
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = [0.0, -0.16, 0.08, 0.0].map { $0 as NSNumber }
        animation.keyTimes = [0.0, 0.35, 0.7, 1.0].map { $0 as NSNumber }
        animation.duration = 0.9
        animation.beginTime = self.moonLayer.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.fillMode = .backwards
        self.moonLayer.add(animation, forKey: "sway")
    }
}

/// The night sky in a rounded square or a circle, with the moon on it: the icon of quiet hours.
public final class QuietHoursSkyIconView: UIView {
    private let gradientLayer = CAGradientLayer()
    public let moonView = QuietHoursMoonView()
    public var isCircle = false {
        didSet {
            self.setNeedsLayout()
        }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.gradientLayer.colors = [QuietHoursColors.top.cgColor, QuietHoursColors.bottom.cgColor]
        self.gradientLayer.startPoint = CGPoint(x: 0.2, y: 0.0)
        self.gradientLayer.endPoint = CGPoint(x: 0.8, y: 1.0)
        self.layer.addSublayer(self.gradientLayer)
        self.addSubview(self.moonView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        self.gradientLayer.frame = self.bounds
        self.gradientLayer.cornerRadius = self.isCircle ? size.height * 0.5 : size.height * (8.0 / 30.0)
        if #available(iOS 13.0, *) {
            self.gradientLayer.cornerCurve = self.isCircle ? .circular : .continuous
        }
        let moonSize = floor(size.width * 0.62)
        self.moonView.frame = CGRect(x: floor((size.width - moonSize) * 0.5) + 1.0, y: floor((size.height - moonSize) * 0.5) - 1.0, width: moonSize, height: moonSize)
    }

    /// Morning colors (a warm sky) or night ones.
    public func setMorning(_ isMorning: Bool, animated: Bool) {
        let colors = isMorning ? [UIColor(rgb: 0xFFC94D).cgColor, UIColor(rgb: 0xFF9500).cgColor] : [QuietHoursColors.top.cgColor, QuietHoursColors.bottom.cgColor]
        let previous = self.gradientLayer.colors
        self.gradientLayer.colors = colors
        if animated, let previous {
            self.gradientLayer.animate(from: previous as NSArray, to: colors as NSArray, keyPath: "colors", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, duration: 0.6)
        }
    }

    /// The sky lights up and the moon comes in.
    public func animateIn(delay: Double = 0.0) {
        self.gradientLayer.animateSpring(from: 0.5 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: delay, damping: 60.0)
        self.gradientLayer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: delay)
        self.moonView.animateIn(delay: delay + 0.08)
    }
}
