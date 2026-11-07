import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import QuietHours

private let quietBadgeCacheLock = NSLock()
private var quietBadgeCache: [String: UIImage] = [:]

extension ChatMessageDateAndStatusNode {
    /// The moon or the sun by the time of `message` (sent without sound in someone's quiet hours) as the account of
    /// `context` sees it; none in a preview.
    public static func quietBadge(message: EngineRawMessage, context: AccountContext, presentationData: ChatPresentationData) -> QuietHoursMessageBadge? {
        if presentationData.isPreview {
            return nil
        }
        return QuietHoursDirectory.shared.badge(message: message, accountPeerId: context.account.peerId, now: quietHoursNow(network: context.account.network))
    }

    /// The moon or the sun, in the color of the time, `size` points. Safe from any thread.
    static func quietBadgeGlyph(_ badge: QuietHoursMessageBadge, color: UIColor, size: CGFloat) -> UIImage? {
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let key = "\(badge == .resting ? "moon" : "sun")_\(Int(size * 10.0))_\(Int(red * 255.0))_\(Int(green * 255.0))_\(Int(blue * 255.0))_\(Int(alpha * 255.0))"
        quietBadgeCacheLock.lock()
        if let image = quietBadgeCache[key] {
            quietBadgeCacheLock.unlock()
            return image
        }
        quietBadgeCacheLock.unlock()

        let image = generateImage(CGSize(width: size, height: size), rotatedContext: { imageSize, context in
            let rect = CGRect(origin: CGPoint(), size: imageSize)
            context.clear(rect)
            switch badge {
            case .resting:
                context.setFillColor(color.cgColor)
                context.addPath(quietHoursMoonPath(in: rect.insetBy(dx: imageSize.width * 0.08, dy: imageSize.height * 0.08)).cgPath)
                context.fillPath()
            case .awake:
                quietHoursDrawSun(context: context, rect: rect, color: color)
            }
        })
        if let image {
            quietBadgeCacheLock.lock()
            quietBadgeCache[key] = image
            quietBadgeCacheLock.unlock()
        }
        return image
    }

    /// A message that has just gone without sound: its moon comes in large over the time, swings a little, then
    /// settles into its place.
    static func animateQuietBadgeArrival(_ layer: CALayer) {
        let delay = 0.2
        let duration = 1.5
        let lift: CGFloat = -18.0
        layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: delay)
        quietHoursAddKeyframes(layer, keyPath: "transform.scale", values: [0.2, 3.2, 2.8, 2.9, 0.85, 1.0], keyTimes: [0.0, 0.16, 0.3, 0.55, 0.86, 1.0], duration: duration, delay: delay)
        quietHoursAddKeyframes(layer, keyPath: "transform.rotation.z", values: [-1.3, 0.2, -0.22, 0.12, 0.0], keyTimes: [0.0, 0.18, 0.36, 0.55, 1.0], duration: duration, delay: delay)
        quietHoursAddKeyframes(layer, keyPath: "transform.translation.y", values: [0.0, lift, lift, lift, 0.0], keyTimes: [0.0, 0.16, 0.3, 0.55, 0.86], duration: duration, delay: delay)
    }

    /// The quiet hours are over: the moon sets, and the sun comes up in its place large, turning, then settles.
    static func animateQuietBadgeChange(node: ASImageNode, previousImage: UIImage, toAwake: Bool) {
        guard !UIAccessibility.isReduceMotionEnabled, let supernode = node.supernode else {
            return
        }
        let outgoing = ASImageNode()
        outgoing.isLayerBacked = true
        outgoing.displaysAsynchronously = false
        outgoing.image = previousImage
        outgoing.frame = node.frame
        supernode.insertSubnode(outgoing, belowSubnode: node)
        let direction: CGFloat = toAwake ? 1.0 : -1.0
        outgoing.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak outgoing] _ in
            outgoing?.removeFromSupernode()
        })
        outgoing.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: 8.0 * direction), duration: 0.35, removeOnCompletion: false, additive: true)
        outgoing.layer.animateScale(from: 1.0, to: 0.3, duration: 0.35, removeOnCompletion: false)

        let layer = node.layer
        let delay = 0.15
        let duration = 1.3
        layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15, delay: delay)
        quietHoursAddKeyframes(layer, keyPath: "transform.scale", values: [0.2, 2.8, 2.5, 2.6, 0.88, 1.0], keyTimes: [0.0, 0.18, 0.32, 0.55, 0.86, 1.0], duration: duration, delay: delay)
        quietHoursAddKeyframes(layer, keyPath: "transform.rotation.z", values: [-2.4, -0.6, 0.0], keyTimes: [0.0, 0.45, 1.0], duration: duration, delay: delay, timing: .easeOut)
        quietHoursAddKeyframes(layer, keyPath: "transform.translation.y", values: [0.0, -16.0, -16.0, -16.0, 0.0], keyTimes: [0.0, 0.18, 0.32, 0.55, 0.86], duration: duration, delay: delay)
    }
}
