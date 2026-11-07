import Foundation
import TelegramCore

/// The time now, in seconds since 1970 (one place for the whole feature): the server's time when `network` is given, as
/// the times of messages are, so that a device clock that is off does not matter.
public func quietHoursNow(network: Network?) -> Int32 {
    let timestamp = network?.getApproximateRemoteTimestamp() ?? Int32(Date().timeIntervalSince1970)
    return timestamp
}

/// What a message sent without sound into someone's quiet hours shows next to its time: a moon while they rest, a sun
/// once their quiet hours are over.
public enum QuietHoursMessageBadge: Equatable {
    case resting
    case awake
}

/// Whose quiet hours this app knows, for each account: its own and those of the people whose chats it has shown since it
/// started, read from their bios. Safe from any thread.
public final class QuietHoursDirectory {
    public static let shared = QuietHoursDirectory()

    private struct Key: Hashable {
        let accountPeerId: EnginePeer.Id
        let peerId: EnginePeer.Id
    }

    private let lock = NSLock()
    private var hours: [Key: QuietHours] = [:]

    public func set(_ quietHours: QuietHours?, for peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id) {
        self.lock.lock()
        self.hours[Key(accountPeerId: accountPeerId, peerId: peerId)] = quietHours
        self.lock.unlock()
    }

    public func get(_ peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id) -> QuietHours? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.hours[Key(accountPeerId: accountPeerId, peerId: peerId)]
    }

    /// The badge of `message` as the account sees it, if it is a message of a private chat that arrived without sound
    /// during the quiet hours of the one it was sent to (the chat's person for an outgoing message, the account for an
    /// incoming one): a moon while they rest, a sun for a day after.
    public func badge(message: EngineRawMessage, accountPeerId: EnginePeer.Id, now: Int32) -> QuietHoursMessageBadge? {
        let chatPeerId = message.id.peerId
        guard chatPeerId.namespace == Namespaces.Peer.CloudUser, chatPeerId != accountPeerId, message.forwardInfo == nil else {
            return nil
        }
        // Messages of the chat itself, not scheduled ones.
        guard message.id.namespace == Namespaces.Message.Cloud || message.id.namespace == Namespaces.Message.Local else {
            return nil
        }
        if let user = message.peers[chatPeerId] as? TelegramUser, user.botInfo != nil {
            return nil
        }
        guard let notificationInfo = message.attributes.first(where: { $0 is NotificationInfoMessageAttribute }) as? NotificationInfoMessageAttribute, notificationInfo.flags.contains(.muted) else {
            return nil
        }
        let quietedPeerId = message.flags.contains(.Incoming) ? accountPeerId : chatPeerId
        guard let quietHours = self.get(quietedPeerId, accountPeerId: accountPeerId), let window = quietHours.window(containing: message.timestamp) else {
            return nil
        }
        if Int64(now) < window.upperBound {
            return .resting
        } else if Int64(now) < window.upperBound + 24 * 60 * 60 {
            return .awake
        } else {
            return nil
        }
    }
}
