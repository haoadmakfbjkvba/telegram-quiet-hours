import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import AccountContext
import QuietHours

/// Quiet Hours in Settings: the night sky, the title, the hours (or Off) and an arrow. The first times it is seen it
/// introduces itself: the row lights up and grows a little, the moon swings in, the title rises letter by letter and a
/// NEW badge pops up.
final class PeerInfoScreenQuietHoursItem: PeerInfoScreenItem {
    private static let introductionsKey = "QuietHoursSettingsItem.Introductions"
    private static let introductionCount = 3

    let id: AnyHashable
    let title: String
    let value: String
    let badge: String
    let action: (() -> Void)?

    init(id: AnyHashable, title: String, value: String, badge: String, action: (() -> Void)?) {
        self.id = id
        self.title = title
        self.value = value
        self.badge = badge
        self.action = action
    }

    func node() -> PeerInfoScreenItemNode {
        let introduces = UserDefaults.standard.integer(forKey: PeerInfoScreenQuietHoursItem.introductionsKey) < PeerInfoScreenQuietHoursItem.introductionCount
        return PeerInfoScreenQuietHoursItemNode(introduces: introduces)
    }

    fileprivate static func noteIntroduction() {
        let count = UserDefaults.standard.integer(forKey: PeerInfoScreenQuietHoursItem.introductionsKey)
        UserDefaults.standard.set(count + 1, forKey: PeerInfoScreenQuietHoursItem.introductionsKey)
    }
}

private final class PeerInfoScreenQuietHoursItemNode: PeerInfoScreenItemNode {
    private let selectionNode: PeerInfoScreenSelectableBackgroundNode
    private let maskNode: ASImageNode
    private let tintView = UIView()
    private let contentView = UIView()
    private let iconView = QuietHoursSkyIconView()
    private let titleView = QuietHoursTextView()
    private let valueView = QuietHoursTextView()
    private let badgeView = UIView()
    private let badgeLabel = UILabel()
    private let arrowNode: ASImageNode
    private let bottomSeparatorNode: ASDisplayNode
    private let activateArea: AccessibilityAreaNode

    private var item: PeerInfoScreenQuietHoursItem?
    private let introduces: Bool
    private var didIntroduce = false

    init(introduces: Bool) {
        self.introduces = introduces
        var bringToFrontForHighlightImpl: (() -> Void)?
        self.selectionNode = PeerInfoScreenSelectableBackgroundNode(bringToFrontForHighlight: { bringToFrontForHighlightImpl?() })
        self.maskNode = ASImageNode()
        self.maskNode.isUserInteractionEnabled = false
        self.arrowNode = ASImageNode()
        // A view (not just a layer): the row's own views go below it.
        self.arrowNode.displaysAsynchronously = false
        self.arrowNode.isUserInteractionEnabled = false
        self.arrowNode.displayWithoutProcessing = true
        self.bottomSeparatorNode = ASDisplayNode()
        self.bottomSeparatorNode.isLayerBacked = true
        self.activateArea = AccessibilityAreaNode()

        super.init()

        bringToFrontForHighlightImpl = { [weak self] in
            self?.bringToFrontForHighlight?()
        }

        self.addSubnode(self.bottomSeparatorNode)
        self.addSubnode(self.selectionNode)
        self.addSubnode(self.maskNode)
        self.addSubnode(self.arrowNode)
        self.addSubnode(self.activateArea)
    }

    override func didLoad() {
        super.didLoad()
        self.tintView.isUserInteractionEnabled = false
        self.tintView.alpha = 0.0
        self.view.insertSubview(self.tintView, aboveSubview: self.selectionNode.view)
        self.contentView.isUserInteractionEnabled = false
        self.contentView.layer.anchorPoint = CGPoint(x: 0.0, y: 0.5)
        self.view.insertSubview(self.contentView, belowSubview: self.arrowNode.view)
        self.contentView.addSubview(self.iconView)
        self.contentView.addSubview(self.titleView)
        self.badgeLabel.textAlignment = .center
        self.badgeLabel.isAccessibilityElement = false
        self.titleView.isAccessibilityElement = false
        self.valueView.isAccessibilityElement = false
        self.badgeView.addSubview(self.badgeLabel)
        self.badgeView.isHidden = !self.introduces
        self.contentView.addSubview(self.badgeView)
        self.view.insertSubview(self.valueView, belowSubview: self.arrowNode.view)
        if self.introduces && !UIAccessibility.isReduceMotionEnabled {
            // The row comes in by itself once Settings has opened: until then it is empty.
            self.contentView.alpha = 0.0
            self.valueView.alpha = 0.0
        }
    }

    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        if self.introduces && !self.didIntroduce {
            self.didIntroduce = true
            PeerInfoScreenQuietHoursItem.noteIntroduction()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: { [weak self] in
                self?.playIntroduction()
            })
        }
    }

    override func update(context: AccountContext, width: CGFloat, safeInsets: UIEdgeInsets, presentationData: PresentationData, item: PeerInfoScreenItem, topItem: PeerInfoScreenItem?, bottomItem: PeerInfoScreenItem?, hasCorners: Bool, transition: ContainedViewLayoutTransition) -> CGFloat {
        guard let item = item as? PeerInfoScreenQuietHoursItem else {
            return 10.0
        }
        let previousItem = self.item
        self.item = item
        self.selectionNode.pressed = item.action

        let theme = presentationData.theme
        let sideInset: CGFloat = 16.0 + safeInsets.left
        let sideInsetRight: CGFloat = 16.0 + safeInsets.right
        let leftInset = sideInset + 29.0 + 16.0
        let rightInset = sideInsetRight + 18.0
        let titleFont = Font.regular(presentationData.listsFontSize.itemListBaseFontSize)

        self.bottomSeparatorNode.backgroundColor = theme.list.itemBlocksSeparatorColor
        self.tintView.backgroundColor = QuietHoursColors.middle.withAlphaComponent(theme.overallDarkAppearance ? 0.22 : 0.12)

        self.badgeLabel.attributedText = NSAttributedString(string: item.badge, attributes: [.font: Font.medium(11.0), .foregroundColor: UIColor.white])
        self.badgeLabel.sizeToFit()
        let badgeSize = CGSize(width: self.badgeLabel.bounds.width + 8.0, height: 18.0)
        let badgeSpace = self.introduces ? badgeSize.width + 10.0 : 0.0

        let valueSize = self.valueView.update(text: NSAttributedString(string: item.value, attributes: [.font: titleFont, .foregroundColor: theme.list.itemSecondaryTextColor]), width: max(1.0, width * 0.45), maxLines: 1)
        let titleWidth = max(1.0, width - leftInset - rightInset - valueSize.width - badgeSpace - 12.0)
        let titleSize = self.titleView.update(text: NSAttributedString(string: item.title, attributes: [.font: titleFont, .foregroundColor: theme.list.itemPrimaryTextColor]), width: titleWidth, maxLines: 1)

        let height = titleSize.height + 32.0
        let iconSize: CGFloat = 30.0

        // The content grows from its left edge.
        self.contentView.bounds = CGRect(origin: CGPoint(), size: CGSize(width: width - sideInset - rightInset, height: height))
        self.contentView.center = CGPoint(x: sideInset, y: height * 0.5)
        self.iconView.frame = CGRect(x: 0.0, y: floorToScreenPixels((height - iconSize) * 0.5), width: iconSize, height: iconSize)
        let titleFrame = CGRect(origin: CGPoint(x: leftInset - sideInset, y: floorToScreenPixels((height - titleSize.height) * 0.5)), size: titleSize)
        self.titleView.frame = titleFrame
        self.badgeView.frame = CGRect(x: titleFrame.maxX + 10.0, y: floorToScreenPixels((height - badgeSize.height) * 0.5) + 1.0, width: badgeSize.width, height: badgeSize.height)
        self.badgeView.layer.cornerRadius = 5.0
        self.badgeView.backgroundColor = QuietHoursColors.middle
        self.badgeLabel.frame = CGRect(origin: CGPoint(), size: badgeSize)

        let valueFrame = CGRect(origin: CGPoint(x: width - rightInset - valueSize.width, y: floorToScreenPixels((height - valueSize.height) * 0.5)), size: valueSize)
        self.valueView.frame = valueFrame
        if let previousItem, previousItem.value != item.value, !UIAccessibility.isReduceMotionEnabled {
            // New hours: they rise into place letter by letter.
            let _ = self.valueView.animateLettersIn(delay: 0.15, stagger: 0.02)
        }

        if let arrowImage = PresentationResourcesItemList.disclosureArrowImage(theme) {
            self.arrowNode.image = arrowImage
            let arrowFrame = CGRect(origin: CGPoint(x: width - 7.0 - arrowImage.size.width - safeInsets.right, y: floorToScreenPixels((height - arrowImage.size.height) / 2.0)), size: arrowImage.size)
            transition.updateFrame(node: self.arrowNode, frame: arrowFrame)
        }

        self.activateArea.accessibilityLabel = self.introduces ? item.title + ", " + item.badge : item.title
        self.activateArea.accessibilityValue = item.value
        self.activateArea.accessibilityTraits = [.button]

        let hasCorners = hasCorners && (topItem == nil || bottomItem == nil)
        let hasTopCorners = hasCorners && topItem == nil
        let hasBottomCorners = hasCorners && bottomItem == nil
        self.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(theme, top: hasTopCorners, bottom: hasBottomCorners, glass: true) : nil
        self.maskNode.frame = CGRect(origin: CGPoint(x: safeInsets.left, y: 0.0), size: CGSize(width: width - safeInsets.left - safeInsets.right, height: height))
        self.bottomSeparatorNode.isHidden = hasBottomCorners
        self.tintView.frame = CGRect(origin: CGPoint(), size: CGSize(width: width, height: height))

        let highlightNodeOffset: CGFloat = topItem == nil ? 0.0 : UIScreenPixel
        self.selectionNode.update(size: CGSize(width: width, height: height + highlightNodeOffset), theme: theme, transition: transition)
        transition.updateFrame(node: self.selectionNode, frame: CGRect(origin: CGPoint(x: 0.0, y: -highlightNodeOffset), size: CGSize(width: width, height: height + highlightNodeOffset)))
        transition.updateFrame(node: self.bottomSeparatorNode, frame: CGRect(origin: CGPoint(x: leftInset - 1.0, y: height - UIScreenPixel), size: CGSize(width: width - leftInset + 1.0 - 16.0, height: UIScreenPixel)))
        transition.updateAlpha(node: self.bottomSeparatorNode, alpha: bottomItem == nil ? 0.0 : 1.0)
        self.activateArea.frame = CGRect(origin: CGPoint(x: safeInsets.left, y: 0.0), size: CGSize(width: width - safeInsets.left - safeInsets.right, height: height))
        return height
    }

    /// The row lights up and grows a little while its parts come in, then it all settles.
    private func playIntroduction() {
        guard self.isNodeLoaded else {
            return
        }
        self.contentView.alpha = 1.0
        self.valueView.alpha = 1.0
        guard !UIAccessibility.isReduceMotionEnabled else {
            return
        }
        self.tintView.layer.animateKeyframes(values: [0.0, 1.0, 1.0, 0.0].map { $0 as NSNumber }, keyTimes: [0.0, 0.18, 0.65, 1.0].map { $0 as NSNumber }, duration: 1.7, keyPath: "opacity")
        self.contentView.layer.animateKeyframes(values: [0.94, 1.08, 1.08, 1.0].map { $0 as NSNumber }, keyTimes: [0.0, 0.3, 0.62, 1.0].map { $0 as NSNumber }, duration: 1.5, keyPath: "transform.scale", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
        self.iconView.animateIn(delay: 0.0)
        self.iconView.moonView.twinkle(delay: 0.75, count: 2)
        let _ = self.titleView.animateLettersIn(delay: 0.1, stagger: 0.024)
        quietHoursAnimateRiseIn(self.valueView.layer, delay: 0.3, offset: 8.0, scale: 0.9, blur: 5.0)
        if !self.badgeView.isHidden {
            self.badgeView.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.6, delay: 0.45, damping: 52.0)
            self.badgeView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: 0.45)
            quietHoursAnimateSheen(over: self.badgeView, cornerRadius: 5.0, delay: 0.9, duration: 0.7, alpha: 0.6)
        }
    }
}
