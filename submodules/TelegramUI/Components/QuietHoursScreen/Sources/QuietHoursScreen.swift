import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import AccountContext
import ComponentFlow
import ViewControllerComponent
import MultilineTextComponent
import BalancedTextComponent
import ListSectionComponent
import ListActionItemComponent
import ButtonComponent
import TelegramStringFormatting
import QuietHours

/// The dial as an item of a list section.
private final class QuietHoursDialItemComponent: Component {
    let theme: PresentationTheme
    let strings: PresentationStrings
    let dateTimeFormat: PresentationDateTimeFormat
    let startMinute: Int
    let endMinute: Int
    let changed: (Int, Int) -> Void

    init(theme: PresentationTheme, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat, startMinute: Int, endMinute: Int, changed: @escaping (Int, Int) -> Void) {
        self.theme = theme
        self.strings = strings
        self.dateTimeFormat = dateTimeFormat
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.changed = changed
    }

    static func ==(lhs: QuietHoursDialItemComponent, rhs: QuietHoursDialItemComponent) -> Bool {
        return lhs.theme === rhs.theme && lhs.strings === rhs.strings && lhs.dateTimeFormat == rhs.dateTimeFormat && lhs.startMinute == rhs.startMinute && lhs.endMinute == rhs.endMinute
    }

    final class View: UIView {
        let dialView = QuietHoursDialView()
        private var didAppear = false
        private var theme: PresentationTheme?

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.addSubview(self.dialView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(component: QuietHoursDialItemComponent, availableSize: CGSize, transition: ComponentTransition) -> CGSize {
            let dialSize = min(availableSize.width - 48.0, 276.0)
            let size = CGSize(width: availableSize.width, height: dialSize + 36.0)
            self.dialView.frame = CGRect(x: floor((size.width - dialSize) * 0.5), y: 18.0, width: dialSize, height: dialSize)
            self.dialView.changed = component.changed
            if self.dialView.startMinute != component.startMinute || self.dialView.endMinute != component.endMinute || self.theme !== component.theme || !self.didAppear {
                self.theme = component.theme
                self.dialView.update(theme: component.theme, strings: component.strings, dateTimeFormat: component.dateTimeFormat, startMinute: component.startMinute, endMinute: component.endMinute)
            }
            if !self.didAppear {
                self.didAppear = true
                self.dialView.animateIn(delay: 0.12)
            }
            return size
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}

final class QuietHoursScreenComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext
    let initialQuietHours: QuietHours?

    init(context: AccountContext, initialQuietHours: QuietHours?) {
        self.context = context
        self.initialQuietHours = initialQuietHours
    }

    static func ==(lhs: QuietHoursScreenComponent, rhs: QuietHoursScreenComponent) -> Bool {
        return lhs.context === rhs.context && lhs.initialQuietHours == rhs.initialQuietHours
    }

    final class View: UIView {
        private let scrollView = UIScrollView()
        private let navigationTitle = ComponentView<Empty>()
        private let skyView = QuietHoursSkyIconView()
        private let subtitle = ComponentView<Empty>()
        private let toggleSection = ComponentView<Empty>()
        private let dialSection = ComponentView<Empty>()
        private let saveButton = ComponentView<Empty>()

        private var component: QuietHoursScreenComponent?
        private var environment: EnvironmentType?
        private weak var state: EmptyComponentState?
        private var isUpdating = false

        private var isOn = false
        private var startMinute = 23 * 60
        private var endMinute = 8 * 60
        private var isSaving = false
        private var didAppear = false
        private let haptic = HapticFeedback()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.scrollView.showsVerticalScrollIndicator = true
            self.scrollView.showsHorizontalScrollIndicator = false
            self.scrollView.delaysContentTouches = false
            self.scrollView.canCancelContentTouches = true
            self.scrollView.contentInsetAdjustmentBehavior = .never
            self.scrollView.alwaysBounceVertical = true
            self.addSubview(self.scrollView)
            self.scrollView.addSubview(self.skyView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// The device's offset from GMT, whole minutes.
        private var currentUtcOffset: Int {
            let offset = TimeZone.current.secondsFromGMT()
            return offset - offset % 60
        }

        /// What saving would set: the hours on this device's clock, or none.
        private var currentValue: QuietHours? {
            return self.isOn ? QuietHours(startMinute: self.startMinute, endMinute: self.endMinute, utcOffset: self.currentUtcOffset) : nil
        }

        private var hasChanges: Bool {
            return self.currentValue != self.component?.initialQuietHours
        }

        // MARK: - Actions

        private func toggle() {
            guard !self.isSaving else {
                return
            }
            self.isOn = !self.isOn
            self.haptic.impact(.light)
            if self.isOn && !UIAccessibility.isReduceMotionEnabled {
                quietHoursAnimatePop(self.skyView.layer, from: 0.9, overshoot: 1.08, duration: 0.45)
                self.skyView.moonView.sway(delay: 0.05)
                self.skyView.moonView.twinkle(delay: 0.2, count: 2)
            }
            self.state?.updated(transition: .spring(duration: 0.5))
        }

        private func save() {
            guard let component = self.component, let environment = self.environment, !self.isSaving else {
                return
            }
            let context = component.context
            let value = self.currentValue
            let strings = environment.strings
            self.isSaving = true
            self.state?.updated(transition: .easeInOut(duration: 0.2))

            let accountPeerId = context.account.peerId
            let failed: () -> Void = { [weak self] in
                guard let self else {
                    return
                }
                self.isSaving = false
                self.state?.updated(transition: .easeInOut(duration: 0.2))
                self.haptic.error()
                self.presentAlert(strings.QuietHours_SaveError)
            }
            // The bio as it is on the server now (it may have been changed on another device), then written with the hours.
            // The save goes on if the screen is left meanwhile.
            let _ = (QuietHoursScreen.currentAbout(context: context)
            |> deliverOnMainQueue).startStandalone(next: { [weak self] currentAbout in
                let text = QuietHours.split(about: currentAbout).text
                let about = QuietHours.about(text: text, quietHours: value)
                // Counted as the bio field counts it (its characters), with the room the tag takes after it.
                let limit = Int(context.userLimits.maxAboutLength)
                let length = text.count + (value.map { QuietHours.length(of: $0.tag) + (text.isEmpty ? 0 : 1) } ?? 0)
                if length > limit {
                    guard let self else {
                        return
                    }
                    self.isSaving = false
                    self.state?.updated(transition: .easeInOut(duration: 0.2))
                    self.haptic.error()
                    self.presentAlert(strings.QuietHours_BioTooLong("\(length - limit)").string)
                    return
                }
                let _ = (QuietHoursScreen.updateAbout(context: context, about: about)
                |> deliverOnMainQueue).startStandalone(error: { _ in
                    failed()
                }, completed: { [weak self] in
                    QuietHoursDirectory.shared.set(value, for: accountPeerId, accountPeerId: accountPeerId)
                    QuietHoursKeeper.remember(value, accountPeerId: accountPeerId)
                    guard let self else {
                        return
                    }
                    self.haptic.success()
                    (self.environment?.controller() as? QuietHoursScreen)?.dismiss()
                })
            }, error: { _ in
                failed()
            })
        }

        private func presentAlert(_ text: String) {
            guard let component = self.component, let controller = self.environment?.controller() else {
                return
            }
            let presentationData = component.context.sharedContext.currentPresentationData.with { $0 }
            controller.present(textAlertController(context: component.context, updatedPresentationData: nil, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
        }

        // MARK: - Layout

        func update(component: QuietHoursScreenComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
            self.isUpdating = true
            defer {
                self.isUpdating = false
            }
            let environment = environment[EnvironmentType.self].value
            let themeUpdated = self.environment?.theme !== environment.theme
            if self.component == nil {
                if let initial = component.initialQuietHours {
                    self.isOn = true
                    let minutes = initial.minutes(onClockWithOffset: self.currentUtcOffset)
                    self.startMinute = minutes.start
                    self.endMinute = minutes.end
                }
            }
            self.component = component
            self.environment = environment
            self.state = state
            let theme = environment.theme
            let strings = environment.strings
            if themeUpdated {
                self.backgroundColor = theme.list.blocksBackgroundColor
            }
            let presentationData = component.context.sharedContext.currentPresentationData.with { $0 }

            // The title in the navigation bar.
            let navigationTitleSize = self.navigationTitle.update(
                transition: transition,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: strings.QuietHours_Title, font: Font.semibold(17.0), textColor: theme.rootController.navigationBar.primaryTextColor)),
                    horizontalAlignment: .center
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width, height: 100.0)
            )
            let navigationTitleFrame = CGRect(origin: CGPoint(x: floor((availableSize.width - navigationTitleSize.width) / 2.0), y: environment.statusBarHeight + floor((environment.navigationHeight - environment.statusBarHeight - navigationTitleSize.height) / 2.0)), size: navigationTitleSize)
            if let navigationTitleView = self.navigationTitle.view {
                if navigationTitleView.superview == nil, let navigationBar = environment.controller()?.navigationBar {
                    navigationBar.view.addSubview(navigationTitleView)
                }
                transition.setFrame(view: navigationTitleView, frame: navigationTitleFrame)
            }

            let sideInset: CGFloat = 16.0 + environment.safeInsets.left
            let rightSideInset: CGFloat = 16.0 + environment.safeInsets.right
            let bandCenterX = environment.safeInsets.left + (availableSize.width - environment.safeInsets.left - environment.safeInsets.right) / 2.0
            var contentHeight: CGFloat = environment.navigationHeight

            // The night sky.
            let skySize: CGFloat = 92.0
            let skyFrame = CGRect(x: floor(bandCenterX - skySize * 0.5), y: contentHeight + 12.0, width: skySize, height: skySize)
            transition.setFrame(view: self.skyView, frame: skyFrame)
            contentHeight += 12.0 + skySize + 18.0

            let subtitleSize = self.subtitle.update(
                transition: .immediate,
                component: AnyComponent(BalancedTextComponent(
                    text: .plain(NSAttributedString(string: strings.QuietHours_Text, font: Font.regular(15.0), textColor: theme.list.freeTextColor)),
                    horizontalAlignment: .center,
                    maximumNumberOfLines: 0,
                    lineSpacing: 0.2
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset - rightSideInset - 16.0, height: 1000.0)
            )
            let subtitleFrame = CGRect(origin: CGPoint(x: floor(bandCenterX - subtitleSize.width * 0.5), y: contentHeight), size: subtitleSize)
            if let subtitleView = self.subtitle.view {
                if subtitleView.superview == nil {
                    self.scrollView.addSubview(subtitleView)
                }
                transition.setFrame(view: subtitleView, frame: subtitleFrame)
            }
            contentHeight += subtitleSize.height + 24.0

            // The switch.
            let toggleSize = self.toggleSection.update(
                transition: transition,
                component: AnyComponent(ListSectionComponent(
                    theme: theme,
                    style: .glass,
                    header: nil,
                    footer: nil,
                    items: [
                        AnyComponentWithIdentity(id: 0, component: AnyComponent(ListActionItemComponent(
                            theme: theme,
                            style: .glass,
                            title: AnyComponent(MultilineTextComponent(
                                text: .plain(NSAttributedString(string: strings.QuietHours_Toggle, font: Font.regular(presentationData.listsFontSize.baseDisplaySize), textColor: theme.list.itemPrimaryTextColor)),
                                maximumNumberOfLines: 1
                            )),
                            accessory: .toggle(ListActionItemComponent.Toggle(style: .regular, isOn: self.isOn, action: { [weak self] _ in
                                self?.toggle()
                            })),
                            action: nil
                        )))
                    ]
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset - rightSideInset, height: 10000.0)
            )
            let toggleFrame = CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: toggleSize)
            if let toggleView = self.toggleSection.view {
                if toggleView.superview == nil {
                    self.scrollView.addSubview(toggleView)
                }
                transition.setFrame(view: toggleView, frame: toggleFrame)
            }
            contentHeight += toggleSize.height + 30.0

            // The dial, while quiet hours are on.
            let tag = QuietHours(startMinute: self.startMinute, endMinute: self.endMinute, utcOffset: self.currentUtcOffset)?.tag ?? ""
            let dialSize = self.dialSection.update(
                transition: transition,
                component: AnyComponent(ListSectionComponent(
                    theme: theme,
                    style: .glass,
                    header: nil,
                    footer: AnyComponent(MultilineTextComponent(
                        text: .plain(NSAttributedString(string: strings.QuietHours_Footer(tag).string, font: Font.regular(13.0), textColor: theme.list.freeTextColor)),
                        maximumNumberOfLines: 0
                    )),
                    items: [
                        AnyComponentWithIdentity(id: 0, component: AnyComponent(QuietHoursDialItemComponent(
                            theme: theme,
                            strings: strings,
                            dateTimeFormat: presentationData.dateTimeFormat,
                            startMinute: self.startMinute,
                            endMinute: self.endMinute,
                            changed: { [weak self] start, end in
                                guard let self else {
                                    return
                                }
                                self.startMinute = start
                                self.endMinute = end
                                if !self.isUpdating {
                                    self.state?.updated(transition: .immediate)
                                }
                            }
                        )))
                    ]
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - sideInset - rightSideInset, height: 10000.0)
            )
            let dialFrame = CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: dialSize)
            if let dialView = self.dialSection.view {
                if dialView.superview == nil {
                    self.scrollView.addSubview(dialView)
                    dialView.alpha = 0.0
                }
                transition.setFrame(view: dialView, frame: dialFrame)
                let isShown = self.isOn
                if isShown != (dialView.alpha > 0.5) {
                    if isShown {
                        dialView.alpha = 1.0
                        dialView.isUserInteractionEnabled = true
                        if !transition.animation.isImmediate && !UIAccessibility.isReduceMotionEnabled {
                            quietHoursAnimateRiseIn(dialView.layer, delay: 0.0, offset: 24.0, scale: 0.96, blur: 8.0)
                            (self.dialSectionDialView(in: dialView))?.animateIn(delay: 0.1)
                        }
                    } else {
                        dialView.isUserInteractionEnabled = false
                        ComponentTransition.easeInOut(duration: 0.25).setAlpha(view: dialView, alpha: 0.0)
                        if !UIAccessibility.isReduceMotionEnabled {
                            dialView.layer.animateScale(from: 1.0, to: 0.96, duration: 0.25)
                            dialView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: 16.0), duration: 0.25, additive: true)
                        }
                    }
                }
            }
            if self.isOn {
                contentHeight += dialSize.height
            }

            // Save.
            let buttonInsets = ContainerViewLayout.concentricInsets(bottomInset: environment.safeInsets.bottom, innerDiameter: 52.0, sideInset: 30.0)
            let buttonSize = self.saveButton.update(
                transition: transition,
                component: AnyComponent(ButtonComponent(
                    background: ButtonComponent.Background(
                        style: .glass,
                        color: QuietHoursColors.middle,
                        foreground: .white,
                        pressedColor: QuietHoursColors.middle.withMultipliedAlpha(0.9),
                        cornerRadius: 26.0
                    ),
                    content: AnyComponentWithIdentity(id: "save", component: AnyComponent(Text(
                        text: strings.QuietHours_Save,
                        font: Font.semibold(17.0),
                        color: .white
                    ))),
                    isEnabled: self.hasChanges,
                    displaysProgress: self.isSaving,
                    action: { [weak self] in
                        self?.save()
                    }
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - buttonInsets.left - buttonInsets.right, height: 52.0)
            )
            let buttonFrame = CGRect(origin: CGPoint(x: floor((availableSize.width - buttonSize.width) * 0.5), y: availableSize.height - buttonInsets.bottom - buttonSize.height), size: buttonSize)
            if let buttonView = self.saveButton.view {
                if buttonView.superview == nil {
                    self.addSubview(buttonView)
                }
                transition.setFrame(view: buttonView, frame: buttonFrame)
            }
            contentHeight += 24.0 + buttonSize.height + buttonInsets.bottom + 16.0

            let contentSize = CGSize(width: availableSize.width, height: contentHeight)
            if self.scrollView.frame != CGRect(origin: CGPoint(), size: availableSize) {
                self.scrollView.frame = CGRect(origin: CGPoint(), size: availableSize)
            }
            if self.scrollView.contentSize != contentSize {
                self.scrollView.contentSize = contentSize
            }
            self.scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: environment.navigationHeight, left: 0.0, bottom: 0.0, right: 0.0)

            if !self.didAppear {
                self.didAppear = true
                self.animateIn()
            }
            return availableSize
        }

        private func dialSectionDialView(in view: UIView) -> QuietHoursDialView? {
            var result: QuietHoursDialView?
            func find(_ view: UIView) {
                if let dial = view as? QuietHoursDialView {
                    result = dial
                    return
                }
                for subview in view.subviews where result == nil {
                    find(subview)
                }
            }
            find(view)
            return result
        }

        /// The screen comes in part by part: the sky and the moon, the text, the switch, the dial, the button.
        private func animateIn() {
            guard !UIAccessibility.isReduceMotionEnabled else {
                return
            }
            self.skyView.animateIn(delay: 0.08)
            self.skyView.moonView.twinkle(delay: 0.9, count: 2)
            if let subtitleView = self.subtitle.view {
                quietHoursAnimateRiseIn(subtitleView.layer, delay: 0.2, offset: 12.0, scale: 0.98, blur: 6.0)
            }
            if let toggleView = self.toggleSection.view {
                quietHoursAnimateRiseIn(toggleView.layer, delay: 0.3, offset: 16.0, scale: 0.96, blur: 6.0)
            }
            if self.isOn, let dialView = self.dialSection.view {
                quietHoursAnimateRiseIn(dialView.layer, delay: 0.38, offset: 20.0, scale: 0.96, blur: 8.0)
            }
            if let buttonView = self.saveButton.view {
                quietHoursAnimateRiseIn(buttonView.layer, delay: 0.45, offset: 24.0, scale: 0.92, blur: 8.0)
            }
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

/// Quiet hours, from Settings: on or off, and when.
public final class QuietHoursScreen: ViewControllerComponentContainer {
    public init(context: AccountContext, initialQuietHours: QuietHours?) {
        super.init(context: context, component: QuietHoursScreenComponent(
            context: context,
            initialQuietHours: initialQuietHours
        ), navigationBarAppearance: .default, theme: .default, updatedPresentationData: nil)

        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.title = ""
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The account's bio as it is on the server now: the profile is fetched again first (the bio on the device may be
    /// out of date, changed on another device), then read. Fails if it cannot be learned within ten seconds.
    static func currentAbout(context: AccountContext) -> Signal<String?, UpdateAboutError> {
        let accountPeerId = context.account.peerId
        return context.engine.peers.fetchAndUpdateCachedPeerData(peerId: accountPeerId)
        |> take(1)
        |> castError(UpdateAboutError.self)
        |> mapToSignal { _ -> Signal<String?, UpdateAboutError> in
            return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.AboutText(id: accountPeerId))
            |> castError(UpdateAboutError.self)
            |> mapToSignal { about -> Signal<String?, UpdateAboutError> in
                if case let .known(text) = about {
                    return .single(text)
                }
                return .fail(.generic)
            }
        }
        |> timeout(10.0, queue: Queue.mainQueue(), alternate: .fail(.generic))
    }

    /// Writes the bio (with or without the quiet hours tag).
    static func updateAbout(context: AccountContext, about: String) -> Signal<Void, UpdateAboutError> {
        return context.engine.accountData.updateAbout(about: about)
        |> afterCompleted {
            // A fetch of the profile that began before the writing could still land after it, with the old bio.
            let _ = context.engine.peers.fetchAndUpdateCachedPeerData(peerId: context.account.peerId).startStandalone()
        }
    }

    override public func preferredContentSizeForLayout(_ layout: ContainerViewLayout) -> CGSize? {
        guard layout.metrics.widthClass == .regular else {
            return nil
        }
        return CGSize(width: min(480.0, layout.size.width - 20.0), height: min(layout.size.width, layout.size.height) - 88.0)
    }
}
