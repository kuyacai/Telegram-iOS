import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import TextSelectionNode
import ReactionSelectionNode
import TelegramCore
import SwiftSignalKit

private let animationDurationFactor: Double = 1.0

public enum ContextMenuActionItemTextLayout {
    case singleLine
    case twoLinesMax
    case secondLineWithValue(String)
}

public enum ContextMenuActionItemTextColor {
    case primary
    case destructive
}

public enum ContextMenuActionResult {
    case `default`
    case dismissWithoutContent
    case custom(ContainedViewLayoutTransition)
}

public final class ContextMenuActionItem {
    public let text: String
    public let textColor: ContextMenuActionItemTextColor
    public let textLayout: ContextMenuActionItemTextLayout
    public let icon: (PresentationTheme) -> UIImage?
    public let action: (ContextController, @escaping (ContextMenuActionResult) -> Void) -> Void
    
    public init(text: String, textColor: ContextMenuActionItemTextColor = .primary, textLayout: ContextMenuActionItemTextLayout = .twoLinesMax, icon: @escaping (PresentationTheme) -> UIImage?, action: @escaping (ContextController, @escaping (ContextMenuActionResult) -> Void) -> Void) {
        self.text = text
        self.textColor = textColor
        self.textLayout = textLayout
        self.icon = icon
        self.action = action
    }
}

public enum ContextMenuItem {
    case action(ContextMenuActionItem)
    case separator
}

private func convertFrame(_ frame: CGRect, from fromView: UIView, to toView: UIView) -> CGRect {
    let sourceWindowFrame = fromView.convert(frame, to: nil)
    var targetWindowFrame = toView.convert(sourceWindowFrame, from: nil)
    
    if let fromWindow = fromView.window, let toWindow = toView.window {
        targetWindowFrame.origin.x += toWindow.bounds.width - fromWindow.bounds.width
    }
    return targetWindowFrame
}

private final class ContextControllerNode: ViewControllerTracingNode, UIScrollViewDelegate {
    private var theme: PresentationTheme
    private var strings: PresentationStrings
    private let source: ContextContentSource
    private var items: Signal<[ContextMenuItem], NoError>
    private let beginDismiss: (ContextMenuActionResult) -> Void
    private let reactionSelected: (String) -> Void
    private let getController: () -> ContextController?
    private weak var gesture: ContextGesture?
    
    private var didSetItemsReady = false
    let itemsReady = Promise<Bool>()
    let contentReady = Promise<Bool>()
    
    private var currentItems: [ContextMenuItem]?
    
    private var validLayout: ContainerViewLayout?
    
    private let effectView: UIVisualEffectView
    private var propertyAnimator: AnyObject?
    private var displayLinkAnimator: DisplayLinkAnimator?
    private let dimNode: ASDisplayNode
    private let dismissNode: ASDisplayNode
    
    private let clippingNode: ASDisplayNode
    private let scrollNode: ASScrollNode
    
    private var originalProjectedContentViewFrame: (CGRect, CGRect)?
    private var contentAreaInScreenSpace: CGRect?
    private let contentContainerNode: ContextContentContainerNode
    private var actionsContainerNode: ContextActionsContainerNode
    private var reactionContextNode: ReactionContextNode?
    private var reactionContextNodeIsAnimatingOut = false
    
    private var didCompleteAnimationIn = false
    private var initialContinueGesturePoint: CGPoint?
    private var didMoveFromInitialGesturePoint = false
    private var highlightedActionNode: ContextActionNode?
    private var highlightedReaction: String?
    
    private let hapticFeedback = HapticFeedback()
    
    private var isAnimatingOut = false
    
    private let itemsDisposable = MetaDisposable()
    
    init(account: Account, controller: ContextController, theme: PresentationTheme, strings: PresentationStrings, source: ContextContentSource, items: Signal<[ContextMenuItem], NoError>, reactionItems: [ReactionContextItem], beginDismiss: @escaping (ContextMenuActionResult) -> Void, recognizer: TapLongTapOrDoubleTapGestureRecognizer?, gesture: ContextGesture?, reactionSelected: @escaping (String) -> Void) {
        self.theme = theme
        self.strings = strings
        self.source = source
        self.items = items
        self.beginDismiss = beginDismiss
        self.reactionSelected = reactionSelected
        self.gesture = gesture
        
        self.getController = { [weak controller] in
            return controller
        }
        
        self.effectView = UIVisualEffectView()
        if #available(iOS 9.0, *) {
        } else {
            if theme.rootController.keyboardColor == .dark {
                self.effectView.effect = UIBlurEffect(style: .dark)
            } else {
                self.effectView.effect = UIBlurEffect(style: .light)
            }
            self.effectView.alpha = 0.0
        }
        
        self.dimNode = ASDisplayNode()
        self.dimNode.backgroundColor = theme.contextMenu.dimColor
        self.dimNode.alpha = 0.0
        
        self.dismissNode = ASDisplayNode()
        
        self.clippingNode = ASDisplayNode()
        self.clippingNode.clipsToBounds = true
        
        self.scrollNode = ASScrollNode()
        self.scrollNode.canCancelAllTouchesInViews = true
        self.scrollNode.view.delaysContentTouches = false
        self.scrollNode.view.showsVerticalScrollIndicator = false
        if #available(iOS 11.0, *) {
            self.scrollNode.view.contentInsetAdjustmentBehavior = .never
        }
        
        self.contentContainerNode = ContextContentContainerNode()
        
        self.actionsContainerNode = ContextActionsContainerNode(theme: theme, items: [], getController: { [weak controller] in
            return controller
        }, actionSelected: { result in
            beginDismiss(result)
        })
        
        if !reactionItems.isEmpty {
            let reactionContextNode = ReactionContextNode(account: account, theme: theme, items: reactionItems)
            self.reactionContextNode = reactionContextNode
        } else {
            self.reactionContextNode = nil
        }
        
        super.init()
        
        self.scrollNode.view.delegate = self
        
        self.view.addSubview(self.effectView)
        self.addSubnode(self.dimNode)
        
        self.addSubnode(self.clippingNode)
        
        self.clippingNode.addSubnode(self.scrollNode)
        self.scrollNode.addSubnode(self.dismissNode)
        
        self.scrollNode.addSubnode(self.actionsContainerNode)
        self.scrollNode.addSubnode(self.contentContainerNode)
        self.reactionContextNode.flatMap(self.addSubnode)
        
        if let recognizer = recognizer {
            recognizer.externalUpdated = { [weak self, weak recognizer] view, point in
                guard let strongSelf = self, let _ = recognizer else {
                    return
                }
                let localPoint = strongSelf.view.convert(point, from: view)
                let initialPoint: CGPoint
                if let current = strongSelf.initialContinueGesturePoint {
                    initialPoint = current
                } else {
                    initialPoint = localPoint
                    strongSelf.initialContinueGesturePoint = localPoint
                }
                if strongSelf.didCompleteAnimationIn {
                    if !strongSelf.didMoveFromInitialGesturePoint {
                        let distance = abs(localPoint.y - initialPoint.y)
                        if distance > 4.0 {
                            strongSelf.didMoveFromInitialGesturePoint = true
                        }
                    }
                    if strongSelf.didMoveFromInitialGesturePoint {
                        let actionPoint = strongSelf.view.convert(localPoint, to: strongSelf.actionsContainerNode.view)
                        let actionNode = strongSelf.actionsContainerNode.actionNode(at: actionPoint)
                        if strongSelf.highlightedActionNode !== actionNode {
                            strongSelf.highlightedActionNode?.setIsHighlighted(false)
                            strongSelf.highlightedActionNode = actionNode
                            if let actionNode = actionNode {
                                actionNode.setIsHighlighted(true)
                                strongSelf.hapticFeedback.tap()
                            }
                        }
                        
                        if let reactionContextNode = strongSelf.reactionContextNode {
                            let highlightedReaction = reactionContextNode.reaction(at: strongSelf.view.convert(localPoint, to: reactionContextNode.view)).flatMap { value -> String? in
                                switch value {
                                case let .reaction(reaction, _, _):
                                    return reaction
                                default:
                                    return nil
                                }
                            }
                            if strongSelf.highlightedReaction != highlightedReaction {
                                strongSelf.highlightedReaction = highlightedReaction
                                reactionContextNode.setHighlightedReaction(highlightedReaction)
                                if let _ = highlightedReaction {
                                    strongSelf.hapticFeedback.tap()
                                }
                            }
                        }
                    }
                }
            }
            recognizer.externalEnded = { [weak self, weak recognizer] viewAndPoint in
                guard let strongSelf = self, let recognizer = recognizer else {
                    return
                }
                recognizer.externalUpdated = nil
                if strongSelf.didMoveFromInitialGesturePoint {
                    if let (_, _) = viewAndPoint {
                        if let highlightedActionNode = strongSelf.highlightedActionNode {
                            strongSelf.highlightedActionNode = nil
                            highlightedActionNode.performAction()
                        }
                        if let _ = strongSelf.reactionContextNode {
                            if let reaction = strongSelf.highlightedReaction {
                                strongSelf.reactionSelected(reaction)
                            }
                        }
                    } else {
                        if let highlightedActionNode = strongSelf.highlightedActionNode {
                            strongSelf.highlightedActionNode = nil
                            highlightedActionNode.setIsHighlighted(false)
                        }
                        if let reactionContextNode = strongSelf.reactionContextNode, let _ = strongSelf.highlightedReaction {
                            strongSelf.highlightedReaction = nil
                            reactionContextNode.setHighlightedReaction(nil)
                        }
                    }
                }
            }
        } else if let gesture = gesture {
            gesture.externalUpdated = { [weak self, weak gesture] view, point in
                guard let strongSelf = self, let _ = gesture else {
                    return
                }
                let localPoint = strongSelf.view.convert(point, from: view)
                let initialPoint: CGPoint
                if let current = strongSelf.initialContinueGesturePoint {
                    initialPoint = current
                } else {
                    initialPoint = localPoint
                    strongSelf.initialContinueGesturePoint = localPoint
                }
                if strongSelf.didCompleteAnimationIn {
                    if !strongSelf.didMoveFromInitialGesturePoint {
                        let distance = abs(localPoint.y - initialPoint.y)
                        if distance > 4.0 {
                            strongSelf.didMoveFromInitialGesturePoint = true
                        }
                    }
                    if strongSelf.didMoveFromInitialGesturePoint {
                        let actionPoint = strongSelf.view.convert(localPoint, to: strongSelf.actionsContainerNode.view)
                        let actionNode = strongSelf.actionsContainerNode.actionNode(at: actionPoint)
                        if strongSelf.highlightedActionNode !== actionNode {
                            strongSelf.highlightedActionNode?.setIsHighlighted(false)
                            strongSelf.highlightedActionNode = actionNode
                            if let actionNode = actionNode {
                                actionNode.setIsHighlighted(true)
                                strongSelf.hapticFeedback.tap()
                            }
                        }
                        
                        if let reactionContextNode = strongSelf.reactionContextNode {
                            let highlightedReaction = reactionContextNode.reaction(at: strongSelf.view.convert(localPoint, to: reactionContextNode.view)).flatMap { value -> String? in
                                switch value {
                                case let .reaction(reaction, _, _):
                                    return reaction
                                default:
                                    return nil
                                }
                            }
                            if strongSelf.highlightedReaction != highlightedReaction {
                                strongSelf.highlightedReaction = highlightedReaction
                                reactionContextNode.setHighlightedReaction(highlightedReaction)
                                if let _ = highlightedReaction {
                                    strongSelf.hapticFeedback.tap()
                                }
                            }
                        }
                    }
                }
            }
            gesture.externalEnded = { [weak self, weak gesture] viewAndPoint in
                guard let strongSelf = self, let gesture = gesture else {
                    return
                }
                gesture.externalUpdated = nil
                if strongSelf.didMoveFromInitialGesturePoint {
                    if let (_, _) = viewAndPoint {
                        if let highlightedActionNode = strongSelf.highlightedActionNode {
                            strongSelf.highlightedActionNode = nil
                            highlightedActionNode.performAction()
                        }
                        if let _ = strongSelf.reactionContextNode {
                            if let reaction = strongSelf.highlightedReaction {
                                strongSelf.reactionSelected(reaction)
                            }
                        }
                    } else {
                        if let highlightedActionNode = strongSelf.highlightedActionNode {
                            strongSelf.highlightedActionNode = nil
                            highlightedActionNode.setIsHighlighted(false)
                        }
                        if let reactionContextNode = strongSelf.reactionContextNode, let _ = strongSelf.highlightedReaction {
                            strongSelf.highlightedReaction = nil
                            reactionContextNode.setHighlightedReaction(nil)
                        }
                    }
                }
            }
        }
        
        if let reactionContextNode = self.reactionContextNode {
            reactionContextNode.reactionSelected = { [weak self] reaction in
                guard let _ = self else {
                    return
                }
                switch reaction {
                case let .reaction(value, _, _):
                    reactionSelected(value)
                default:
                    break
                }
            }
        }
        
        self.itemsDisposable.set((items
        |> deliverOnMainQueue).start(next: { [weak self] items in
            self?.setItems(items: items)
        }))
        
        switch source {
        case .extracted:
            self.contentReady.set(.single(true))
        case let .controller(source):
            self.contentReady.set(source.controller.ready.get())
        }
        
        self.initializeContent()
    }
    
    deinit {
        if let propertyAnimator = self.propertyAnimator {
            if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
                let propertyAnimator = propertyAnimator as? UIViewPropertyAnimator
                propertyAnimator?.stopAnimation(true)
            }
        }
        
        self.itemsDisposable.dispose()
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.dismissNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dimNodeTapped)))
    }
    
    @objc private func dimNodeTapped() {
        self.beginDismiss(.default)
    }
    
    private func initializeContent() {
        switch self.source {
        case let .extracted(source):
            let takenViewInfo = source.takeView()
            
            if let takenViewInfo = takenViewInfo, let parentSupernode = takenViewInfo.contentContainingNode.supernode {
                self.contentContainerNode.contentNode = .extracted(takenViewInfo.contentContainingNode)
                let contentParentNode = takenViewInfo.contentContainingNode
                takenViewInfo.contentContainingNode.layoutUpdated = { [weak contentParentNode, weak self] size in
                    guard let strongSelf = self, let contentParentNode = contentParentNode, let parentSupernode = contentParentNode.supernode else {
                        return
                    }
                    if strongSelf.isAnimatingOut {
                        return
                    }
                    strongSelf.originalProjectedContentViewFrame = (convertFrame(contentParentNode.frame, from: parentSupernode.view, to: strongSelf.view), convertFrame(contentParentNode.contentRect, from: contentParentNode.view, to: strongSelf.view))
                    if let validLayout = strongSelf.validLayout {
                        strongSelf.updateLayout(layout: validLayout, transition: .animated(duration: 0.2 * animationDurationFactor, curve: .easeInOut), previousActionsContainerNode: nil)
                    }
                }
                takenViewInfo.contentContainingNode.updateDistractionFreeMode = { [weak self] value in
                    guard let strongSelf = self, let reactionContextNode = strongSelf.reactionContextNode else {
                        return
                    }
                    if value {
                        if !reactionContextNode.alpha.isZero {
                            reactionContextNode.alpha = 0.0
                            reactionContextNode.allowsGroupOpacity = true
                            reactionContextNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3 * animationDurationFactor, completion: { [weak reactionContextNode] _ in
                                reactionContextNode?.allowsGroupOpacity = false
                            })
                        }
                    } else if reactionContextNode.alpha != 1.0 {
                        reactionContextNode.alpha = 1.0
                        reactionContextNode.allowsGroupOpacity = true
                        reactionContextNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3 * animationDurationFactor, completion: { [weak reactionContextNode] _ in
                            reactionContextNode?.allowsGroupOpacity = false
                        })
                    }
                }
                
                self.contentAreaInScreenSpace = takenViewInfo.contentAreaInScreenSpace
                self.contentContainerNode.addSubnode(takenViewInfo.contentContainingNode.contentNode)
                takenViewInfo.contentContainingNode.isExtractedToContextPreview = true
                takenViewInfo.contentContainingNode.isExtractedToContextPreviewUpdated?(true)
                
                self.originalProjectedContentViewFrame = (convertFrame(takenViewInfo.contentContainingNode.frame, from: parentSupernode.view, to: self.view), convertFrame(takenViewInfo.contentContainingNode.contentRect, from: takenViewInfo.contentContainingNode.view, to: self.view))
            }
        case let .controller(source):
            let contentParentNode = ContextControllerContentNode(controller: source.controller)
            self.contentContainerNode.contentNode = .controller(contentParentNode)
            self.contentContainerNode.clipsToBounds = true
            self.contentContainerNode.cornerRadius = 14.0
            self.contentContainerNode.addSubnode(contentParentNode)
            
            let transitionInfo = source.transitionInfo()
            if let transitionInfo = transitionInfo, let (sourceNode, sourceNodeRect) = transitionInfo.sourceNode() {
                let projectedFrame = convertFrame(sourceNodeRect, from: sourceNode.view, to: self.view)
                self.originalProjectedContentViewFrame = (projectedFrame, projectedFrame)
            }
        }
    }
    
    func animateIn() {
        self.gesture?.endPressedAppearance()
        
        self.hapticFeedback.impact()
        
        switch self.source {
        case let .extracted(source):
            if let contentAreaInScreenSpace = contentAreaInScreenSpace {
            var updatedContentAreaInScreenSpace = contentAreaInScreenSpace
                updatedContentAreaInScreenSpace.origin.x = 0.0
                updatedContentAreaInScreenSpace.size.width = self.bounds.width
                
                self.clippingNode.layer.animateFrame(from: updatedContentAreaInScreenSpace, to: self.clippingNode.frame, duration: 0.18 * animationDurationFactor, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
                self.clippingNode.layer.animateBoundsOriginYAdditive(from: updatedContentAreaInScreenSpace.minY, to: 0.0, duration: 0.18 * animationDurationFactor, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
            }
        case let .controller(source):
            let transitionInfo = source.transitionInfo()
            if let transitionInfo = transitionInfo, let (sourceNode, sourceNodeRect) = transitionInfo.sourceNode() {
                let projectedFrame = convertFrame(sourceNodeRect, from: sourceNode.view, to: self.view)
                self.originalProjectedContentViewFrame = (projectedFrame, projectedFrame)
                
                var updatedContentAreaInScreenSpace = transitionInfo.contentAreaInScreenSpace
                updatedContentAreaInScreenSpace.origin.x = 0.0
                updatedContentAreaInScreenSpace.size.width = self.bounds.width
                self.contentAreaInScreenSpace = updatedContentAreaInScreenSpace
            }
        }
        
        if let validLayout = self.validLayout {
            self.updateLayout(layout: validLayout, transition: .immediate, previousActionsContainerNode: nil)
        }
        
        self.dimNode.alpha = 1.0
        self.dimNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2 * animationDurationFactor)
        
        if #available(iOS 10.0, *) {
            if let propertyAnimator = self.propertyAnimator {
                let propertyAnimator = propertyAnimator as? UIViewPropertyAnimator
                propertyAnimator?.stopAnimation(true)
            }
            self.propertyAnimator = UIViewPropertyAnimator(duration: 0.2 * animationDurationFactor * UIView.animationDurationFactor(), curve: .easeInOut, animations: { [weak self] in
                self?.effectView.effect = makeCustomZoomBlurEffect()
            })
        }
        
        if let _ = self.propertyAnimator {
            if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
                self.displayLinkAnimator = DisplayLinkAnimator(duration: 0.2 * animationDurationFactor * UIView.animationDurationFactor(), from: 0.0, to: 1.0, update: { [weak self] value in
                    (self?.propertyAnimator as? UIViewPropertyAnimator)?.fractionComplete = value
                }, completion: { [weak self] in
                    self?.didCompleteAnimationIn = true
                    self?.hapticFeedback.prepareTap()
                })
            }
        } else {
            UIView.animate(withDuration: 0.2 * animationDurationFactor, animations: {
                self.effectView.effect = makeCustomZoomBlurEffect()
            }, completion: { [weak self] _ in
                self?.didCompleteAnimationIn = true
            })
        }
        
        if let contentNode = self.contentContainerNode.contentNode {
            switch contentNode {
            case let .extracted(extracted):
                let springDuration: Double = 0.42 * animationDurationFactor
                let springDamping: CGFloat = 104.0
                
                self.actionsContainerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2 * animationDurationFactor)
                self.actionsContainerNode.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: springDuration, initialVelocity: 0.0, damping: springDamping)
                
                if let originalProjectedContentViewFrame = self.originalProjectedContentViewFrame {
                    let contentParentNode = extracted
                    let localSourceFrame = self.view.convert(originalProjectedContentViewFrame.1, to: self.scrollNode.view)
                    
                    if let reactionContextNode = self.reactionContextNode {
                        reactionContextNode.animateIn(from: CGRect(origin: CGPoint(x: originalProjectedContentViewFrame.1.minX, y: originalProjectedContentViewFrame.1.minY), size: contentParentNode.contentRect.size))
                    }
                    
                    self.actionsContainerNode.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: localSourceFrame.center.x - self.actionsContainerNode.position.x, y: localSourceFrame.center.y - self.actionsContainerNode.position.y)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: springDuration, initialVelocity: 0.0, damping: springDamping, additive: true)
                    let contentContainerOffset = CGPoint(x: localSourceFrame.center.x - self.contentContainerNode.frame.center.x - contentParentNode.contentRect.minX, y: localSourceFrame.center.y - self.contentContainerNode.frame.center.y)
                    self.contentContainerNode.layer.animateSpring(from: NSValue(cgPoint: contentContainerOffset), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: springDuration, initialVelocity: 0.0, damping: springDamping, additive: true)
                    contentParentNode.applyAbsoluteOffsetSpring?(-contentContainerOffset.y, springDuration, springDamping)
                }
            case .controller:
                let springDuration: Double = 0.52 * animationDurationFactor
                let springDamping: CGFloat = 110.0
                
                self.actionsContainerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2 * animationDurationFactor)
                self.actionsContainerNode.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: springDuration, initialVelocity: 0.0, damping: springDamping)
                self.contentContainerNode.allowsGroupOpacity = true
                self.contentContainerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2 * animationDurationFactor, completion: { [weak self] _ in
                    self?.contentContainerNode.allowsGroupOpacity = false
                })
                self.contentContainerNode.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: springDuration, initialVelocity: 0.0, damping: springDamping)
                
                if let originalProjectedContentViewFrame = self.originalProjectedContentViewFrame {
                    let actionsSideInset: CGFloat = 11.0
                    
                    let localSourceFrame = self.view.convert(CGRect(origin: CGPoint(x: originalProjectedContentViewFrame.1.minX, y: originalProjectedContentViewFrame.1.minY), size: CGSize(width: originalProjectedContentViewFrame.1.width, height: originalProjectedContentViewFrame.1.height)), to: self.scrollNode.view)
                    self.actionsContainerNode.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: localSourceFrame.center.x - self.actionsContainerNode.position.x, y: localSourceFrame.center.y - self.actionsContainerNode.position.y)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: springDuration, initialVelocity: 0.0, damping: springDamping, additive: true)
                    let contentContainerOffset = CGPoint(x: localSourceFrame.center.x - self.contentContainerNode.frame.center.x, y: localSourceFrame.center.y - self.contentContainerNode.frame.center.y)
                    self.contentContainerNode.layer.animateSpring(from: NSValue(cgPoint: contentContainerOffset), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: springDuration, initialVelocity: 0.0, damping: springDamping, additive: true)
                }
            }
        }
    }
    
    func animateOut(result initialResult: ContextMenuActionResult, completion: @escaping () -> Void) {
        var transitionDuration: Double = 0.2
        var transitionCurve: ContainedViewLayoutTransitionCurve = .easeInOut
        
        var result = initialResult
        
        switch self.source {
        case let .extracted(source):
            guard let maybeContentNode = self.contentContainerNode.contentNode, case let .extracted(contentParentNode) = maybeContentNode else {
                return
            }
            
            let putBackInfo = source.putBack()
            
            if putBackInfo == nil {
                result = .dismissWithoutContent
            }
            
            switch result {
            case let .custom(value):
                switch value {
                case let .animated(duration, curve):
                    transitionDuration = duration
                    transitionCurve = curve
                default:
                    break
                }
            default:
                break
            }
            
            self.isUserInteractionEnabled = false
            self.isAnimatingOut = true
            
            self.scrollNode.view.setContentOffset(self.scrollNode.view.contentOffset, animated: false)
            
            var completedEffect = false
            var completedContentNode = false
            var completedActionsNode = false
            
            if let putBackInfo = putBackInfo, let parentSupernode = contentParentNode.supernode {
                self.originalProjectedContentViewFrame = (convertFrame(contentParentNode.frame, from: parentSupernode.view, to: self.view), convertFrame(contentParentNode.contentRect, from: contentParentNode.view, to: self.view))
                
                var updatedContentAreaInScreenSpace = putBackInfo.contentAreaInScreenSpace
                updatedContentAreaInScreenSpace.origin.x = 0.0
                updatedContentAreaInScreenSpace.size.width = self.bounds.width
                
                self.clippingNode.layer.animateFrame(from: self.clippingNode.frame, to: updatedContentAreaInScreenSpace, duration: transitionDuration * animationDurationFactor, timingFunction: transitionCurve.timingFunction, removeOnCompletion: false)
                self.clippingNode.layer.animateBoundsOriginYAdditive(from: 0.0, to: updatedContentAreaInScreenSpace.minY, duration: transitionDuration * animationDurationFactor, timingFunction: transitionCurve.timingFunction, removeOnCompletion: false)
            }
            
            contentParentNode.willUpdateIsExtractedToContextPreview?(false)
            
            let intermediateCompletion: () -> Void = { [weak contentParentNode] in
                if completedEffect && completedContentNode && completedActionsNode {
                    switch result {
                    case .default, .custom:
                        if let contentParentNode = contentParentNode {
                            contentParentNode.addSubnode(contentParentNode.contentNode)
                            contentParentNode.isExtractedToContextPreview = false
                            contentParentNode.isExtractedToContextPreviewUpdated?(false)
                        }
                    case .dismissWithoutContent:
                        break
                    }
                    
                    completion()
                }
            }
            
            if #available(iOS 10.0, *) {
                if let propertyAnimator = self.propertyAnimator {
                    let propertyAnimator = propertyAnimator as? UIViewPropertyAnimator
                    propertyAnimator?.stopAnimation(true)
                }
                self.propertyAnimator = UIViewPropertyAnimator(duration: transitionDuration * UIView.animationDurationFactor(), curve: .easeInOut, animations: { [weak self] in
                    self?.effectView.effect = nil
                })
            }
            
            if let _ = self.propertyAnimator {
                if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
                    self.displayLinkAnimator = DisplayLinkAnimator(duration: 0.2 * animationDurationFactor * UIView.animationDurationFactor(), from: 0.0, to: 0.999, update: { [weak self] value in
                        (self?.propertyAnimator as? UIViewPropertyAnimator)?.fractionComplete = value
                    }, completion: {
                        completedEffect = true
                        intermediateCompletion()
                    })
                }
                self.effectView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.05 * animationDurationFactor, delay: 0.15, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false)
            } else {
                UIView.animate(withDuration: 0.21 * animationDurationFactor, animations: {
                    if #available(iOS 9.0, *) {
                        self.effectView.effect = nil
                    } else {
                        self.effectView.alpha = 0.0
                    }
                }, completion: { _ in
                    completedEffect = true
                    intermediateCompletion()
                })
            }
            
            self.dimNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: transitionDuration * animationDurationFactor, removeOnCompletion: false)
            self.actionsContainerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2 * animationDurationFactor, removeOnCompletion: false, completion: { _ in
                completedActionsNode = true
                intermediateCompletion()
            })
            self.actionsContainerNode.layer.animateScale(from: 1.0, to: 0.1, duration: transitionDuration * animationDurationFactor, timingFunction: transitionCurve.timingFunction, removeOnCompletion: false)
            
            let animateOutToItem: Bool
            switch result {
            case .default, .custom:
                animateOutToItem = true
            case .dismissWithoutContent:
                animateOutToItem = false
            }
            
            if animateOutToItem, let originalProjectedContentViewFrame = self.originalProjectedContentViewFrame {
                let localSourceFrame = self.view.convert(originalProjectedContentViewFrame.1, to: self.scrollNode.view)
                self.actionsContainerNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: localSourceFrame.center.x - self.actionsContainerNode.position.x, y: localSourceFrame.center.y - self.actionsContainerNode.position.y), duration: transitionDuration * animationDurationFactor, timingFunction: transitionCurve.timingFunction, removeOnCompletion: false, additive: true)
                let contentContainerOffset = CGPoint(x: localSourceFrame.center.x - self.contentContainerNode.frame.center.x - contentParentNode.contentRect.minX, y: localSourceFrame.center.y - self.contentContainerNode.frame.center.y - contentParentNode.contentRect.minY)
                self.contentContainerNode.layer.animatePosition(from: CGPoint(), to: contentContainerOffset, duration: transitionDuration * animationDurationFactor, timingFunction: transitionCurve.timingFunction, removeOnCompletion: false, additive: true, completion: { _ in
                    completedContentNode = true
                    intermediateCompletion()
                })
                contentParentNode.updateAbsoluteRect?(self.contentContainerNode.frame.offsetBy(dx: 0.0, dy: -self.scrollNode.view.contentOffset.y + contentContainerOffset.y), self.bounds.size)
                contentParentNode.applyAbsoluteOffset?(-contentContainerOffset.y, transitionCurve, transitionDuration)
                
                if let reactionContextNode = self.reactionContextNode {
                    reactionContextNode.animateOut(to: CGRect(origin: CGPoint(x: originalProjectedContentViewFrame.1.minX, y: originalProjectedContentViewFrame.1.minY), size: contentParentNode.contentRect.size), animatingOutToReaction: self.reactionContextNodeIsAnimatingOut)
                }
            } else {
                if let snapshotView = contentParentNode.contentNode.view.snapshotContentTree() {
                    self.contentContainerNode.view.addSubview(snapshotView)
                }
                
                contentParentNode.addSubnode(contentParentNode.contentNode)
                contentParentNode.isExtractedToContextPreview = false
                contentParentNode.isExtractedToContextPreviewUpdated?(false)
                
                self.contentContainerNode.allowsGroupOpacity = true
                self.contentContainerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: transitionDuration * animationDurationFactor, removeOnCompletion: false, completion: { _ in
                    completedContentNode = true
                    intermediateCompletion()
                })
                //self.contentContainerNode.layer.animateScale(from: 1.0, to: 0.1, duration: transitionDuration * animationDurationFactor, removeOnCompletion: false)
                
                if let reactionContextNode = self.reactionContextNode {
                    reactionContextNode.animateOut(to: nil, animatingOutToReaction: self.reactionContextNodeIsAnimatingOut)
                }
            }
        case let .controller(source):
            guard let maybeContentNode = self.contentContainerNode.contentNode, case let .controller(controller) = maybeContentNode else {
                return
            }
            
            let transitionInfo = source.transitionInfo()
            
            if transitionInfo == nil {
                result = .dismissWithoutContent
            }
            
            switch result {
            case let .custom(value):
                switch value {
                case let .animated(duration, curve):
                    transitionDuration = duration
                    transitionCurve = curve
                default:
                    break
                }
            default:
                break
            }
            
            self.isUserInteractionEnabled = false
            self.isAnimatingOut = true
            
            self.scrollNode.view.setContentOffset(self.scrollNode.view.contentOffset, animated: false)
            
            var completedEffect = false
            var completedContentNode = false
            var completedActionsNode = false
            
            if let transitionInfo = transitionInfo, let (sourceNode, sourceNodeRect) = transitionInfo.sourceNode() {
                let projectedFrame = convertFrame(sourceNodeRect, from: sourceNode.view, to: self.view)
                self.originalProjectedContentViewFrame = (projectedFrame, projectedFrame)
                
                var updatedContentAreaInScreenSpace = transitionInfo.contentAreaInScreenSpace
                updatedContentAreaInScreenSpace.origin.x = 0.0
                updatedContentAreaInScreenSpace.size.width = self.bounds.width
            }
            
            let intermediateCompletion: () -> Void = {
                if completedEffect && completedContentNode && completedActionsNode {
                    switch result {
                    case .default, .custom:
                        break
                    case .dismissWithoutContent:
                        break
                    }
                    
                    completion()
                }
            }
            
            if #available(iOS 10.0, *) {
                if let propertyAnimator = self.propertyAnimator {
                    let propertyAnimator = propertyAnimator as? UIViewPropertyAnimator
                    propertyAnimator?.stopAnimation(true)
                }
                self.propertyAnimator = UIViewPropertyAnimator(duration: transitionDuration * UIView.animationDurationFactor(), curve: .easeInOut, animations: { [weak self] in
                    self?.effectView.effect = nil
                })
            }
            
            if let _ = self.propertyAnimator {
                if #available(iOSApplicationExtension 10.0, iOS 10.0, *) {
                    self.displayLinkAnimator = DisplayLinkAnimator(duration: 0.2 * animationDurationFactor * UIView.animationDurationFactor(), from: 0.0, to: 0.999, update: { [weak self] value in
                        (self?.propertyAnimator as? UIViewPropertyAnimator)?.fractionComplete = value
                        }, completion: {
                            completedEffect = true
                            intermediateCompletion()
                    })
                }
                self.effectView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.05 * animationDurationFactor, delay: 0.15, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false)
            } else {
                UIView.animate(withDuration: 0.21 * animationDurationFactor, animations: {
                    if #available(iOS 9.0, *) {
                        self.effectView.effect = nil
                    } else {
                        self.effectView.alpha = 0.0
                    }
                }, completion: { _ in
                    completedEffect = true
                    intermediateCompletion()
                })
            }
            
            self.dimNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: transitionDuration * animationDurationFactor, removeOnCompletion: false)
            self.actionsContainerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2 * animationDurationFactor, removeOnCompletion: false, completion: { _ in
                completedActionsNode = true
                intermediateCompletion()
            })
            self.contentContainerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2 * animationDurationFactor, removeOnCompletion: false, completion: { _ in
            })
            self.actionsContainerNode.layer.animateScale(from: 1.0, to: 0.1, duration: transitionDuration * animationDurationFactor, timingFunction: transitionCurve.timingFunction, removeOnCompletion: false)
            self.contentContainerNode.layer.animateScale(from: 1.0, to: 0.01, duration: transitionDuration * animationDurationFactor, timingFunction: transitionCurve.timingFunction, removeOnCompletion: false)
            
            let animateOutToItem: Bool
            switch result {
            case .default, .custom:
                animateOutToItem = true
            case .dismissWithoutContent:
                animateOutToItem = false
            }
            
            if animateOutToItem, let originalProjectedContentViewFrame = self.originalProjectedContentViewFrame {
                let actionsSideInset: CGFloat = 11.0
                
                let localSourceFrame = self.view.convert(CGRect(origin: CGPoint(x: originalProjectedContentViewFrame.1.minX, y: originalProjectedContentViewFrame.1.minY), size: CGSize(width: originalProjectedContentViewFrame.1.width, height: originalProjectedContentViewFrame.1.height)), to: self.scrollNode.view)
                
                self.actionsContainerNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: localSourceFrame.center.x - self.actionsContainerNode.position.x, y: localSourceFrame.center.y - self.actionsContainerNode.position.y), duration: transitionDuration * animationDurationFactor, timingFunction: transitionCurve.timingFunction, removeOnCompletion: false, additive: true)
                let contentContainerOffset = CGPoint(x: localSourceFrame.center.x - self.contentContainerNode.frame.center.x, y: localSourceFrame.center.y - self.contentContainerNode.frame.center.y)
                self.contentContainerNode.layer.animatePosition(from: CGPoint(), to: contentContainerOffset, duration: transitionDuration * animationDurationFactor, timingFunction: transitionCurve.timingFunction, removeOnCompletion: false, additive: true, completion: { _ in
                    completedContentNode = true
                    intermediateCompletion()
                })
            } else {
                if let snapshotView = controller.view.snapshotContentTree() {
                    self.contentContainerNode.view.addSubview(snapshotView)
                }
                
                self.contentContainerNode.allowsGroupOpacity = true
                self.contentContainerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: transitionDuration * animationDurationFactor, removeOnCompletion: false, completion: { _ in
                    completedContentNode = true
                    intermediateCompletion()
                })
                
                if let reactionContextNode = self.reactionContextNode {
                    reactionContextNode.animateOut(to: nil, animatingOutToReaction: self.reactionContextNodeIsAnimatingOut)
                }
            }
        }
    }
    
    func animateOutToReaction(value: String, into targetNode: ASImageNode, hideNode: Bool, completion: @escaping () -> Void) {
        guard let reactionContextNode = self.reactionContextNode else {
            self.animateOut(result: .default, completion: completion)
            return
        }
        var contentCompleted = false
        var reactionCompleted = false
        let intermediateCompletion: () -> Void = {
            if contentCompleted && reactionCompleted {
                completion()
            }
        }
        
        self.reactionContextNodeIsAnimatingOut = true
        self.animateOut(result: .default, completion: {
            contentCompleted = true
            intermediateCompletion()
        })
        reactionContextNode.animateOutToReaction(value: value, targetNode: targetNode, hideNode: hideNode, completion: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.reactionContextNode?.removeFromSupernode()
            strongSelf.reactionContextNode = nil
            reactionCompleted = true
            intermediateCompletion()
            /*strongSelf.animateOut(result: .default, completion: {
                reactionCompleted = true
                intermediateCompletion()
            })*/
        })
    }
    
    func setItemsSignal(items: Signal<[ContextMenuItem], NoError>) {
        self.items = items
        self.itemsDisposable.set((items
        |> deliverOnMainQueue).start(next: { [weak self] items in
            guard let strongSelf = self else {
                return
            }
            strongSelf.setItems(items: items)
        }))
    }
    
    private func setItems(items: [ContextMenuItem]) {
        self.currentItems = items
        
        let previousActionsContainerNode = self.actionsContainerNode
        self.actionsContainerNode = ContextActionsContainerNode(theme: self.theme, items: items, getController: { [weak self] in
            return self?.getController()
        }, actionSelected: { [weak self] result in
            self?.beginDismiss(result)
        })
        self.scrollNode.insertSubnode(self.actionsContainerNode, aboveSubnode: previousActionsContainerNode)
        
        if let layout = self.validLayout {
            self.updateLayout(layout: layout, transition: .animated(duration: 0.3, curve: .spring), previousActionsContainerNode: previousActionsContainerNode)
            
        } else {
            previousActionsContainerNode.removeFromSupernode()
        }
        
        if !self.didSetItemsReady {
            self.didSetItemsReady = true
            self.itemsReady.set(.single(true))
        }
    }
    
    func updateTheme(theme: PresentationTheme) {
        self.theme = theme
        
        self.dimNode.backgroundColor = theme.contextMenu.dimColor
        self.actionsContainerNode.updateTheme(theme: theme)
        
        if let validLayout = self.validLayout {
            self.updateLayout(layout: validLayout, transition: .immediate, previousActionsContainerNode: nil)
        }
    }
    
    func updateLayout(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition, previousActionsContainerNode: ContextActionsContainerNode?) {
        if self.isAnimatingOut {
            return
        }
        
        self.validLayout = layout
        
        var actionsContainerTransition = transition
        if previousActionsContainerNode != nil {
            actionsContainerTransition = .immediate
        }
        
        transition.updateFrame(view: self.effectView, frame: CGRect(origin: CGPoint(), size: layout.size))
        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        transition.updateFrame(node: self.clippingNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        
        transition.updateFrame(node: self.scrollNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        
        let actionsSideInset: CGFloat = 11.0
        var contentTopInset: CGFloat = max(11.0, layout.statusBarHeight ?? 0.0)
        if let _ = self.reactionContextNode {
            contentTopInset += 34.0
        }
        let actionsBottomInset: CGFloat = 11.0
        
        if let contentNode = self.contentContainerNode.contentNode {
            switch contentNode {
            case let .extracted(contentParentNode):
                let contentActionsSpacing: CGFloat = 8.0
                if let originalProjectedContentViewFrame = self.originalProjectedContentViewFrame {
                    let isInitialLayout = self.actionsContainerNode.frame.size.width.isZero
                    let previousContainerFrame = self.view.convert(self.contentContainerNode.frame, from: self.scrollNode.view)
                    
                    let actionsSize = self.actionsContainerNode.updateLayout(constrainedWidth: layout.size.width - actionsSideInset * 2.0, transition: actionsContainerTransition)
                    let contentSize = originalProjectedContentViewFrame.1.size
                    self.contentContainerNode.updateLayout(size: contentSize, scaledSize: contentSize, transition: transition)
                    
                    let maximumActionsFrameOrigin = max(60.0, layout.size.height - layout.intrinsicInsets.bottom - actionsBottomInset - actionsSize.height)
                    var originalActionsFrame = CGRect(origin: CGPoint(x: max(actionsSideInset, min(layout.size.width - actionsSize.width - actionsSideInset, originalProjectedContentViewFrame.1.minX)), y: min(originalProjectedContentViewFrame.1.maxY + contentActionsSpacing, maximumActionsFrameOrigin)), size: actionsSize)
                    var originalContentFrame = CGRect(origin: CGPoint(x: originalProjectedContentViewFrame.1.minX, y: originalActionsFrame.minY - contentActionsSpacing - originalProjectedContentViewFrame.1.size.height), size: originalProjectedContentViewFrame.1.size)
                    let topEdge = max(contentTopInset, self.contentAreaInScreenSpace?.minY ?? 0.0)
                    if originalContentFrame.minY < topEdge {
                        let requiredOffset = topEdge - originalContentFrame.minY
                        let availableOffset = max(0.0, layout.size.height - layout.intrinsicInsets.bottom - actionsBottomInset - originalActionsFrame.maxY)
                        let offset = min(requiredOffset, availableOffset)
                        originalActionsFrame = originalActionsFrame.offsetBy(dx: 0.0, dy: offset)
                        originalContentFrame = originalContentFrame.offsetBy(dx: 0.0, dy: offset)
                    }
                    
                    let contentHeight = max(layout.size.height, max(layout.size.height, originalActionsFrame.maxY + actionsBottomInset) - originalContentFrame.minY + contentTopInset)
                    
                    let scrollContentSize = CGSize(width: layout.size.width, height: contentHeight)
                    if self.scrollNode.view.contentSize != scrollContentSize {
                        self.scrollNode.view.contentSize = scrollContentSize
                    }
                    
                    let overflowOffset = min(0.0, originalContentFrame.minY - contentTopInset)
                    
                    let contentContainerFrame = originalContentFrame.offsetBy(dx: -contentParentNode.contentRect.minX, dy: -overflowOffset - contentParentNode.contentRect.minY)
                    transition.updateFrame(node: self.contentContainerNode, frame: contentContainerFrame)
                    actionsContainerTransition.updateFrame(node: self.actionsContainerNode, frame: originalActionsFrame.offsetBy(dx: 0.0, dy: -overflowOffset))
                    
                    if isInitialLayout {
                        self.scrollNode.view.contentOffset = CGPoint(x: 0.0, y: -overflowOffset)
                        let currentContainerFrame = self.view.convert(self.contentContainerNode.frame, from: self.scrollNode.view)
                        if overflowOffset < 0.0 {
                            transition.animateOffsetAdditive(node: self.scrollNode, offset: currentContainerFrame.minY - previousContainerFrame.minY)
                        }
                    }
                    
                    let absoluteContentRect = contentContainerFrame.offsetBy(dx: 0.0, dy: -self.scrollNode.view.contentOffset.y)
                    
                    contentParentNode.updateAbsoluteRect?(absoluteContentRect, layout.size)
                    
                    if let reactionContextNode = self.reactionContextNode {
                        let insets = layout.insets(options: [.statusBar])
                        transition.updateFrame(node: reactionContextNode, frame: CGRect(origin: CGPoint(), size: layout.size))
                        reactionContextNode.updateLayout(size: layout.size, insets: insets, anchorRect: CGRect(origin: CGPoint(x: absoluteContentRect.minX + contentParentNode.contentRect.minX, y: absoluteContentRect.minY + contentParentNode.contentRect.minY), size: contentParentNode.contentRect.size), transition: transition)
                    }
                }
            case let .controller(contentParentNode):
                let contentActionsSpacing: CGFloat = actionsSideInset
                let topEdge = max(contentTopInset, self.contentAreaInScreenSpace?.minY ?? 0.0)
                
                //contentParentNode.updateLayout(size: layout.size, transition: transition)
                
                let isInitialLayout = self.actionsContainerNode.frame.size.width.isZero
                let previousContainerFrame = self.view.convert(self.contentContainerNode.frame, from: self.scrollNode.view)
                
                let actionsSize = self.actionsContainerNode.updateLayout(constrainedWidth: layout.size.width - actionsSideInset * 2.0, transition: actionsContainerTransition)
                let contentScale = (layout.size.width - actionsSideInset * 2.0) / layout.size.width
                let contentUnscaledSize: CGSize
                if !contentParentNode.controller.preferredContentSize.width.isZero {
                    contentUnscaledSize = contentParentNode.controller.preferredContentSize
                } else {
                    let proposedContentHeight = layout.size.height - topEdge - contentActionsSpacing - actionsSize.height - layout.intrinsicInsets.bottom - actionsBottomInset
                    contentUnscaledSize = CGSize(width: layout.size.width, height: max(400.0, proposedContentHeight))
                }
                let contentSize = CGSize(width: floor(contentUnscaledSize.width * contentScale), height: floor(contentUnscaledSize.height * contentScale))
                
                self.contentContainerNode.updateLayout(size: contentUnscaledSize, scaledSize: contentSize, transition: transition)
                
                let maximumActionsFrameOrigin = max(60.0, layout.size.height - layout.intrinsicInsets.bottom - actionsBottomInset - actionsSize.height)
                var originalActionsFrame = CGRect(origin: CGPoint(x: actionsSideInset, y: min(maximumActionsFrameOrigin, floor((layout.size.height - contentActionsSpacing - contentSize.height) / 2.0) + contentSize.height + contentActionsSpacing)), size: actionsSize)
                var originalContentFrame = CGRect(origin: CGPoint(x: actionsSideInset, y: originalActionsFrame.minY - contentActionsSpacing - contentSize.height), size: contentSize)
                if originalContentFrame.minY < topEdge {
                    let requiredOffset = topEdge - originalContentFrame.minY
                    let availableOffset = max(0.0, layout.size.height - layout.intrinsicInsets.bottom - actionsBottomInset - originalActionsFrame.maxY)
                    let offset = min(requiredOffset, availableOffset)
                    originalActionsFrame = originalActionsFrame.offsetBy(dx: 0.0, dy: offset)
                    originalContentFrame = originalContentFrame.offsetBy(dx: 0.0, dy: offset)
                }
                
                let contentHeight = max(layout.size.height, max(layout.size.height, originalActionsFrame.maxY + actionsBottomInset) - originalContentFrame.minY + contentTopInset)
                
                let scrollContentSize = CGSize(width: layout.size.width, height: contentHeight)
                if self.scrollNode.view.contentSize != scrollContentSize {
                    self.scrollNode.view.contentSize = scrollContentSize
                }
                
                let overflowOffset = min(0.0, originalContentFrame.minY - contentTopInset)
                
                let contentContainerFrame = originalContentFrame
                transition.updateFrame(node: self.contentContainerNode, frame: contentContainerFrame.offsetBy(dx: 0.0, dy: -overflowOffset))
                actionsContainerTransition.updateFrame(node: self.actionsContainerNode, frame: originalActionsFrame.offsetBy(dx: 0.0, dy: -overflowOffset))
                
                if isInitialLayout {
                    self.scrollNode.view.contentOffset = CGPoint(x: 0.0, y: -overflowOffset)
                    let currentContainerFrame = self.view.convert(self.contentContainerNode.frame, from: self.scrollNode.view)
                    if overflowOffset < 0.0 {
                        transition.animateOffsetAdditive(node: self.scrollNode, offset: currentContainerFrame.minY - previousContainerFrame.minY)
                    }
                }
                
                let absoluteContentRect = contentContainerFrame.offsetBy(dx: 0.0, dy: -self.scrollNode.view.contentOffset.y)
                
                if let reactionContextNode = self.reactionContextNode {
                    let insets = layout.insets(options: [.statusBar])
                    transition.updateFrame(node: reactionContextNode, frame: CGRect(origin: CGPoint(), size: layout.size))
                    reactionContextNode.updateLayout(size: layout.size, insets: insets, anchorRect: CGRect(origin: CGPoint(x: absoluteContentRect.minX, y: absoluteContentRect.minY), size: contentSize), transition: transition)
                }
            }
        }
        
        if let previousActionsContainerNode = previousActionsContainerNode {
            if transition.isAnimated {
                transition.updateTransformScale(node: previousActionsContainerNode, scale: 0.1)
                previousActionsContainerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak previousActionsContainerNode] _ in
                    previousActionsContainerNode?.removeFromSupernode()
                })
                
                transition.animateTransformScale(node: self.actionsContainerNode, from: 0.1)
                if transition.isAnimated {
                    self.actionsContainerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                }
            } else {
                previousActionsContainerNode.removeFromSupernode()
            }
        }
        
        transition.updateFrame(node: self.dismissNode, frame: CGRect(origin: CGPoint(), size: scrollNode.view.contentSize))
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let layout = self.validLayout else {
            return
        }
        if let maybeContentNode = self.contentContainerNode.contentNode, case let .extracted(contentParentNode) = maybeContentNode {
            let contentContainerFrame = self.contentContainerNode.frame
            contentParentNode.updateAbsoluteRect?(contentContainerFrame.offsetBy(dx: 0.0, dy: -self.scrollNode.view.contentOffset.y), layout.size)
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.bounds.contains(point) {
            return nil
        }
        if let reactionContextNode = self.reactionContextNode {
            if let result = reactionContextNode.hitTest(self.view.convert(point, to: reactionContextNode.view), with: event) {
                return result
            }
        }
        let mappedPoint = self.view.convert(point, to: self.scrollNode.view)
        if let maybeContentNode = self.contentContainerNode.contentNode {
            switch maybeContentNode {
            case let .extracted(contentParentNode):
                let contentPoint = self.view.convert(point, to: contentParentNode.contentNode.view)
                if let result = contentParentNode.contentNode.hitTest(contentPoint, with: event) {
                    if result is TextSelectionNodeView {
                        return result
                    } else if contentParentNode.contentRect.contains(contentPoint) {
                        return contentParentNode.contentNode.view
                    }
                }
            case let .controller(controller):
                break
            }
        }
        
        if self.actionsContainerNode.frame.contains(mappedPoint) {
            return self.actionsContainerNode.hitTest(self.view.convert(point, to: self.actionsContainerNode.view), with: event)
        }
        
        return self.dismissNode.view
    }
}

public final class ContextControllerTakeViewInfo {
    public let contentContainingNode: ContextExtractedContentContainingNode
    public let contentAreaInScreenSpace: CGRect
    
    public init(contentContainingNode: ContextExtractedContentContainingNode, contentAreaInScreenSpace: CGRect) {
        self.contentContainingNode = contentContainingNode
        self.contentAreaInScreenSpace = contentAreaInScreenSpace
    }
}

public final class ContextControllerTakeControllerInfo {
    public let contentAreaInScreenSpace: CGRect
    public let sourceNode: () -> (ASDisplayNode, CGRect)?
    
    public init(contentAreaInScreenSpace: CGRect, sourceNode: @escaping () -> (ASDisplayNode, CGRect)?) {
        self.contentAreaInScreenSpace = contentAreaInScreenSpace
        self.sourceNode = sourceNode
    }
}

public final class ContextControllerPutBackViewInfo {
    public let contentAreaInScreenSpace: CGRect
    
    public init(contentAreaInScreenSpace: CGRect) {
        self.contentAreaInScreenSpace = contentAreaInScreenSpace
    }
}

public protocol ContextExtractedContentSource: class {
    func takeView() -> ContextControllerTakeViewInfo?
    func putBack() -> ContextControllerPutBackViewInfo?
}

public protocol ContextControllerContentSource: class {
    var controller: ViewController { get }
    func transitionInfo() -> ContextControllerTakeControllerInfo?
}

public enum ContextContentSource {
    case extracted(ContextExtractedContentSource)
    case controller(ContextControllerContentSource)
}

public final class ContextController: ViewController {
    private let account: Account
    private var theme: PresentationTheme
    private var strings: PresentationStrings
    private let source: ContextContentSource
    private var items: Signal<[ContextMenuItem], NoError>
    private var reactionItems: [ReactionContextItem]
    
    private let _ready = Promise<Bool>()
    override public var ready: Promise<Bool> {
        return self._ready
    }
    
    private weak var recognizer: TapLongTapOrDoubleTapGestureRecognizer?
    private weak var gesture: ContextGesture?
    
    private var animatedDidAppear = false
    private var wasDismissed = false
    
    private var controllerNode: ContextControllerNode {
        return self.displayNode as! ContextControllerNode
    }
    
    public var reactionSelected: ((String) -> Void)?
    
    public init(account: Account, theme: PresentationTheme, strings: PresentationStrings, source: ContextContentSource, items: Signal<[ContextMenuItem], NoError>, reactionItems: [ReactionContextItem], recognizer: TapLongTapOrDoubleTapGestureRecognizer? = nil, gesture: ContextGesture? = nil) {
        self.account = account
        self.theme = theme
        self.strings = strings
        self.source = source
        self.items = items
        self.reactionItems = reactionItems
        self.recognizer = recognizer
        self.gesture = gesture
        
        super.init(navigationBarPresentationData: nil)
        
        self.statusBar.statusBarStyle = .Hide
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func loadDisplayNode() {
        self.displayNode = ContextControllerNode(account: self.account, controller: self, theme: self.theme, strings: self.strings, source: self.source, items: self.items, reactionItems: self.reactionItems, beginDismiss: { [weak self] result in
            self?.dismiss(result: result, completion: nil)
            }, recognizer: self.recognizer, gesture: self.gesture, reactionSelected: { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            strongSelf.reactionSelected?(value)
        })
        
        self.displayNodeDidLoad()
        
        self._ready.set(combineLatest(queue: .mainQueue(), self.controllerNode.itemsReady.get(), self.controllerNode.contentReady.get())
        |> map { values in
            return values.0 && values.1
        })
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.controllerNode.updateLayout(layout: layout, transition: transition, previousActionsContainerNode: nil)
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        if self.ignoreAppearanceMethodInvocations() {
            return
        }
        super.viewDidAppear(animated)
        
        if !self.wasDismissed && !self.animatedDidAppear {
            self.animatedDidAppear = true
            self.controllerNode.animateIn()
        }
    }
    
    public func setItems(_ items: Signal<[ContextMenuItem], NoError>) {
        self.items = items
        if self.isNodeLoaded {
            self.controllerNode.setItemsSignal(items: items)
        }
    }
    
    public func updateTheme(theme: PresentationTheme) {
        self.theme = theme
        if self.isNodeLoaded {
            self.controllerNode.updateTheme(theme: theme)
        }
    }
    
    private func dismiss(result: ContextMenuActionResult, completion: (() -> Void)?) {
        if !self.wasDismissed {
            self.wasDismissed = true
            self.controllerNode.animateOut(result: result, completion: { [weak self] in
                self?.presentingViewController?.dismiss(animated: false, completion: nil)
                completion?()
            })
        }
    }
    
    override public func dismiss(completion: (() -> Void)? = nil) {
        self.dismiss(result: .default, completion: completion)
    }
    
    public func dismissWithReaction(value: String, into targetNode: ASImageNode, hideNode: Bool, completion: (() -> Void)?) {
        if !self.wasDismissed {
            self.wasDismissed = true
            self.controllerNode.animateOutToReaction(value: value, into: targetNode, hideNode: hideNode, completion: { [weak self] in
                self?.presentingViewController?.dismiss(animated: false, completion: nil)
                completion?()
            })
        }
    }
}