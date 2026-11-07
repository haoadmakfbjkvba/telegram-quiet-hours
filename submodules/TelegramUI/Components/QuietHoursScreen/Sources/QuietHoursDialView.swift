import Foundation
import UIKit
import Display
import TelegramPresentationData
import TelegramStringFormatting
import QuietHours
import TextFormat

/// A handle of the dial for VoiceOver: swipe up or down to move it by a quarter of an hour.
private final class QuietHoursDialHandleView: UIView {
    var increment: (() -> Void)?
    var decrement: (() -> Void)?

    override func accessibilityIncrement() {
        self.increment?()
    }

    override func accessibilityDecrement() {
        self.decrement?()
    }
}

/// A 24-hour dial: the quiet hours are an arc from a moon (when they start) to a sun (when they end). Either end can be
/// dragged round, or the whole arc, in steps of a quarter of an hour.
final class QuietHoursDialView: UIView, UIGestureRecognizerDelegate {
    static let step = 15

    private let trackLayer = CAShapeLayer()
    private let ticksLayer = CAShapeLayer()
    private var hourLabels: [UILabel] = []
    private let arcLayer = CAShapeLayer()
    private let startHandle = QuietHoursDialHandleView()
    private let endHandle = QuietHoursDialHandleView()
    private let startGlyph = UIImageView()
    private let endGlyph = UIImageView()
    private let durationLabel = UILabel()
    private let durationCaption = UILabel()
    private var panRecognizer: UIPanGestureRecognizer?

    private(set) var startMinute = 23 * 60
    private(set) var endMinute = 8 * 60
    /// The hours were moved by hand.
    var changed: ((Int, Int) -> Void)?

    private var theme: PresentationTheme?
    private var strings: PresentationStrings?
    private var dateTimeFormat: PresentationDateTimeFormat?
    private let haptic = UISelectionFeedbackGenerator()

    private enum Drag {
        case start
        case end
        case both(startOffset: Int, grabMinute: Int)
    }
    private var drag: Drag?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.trackLayer.fillColor = UIColor.clear.cgColor
        self.layer.addSublayer(self.trackLayer)
        self.ticksLayer.fillColor = UIColor.clear.cgColor
        self.ticksLayer.lineCap = .round
        self.layer.addSublayer(self.ticksLayer)
        for _ in 0 ..< 4 {
            let label = UILabel()
            label.textAlignment = .center
            self.hourLabels.append(label)
            self.addSubview(label)
        }
        self.arcLayer.fillColor = UIColor.clear.cgColor
        self.arcLayer.lineCap = .butt
        self.layer.addSublayer(self.arcLayer)
        for (handle, glyph) in [(self.startHandle, self.startGlyph), (self.endHandle, self.endGlyph)] {
            handle.isUserInteractionEnabled = false
            handle.layer.shadowColor = UIColor.black.cgColor
            handle.layer.shadowOpacity = 0.18
            handle.layer.shadowRadius = 3.0
            handle.layer.shadowOffset = CGSize(width: 0.0, height: 1.0)
            glyph.contentMode = .center
            handle.addSubview(glyph)
            self.addSubview(handle)
        }
        self.durationLabel.textAlignment = .center
        self.addSubview(self.durationLabel)
        self.durationCaption.textAlignment = .center
        self.addSubview(self.durationCaption)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.panned(_:)))
        pan.delegate = self
        self.addGestureRecognizer(pan)
        self.panRecognizer = pan

        self.isAccessibilityElement = false
        self.startHandle.isAccessibilityElement = true
        self.startHandle.accessibilityTraits = [.adjustable]
        self.endHandle.isAccessibilityElement = true
        self.endHandle.accessibilityTraits = [.adjustable]
        self.startHandle.increment = { [weak self] in
            self?.adjust(start: true, by: QuietHoursDialView.step)
        }
        self.startHandle.decrement = { [weak self] in
            self?.adjust(start: true, by: -QuietHoursDialView.step)
        }
        self.endHandle.increment = { [weak self] in
            self?.adjust(start: false, by: QuietHoursDialView.step)
        }
        self.endHandle.decrement = { [weak self] in
            self?.adjust(start: false, by: -QuietHoursDialView.step)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Geometry

    private var center_: CGPoint {
        return CGPoint(x: self.bounds.midX, y: self.bounds.midY)
    }

    private var ringWidth: CGFloat {
        return floor(self.bounds.width * 0.13)
    }

    private var ringRadius: CGFloat {
        return self.bounds.width * 0.5 - self.ringWidth * 0.5 - 2.0
    }

    /// 0:00 at the top, clockwise.
    private func angle(minute: Int) -> CGFloat {
        return CGFloat(minute) / CGFloat(24 * 60) * .pi * 2.0 - .pi * 0.5
    }

    private func point(minute: Int, radius: CGFloat) -> CGPoint {
        let angle = self.angle(minute: minute)
        return CGPoint(x: self.center_.x + cos(angle) * radius, y: self.center_.y + sin(angle) * radius)
    }

    private func minute(at point: CGPoint) -> Int {
        var angle = atan2(point.y - self.center_.y, point.x - self.center_.x) + .pi * 0.5
        if angle < 0.0 {
            angle += .pi * 2.0
        }
        let minute = Int(round(angle / (.pi * 2.0) * CGFloat(24 * 60) / CGFloat(QuietHoursDialView.step))) * QuietHoursDialView.step
        return minute % (24 * 60)
    }

    private static func duration(_ start: Int, _ end: Int) -> Int {
        return (end - start + 24 * 60) % (24 * 60)
    }

    // MARK: - Update

    func update(theme: PresentationTheme, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, startMinute: Int, endMinute: Int) {
        let themeChanged = self.theme !== theme
        self.theme = theme
        self.strings = strings
        self.dateTimeFormat = dateTimeFormat
        self.startMinute = startMinute
        self.endMinute = endMinute

        if themeChanged {
            let trackColor = theme.overallDarkAppearance ? UIColor(white: 1.0, alpha: 0.08) : UIColor(white: 0.0, alpha: 0.05)
            self.trackLayer.strokeColor = trackColor.cgColor
            self.ticksLayer.strokeColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.45).cgColor
            self.arcLayer.strokeColor = QuietHoursColors.middle.cgColor
            for handle in [self.startHandle, self.endHandle] {
                handle.backgroundColor = UIColor.white
            }
            self.startGlyph.image = generateImage(CGSize(width: 18.0, height: 18.0), rotatedContext: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                context.setFillColor(QuietHoursColors.middle.cgColor)
                context.addPath(quietHoursMoonPath(in: CGRect(origin: CGPoint(), size: size).insetBy(dx: 1.5, dy: 1.5)).cgPath)
                context.fillPath()
            })
            self.endGlyph.image = generateImage(CGSize(width: 20.0, height: 20.0), rotatedContext: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                quietHoursDrawSun(context: context, rect: CGRect(origin: CGPoint(), size: size), color: QuietHoursColors.sunOnLight)
            })
            let hourTexts = [0, 6, 12, 18].map { stringForShortTimestamp(hours: Int32($0), minutes: 0, dateTimeFormat: dateTimeFormat) }
            for (label, text) in zip(self.hourLabels, hourTexts) {
                label.attributedText = NSAttributedString(string: text, attributes: [.font: Font.medium(11.0), .foregroundColor: theme.list.itemSecondaryTextColor])
                label.sizeToFit()
            }
        }
        self.updateDuration()
        self.setNeedsLayout()
        self.layoutIfNeeded()
    }

    private func updateDuration() {
        guard let theme = self.theme, let strings = self.strings, let dateTimeFormat = self.dateTimeFormat else {
            return
        }
        let duration = QuietHoursDialView.duration(self.startMinute, self.endMinute)
        let hours = duration / 60
        let minutes = duration % 60
        let text = minutes == 0 ? strings.QuietHours_Hours("\(hours)").string : strings.QuietHours_HoursMinutes("\(hours)", "\(minutes)").string
        self.durationLabel.attributedText = NSAttributedString(string: text, attributes: [.font: Font.with(size: 30.0, design: .round, weight: .bold), .foregroundColor: theme.list.itemPrimaryTextColor])
        let start = stringForShortTimestamp(hours: Int32(self.startMinute / 60), minutes: Int32(self.startMinute % 60), dateTimeFormat: dateTimeFormat)
        let end = stringForShortTimestamp(hours: Int32(self.endMinute / 60), minutes: Int32(self.endMinute % 60), dateTimeFormat: dateTimeFormat)
        self.durationCaption.attributedText = NSAttributedString(string: "\(start) - \(end)", attributes: [.font: Font.regular(14.0), .foregroundColor: theme.list.itemSecondaryTextColor])
        // VoiceOver: how long and when, then the two handles (each with how long the hours now last).
        self.durationLabel.isAccessibilityElement = true
        self.durationLabel.accessibilityLabel = strings.QuietHours_Title
        self.durationLabel.accessibilityValue = "\(text), \(start) - \(end)"
        self.startHandle.accessibilityLabel = strings.QuietHours_Start
        self.startHandle.accessibilityValue = "\(start), \(text)"
        self.endHandle.accessibilityLabel = strings.QuietHours_End
        self.endHandle.accessibilityValue = "\(end), \(text)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        guard size.width > 0.0 else {
            return
        }
        let center = self.center_
        let radius = self.ringRadius
        let width = self.ringWidth
        self.trackLayer.frame = self.bounds
        self.trackLayer.lineWidth = width
        self.trackLayer.path = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0.0, endAngle: .pi * 2.0, clockwise: true).cgPath

        // A tick for every hour inside the ring, longer every six hours.
        let ticks = CGMutablePath()
        for hour in 0 ..< 24 {
            let isMajor = hour % 6 == 0
            let outer = radius - width * 0.5 - 6.0
            let inner = outer - (isMajor ? 7.0 : 4.0)
            ticks.move(to: self.point(minute: hour * 60, radius: outer))
            ticks.addLine(to: self.point(minute: hour * 60, radius: inner))
        }
        self.ticksLayer.frame = self.bounds
        self.ticksLayer.lineWidth = 1.5
        self.ticksLayer.path = ticks
        // Each hour label just inside the long ticks, its nearest edge (not its center) a few points from them, so that
        // the wide labels at the sides stay clear of the ticks as the short ones at the top and the bottom do.
        let labelEdgeRadius = radius - width * 0.5 - 6.0 - 7.0 - 4.0
        for (index, label) in self.hourLabels.enumerated() {
            let angle = self.angle(minute: index * 6 * 60)
            let extent = abs(cos(angle)) * label.bounds.width * 0.5 + abs(sin(angle)) * label.bounds.height * 0.5
            label.center = self.point(minute: index * 6 * 60, radius: labelEdgeRadius - extent)
        }

        self.arcLayer.frame = self.bounds
        self.arcLayer.lineWidth = width - 6.0
        self.arcLayer.path = self.arcPath(start: self.startMinute, end: self.endMinute).cgPath

        let handleSize = width - 8.0
        for (handle, glyph, minute) in [(self.startHandle, self.startGlyph, self.startMinute), (self.endHandle, self.endGlyph, self.endMinute)] {
            handle.bounds = CGRect(origin: CGPoint(), size: CGSize(width: handleSize, height: handleSize))
            handle.layer.cornerRadius = handleSize * 0.5
            handle.center = self.point(minute: minute, radius: radius)
            glyph.frame = handle.bounds
        }

        self.durationLabel.sizeToFit()
        self.durationCaption.sizeToFit()
        let blockHeight = self.durationLabel.bounds.height + 2.0 + self.durationCaption.bounds.height
        self.durationLabel.center = CGPoint(x: center.x, y: center.y - blockHeight * 0.5 + self.durationLabel.bounds.height * 0.5)
        self.durationCaption.center = CGPoint(x: center.x, y: self.durationLabel.frame.maxY + 2.0 + self.durationCaption.bounds.height * 0.5)
    }

    private func arcPath(start: Int, end: Int) -> UIBezierPath {
        let startAngle = self.angle(minute: start)
        var endAngle = self.angle(minute: end)
        if endAngle <= startAngle {
            endAngle += .pi * 2.0
        }
        return UIBezierPath(arcCenter: self.center_, radius: self.ringRadius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    }

    // MARK: - Dragging

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Only the dial's own drag; the scroll view around it scrolls as usual.
        guard gestureRecognizer === self.panRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let location = gestureRecognizer.location(in: self)
        let distance = hypot(location.x - self.center_.x, location.y - self.center_.y)
        // Only on the ring.
        return abs(distance - self.ringRadius) < self.ringWidth
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            let toStart = hypot(location.x - self.startHandle.center.x, location.y - self.startHandle.center.y)
            let toEnd = hypot(location.x - self.endHandle.center.x, location.y - self.endHandle.center.y)
            let grab = self.ringWidth * 0.9
            if toStart < grab && toStart <= toEnd {
                self.drag = .start
                quietHoursAnimatePop(self.startHandle.layer, from: 1.0, overshoot: 1.18, duration: 0.3)
            } else if toEnd < grab {
                self.drag = .end
                quietHoursAnimatePop(self.endHandle.layer, from: 1.0, overshoot: 1.18, duration: 0.3)
            } else {
                let grabMinute = self.minute(at: location)
                let fromStart = QuietHoursDialView.duration(self.startMinute, grabMinute)
                if fromStart <= QuietHoursDialView.duration(self.startMinute, self.endMinute) {
                    self.drag = .both(startOffset: fromStart, grabMinute: grabMinute)
                } else {
                    self.drag = nil
                }
            }
            self.haptic.prepare()
        case .changed:
            guard let drag = self.drag else {
                return
            }
            let minute = self.minute(at: location)
            var start = self.startMinute
            var end = self.endMinute
            switch drag {
            case .start:
                start = minute
            case .end:
                end = minute
            case let .both(startOffset, _):
                let duration = QuietHoursDialView.duration(start, end)
                start = (minute - startOffset + 24 * 60) % (24 * 60)
                end = (start + duration) % (24 * 60)
            }
            let duration = QuietHoursDialView.duration(start, end)
            guard duration >= QuietHours.minimumDurationMinutes, duration <= 24 * 60 - QuietHours.minimumDurationMinutes else {
                return
            }
            // One handle dragged across the other would turn the arc inside out: it stops at the other instead.
            let previousDuration = QuietHoursDialView.duration(self.startMinute, self.endMinute)
            if abs(duration - previousDuration) > 12 * 60 {
                return
            }
            if start != self.startMinute || end != self.endMinute {
                self.startMinute = start
                self.endMinute = end
                self.haptic.selectionChanged()
                self.updateDuration()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.setNeedsLayout()
                self.layoutIfNeeded()
                CATransaction.commit()
                self.changed?(start, end)
            }
        default:
            self.drag = nil
        }
    }

    // MARK: - Accessibility

    override var accessibilityElements: [Any]? {
        get {
            return [self.durationLabel, self.startHandle, self.endHandle]
        }
        set {
        }
    }

    func adjust(start: Bool, by minutes: Int) {
        var newStart = self.startMinute
        var newEnd = self.endMinute
        if start {
            newStart = (newStart + minutes + 24 * 60) % (24 * 60)
        } else {
            newEnd = (newEnd + minutes + 24 * 60) % (24 * 60)
        }
        let duration = QuietHoursDialView.duration(newStart, newEnd)
        guard duration >= QuietHours.minimumDurationMinutes, duration <= 24 * 60 - QuietHours.minimumDurationMinutes else {
            return
        }
        self.startMinute = newStart
        self.endMinute = newEnd
        self.updateDuration()
        self.setNeedsLayout()
        self.changed?(newStart, newEnd)
    }

    // MARK: - Appearance

    /// The ring fades in, the arc is drawn from the moon round to the sun, the handles and the hours pop up.
    func animateIn(delay: Double) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3, delay: delay)
            return
        }
        self.trackLayer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3, delay: delay)
        self.trackLayer.animateSpring(from: 0.86 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.7, delay: delay, damping: 80.0)
        self.ticksLayer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4, delay: delay + 0.15)
        for (index, label) in self.hourLabels.enumerated() {
            quietHoursAnimateRiseIn(label.layer, delay: delay + 0.2 + Double(index) * 0.05, offset: 4.0, scale: 0.8, blur: 3.0)
        }
        self.arcLayer.animate(from: 0.0 as NSNumber, to: 1.0 as NSNumber, keyPath: "strokeEnd", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, duration: 0.7, delay: delay + 0.15)
        self.arcLayer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1, delay: delay + 0.15)
        for (index, handle) in [self.startHandle, self.endHandle].enumerated() {
            let handleDelay = delay + 0.15 + (index == 0 ? 0.0 : 0.62)
            handle.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: handleDelay)
            handle.layer.animateSpring(from: 0.2 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: handleDelay, damping: 52.0)
        }
        self.startGlyph.layer.animateSpring(from: -1.2 as NSNumber, to: 0.0 as NSNumber, keyPath: "transform.rotation.z", duration: 0.8, delay: delay + 0.2, damping: 60.0)
        self.endGlyph.layer.animateSpring(from: -1.6 as NSNumber, to: 0.0 as NSNumber, keyPath: "transform.rotation.z", duration: 0.9, delay: delay + 0.8, damping: 60.0)
        quietHoursAnimateRiseIn(self.durationLabel.layer, delay: delay + 0.35, offset: 8.0, scale: 0.8, blur: 6.0)
        quietHoursAnimateRiseIn(self.durationCaption.layer, delay: delay + 0.45, offset: 6.0, scale: 1.0, blur: 4.0)
    }
}
