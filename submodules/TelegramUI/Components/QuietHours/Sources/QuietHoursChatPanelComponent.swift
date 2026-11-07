import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramPresentationData

/// The line above the message field in a chat with someone who is in their quiet hours: it says so while a message is
/// being written, that the message went without sound once it is sent, and that the quiet hours are over when they end.
public final class QuietHoursChatPanelComponent: Component {
    public enum Mode: Equatable {
        /// A message is being written: it will arrive without sound.
        case composing
        /// A message has just gone without sound.
        case sent
        /// The quiet hours have just ended.
        case morning
    }

    let theme: PresentationTheme
    let strings: PresentationStrings
    let name: String
    let endTime: String
    let mode: Mode

    public init(theme: PresentationTheme, strings: PresentationStrings, name: String, endTime: String, mode: Mode) {
        self.theme = theme
        self.strings = strings
        self.name = name
        self.endTime = endTime
        self.mode = mode
    }

    public static func ==(lhs: QuietHoursChatPanelComponent, rhs: QuietHoursChatPanelComponent) -> Bool {
        return lhs.theme === rhs.theme && lhs.strings === rhs.strings && lhs.name == rhs.name && lhs.endTime == rhs.endTime && lhs.mode == rhs.mode
    }

    public final class View: UIView {
        private let iconView = QuietHoursSkyIconView()
        private let sunView = UIImageView()
        private let titleView = QuietHoursTextView()
        private let textView = QuietHoursTextView()
        private var component: QuietHoursChatPanelComponent?
        private var didAppear = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.iconView.isCircle = true
            self.addSubview(self.iconView)
            self.sunView.alpha = 0.0
            self.addSubview(self.sunView)
            self.addSubview(self.titleView)
            self.addSubview(self.textView)
            self.isAccessibilityElement = true
            self.accessibilityTraits = [.staticText, .updatesFrequently]
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func texts(_ component: QuietHoursChatPanelComponent) -> (title: String, text: String) {
            switch component.mode {
            case .composing:
                return (component.strings.QuietHours_PanelTitle(component.name).string, component.strings.QuietHours_PanelText(component.endTime).string)
            case .sent:
                return (component.strings.QuietHours_PanelSentTitle, component.strings.QuietHours_PanelSentText(component.name, component.endTime).string)
            case .morning:
                return (component.strings.QuietHours_PanelMorningTitle(component.name).string, component.strings.QuietHours_PanelMorningText)
            }
        }

        func update(component: QuietHoursChatPanelComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            let previous = self.component
            self.component = component

            let theme = component.theme
            let (title, text) = self.texts(component)
            let iconSize: CGFloat = 32.0
            let leftInset: CGFloat = 12.0
            let textX = leftInset + iconSize + 11.0
            let textWidth = max(1.0, availableSize.width - textX - 12.0)

            let titleFont = Font.semibold(15.0)
            let textFont = Font.regular(13.0)
            let titleColor = theme.rootController.navigationBar.primaryTextColor
            let textColor = theme.rootController.navigationBar.secondaryTextColor
            let titleSize = self.titleView.update(text: NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: titleColor]), width: textWidth, maxLines: 1)
            let textSize = self.textView.update(text: NSAttributedString(string: text, attributes: [.font: textFont, .foregroundColor: textColor]), width: textWidth, maxLines: 2)

            let verticalInset: CGFloat = 9.0
            let height = max(iconSize + verticalInset * 2.0, verticalInset * 2.0 + titleSize.height + 1.0 + textSize.height)
            let iconFrame = CGRect(x: leftInset, y: floor((height - iconSize) * 0.5), width: iconSize, height: iconSize)
            self.iconView.frame = iconFrame
            self.sunView.frame = iconFrame.insetBy(dx: 5.0, dy: 5.0)
            if self.sunView.image == nil {
                self.sunView.image = generateImage(CGSize(width: 22.0, height: 22.0), rotatedContext: { size, context in
                    context.clear(CGRect(origin: CGPoint(), size: size))
                    quietHoursDrawSun(context: context, rect: CGRect(origin: CGPoint(), size: size), color: .white)
                })
            }
            let textBlockHeight = titleSize.height + 1.0 + textSize.height
            let titleFrame = CGRect(origin: CGPoint(x: textX, y: floor((height - textBlockHeight) * 0.5)), size: titleSize)
            let textFrame = CGRect(origin: CGPoint(x: textX, y: titleFrame.maxY + 1.0), size: textSize)
            self.titleView.frame = titleFrame
            self.textView.frame = textFrame
            self.accessibilityLabel = title + ", " + text

            let size = CGSize(width: availableSize.width, height: height)
            if !self.didAppear {
                self.didAppear = true
                if component.mode == .morning {
                    // It comes up already in the morning: the sun, not the moon.
                    self.showSun(true, animated: false)
                }
                // Once the container has given the line its frame (the sheen needs it).
                let isMorning = component.mode == .morning
                DispatchQueue.main.async { [weak self] in
                    self?.animateAppearance(isMorning: isMorning)
                }
                UIAccessibility.post(notification: .announcement, argument: title + ". " + text)
            } else if let previous, previous.mode != component.mode {
                self.animateModeChange(to: component.mode)
                UIAccessibility.post(notification: .announcement, argument: title + ". " + text)
            }
            return size
        }

        /// The first time it shows: the night sky pops up with a turn and sends a ring out, the moon swings in and
        /// its stars twinkle, the title comes in letter by letter, then the line under it, and light passes over.
        private func animateAppearance(isMorning: Bool) {
            guard !UIAccessibility.isReduceMotionEnabled else {
                return
            }
            let icon = self.iconView.layer
            quietHoursAddKeyframes(icon, keyPath: "transform.scale", values: [0.0, 1.35, 0.9, 1.06, 1.0], keyTimes: [0.0, 0.35, 0.6, 0.8, 1.0], duration: 0.8, delay: 0.1)
            quietHoursAddKeyframes(icon, keyPath: "transform.rotation.z", values: [-0.9, 0.18, -0.06, 0.0], keyTimes: [0.0, 0.4, 0.7, 1.0], duration: 0.8, delay: 0.1)
            if isMorning {
                quietHoursAddKeyframes(self.sunView.layer, keyPath: "transform.rotation.z", values: [-2.0, 0.0], keyTimes: [0.0, 1.0], duration: 1.0, delay: 0.2, timing: .easeOut)
                quietHoursAddKeyframes(self.sunView.layer, keyPath: "transform.scale", values: [0.2, 1.25, 1.0], keyTimes: [0.0, 0.5, 1.0], duration: 0.8, delay: 0.2)
            } else {
                self.iconView.moonView.animateIn(delay: 0.25)
                self.iconView.moonView.twinkle(delay: 1.0, count: 2)
            }
            self.sendRing(delay: 0.38, color: isMorning ? QuietHoursColors.sun : QuietHoursColors.middle)
            let _ = self.titleView.animateLettersIn(delay: 0.22, stagger: 0.022, offset: 12.0)
            let _ = self.textView.animateLettersIn(delay: 0.45, stagger: 0.009, offset: 8.0)
            quietHoursAnimateSheen(over: self, cornerRadius: min(20.0, self.bounds.height * 0.5), delay: 1.0, duration: 0.9, alpha: 0.4)
        }

        /// A soft ring going out of the icon.
        private func sendRing(delay: Double, color: UIColor = QuietHoursColors.middle) {
            let frame = self.iconView.frame
            let ring = CAShapeLayer()
            ring.frame = frame
            ring.path = UIBezierPath(ovalIn: CGRect(origin: CGPoint(), size: frame.size)).cgPath
            ring.fillColor = UIColor.clear.cgColor
            ring.strokeColor = color.cgColor
            ring.lineWidth = 2.0
            ring.opacity = 0.0
            self.layer.insertSublayer(ring, below: self.iconView.layer)
            quietHoursAddKeyframes(ring, keyPath: "transform.scale", values: [1.0, 1.9], keyTimes: [0.0, 1.0], duration: 0.8, delay: delay, timing: .easeOut)
            quietHoursAddKeyframes(ring, keyPath: "opacity", values: [0.0, 0.7, 0.0], keyTimes: [0.0, 0.15, 1.0], duration: 0.8, delay: delay, timing: .easeOut)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.9, execute: { [weak ring] in
                ring?.removeFromSuperlayer()
            })
        }

        private func animateModeChange(to mode: Mode) {
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            for view in [self.titleView, self.textView] {
                if reduceMotion {
                    view.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                } else {
                    quietHoursAnimateRiseIn(view.layer, delay: view === self.titleView ? 0.0 : 0.08, offset: 8.0, scale: 0.96, blur: 6.0)
                }
            }
            switch mode {
            case .composing:
                self.showSun(false, animated: !reduceMotion)
            case .sent:
                self.showSun(false, animated: !reduceMotion)
                if !reduceMotion {
                    quietHoursAnimatePop(self.iconView.layer, from: 0.8, overshoot: 1.22, duration: 0.55)
                    self.iconView.moonView.sway(delay: 0.1)
                    self.iconView.moonView.twinkle(delay: 0.25, count: 1)
                    self.sendRing(delay: 0.15)
                }
            case .morning:
                self.showSun(true, animated: !reduceMotion)
            }
        }

        /// Morning: the moon sets and the sun comes up over a warm sky.
        private func showSun(_ show: Bool, animated: Bool) {
            let isShown = self.sunView.alpha > 0.5
            guard show != isShown else {
                return
            }
            self.sunView.alpha = show ? 1.0 : 0.0
            self.iconView.moonView.alpha = show ? 0.0 : 1.0
            self.iconView.setMorning(show, animated: animated)
            guard animated else {
                return
            }
            if show {
                self.iconView.moonView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.25)
                self.iconView.moonView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: 10.0), duration: 0.35, additive: true)
                self.sunView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3, delay: 0.15)
                self.sunView.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: 0.0, y: 12.0)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.7, delay: 0.15, damping: 70.0, additive: true)
                self.sunView.layer.animateSpring(from: -0.8 as NSNumber, to: 0.0 as NSNumber, keyPath: "transform.rotation.z", duration: 0.9, delay: 0.15, damping: 60.0)
            } else {
                self.sunView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.25)
                self.iconView.moonView.animateIn(delay: 0.1)
            }
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
