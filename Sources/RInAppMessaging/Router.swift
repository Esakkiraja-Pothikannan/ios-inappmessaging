import UIKit

#if SWIFT_PACKAGE
import RSDKUtilsMain
#else
import RSDKUtils
#endif

internal protocol RouterType: ErrorReportable {
    var accessibilityCompatibleDisplay: Bool { get set }

    /// Contains logic to display the correct view type and create
    /// a view controller to present a single campaign.
    /// - Parameter campaign: The campaign object to display.
    /// - Parameter associatedImageData: Campaign-associated image as Data
    /// - Parameter confirmation: A handler called just before displaying.
    /// - Parameter completion: Completion handler called once displaying has finished.
    /// - Parameter cancelled: true when message display was cancelled
    func displayCampaign(_ campaign: Campaign,
                         associatedImageData: Data?,
                         confirmation: @escaping @autoclosure () -> Bool,
                         completion: @escaping (_ cancelled: Bool) -> Void)

    func displayTooltip(_ tooltip: Campaign,
                        targetView: UIView,
                        identifier: String,
                        imageBlob: Data,
                        becameVisibleHandler: @escaping (_ tooltipView: TooltipView) -> Void,
                        confirmation: @escaping @autoclosure () -> Bool,
                        completion: @escaping (_ cancelled: Bool) -> Void)
    
    /// Removes displayed campaign view from the stack
    func discardDisplayedCampaign()

    /// Removes all tooltips attached to a view with matching uiElementIdentifier
    func discardDisplayedTooltip(with uiElementIdentifier: String)

    /// Checks if given tooltip is already displayed.
    /// - Returns: true if the tooltip is currently displayed. `displayTooltip()` shouldn't be called in this case.
    func isDisplayingTooltip(with uiElementIdentifier: String) -> Bool
}

/// Handles all the displaying logic of the SDK.
internal class Router: RouterType, ViewListenerObserver {

    private enum UIConstants {
        enum Tooltip {
            static let minDistFromEdge: CGFloat = 20.0
            static let targetViewSpacing: CGFloat = 0.0
        }
    }

    private let dependencyManager: TypedDependencyManager
    private let displayQueue = DispatchQueue(label: "IAM.MessageLoader")
    private var displayedTooltips = [String: TooltipView]()
    private var positionObservers = [TooltipView: [NSKeyValueObservation]]()

    weak var errorDelegate: ErrorDelegate?
    var accessibilityCompatibleDisplay = false

    init(dependencyManager: TypedDependencyManager, viewListener: ViewListenerType) {
        self.dependencyManager = dependencyManager
        viewListener.addObserver(self)
    }

    func discardDisplayedCampaign() {
        displayQueue.sync {
            DispatchQueue.main.async {
                guard let rootView = UIApplication.shared.getKeyWindow(),
                      let presentedView = rootView.findIAMView() else {
                    return
                }

                presentedView.onDismiss?(true)
                presentedView.removeFromSuperview()
            }
        }
    }

    func discardDisplayedTooltip(with uiElementIdentifier: String) {
        displayQueue.sync {
            DispatchQueue.main.async {
                let displayedToolip = self.displayedTooltips[uiElementIdentifier]
                displayedToolip?.presenter.onDismiss?(true)
                displayedToolip?.removeFromSuperview()
            }
        }
    }

    func isDisplayingTooltip(with uiElementIdentifier: String) -> Bool {
        let result = {
            return self.displayedTooltips[uiElementIdentifier] != nil
        }
        if Thread.current == .main {
            return result()
        } else {
            return DispatchQueue.main.sync(execute: result)
        }
    }

    func displayCampaign(_ campaign: Campaign,
                         associatedImageData: Data?,
                         confirmation: @escaping @autoclosure () -> Bool,
                         completion: @escaping (_ cancelled: Bool) -> Void) {

        let campaignViewType = campaign.data.type
        guard campaignViewType != .invalid else {
            Logger.debug("Error: Campaign view type is invalid")
            completion(true)
            return
        }

        displayQueue.async {
            guard let viewConstructor = self.createViewConstructor(for: campaign, associatedImageData: associatedImageData) else {
                completion(true)
                return
            }

            DispatchQueue.main.async {
                guard let rootView = UIApplication.shared.getKeyWindow(),
                      rootView.findIAMView() == nil,
                      confirmation() else {

                    completion(true)
                    return
                }

                let view = viewConstructor()
                let parentView = self.findParentView(rootView: rootView)
                view.show(parentView: parentView, onDismiss: completion)
            }
        }
    }

    private func createViewConstructor(for campaign: Campaign, associatedImageData: Data?) -> (() -> BaseView)? {
        func getPresenter<T>(type: T.Type) -> T? {
            guard let presenter = self.dependencyManager.resolve(type: type) else {
                Logger.debug("Error: \(type) couldn't be resolved")
                assertionFailure()
                return nil
            }
            return presenter
        }

        switch campaign.data.type {
        case .modal:
            guard let presenter = getPresenter(type: FullViewPresenterType.self) else {
                break
            }
            presenter.campaign = campaign
            if let associatedImageData = associatedImageData {
                presenter.associatedImage = UIImage(data: associatedImageData)
            }
            return { ModalView(presenter: presenter) }
        case .full:
            guard let presenter = getPresenter(type: FullViewPresenterType.self) else {
                break
            }
            presenter.campaign = campaign
            if let associatedImageData = associatedImageData {
                presenter.associatedImage = UIImage(data: associatedImageData)
            }
            return { FullScreenView(presenter: presenter) }
        case .slide:
            guard let presenter = getPresenter(type: SlideUpViewPresenterType.self) else {
                break
            }
            presenter.campaign = campaign
            return { SlideUpView(presenter: presenter) }
        case .invalid, .html:
            Logger.debug("Error: Campaign view type not supported")
        }

        return nil
    }

    // swiftlint:disable:next function_parameter_count
    func displayTooltip(_ tooltip: Campaign,
                        targetView: UIView,
                        identifier: String,
                        imageBlob: Data,
                        becameVisibleHandler: @escaping (_ tooltipView: TooltipView) -> Void,
                        confirmation: @escaping @autoclosure () -> Bool,
                        completion: @escaping (_ cancelled: Bool) -> Void) {

        guard let presenter = self.dependencyManager.resolve(type: TooltipPresenterType.self) else {
            Logger.debug("Error: TooltipPresenterType couldn't be resolved")
            assertionFailure()
            return
        }
        guard let tooltipData = tooltip.tooltipData else {
            completion(true)
            return
        }

        DispatchQueue.main.async {
            self.displayedTooltips[identifier]?.removeFromSuperview()
            self.displayedTooltips[identifier] = nil

            guard let image = UIImage(data: imageBlob) else {
                self.reportError(description: "Invalid image data for tooltip targeting \(tooltipData.bodyData.uiElementIdentifier)", data: nil)
                completion(true)
                return
            }

            let superview = self.findParentViewForTooltip(targetView)
            guard superview != targetView else {
                self.reportError(description: "Cannot find suitable view for tooltip targeting \(tooltipData.bodyData.uiElementIdentifier)", data: targetView)
                completion(true)
                return
            }

            guard confirmation() else {
                completion(true)
                return
            }

            let tooltipView = TooltipView(presenter: presenter)
            presenter.set(view: tooltipView, dataModel: tooltip, image: image)
            presenter.onDismiss = { [weak self] cancelled in
                self?.displayedTooltips[identifier]?.removeFromSuperview()
                self?.displayedTooltips[identifier] = nil
                completion(cancelled)
            }

            self.displayedTooltips[identifier] = tooltipView
            self.commitTooltipDisplay(tooltipView: tooltipView,
                                      targetView: targetView,
                                      superview: superview,
                                      data: tooltipData,
                                      image: image,
                                      becameVisibleHandler: becameVisibleHandler)
        }
    }

    private func commitTooltipDisplay(tooltipView: TooltipView,
                                      targetView: UIView,
                                      superview: UIView,
                                      data: TooltipData,
                                      image: UIImage,
                                      becameVisibleHandler: @escaping (_ tooltipView: TooltipView) -> Void) {

        superview.addSubview(tooltipView)
        superview.layoutIfNeeded()
        if let displayedCampaign = superview.findIAMView() {
            superview.bringSubviewToFront(displayedCampaign)
        }
        let position = data.bodyData.position

        updateFrame(targetView: targetView, tooltipView: tooltipView, superview: superview, position: position)

        var didBecomeVisible = false
        weak var weakSelf = self
        func verifyVisibility() {
            if !didBecomeVisible && weakSelf?.isTooltipVisible(tooltipView) == true {
                didBecomeVisible = true
                becameVisibleHandler(tooltipView)
            }
        }
        verifyVisibility()

        let newPositionHandler = { [weak self] in
            self?.updateFrame(targetView: targetView, tooltipView: tooltipView, superview: superview, position: position)
            verifyVisibility()
        }

        if let parentScrollView = superview as? UIScrollView {
            let screenTransitionObserver = parentScrollView.observe(\.frame, options: []) { _, _ in
                newPositionHandler()
            }
            let viewVisibilityObserver = parentScrollView.observe(\.contentOffset, options: []) { _, _ in
                verifyVisibility()
            }
            positionObservers[tooltipView] = [screenTransitionObserver, viewVisibilityObserver]
        } else {
            let observer = targetView.observe(\.frame, options: []) { _, _ in
                newPositionHandler()
            }
            positionObservers[tooltipView] = [observer]
        }

        let orientationObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: nil) { _ in
            // async execution is needed to do position calculation after view layout is updated
            DispatchQueue.main.async(execute: newPositionHandler)
        }
        tooltipView.onDeinit = { [weak self] in
            self?.positionObservers[tooltipView] = nil
            NotificationCenter.default.removeObserver(orientationObserver)
        }
    }

    private func findParentView(rootView: UIView) -> UIView {
        // For accessibilityCompatible option, campaign view must be inserted to
        // UIWindow's main subview. Private instance of UITransitionView
        // shouldn't be used for that - that's why it's omitted.
        if accessibilityCompatibleDisplay,
           let transitionViewClass = NSClassFromString("UITransitionView"),
           let mainSubview = rootView.subviews.first(where: { !$0.isKind(of: transitionViewClass) }) {

            return mainSubview
        } else {
            return rootView
        }
    }

    private func findParentViewForTooltip(_ sourceView: UIView) -> UIView {
        guard let superview = sourceView.superview else {
            return sourceView
        }

        switch superview {
        case is UIScrollView:
            return superview
        case is UIWindow:
            if accessibilityCompatibleDisplay,
               let transitionViewClass = NSClassFromString("UITransitionView"),
               let transitionView = superview.subviews.first(where: { !$0.isKind(of: transitionViewClass) }) {

                return transitionView
            } else {
                return superview
            }
        default:
            return findParentViewForTooltip(superview)
        }
    }

    private func isTooltipVisible(_ toolTip: TooltipView) -> Bool {
        guard let window = UIApplication.shared.getKeyWindow(),
            let tooltipSuperview = toolTip.superview else {
            return false
        }
        let frameInWindow = window.convert(toolTip.frame, from: tooltipSuperview)
        return window.bounds.contains(frameInWindow)
    }

    private func updateFrame(targetView: UIView, tooltipView: TooltipView, superview: UIView, position: TooltipBodyData.Position) {
        guard targetView.superview != nil else {
            return
        }
        let targetViewFrame = superview.convert(targetView.frame, from: targetView.superview)

        switch position {
        case .topCenter:
            tooltipView.frame.origin = CGPoint(x: targetViewFrame.midX - tooltipView.frame.width / 2.0,
                                               y: targetViewFrame.origin.y - tooltipView.frame.height - UIConstants.Tooltip.targetViewSpacing)
        case .topLeft:
            tooltipView.frame.origin = CGPoint(x: targetViewFrame.minX - tooltipView.frame.width,
                                               y: targetViewFrame.origin.y - tooltipView.frame.height - UIConstants.Tooltip.targetViewSpacing)
        case .topRight:
            tooltipView.frame.origin = CGPoint(x: targetViewFrame.maxX,
                                               y: targetViewFrame.origin.y - tooltipView.frame.height - UIConstants.Tooltip.targetViewSpacing)
        case .bottomLeft:
            tooltipView.frame.origin = CGPoint(x: targetViewFrame.minX - tooltipView.frame.width,
                                               y: targetViewFrame.maxY + UIConstants.Tooltip.targetViewSpacing)
        case .bottomRight:
            tooltipView.frame.origin = CGPoint(x: targetViewFrame.maxX,
                                               y: targetViewFrame.maxY + UIConstants.Tooltip.targetViewSpacing)
        case .bottomCenter:
            tooltipView.frame.origin = CGPoint(x: targetViewFrame.midX - tooltipView.frame.width / 2.0,
                                               y: targetViewFrame.maxY + UIConstants.Tooltip.targetViewSpacing)
        case .left:
            tooltipView.frame.origin = CGPoint(x: targetViewFrame.minX - tooltipView.frame.width - UIConstants.Tooltip.targetViewSpacing,
                                               y: targetViewFrame.midY - tooltipView.frame.height / 2.0)
        case .right:
            tooltipView.frame.origin = CGPoint(x: targetViewFrame.maxX + UIConstants.Tooltip.targetViewSpacing,
                                               y: targetViewFrame.midY - tooltipView.frame.height / 2.0)
        }
    }
}

// MARK: - ViewListenerObserver
extension Router {
    func viewDidChangeSuperview(_ view: UIView, identifier: String) {
        // unused
    }

    func viewDidMoveToWindow(_ view: UIView, identifier: String) {
        // unused
    }

    func viewDidGetRemovedFromSuperview(_ view: UIView, identifier: String) {
        displayedTooltips[identifier]?.removeFromSuperview()
        displayedTooltips[identifier] = nil
    }

    func viewDidUpdateIdentifier(from: String?, to: String?, view: UIView) {
        if let oldIdentifier = from, displayedTooltips[oldIdentifier] != nil {
            if let newIdentifier = to {
                displayedTooltips[newIdentifier] = displayedTooltips[oldIdentifier]
                displayedTooltips[oldIdentifier] = nil
            } else {
                viewDidGetRemovedFromSuperview(view, identifier: oldIdentifier)
            }
        }
    }
}
