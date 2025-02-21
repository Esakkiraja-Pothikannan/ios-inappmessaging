import Foundation
import UIKit

internal protocol TooltipDispatcherDelegate: AnyObject {
    func performPing()
    func shouldShowTooltip(title: String, contexts: [String]) -> Bool
}

internal protocol TooltipDispatcherType: AnyObject {
    var delegate: TooltipDispatcherDelegate? { get set }

    func setNeedsDisplay(tooltip: Campaign)
}

internal class TooltipDispatcher: TooltipDispatcherType, ViewListenerObserver {

    private let router: RouterType
    private let permissionService: DisplayPermissionServiceType
    private let campaignRepository: CampaignRepositoryType
    private let viewListener: ViewListenerType
    private let dispatchQueue = DispatchQueue(label: "IAM.TooltipDisplay", qos: .userInteractive)
    private(set) var httpSession: URLSession
    private(set) var queuedTooltips = Set<Campaign>() // ensure to access only in dispatchQueue

    weak var delegate: TooltipDispatcherDelegate?

    init(router: RouterType,
         permissionService: DisplayPermissionServiceType,
         campaignRepository: CampaignRepositoryType,
         viewListener: ViewListenerType) {

        self.router = router
        self.permissionService = permissionService
        self.campaignRepository = campaignRepository
        self.viewListener = viewListener

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = Constants.CampaignMessage.imageRequestTimeoutSeconds
        sessionConfig.timeoutIntervalForResource = Constants.CampaignMessage.imageResourceTimeoutSeconds
        sessionConfig.waitsForConnectivity = true
        sessionConfig.urlCache = URLCache(
            // response must be <= 5% of mem/disk cap in order to committed to cache
            memoryCapacity: URLCache.shared.memoryCapacity,
            diskCapacity: 100*1024*1024, // fits up to 5MB images
            diskPath: "RInAppMessaging")
        httpSession = URLSession(configuration: sessionConfig)

        viewListener.addObserver(self)
    }

    func setNeedsDisplay(tooltip: Campaign) {
        dispatchQueue.async { [weak self] in
            guard let self = self,
                  !self.queuedTooltips.contains(tooltip) else {
                return
            }
            self.queuedTooltips.insert(tooltip)
            self.findViewAndDisplay(tooltip: tooltip)
        }
    }

    private func findViewAndDisplay(tooltip: Campaign) {
        guard let tooltipData = tooltip.tooltipData else {
            return
        }
        viewListener.iterateOverDisplayedViews { view, identifier, stop in
            if identifier.contains(tooltipData.bodyData.uiElementIdentifier) {
                stop = true
                self.dispatchQueue.async {
                    self.displayTooltip(tooltip, targetView: view, identifier: identifier)
                }
            }
        }
    }

    private func displayTooltip(_ tooltip: Campaign,
                                targetView: UIView,
                                identifier: String) {
        
        guard !router.isDisplayingTooltip(with: identifier) else {
            return
        }
        guard let resImgUrlString = tooltip.tooltipData?.imageUrl,
              let resImgUrl = URL(string: resImgUrlString)
        else {
            return
        }

        let permissionResponse = permissionService.checkPermission(forCampaign: tooltip.data)
        if permissionResponse.performPing {
            delegate?.performPing()
        }

        guard permissionResponse.display || tooltip.data.isTest else {
            return
        }

        let waitForImageDispatchGroup = DispatchGroup()
        waitForImageDispatchGroup.enter()

        data(from: resImgUrl) { imageBlob in
            guard let imageBlob = imageBlob else {
                // TOOLTIP: add retry?
                return
            }
            self.router.displayTooltip(
                tooltip,
                targetView: targetView,
                identifier: identifier,
                imageBlob: imageBlob,
                becameVisibleHandler: { tooltipView in
                    guard let autoCloseSeconds = tooltip.tooltipData?.bodyData.autoCloseSeconds, autoCloseSeconds > 0 else {
                        return
                    }
                    tooltipView.startAutoDisappearIfNeeded(seconds: autoCloseSeconds)
                },
                confirmation: {
                    let contexts = Array(tooltip.contexts.dropFirst()) // first context will always be "Tooltip"
                    let tooltipTitle = tooltip.data.messagePayload.title
                    guard let delegate = self.delegate, !contexts.isEmpty, !tooltip.data.isTest else {
                        return true
                    }
                    let shouldShow = delegate.shouldShowTooltip(title: tooltipTitle,
                                                                contexts: contexts)
                    return shouldShow
                }(),
                completion: { cancelled in
                    self.handleDisplayCompletion(cancelled: cancelled, tooltip: tooltip)
                }
            )
            waitForImageDispatchGroup.leave()
        }
    }

    private func handleDisplayCompletion(cancelled: Bool, tooltip: Campaign) {
        dispatchQueue.async {
            if !cancelled {
                self.campaignRepository.decrementImpressionsLeftInCampaign(id: tooltip.id)
            }
            self.queuedTooltips.remove(tooltip)
        }
    }

    private func data(from url: URL, completion: @escaping (Data?) -> Void) {
        httpSession.dataTask(with: URLRequest(url: url)) { (data, _, error) in
            guard error == nil else {
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }
}

// MARK: - ViewListenerObserver
extension TooltipDispatcher {

    func viewDidChangeSuperview(_ view: UIView, identifier: String) {
        guard view.superview != nil else {
            return
        }

        // refresh currently displayed tooltip or
        // restore tooltip if view appeared again
        dispatchQueue.async { [weak self] in
            if let tooltip = self?.queuedTooltips.first(where: {
                guard let tooltipData = $0.tooltipData else {
                    return false
                }
                return identifier.contains(tooltipData.bodyData.uiElementIdentifier)
            }) {
                self?.displayTooltip(tooltip, targetView: view, identifier: identifier)
            }
        }
    }

    func viewDidMoveToWindow(_ view: UIView, identifier: String) {
        viewDidChangeSuperview(view, identifier: identifier)
    }

    func viewDidGetRemovedFromSuperview(_ view: UIView, identifier: String) {
        // unused
    }

    func viewDidUpdateIdentifier(from: String?, to: String?, view: UIView) {
        if let newIdentifier = to {
            viewDidMoveToWindow(view, identifier: newIdentifier)
        }
    }
}
