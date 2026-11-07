import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import QuietHours

/// Keeps the account's quiet hours on its owner's clock. The tag in the bio carries the offset from GMT the hours were
/// set with; after a change to or from summer time in the time zone they were set in, it is written again with the same
/// local hours and the new offset. This device remembers the tag and the time zone it was set in, and only ever moves
/// that tag: a trip to another time zone, or hours set again elsewhere, are left alone.
public final class QuietHoursKeeper {
    /// The tag this device knows the account's quiet hours by, and the time zone they were set in.
    struct Record: Equatable {
        let timeZoneIdentifier: String
        let tag: String
    }

    /// What is to be done with the bio.
    enum Decision: Equatable {
        /// The tag is not this device's to move.
        case none
        /// A tag on the device's clock that this device has not seen yet: it is remembered with the device's time zone.
        case adopt(QuietHours)
        /// The device's time zone has gone to or from summer time: the bio with the tag moved to the new offset.
        case adjust(about: String, quietHours: QuietHours)
    }

    private let context: AccountContext
    private var disposable: Disposable?
    private var observers: [NSObjectProtocol] = []
    private var lastAbout: String?
    private var isWriting = false

    /// Keeps the quiet hours of the account of `context` for as long as it lives (made once per signed-in account).
    public init(context: AccountContext) {
        self.context = context
        self.disposable = (context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.AboutText(id: context.account.peerId))
        |> deliverOnMainQueue).startStrict(next: { [weak self] about in
            guard let self, case let .known(text) = about else {
                return
            }
            self.lastAbout = text
            self.check()
        })
        // The clocks go forward or back while the app runs, or did while it slept.
        for name in [UIApplication.significantTimeChangeNotification, UIApplication.willEnterForegroundNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] _ in
                self?.check()
            }))
        }
    }

    deinit {
        self.disposable?.dispose()
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - What this device remembers

    private static func recordKey(accountPeerId: EnginePeer.Id) -> String {
        return "QuietHours.Record.\(accountPeerId.toInt64())"
    }

    /// Remembers the account's quiet hours as just set on this device, in its time zone now (`nil`: turned off).
    public static func remember(_ quietHours: QuietHours?, accountPeerId: EnginePeer.Id) {
        let key = QuietHoursKeeper.recordKey(accountPeerId: accountPeerId)
        if let quietHours {
            UserDefaults.standard.set(["timeZone": TimeZone.current.identifier, "tag": quietHours.tag], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func record(accountPeerId: EnginePeer.Id) -> Record? {
        guard let dictionary = UserDefaults.standard.dictionary(forKey: QuietHoursKeeper.recordKey(accountPeerId: accountPeerId)), let timeZoneIdentifier = dictionary["timeZone"] as? String, let tag = dictionary["tag"] as? String else {
            return nil
        }
        return Record(timeZoneIdentifier: timeZoneIdentifier, tag: tag)
    }

    // MARK: - Keeping

    /// What is to be done with the bio `about`, given what this device remembers and its time zone now.
    static func decision(about: String?, record: Record?, timeZone: TimeZone, now: Date, maxLength: Int) -> Decision {
        let (text, quietHours) = QuietHours.split(about: about)
        guard let quietHours else {
            return .none
        }
        let offset = timeZone.secondsFromGMT(for: now)
        guard let record, record.tag == quietHours.tag else {
            // Hours this device has not set (before, on another device, or by hand): they are taken as this device's
            // own only if they are on its clock now.
            return quietHours.utcOffset == offset ? .adopt(quietHours) : .none
        }
        guard record.timeZoneIdentifier == timeZone.identifier, offset != quietHours.utcOffset, QuietHoursKeeper.zoneHasOffset(quietHours.utcOffset, timeZone: timeZone, around: now), let adjusted = quietHours.withOffset(offset) else {
            return .none
        }
        // Counted as the bio field and the quiet hours screen count it.
        guard text.count + QuietHours.length(of: adjusted.tag) + (text.isEmpty ? 0 : 1) <= maxLength else {
            return .none
        }
        return .adjust(about: QuietHours.about(text: text, quietHours: adjusted), quietHours: adjusted)
    }

    /// Whether `timeZone` is, at some time of the year around `date`, `utcOffset` seconds from GMT.
    private static func zoneHasOffset(_ utcOffset: Int, timeZone: TimeZone, around date: Date) -> Bool {
        for month in -6 ... 6 {
            let sample = date.addingTimeInterval(Double(month) * 30.5 * 86400.0)
            if timeZone.secondsFromGMT(for: sample) == utcOffset {
                return true
            }
        }
        return false
    }

    private func check() {
        let context = self.context
        let accountPeerId = context.account.peerId
        let maxLength = Int(context.userLimits.maxAboutLength)
        guard !self.isWriting else {
            return
        }
        // A quick look at the bio on the device first: nothing to do most of the time.
        switch QuietHoursKeeper.decision(about: self.lastAbout, record: QuietHoursKeeper.record(accountPeerId: accountPeerId), timeZone: TimeZone.current, now: Date(), maxLength: maxLength) {
        case .none:
            return
        case let .adopt(quietHours):
            QuietHoursKeeper.remember(quietHours, accountPeerId: accountPeerId)
            return
        case .adjust:
            break
        }
        self.isWriting = true
        // The bio may have been changed on another device: it is read from the server again before it is written.
        let write: Signal<QuietHours?, UpdateAboutError> = QuietHoursScreen.currentAbout(context: context)
        |> mapToSignal { currentAbout -> Signal<QuietHours?, UpdateAboutError> in
            guard case let .adjust(updated, adjusted) = QuietHoursKeeper.decision(about: currentAbout, record: QuietHoursKeeper.record(accountPeerId: accountPeerId), timeZone: TimeZone.current, now: Date(), maxLength: maxLength) else {
                return .single(nil)
            }
            return QuietHoursScreen.updateAbout(context: context, about: updated)
            |> map { _ -> QuietHours? in
                return nil
            }
            |> then(.single(adjusted))
        }
        let _ = (write
        |> deliverOnMainQueue).startStandalone(next: { adjusted in
            if let adjusted {
                QuietHoursKeeper.remember(adjusted, accountPeerId: accountPeerId)
                QuietHoursDirectory.shared.set(adjusted, for: accountPeerId, accountPeerId: accountPeerId)
            }
        }, error: { [weak self] _ in
            self?.isWriting = false
        }, completed: { [weak self] in
            self?.isWriting = false
        })
    }
}
