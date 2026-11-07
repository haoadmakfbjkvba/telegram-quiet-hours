import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChatPresentationInterfaceState
import TelegramStringFormatting
import ChatMessageItemView
import QuietHours
import TextFormat

/// What a chat knows of quiet hours: those of the person it is with, the account's own, and what the line above the
/// message field shows.
final class ChatControllerQuietHoursState {
    /// The quiet hours of the person this private chat is with.
    var peerQuietHours: QuietHours?
    /// The account's own quiet hours (for the messages that reach it).
    var ownQuietHours: QuietHours?
    var ownQuietHoursDisposable: Disposable?
    var timeChangeObserver: NSObjectProtocol?
    var foregroundObserver: NSObjectProtocol?
    var changeTimer: SwiftSignalKit.Timer?
    var panelTimer: SwiftSignalKit.Timer?
    /// When a message last went without sound into the person's quiet hours (the line says so for a moment).
    var lastQuietSendTime: Double?
    /// Until when the line says that the quiet hours are over (right after they end).
    var morningUntil: Double?
    var isPanelVisible = false

    deinit {
        if let timeChangeObserver = self.timeChangeObserver {
            NotificationCenter.default.removeObserver(timeChangeObserver)
        }
        if let foregroundObserver = self.foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        self.ownQuietHoursDisposable?.dispose()
        self.changeTimer?.invalidate()
        self.panelTimer?.invalidate()
    }
}

extension ChatControllerImpl {
    /// The person this chat is with, if it is a private chat with a person who is not the account.
    private var quietHoursPeer: TelegramUser? {
        guard let peerId = self.chatLocation.peerId, peerId.namespace == Namespaces.Peer.CloudUser, peerId != self.context.account.peerId, self.chatLocation.threadId == nil else {
            return nil
        }
        switch self.subject {
        case .none, .message:
            break
        default:
            return nil
        }
        // The chat's data first: it is there before the interface state has been filled from it.
        let peer = self.contentData?.state.renderedPeer?.peer ?? self.presentationInterfaceState.renderedPeer?.peer
        guard let user = peer as? TelegramUser, user.botInfo == nil, !user.isDeleted else {
            return nil
        }
        return user
    }

    /// Whether a message sent now goes without sound: the person is in their quiet hours.
    var quietHoursSilenceMessages: Bool {
        guard self.quietHoursPeer != nil, let quietHours = self.quietHoursState.peerQuietHours else {
            return false
        }
        return quietHours.isActive(at: quietHoursNow(network: self.context.account.network))
    }

    /// The person's bio (their quiet hours) has been read or changed; also keeps the account's own quiet hours known,
    /// for the messages that reach it.
    func updateQuietHoursFromContentData() {
        let state = self.quietHoursState
        if state.ownQuietHoursDisposable == nil {
            let accountPeerId = self.context.account.peerId
            state.ownQuietHoursDisposable = (self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.AboutText(id: accountPeerId))
            |> deliverOnMainQueue).startStrict(next: { [weak self] about in
                guard case let .known(text) = about else {
                    return
                }
                let quietHours = QuietHours.split(about: text).quietHours
                QuietHoursDirectory.shared.set(quietHours, for: accountPeerId, accountPeerId: accountPeerId)
                guard let self, self.quietHoursState.ownQuietHours != quietHours else {
                    return
                }
                self.quietHoursState.ownQuietHours = quietHours
                self.scheduleQuietHoursChange()
                self.refreshQuietHoursMessages()
            })
            // Midnight, a new time zone or a changed clock; and back from the background (timers do not run while the
            // device sleeps).
            state.timeChangeObserver = NotificationCenter.default.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
                self?.quietHoursChanged()
            })
            state.foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main, using: { [weak self] _ in
                self?.quietHoursChanged()
            })
        }

        var quietHours: QuietHours?
        if let user = self.quietHoursPeer, let cachedData = self.contentData?.state.peerView?.cachedData as? CachedUserData {
            quietHours = QuietHours.split(about: cachedData.about).quietHours
            QuietHoursDirectory.shared.set(quietHours, for: user.id, accountPeerId: self.context.account.peerId)
        }
        guard quietHours != state.peerQuietHours else {
            return
        }
        state.peerQuietHours = quietHours
        self.scheduleQuietHoursChange()
        // Not in the middle of the chat's own update (this runs while its data is being applied, also on first load).
        Queue.mainQueue().justDispatch { [weak self] in
            guard let self else {
                return
            }
            self.refreshQuietHoursMessages()
            self.updateChatPresentationInterfaceState(animated: true, interactive: false, { $0 })
        }
    }

    /// At the next moment the person's quiet hours (or the account's own) start or end, the line and the badges change.
    private func scheduleQuietHoursChange() {
        let state = self.quietHoursState
        state.changeTimer?.invalidate()
        state.changeTimer = nil
        let now = quietHoursNow(network: self.context.account.network)
        let changes = [state.peerQuietHours, state.ownQuietHours].compactMap { $0?.nextChange(after: now) }
        guard let next = changes.min() else {
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: max(1.0, Double(next - now) + 0.5), repeat: false, completion: { [weak self] in
            self?.quietHoursChanged()
        }, queue: Queue.mainQueue())
        state.changeTimer = timer
        timer.start()
    }

    /// The clock moved on (their quiet hours started or ended, or the time or the zone changed).
    func quietHoursChanged() {
        let state = self.quietHoursState
        let now = quietHoursNow(network: self.context.account.network)
        // Quiet hours last at least half an hour, and so do the hours between them: ten minutes ago they were on and now
        // they are off only when they have just ended (not on coming back to the chat hours later).
        if let quietHours = state.peerQuietHours, !quietHours.isActive(at: now) {
            if quietHours.isActive(at: now - 10 * 60), state.isPanelVisible || state.lastQuietSendTime != nil {
                // They are over while the line is up, or after a message went without sound here: it says so for a few
                // seconds, long enough to be read.
                state.morningUntil = CACurrentMediaTime() + 6.0
                self.scheduleQuietHoursPanelUpdate(after: 6.1)
            }
            state.lastQuietSendTime = nil
        }
        self.scheduleQuietHoursChange()
        self.refreshQuietHoursMessages()
        self.updateChatPresentationInterfaceState(animated: true, interactive: false, { $0 })
    }

    /// Messages are being sent to this chat now: if any goes without sound into the person's quiet hours (not a
    /// scheduled one), the line says so for a moment.
    func noteQuietHoursSendIfNeeded(_ messages: [EnqueueMessage]) {
        guard self.quietHoursSilenceMessages else {
            return
        }
        let goesQuietly = messages.contains(where: { message in
            var attributes: [EngineMessage.Attribute] = []
            switch message {
            case let .message(_, messageAttributes, _, _, _, _, _, _, _, _):
                attributes = messageAttributes
            case let .forward(_, _, _, messageAttributes, _):
                attributes = messageAttributes
            }
            let isMuted = (attributes.first(where: { $0 is NotificationInfoMessageAttribute }) as? NotificationInfoMessageAttribute)?.flags.contains(.muted) ?? false
            return isMuted && !attributes.contains(where: { $0 is OutgoingScheduleInfoMessageAttribute })
        })
        if goesQuietly {
            self.noteQuietHoursSend()
        }
    }

    /// A message has gone without sound: the line says so for a moment.
    func noteQuietHoursSend() {
        self.quietHoursState.lastQuietSendTime = CACurrentMediaTime()
        self.scheduleQuietHoursPanelUpdate(after: 2.8)
        Queue.mainQueue().after(0.05, { [weak self] in
            self?.updateChatPresentationInterfaceState(animated: true, interactive: false, { $0 })
        })
    }

    private func scheduleQuietHoursPanelUpdate(after delay: Double) {
        let state = self.quietHoursState
        state.panelTimer?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: delay, repeat: false, completion: { [weak self] in
            self?.updateChatPresentationInterfaceState(animated: true, interactive: false, { $0 })
        }, queue: Queue.mainQueue())
        state.panelTimer = timer
        timer.start()
    }

    /// The messages on screen that went without sound are laid out again (their moon or sun).
    func refreshQuietHoursMessages() {
        guard self.isNodeLoaded else {
            return
        }
        self.chatDisplayNode.historyNode.forEachVisibleMessageItemNode { itemNode in
            guard let item = itemNode.item, let info = item.message.attributes.first(where: { $0 is NotificationInfoMessageAttribute }) as? NotificationInfoMessageAttribute, info.flags.contains(.muted) else {
                return
            }
            self.chatDisplayNode.historyNode.requestMessageUpdate(item.message.id, andScrollToItem: false, customTransition: nil)
        }
    }

    /// The line above the message field for `interfaceState`, set on the chat's node. Returns whether it appeared or went.
    func updateQuietHoursPanel(interfaceState: ChatPresentationInterfaceState) -> Bool {
        let state = self.quietHoursState
        var panel: QuietHoursChatPanelComponent?
        if let user = self.quietHoursPeer, let quietHours = state.peerQuietHours, interfaceState.search == nil, interfaceState.interfaceState.editMessage == nil {
            let now = quietHoursNow(network: self.context.account.network)
            let time = CACurrentMediaTime()
            var mode: QuietHoursChatPanelComponent.Mode?
            var endTimestamp: Int64?
            if let window = quietHours.window(containing: now) {
                endTimestamp = window.upperBound
                if let lastSend = state.lastQuietSendTime, time - lastSend < 2.7, interfaceState.interfaceState.effectiveInputState.inputText.length == 0 {
                    mode = .sent
                } else if interfaceState.interfaceState.effectiveInputState.inputText.length != 0 {
                    mode = .composing
                }
            } else if let morningUntil = state.morningUntil, time < morningUntil {
                mode = .morning
                endTimestamp = Int64(now)
            }
            if let mode, let endTimestamp {
                let endDate = Date(timeIntervalSince1970: Double(endTimestamp))
                let components = Calendar.current.dateComponents([.hour, .minute], from: endDate)
                let endTime = stringForShortTimestamp(hours: Int32(components.hour ?? 0), minutes: Int32(components.minute ?? 0), dateTimeFormat: self.presentationData.dateTimeFormat)
                panel = QuietHoursChatPanelComponent(
                    theme: interfaceState.theme,
                    strings: interfaceState.strings,
                    name: EnginePeer(user).compactDisplayTitle,
                    endTime: endTime,
                    mode: mode
                )
            }
        }
        let wasVisible = state.isPanelVisible
        state.isPanelVisible = panel != nil
        let changed = self.chatDisplayNode.quietHoursPanel != panel
        self.chatDisplayNode.quietHoursPanel = panel
        return changed || wasVisible != state.isPanelVisible
    }
}
