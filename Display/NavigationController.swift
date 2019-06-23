import Foundation
import UIKit
import AsyncDisplayKit
import SwiftSignalKit

public final class NavigationControllerTheme {
    public let navigationBar: NavigationBarTheme
    public let emptyAreaColor: UIColor
    public let emptyDetailIcon: UIImage?
    
    public init(navigationBar: NavigationBarTheme, emptyAreaColor: UIColor, emptyDetailIcon: UIImage?) {
        self.navigationBar = navigationBar
        self.emptyAreaColor = emptyAreaColor
        self.emptyDetailIcon = emptyDetailIcon
    }
}

private final class NavigationControllerContainerView: UIView {
    override class var layerClass: AnyClass {
        return CATracingLayer.self
    }
}

private final class NavigationControllerView: UITracingLayerView {
    var inTransition = false
    
    let sharedStatusBar: StatusBar
    let containerView: NavigationControllerContainerView
    let separatorView: UIView
    var navigationBackgroundView: UIView?
    var navigationSeparatorView: UIView?
    var emptyDetailView: UIImageView?
    
    var topControllerNode: ASDisplayNode?
    
    /*override var accessibilityElements: [Any]? {
        get {
            var accessibilityElements: [Any] = []
            if let topControllerNode = self.topControllerNode {
                addAccessibilityChildren(of: topControllerNode, container: self, to: &accessibilityElements)
            }
            return accessibilityElements
        } set(value) {
        }
    }*/
    
    override init(frame: CGRect) {
        self.containerView = NavigationControllerContainerView()
        self.separatorView = UIView()
        self.sharedStatusBar = StatusBar()
        
        super.init(frame: frame)
        
        self.addSubview(self.containerView)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override class var layerClass: AnyClass {
        return CATracingLayer.self
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.bounds.contains(point) && self.inTransition {
            return self
        }
        return super.hitTest(point, with: event)
    }
}

private enum ControllerTransition {
    case none
    case appearance
}

private final class ControllerRecord {
    let controller: UIViewController
    var transition: ControllerTransition = .none
    
    init(controller: UIViewController) {
        self.controller = controller
    }
}

private enum ControllerLayoutConfiguration {
    case single
    case masterDetail
}

public enum NavigationControllerMode {
    case single
    case automaticMasterDetail
}

open class NavigationController: UINavigationController, ContainableController, UIGestureRecognizerDelegate {
    public var isOpaqueWhenInOverlay: Bool = true
    public var blocksBackgroundWhenInOverlay: Bool = true
    
    public var ready: Promise<Bool> = Promise(true)
    
    public var lockOrientation: Bool = false
    
    public var deferScreenEdgeGestures: UIRectEdge = UIRectEdge()
    
    private let mode: NavigationControllerMode
    private var theme: NavigationControllerTheme
    
    public private(set) weak var overlayPresentingController: ViewController?
    
    private var controllerView: NavigationControllerView {
        return self.view as! NavigationControllerView
    }
    
    private var validLayout: ContainerViewLayout?
    
    private var scheduledLayoutTransitionRequestId: Int = 0
    private var scheduledLayoutTransitionRequest: (Int, ContainedViewLayoutTransition)?
    
    private var navigationTransitionCoordinator: NavigationTransitionCoordinator?
    
    private var currentPushDisposable = MetaDisposable()
    private var currentPresentDisposable = MetaDisposable()
    
    private var _presentedViewController: UIViewController?
    open override var presentedViewController: UIViewController? {
        return self._presentedViewController
    }
    
    private var _viewControllers: [ControllerRecord] = []
    override open var viewControllers: [UIViewController] {
        get {
            return self._viewControllers.map { $0.controller }
        } set(value) {
            self.setViewControllers(value, animated: false)
        }
    }
    
    override open var topViewController: UIViewController? {
        return self._viewControllers.last?.controller
    }
    
    private var _displayNode: ASDisplayNode?
    public var displayNode: ASDisplayNode {
        return self._displayNode!
    }
    
    public init(mode: NavigationControllerMode, theme: NavigationControllerTheme) {
        self.mode = mode
        self.theme = theme
        
        super.init(nibName: nil, bundle: nil)
    }
    
    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        preconditionFailure()
    }
    
    public required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.currentPushDisposable.dispose()
        self.currentPresentDisposable.dispose()
    }
    
    public func combinedSupportedOrientations(currentOrientationToLock: UIInterfaceOrientationMask) -> ViewControllerSupportedOrientations {
        var supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .allButUpsideDown)
        if let controller = self.viewControllers.last {
            if let controller = controller as? ViewController {
                if controller.lockOrientation {
                    if let lockedOrientation = controller.lockedOrientation {
                        supportedOrientations = supportedOrientations.intersection(ViewControllerSupportedOrientations(regularSize: lockedOrientation, compactSize: lockedOrientation))
                    } else {
                        supportedOrientations = supportedOrientations.intersection(ViewControllerSupportedOrientations(regularSize: currentOrientationToLock, compactSize: currentOrientationToLock))
                    }
                } else {
                    supportedOrientations = supportedOrientations.intersection(controller.supportedOrientations)
                }
            }
        }
        return supportedOrientations
    }
    
    public func updateTheme(_ theme: NavigationControllerTheme) {
        self.theme = theme
        if self.isViewLoaded {
            self.controllerView.backgroundColor = theme.emptyAreaColor
            self.controllerView.separatorView.backgroundColor = theme.navigationBar.separatorColor
            self.controllerView.navigationBackgroundView?.backgroundColor = theme.navigationBar.backgroundColor
            self.controllerView.navigationSeparatorView?.backgroundColor = theme.navigationBar.separatorColor
            if let emptyDetailView = self.controllerView.emptyDetailView {
                emptyDetailView.image = theme.emptyDetailIcon
                if let image = theme.emptyDetailIcon {
                    emptyDetailView.frame = CGRect(origin: CGPoint(x: floor(emptyDetailView.center.x - image.size.width / 2.0), y: floor(emptyDetailView.center.y - image.size.height / 2.0)), size: image.size)
                }
            }
        }
    }
    
    private var previouslyLaidOutMasterController: UIViewController?
    private var previouslyLaidOutTopController: UIViewController?
    
    private func layoutConfiguration(for layout: ContainerViewLayout) -> ControllerLayoutConfiguration {
        switch self.mode {
            case .single:
                return .single
            case .automaticMasterDetail:
                if case .regular = layout.metrics.widthClass, case .regular = layout.metrics.heightClass {
                    if layout.size.width > 690.0 {
                        return .masterDetail
                    }
                }
                return .single
        }
    }
    
    private func layoutDataForConfiguration(_ layoutConfiguration: ControllerLayoutConfiguration, layout: ContainerViewLayout, index: Int) -> (CGRect, ContainerViewLayout) {
        switch layoutConfiguration {
            case .masterDetail:
                let masterWidth: CGFloat = max(320.0, floor(layout.size.width / 3.0))
                let detailWidth: CGFloat = layout.size.width - masterWidth
                if index == 0 {
                    return (CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: masterWidth, height: layout.size.height)), ContainerViewLayout(size: CGSize(width: masterWidth, height: layout.size.height), metrics: layout.metrics, intrinsicInsets: layout.intrinsicInsets, safeInsets: layout.safeInsets, statusBarHeight: layout.statusBarHeight, inputHeight: layout.inputHeight, standardInputHeight: layout.standardInputHeight, inputHeightIsInteractivellyChanging: layout.inputHeightIsInteractivellyChanging, inVoiceOver: layout.inVoiceOver))
                } else {
                    let detailFrame = CGRect(origin: CGPoint(x: masterWidth, y: 0.0), size: CGSize(width: detailWidth, height: layout.size.height))
                    return (CGRect(origin: CGPoint(), size: detailFrame.size), ContainerViewLayout(size: CGSize(width: detailWidth, height: layout.size.height), metrics: LayoutMetrics(widthClass: .regular, heightClass: .regular), intrinsicInsets: layout.intrinsicInsets, safeInsets: layout.safeInsets, statusBarHeight: layout.statusBarHeight, inputHeight: layout.inputHeight, standardInputHeight: layout.standardInputHeight, inputHeightIsInteractivellyChanging: layout.inputHeightIsInteractivellyChanging, inVoiceOver: layout.inVoiceOver))
                }
            case .single:
                return (CGRect(origin: CGPoint(), size: CGSize(width: layout.size.width, height: layout.size.height)), ContainerViewLayout(size: CGSize(width: layout.size.width, height: layout.size.height), metrics: LayoutMetrics(widthClass: .compact, heightClass: .compact), intrinsicInsets: layout.intrinsicInsets, safeInsets: layout.safeInsets, statusBarHeight: layout.statusBarHeight, inputHeight: layout.inputHeight, standardInputHeight: layout.standardInputHeight, inputHeightIsInteractivellyChanging: layout.inputHeightIsInteractivellyChanging, inVoiceOver: layout.inVoiceOver))
        }
    }
    
    private func updateControllerLayouts(previousControllers: [ControllerRecord], layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        var firstControllerFrameAndLayout: (CGRect, ContainerViewLayout)?
        let lastControllerFrameAndLayout: (CGRect, ContainerViewLayout)
        
        let layoutConfiguration = self.layoutConfiguration(for: layout)
        
        switch layoutConfiguration {
            case .masterDetail:
                self.viewControllers.first?.view.clipsToBounds = true
                self.controllerView.containerView.clipsToBounds = true
                let masterData = layoutDataForConfiguration(layoutConfiguration, layout: layout, index: 0)
                firstControllerFrameAndLayout = masterData
                lastControllerFrameAndLayout = layoutDataForConfiguration(layoutConfiguration, layout: layout, index: 1)
                if self.controllerView.separatorView.superview == nil {
                    self.controllerView.addSubview(self.controllerView.separatorView)
                }
                
                let navigationBackgroundFrame = CGRect(origin: CGPoint(x: masterData.0.maxX, y: 0.0), size: CGSize(width: lastControllerFrameAndLayout.0.width, height: (layout.statusBarHeight ?? 0.0) + 44.0))
                
                if let navigationBackgroundView = self.controllerView.navigationBackgroundView, let navigationSeparatorView = self.controllerView.navigationSeparatorView, let emptyDetailView = self.controllerView.emptyDetailView {
                    transition.updateFrame(view: navigationBackgroundView, frame: navigationBackgroundFrame)
                    transition.updateFrame(view: navigationSeparatorView, frame: CGRect(origin: CGPoint(x: navigationBackgroundFrame.minX, y: navigationBackgroundFrame.maxY), size: CGSize(width: navigationBackgroundFrame.width, height: UIScreenPixel)))
                    if let image = emptyDetailView.image {
                        transition.updateFrame(view: emptyDetailView, frame: CGRect(origin: CGPoint(x: masterData.0.maxX + floor((lastControllerFrameAndLayout.0.size.width - image.size.width) / 2.0), y: floor((lastControllerFrameAndLayout.0.size.height - image.size.height) / 2.0)), size: image.size))
                    }
                } else {
                    let navigationBackgroundView = UIView()
                    navigationBackgroundView.backgroundColor = self.theme.navigationBar.backgroundColor
                    let navigationSeparatorView = UIView()
                    navigationSeparatorView.backgroundColor = self.theme.navigationBar.separatorColor
                    let emptyDetailView = UIImageView()
                    emptyDetailView.image = self.theme.emptyDetailIcon
                    emptyDetailView.alpha = 0.0
                    
                    self.controllerView.navigationBackgroundView = navigationBackgroundView
                    self.controllerView.navigationSeparatorView = navigationSeparatorView
                    self.controllerView.emptyDetailView = emptyDetailView
                    
                    self.controllerView.insertSubview(navigationBackgroundView, at: 0)
                    self.controllerView.insertSubview(navigationSeparatorView, at: 1)
                    self.controllerView.insertSubview(emptyDetailView, at: 2)
                    
                    navigationBackgroundView.frame = navigationBackgroundFrame
                    navigationSeparatorView.frame = CGRect(origin: CGPoint(x: navigationBackgroundFrame.minX, y: navigationBackgroundFrame.maxY), size: CGSize(width: navigationBackgroundFrame.width, height: UIScreenPixel))
                    
                    transition.animatePositionAdditive(layer: navigationBackgroundView.layer, offset: CGPoint(x: navigationBackgroundFrame.width, y: 0.0))
                    transition.animatePositionAdditive(layer: navigationSeparatorView.layer, offset: CGPoint(x: navigationBackgroundFrame.width, y: 0.0))
                    
                    if let image = emptyDetailView.image {
                        emptyDetailView.frame = CGRect(origin: CGPoint(x: masterData.0.maxX + floor((lastControllerFrameAndLayout.0.size.width - image.size.width) / 2.0), y: floor((lastControllerFrameAndLayout.0.size.height - image.size.height) / 2.0)), size: image.size)
                    }
                    
                    transition.updateAlpha(layer: emptyDetailView.layer, alpha: 1.0)
                }
                transition.updateFrame(view: self.controllerView.separatorView, frame: CGRect(origin: CGPoint(x: masterData.0.maxX, y: 0.0), size: CGSize(width: UIScreenPixel, height: layout.size.height)))
            case .single:
                self.viewControllers.first?.view.clipsToBounds = false
                if let navigationBackgroundView = self.controllerView.navigationBackgroundView, let navigationSeparatorView = self.controllerView.navigationSeparatorView {
                    self.controllerView.navigationBackgroundView = nil
                    self.controllerView.navigationSeparatorView = nil
                    
                    transition.updatePosition(layer: navigationBackgroundView.layer, position: CGPoint(x: layout.size.width + navigationBackgroundView.bounds.size.width / 2.0, y: navigationBackgroundView.center.y), completion: { [weak navigationBackgroundView] _ in
                        navigationBackgroundView?.removeFromSuperview()
                    })
                    transition.updatePosition(layer: navigationSeparatorView.layer, position: CGPoint(x: layout.size.width + navigationSeparatorView.bounds.size.width / 2.0, y: navigationSeparatorView.center.y), completion: { [weak navigationSeparatorView] _ in
                        navigationSeparatorView?.removeFromSuperview()
                    })
                    if let emptyDetailView = self.controllerView.emptyDetailView {
                        self.controllerView.emptyDetailView = nil
                        transition.updateAlpha(layer: emptyDetailView.layer, alpha: 0.0, completion: { [weak emptyDetailView] _ in
                            emptyDetailView?.removeFromSuperview()
                        })
                    }
                }
                self.controllerView.containerView.clipsToBounds = false
                lastControllerFrameAndLayout = layoutDataForConfiguration(layoutConfiguration, layout: layout, index: 1)
                transition.updateFrame(view: self.controllerView.separatorView, frame: CGRect(origin: CGPoint(x: -UIScreenPixel, y: 0.0), size: CGSize(width: UIScreenPixel, height: layout.size.height)), completion: { [weak self] completed in
                    if let strongSelf = self, completed {
                        strongSelf.controllerView.separatorView.removeFromSuperview()
                    }
                })
        }
        transition.updateFrame(view: self.controllerView.containerView, frame: CGRect(origin: CGPoint(x: firstControllerFrameAndLayout?.0.maxX ?? 0.0, y: 0.0), size: lastControllerFrameAndLayout.0.size))
        
        switch layoutConfiguration {
            case .single:
                if self.controllerView.sharedStatusBar.view.superview != nil {
                    self.controllerView.sharedStatusBar.removeFromSupernode()
                    self.controllerView.containerView.layer.setTraceableInfo(nil)
                }
            case .masterDetail:
                if self.controllerView.sharedStatusBar.view.superview == nil {
                    self.controllerView.addSubnode(self.controllerView.sharedStatusBar)
                    self.controllerView.containerView.layer.setTraceableInfo(CATracingLayerInfo(shouldBeAdjustedToInverseTransform: true, userData: self, tracingTag: 0, disableChildrenTracingTags: WindowTracingTags.statusBar | WindowTracingTags.keyboard))
                }
        }
        
        if let _ = layout.statusBarHeight {
            self.controllerView.sharedStatusBar.frame = CGRect(origin: CGPoint(), size: CGSize(width: layout.size.width, height: 40.0))
        }
        
        var controllersAndFrames: [(Bool, ControllerRecord, ContainerViewLayout)] = []
        for i in 0 ..< self._viewControllers.count {
            if let controller = self._viewControllers[i].controller as? ViewController {
                if i == 0 {
                    controller.navigationBar?.previousItem = nil
                } else if case .masterDetail = layoutConfiguration, i == 1 {
                    controller.navigationBar?.previousItem = .close
                } else {
                    controller.navigationBar?.previousItem = .item(viewControllers[i - 1].navigationItem)
                }
            }
            viewControllers[i].navigation_setNavigationController(self)
            
            if i == 0, let (_, layout) = firstControllerFrameAndLayout {
                controllersAndFrames.append((true, self._viewControllers[i], layout))
            } else if i == self._viewControllers.count - 1 {
                controllersAndFrames.append((false, self._viewControllers[i], lastControllerFrameAndLayout.1))
            }
        }
        
        var masterController: UIViewController?
        var appearingMasterController: ControllerRecord?
        var appearingDetailController: ControllerRecord?
        
        for (isMaster, record, layout) in controllersAndFrames {
            let frame: CGRect
            if isMaster, let firstControllerFrameAndLayout = firstControllerFrameAndLayout {
                masterController = record.controller
                frame = firstControllerFrameAndLayout.0
                if let controller = masterController as? ViewController {
                    self.controllerView.sharedStatusBar.statusBarStyle = controller.statusBar.statusBarStyle
                }
            } else {
                frame = lastControllerFrameAndLayout.0
            }
            let isAppearing = record.controller.view.superview == nil
            (record.controller as? ViewController)?.containerLayoutUpdated(layout, transition: isAppearing ? .immediate : transition)
            if isAppearing {
                if isMaster {
                    appearingMasterController = record
                } else {
                    appearingDetailController = record
                }
            } else if record.controller.view.superview !== (isMaster ? self.controllerView : self.controllerView.containerView) {
                record.controller.setIgnoreAppearanceMethodInvocations(true)
                if isMaster {
                    self.controllerView.insertSubview(record.controller.view, at: 0)
                } else {
                    self.controllerView.containerView.addSubview(record.controller.view)
                }
                record.controller.setIgnoreAppearanceMethodInvocations(false)
            }
            if !isAppearing {
                var isPartOfTransition = false
                if let navigationTransitionCoordinator = self.navigationTransitionCoordinator {
                    if navigationTransitionCoordinator.topView == record.controller.view || navigationTransitionCoordinator.bottomView == record.controller.view {
                        isPartOfTransition = true
                    }
                }
                if !isPartOfTransition {
                    transition.updateFrame(view: record.controller.view, frame: frame)
                }
            }
        }
        
        var animatedAppearingDetailController = false
        
        if let previousController = self.previouslyLaidOutTopController, !controllersAndFrames.contains(where: { $0.1.controller === previousController }), previousController.view.superview != nil {
            if transition.isAnimated, let record = appearingDetailController {
                animatedAppearingDetailController = true
                
                previousController.viewWillDisappear(true)
                record.controller.viewWillAppear(true)
                record.controller.setIgnoreAppearanceMethodInvocations(true)
                
                if let controller = record.controller as? ViewController, !controller.hasActiveInput {
                    let (_, controllerLayout) = self.layoutDataForConfiguration(self.layoutConfiguration(for: layout), layout: layout, index: 1)
                    
                    let appliedLayout = controllerLayout.withUpdatedInputHeight(controller.hasActiveInput ? controllerLayout.inputHeight : nil)
                    controller.containerLayoutUpdated(appliedLayout, transition: .immediate)
                }
                self.controllerView.containerView.addSubview(record.controller.view)
                record.controller.setIgnoreAppearanceMethodInvocations(false)
                
                if let _ = previousControllers.index(where: { $0.controller === record.controller }) {
                    //previousControllers[index].transition = .appearance
                    let transitionType: NavigationTransition = .Pop
                    let navigationTransitionCoordinator = NavigationTransitionCoordinator(transition: transitionType, container: self.controllerView.containerView, topView: previousController.view, topNavigationBar: (previousController as? ViewController)?.navigationBar, bottomView: record.controller.view, bottomNavigationBar: (record.controller as? ViewController)?.navigationBar, alongsideTransition: (record.controller as? ViewController)?.navigationAlongsideTransition(type: transitionType))
                    self.navigationTransitionCoordinator = navigationTransitionCoordinator
                    
                    self.controllerView.inTransition = true
                    navigationTransitionCoordinator.animateCompletion(0.0, completion: { [weak self] in
                        if let strongSelf = self {
                            strongSelf.navigationTransitionCoordinator = nil
                            strongSelf.controllerView.inTransition = false
                            
                            record.controller.viewDidAppear(true)
                            
                            previousController.setIgnoreAppearanceMethodInvocations(true)
                            previousController.view.removeFromSuperview()
                            previousController.setIgnoreAppearanceMethodInvocations(false)
                            previousController.viewDidDisappear(true)
                        }
                    })
                } else {
                    if let index = self._viewControllers.index(where: { $0.controller === previousController }) {
                        self._viewControllers[index].transition = .appearance
                    }
                    let navigationTransitionCoordinator = NavigationTransitionCoordinator(transition: .Push, container: self.controllerView.containerView, topView: record.controller.view, topNavigationBar: (record.controller as? ViewController)?.navigationBar, bottomView: previousController.view, bottomNavigationBar: (previousController as? ViewController)?.navigationBar)
                    self.navigationTransitionCoordinator = navigationTransitionCoordinator
                    
                    self.controllerView.inTransition = true
                    navigationTransitionCoordinator.animateCompletion(0.0, completion: { [weak self] in
                        if let strongSelf = self {
                            if let index = strongSelf._viewControllers.index(where: { $0.controller === previousController }) {
                                strongSelf._viewControllers[index].transition = .none
                            }
                            strongSelf.navigationTransitionCoordinator = nil
                            strongSelf.controllerView.inTransition = false
                            
                            record.controller.viewDidAppear(true)
                            
                            previousController.setIgnoreAppearanceMethodInvocations(true)
                            previousController.view.removeFromSuperview()
                            previousController.setIgnoreAppearanceMethodInvocations(false)
                            previousController.viewDidDisappear(true)
                        }
                    })
                }
            } else {
                previousController.viewWillDisappear(false)
                previousController.view.removeFromSuperview()
                previousController.viewDidDisappear(false)
            }
        }
        
        if !animatedAppearingDetailController, let record = appearingDetailController {
            record.controller.viewWillAppear(false)
            record.controller.setIgnoreAppearanceMethodInvocations(true)
            self.controllerView.containerView.addSubview(record.controller.view)
            record.controller.setIgnoreAppearanceMethodInvocations(false)
            record.controller.viewDidAppear(false)
            if let controller = record.controller as? ViewController {
                controller.displayNode.recursivelyEnsureDisplaySynchronously(true)
            }
        }
        
        if let record = appearingMasterController, let firstControllerFrameAndLayout = firstControllerFrameAndLayout {
            record.controller.viewWillAppear(false)
            record.controller.setIgnoreAppearanceMethodInvocations(true)
            self.controllerView.insertSubview(record.controller.view, belowSubview: self.controllerView.containerView)
            record.controller.setIgnoreAppearanceMethodInvocations(false)
            record.controller.viewDidAppear(false)
            if let controller = record.controller as? ViewController {
                controller.displayNode.recursivelyEnsureDisplaySynchronously(true)
            }
            
            record.controller.view.frame = firstControllerFrameAndLayout.0
            record.controller.viewDidAppear(transition.isAnimated)
            transition.animatePositionAdditive(layer: record.controller.view.layer, offset: CGPoint(x: -firstControllerFrameAndLayout.0.width, y: 0.0))
        }
        
        for record in self._viewControllers {
            let controller = record.controller
            if case .none = record.transition, !controllersAndFrames.contains(where: { $0.1.controller === controller }) {
                if controller === self.previouslyLaidOutMasterController {
                    controller.viewWillDisappear(true)
                    record.transition = .appearance
                    transition.animatePositionAdditive(layer: controller.view.layer, offset: CGPoint(), to: CGPoint(x: -controller.view.bounds.size.width, y: 0.0), removeOnCompletion: false, completion: { [weak self] in
                        if let strongSelf = self {
                            controller.setIgnoreAppearanceMethodInvocations(true)
                            controller.view.removeFromSuperview()
                            controller.setIgnoreAppearanceMethodInvocations(false)
                            controller.viewDidDisappear(true)
                            controller.view.layer.removeAllAnimations()
                            for r in strongSelf._viewControllers {
                                if r.controller === controller {
                                    r.transition = .none
                                }
                            }
                        }
                    })
                } else {
                    if controller.isViewLoaded && controller.view.superview != nil {
                        var isPartOfTransition = false
                        if let navigationTransitionCoordinator = self.navigationTransitionCoordinator {
                            if navigationTransitionCoordinator.topView == controller.view || navigationTransitionCoordinator.bottomView == controller.view {
                                isPartOfTransition = true
                            }
                        }
                        
                        if !isPartOfTransition {
                            controller.viewWillDisappear(false)
                            controller.setIgnoreAppearanceMethodInvocations(true)
                            controller.view.removeFromSuperview()
                            controller.setIgnoreAppearanceMethodInvocations(false)
                            controller.viewDidDisappear(false)
                        }
                    }
                }
            }
        }
        
        for previous in previousControllers {
            var isFound = false
            inner: for current in self._viewControllers {
                if previous.controller === current.controller {
                    isFound = true
                    break inner
                }
            }
            if !isFound {
                (previous.controller as? ViewController)?.navigationStackConfigurationUpdated(next: [])
            }
        }
        
        (self.view as! NavigationControllerView).topControllerNode = (self._viewControllers.last?.controller as? ViewController)?.displayNode
        
        for i in 0 ..< self._viewControllers.count {
            var currentNext: UIViewController? = (i == (self._viewControllers.count - 1)) ? nil : self._viewControllers[i + 1].controller
            if case .single = layoutConfiguration {
                currentNext = nil
            }
            
            var previousNext: UIViewController?
            inner: for j in 0 ..< previousControllers.count {
                if previousControllers[j].controller === self._viewControllers[i].controller {
                    previousNext = (j == (previousControllers.count - 1)) ? nil : previousControllers[j + 1].controller
                    break inner
                }
            }
            
            if currentNext !== previousNext {
                let next = currentNext as? ViewController
                (self._viewControllers[i].controller as? ViewController)?.navigationStackConfigurationUpdated(next: next == nil ? [] : [next!])
            }
        }
        
        self.previouslyLaidOutMasterController = masterController
        self.previouslyLaidOutTopController = self._viewControllers.last?.controller
    }
    
    public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        if !self.isViewLoaded {
            self.loadView()
        }
        self.validLayout = layout
        transition.updateFrame(view: self.view, frame: CGRect(origin: self.view.frame.origin, size: layout.size))
        
        self.updateControllerLayouts(previousControllers: self._viewControllers, layout: layout, transition: transition)
        
        if let presentedViewController = self.presentedViewController {
            let containedLayout = ContainerViewLayout(size: layout.size, metrics: layout.metrics, intrinsicInsets: layout.intrinsicInsets, safeInsets: layout.safeInsets, statusBarHeight: layout.statusBarHeight, inputHeight: layout.inputHeight, standardInputHeight: layout.standardInputHeight, inputHeightIsInteractivellyChanging: layout.inputHeightIsInteractivellyChanging, inVoiceOver: layout.inVoiceOver)
            
            if let presentedViewController = presentedViewController as? ContainableController {
                presentedViewController.containerLayoutUpdated(containedLayout, transition: transition)
            } else {
                transition.updateFrame(view: presentedViewController.view, frame: CGRect(x: 0.0, y: 0.0, width: layout.size.width, height: layout.size.height))
            }
        }
        
        if let navigationTransitionCoordinator = self.navigationTransitionCoordinator {
            navigationTransitionCoordinator.updateProgress()
        }
    }
    
    public func updateToInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        for record in self._viewControllers {
            if let controller = record.controller as? ContainableController {
                controller.updateToInterfaceOrientation(orientation)
            }
        }
    }
    
    open override func loadView() {
        self._displayNode = ASDisplayNode(viewBlock: {
            return NavigationControllerView()
        }, didLoad: nil)
        
        self.view = self.displayNode.view
        self.view.clipsToBounds = true
        self.view.autoresizingMask = []
        
        self.controllerView.backgroundColor = self.theme.emptyAreaColor
        self.controllerView.separatorView.backgroundColor = theme.navigationBar.separatorColor
        
        if #available(iOSApplicationExtension 11.0, *) {
            self.navigationBar.prefersLargeTitles = false
        }
        self.navigationBar.removeFromSuperview()
        
        let panRecognizer = InteractiveTransitionGestureRecognizer(target: self, action: #selector(self.panGesture(_:)))
        panRecognizer.delegate = self
        panRecognizer.delaysTouchesBegan = false
        panRecognizer.cancelsTouchesInView = true
        self.view.addGestureRecognizer(panRecognizer)
        
        if self.topViewController != nil {
            self.topViewController?.view.frame = CGRect(origin: CGPoint(), size: self.view.frame.size)
        }
    }
    
    @objc func panGesture(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
            case UIGestureRecognizerState.began:
                guard let layout = self.validLayout else {
                    return
                }
                guard self.navigationTransitionCoordinator == nil else {
                    return
                }
                let beginGesture: Bool
                switch self.layoutConfiguration(for: layout) {
                    case .masterDetail:
                        let location = recognizer.location(in: self.controllerView.containerView)
                        if self.controllerView.containerView.bounds.contains(location) {
                            beginGesture = self._viewControllers.count >= 3
                        } else {
                            beginGesture = false
                        }
                    case .single:
                        beginGesture = self._viewControllers.count >= 2
                }
                
                if beginGesture {
                    let topController = self.viewControllers[self.viewControllers.count - 1] as UIViewController
                    let bottomController = self.viewControllers[self.viewControllers.count - 2] as UIViewController
                    
                    if let topController = topController as? ViewController {
                        if !topController.attemptNavigation({ [weak self] in
                            let _ = self?.popViewController(animated: true)
                        }) {
                            return
                        }
                    }
                    
                    topController.viewWillDisappear(true)
                    let topView = topController.view!
                    if let bottomController = bottomController as? ViewController {
                        let (_, controllerLayout) = self.layoutDataForConfiguration(self.layoutConfiguration(for: layout), layout: layout, index: self.viewControllers.count - 2)
                        
                        let appliedLayout = controllerLayout.withUpdatedInputHeight(bottomController.hasActiveInput ? controllerLayout.inputHeight : nil)
                        bottomController.containerLayoutUpdated(appliedLayout, transition: .immediate)
                    }
                    bottomController.viewWillAppear(true)
                    let bottomView = bottomController.view!
                    
                    if let bottomController = bottomController as? ViewController {
                        bottomController.displayNode.recursivelyEnsureDisplaySynchronously(true)
                    }
                    
                    let transitionType: NavigationTransition = .Pop
                    let navigationTransitionCoordinator = NavigationTransitionCoordinator(transition: transitionType, container: self.controllerView.containerView, topView: topView, topNavigationBar: (topController as? ViewController)?.navigationBar, bottomView: bottomView, bottomNavigationBar: (bottomController as? ViewController)?.navigationBar, alongsideTransition: (bottomController as? ViewController)?.navigationAlongsideTransition(type: transitionType))
                    self.navigationTransitionCoordinator = navigationTransitionCoordinator
                }
            case UIGestureRecognizerState.changed:
                if let navigationTransitionCoordinator = self.navigationTransitionCoordinator, !navigationTransitionCoordinator.animatingCompletion {
                    let translation = recognizer.translation(in: self.view).x
                    navigationTransitionCoordinator.progress = max(0.0, min(1.0, translation / self.view.frame.width))
                }
            case UIGestureRecognizerState.ended:
                if let navigationTransitionCoordinator = self.navigationTransitionCoordinator, !navigationTransitionCoordinator.animatingCompletion {
                    let velocity = recognizer.velocity(in: self.view).x
                    
                    if velocity > 1000 || navigationTransitionCoordinator.progress > 0.2 {
                        (self.view as! NavigationControllerView).inTransition = true
                        navigationTransitionCoordinator.animateCompletion(velocity, completion: {
                            (self.view as! NavigationControllerView).inTransition = false
                            
                            self.navigationTransitionCoordinator = nil
                            
                            if self.viewControllers.count >= 2 && self.navigationTransitionCoordinator == nil {
                                let topController = self.viewControllers[self.viewControllers.count - 1] as UIViewController
                                let bottomController = self.viewControllers[self.viewControllers.count - 2] as UIViewController
                                
                                topController.setIgnoreAppearanceMethodInvocations(true)
                                bottomController.setIgnoreAppearanceMethodInvocations(true)
                                let _ = self.popViewController(animated: false)
                                topController.setIgnoreAppearanceMethodInvocations(false)
                                bottomController.setIgnoreAppearanceMethodInvocations(false)
                                
                                topController.viewDidDisappear(true)
                                bottomController.viewDidAppear(true)
                            }
                        })
                    } else {
                        if self.viewControllers.count >= 2 && self.navigationTransitionCoordinator == nil {
                            let topController = self.viewControllers[self.viewControllers.count - 1] as UIViewController
                            let bottomController = self.viewControllers[self.viewControllers.count - 2] as UIViewController
                            
                            topController.viewWillAppear(true)
                            bottomController.viewWillDisappear(true)
                        }
                        
                        (self.view as! NavigationControllerView).inTransition = true
                        navigationTransitionCoordinator.animateCancel({
                            (self.view as! NavigationControllerView).inTransition = false
                            self.navigationTransitionCoordinator = nil
                            
                            if self.viewControllers.count >= 2 && self.navigationTransitionCoordinator == nil {
                                let topController = self.viewControllers[self.viewControllers.count - 1] as UIViewController
                                let bottomController = self.viewControllers[self.viewControllers.count - 2] as UIViewController
                                
                                topController.viewDidAppear(true)
                                bottomController.viewDidDisappear(true)
                            }
                        })
                    }
                }
            case .cancelled:
                if let navigationTransitionCoordinator = self.navigationTransitionCoordinator, !navigationTransitionCoordinator.animatingCompletion {
                    if self.viewControllers.count >= 2 && self.navigationTransitionCoordinator == nil {
                        let topController = self.viewControllers[self.viewControllers.count - 1] as UIViewController
                        let bottomController = self.viewControllers[self.viewControllers.count - 2] as UIViewController
                        
                        topController.viewWillAppear(true)
                        bottomController.viewWillDisappear(true)
                    }
                    
                    (self.view as! NavigationControllerView).inTransition = true
                    navigationTransitionCoordinator.animateCancel({
                        (self.view as! NavigationControllerView).inTransition = false
                        self.navigationTransitionCoordinator = nil
                        
                        if self.viewControllers.count >= 2 && self.navigationTransitionCoordinator == nil {
                            let topController = self.viewControllers[self.viewControllers.count - 1] as UIViewController
                            let bottomController = self.viewControllers[self.viewControllers.count - 2] as UIViewController
                            
                            topController.viewDidAppear(true)
                            bottomController.viewDidDisappear(true)
                        }
                    })
                }
            default:
                break
        }
    }
    
    public func pushViewController(_ controller: ViewController) {
        self.pushViewController(controller, completion: {})
    }
    
    public func pushViewController(_ controller: ViewController, animated: Bool = true, completion: @escaping () -> Void) {
        let navigateAction: () -> Void = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            
            if !controller.hasActiveInput {
                strongSelf.view.endEditing(true)
            }
            strongSelf.scheduleAfterLayout({
                guard let strongSelf = self else {
                    return
                }
        
                if let validLayout = strongSelf.validLayout {
                    let (_, controllerLayout) = strongSelf.layoutDataForConfiguration(strongSelf.layoutConfiguration(for: validLayout), layout: validLayout, index: strongSelf.viewControllers.count)
                    
                    let appliedLayout = controllerLayout.withUpdatedInputHeight(controller.hasActiveInput ? controllerLayout.inputHeight : nil)
                    controller.containerLayoutUpdated(appliedLayout, transition: .immediate)
                    strongSelf.currentPushDisposable.set((controller.ready.get() |> take(1)).start(next: { _ in
                        guard let strongSelf = self else {
                            return
                        }
                        
                        if let validLayout = strongSelf.validLayout {
                            let (_, controllerLayout) = strongSelf.layoutDataForConfiguration(strongSelf.layoutConfiguration(for: validLayout), layout: validLayout, index: strongSelf.viewControllers.count)
                            
                            let containerLayout = controllerLayout.withUpdatedInputHeight(controller.hasActiveInput ? controllerLayout.inputHeight : nil)
                            if containerLayout != appliedLayout {
                                controller.containerLayoutUpdated(containerLayout, transition: .immediate)
                            }
                            strongSelf.pushViewController(controller, animated: animated)
                        }
                    }))
                } else {
                    strongSelf.pushViewController(controller, animated: false)
                }
            })
        }
        
        if let lastController = self.viewControllers.last as? ViewController, !lastController.attemptNavigation(navigateAction) {
        } else {
            navigateAction()
        }
    }
    
    open override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        self.currentPushDisposable.set(nil)
        
        var controllers = self.viewControllers
        controllers.append(viewController)
        self.setViewControllers(controllers, animated: animated)
    }
    
    public func replaceTopController(_ controller: ViewController, animated: Bool, ready: ValuePromise<Bool>? = nil) {
        self.view.endEditing(true)
        if !controller.hasActiveInput {
            self.view.endEditing(true)
        }
        if let validLayout = self.validLayout {
            var (_, controllerLayout) = self.layoutDataForConfiguration(self.layoutConfiguration(for: validLayout), layout: validLayout, index: self.viewControllers.count)
            controllerLayout.inputHeight = nil
            controller.containerLayoutUpdated(controllerLayout, transition: .immediate)
        }
        self.currentPushDisposable.set((controller.ready.get() |> take(1)).start(next: { [weak self] _ in
            if let strongSelf = self {
                ready?.set(true)
                var controllers = strongSelf.viewControllers
                controllers.removeLast()
                controllers.append(controller)
                strongSelf.setViewControllers(controllers, animated: animated)
            }
        }))
    }
    
    public func filterController(_ controller: ViewController, animated: Bool) {
        let controllers = self.viewControllers.filter({ $0 !== controller })
        if controllers.count != self.viewControllers.count {
            self.setViewControllers(controllers, animated: animated)
        }
    }
    
    public func replaceControllersAndPush(controllers: [UIViewController], controller: ViewController, animated: Bool, ready: ValuePromise<Bool>? = nil, completion: @escaping () -> Void = {}) {
        self.view.endEditing(true)
        self.scheduleAfterLayout { [weak self] in
            guard let strongSelf = self else {
                return
            }
            if let validLayout = strongSelf.validLayout {
                var (_, controllerLayout) = strongSelf.layoutDataForConfiguration(strongSelf.layoutConfiguration(for: validLayout), layout: validLayout, index: strongSelf.viewControllers.count)
                controllerLayout.inputHeight = nil
                controller.containerLayoutUpdated(controllerLayout, transition: .immediate)
            }
            strongSelf.currentPushDisposable.set((controller.ready.get() |> take(1)).start(next: { _ in
                guard let strongSelf = self else {
                    return
                }
                ready?.set(true)
                var controllers = controllers
                controllers.append(controller)
                strongSelf.setViewControllers(controllers, animated: animated)
                completion()
            }))
        }
    }
    
    public func replaceAllButRootController(_ controller: ViewController, animated: Bool, ready: ValuePromise<Bool>? = nil, completion: @escaping () -> Void = {}) {
        self.view.endEditing(true)
        self.scheduleAfterLayout { [weak self] in
            guard let strongSelf = self else {
                return
            }
            if let validLayout = strongSelf.validLayout {
                var (_, controllerLayout) = strongSelf.layoutDataForConfiguration(strongSelf.layoutConfiguration(for: validLayout), layout: validLayout, index: strongSelf.viewControllers.count)
                controllerLayout.inputHeight = nil
                controller.containerLayoutUpdated(controllerLayout, transition: .immediate)
            }
            strongSelf.currentPushDisposable.set((controller.ready.get() |> take(1)).start(next: { _ in
                guard let strongSelf = self else {
                    return
                }
                ready?.set(true)
                var controllers = strongSelf.viewControllers
                while controllers.count > 1 {
                    controllers.removeLast()
                }
                controllers.append(controller)
                strongSelf.setViewControllers(controllers, animated: animated)
                completion()
            }))
        }
    }

    public func popToRoot(animated: Bool) {
        var controllers = self.viewControllers
        while controllers.count > 1 {
            controllers.removeLast()
        }
        self.setViewControllers(controllers, animated: animated)
    }
    
    override open func popToViewController(_ viewController: UIViewController, animated: Bool) -> [UIViewController]? {
        var poppedControllers: [UIViewController] = []
        var found = false
        var controllers = self.viewControllers
        if !controllers.contains(where: { $0 === viewController }) {
            return nil
        }
        while !controllers.isEmpty {
            if controllers[controllers.count - 1] === viewController {
                found = true
                break
            }
            poppedControllers.insert(controllers[controllers.count - 1], at: 0)
            controllers.removeLast()
        }
        if found {
            self.setViewControllers(controllers, animated: animated)
            return poppedControllers
        } else {
            return nil
        }
    }
    
    open override func popViewController(animated: Bool) -> UIViewController? {
        var controller: UIViewController?
        var controllers = self.viewControllers
        if controllers.count != 0 {
            controller = controllers[controllers.count - 1] as UIViewController
            controllers.remove(at: controllers.count - 1)
            self.setViewControllers(controllers, animated: animated)
        }
        return controller
    }
    
    open override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        var resultControllers: [ControllerRecord] = []
        for controller in viewControllers {
            var found = false
            inner: for current in self._viewControllers {
                if current.controller === controller {
                    resultControllers.append(current)
                    found = true
                    break inner
                }
            }
            if !found {
                resultControllers.append(ControllerRecord(controller: controller))
            }
        }
        let previousControllers = self._viewControllers
        self._viewControllers = resultControllers
        if let navigationTransitionCoordinator = self.navigationTransitionCoordinator {
            navigationTransitionCoordinator.complete()
        }
        if let layout = self.validLayout {
            self.updateControllerLayouts(previousControllers: previousControllers, layout: layout, transition: animated ? .animated(duration: 0.5, curve: .spring) : .immediate)
        }
    }
    
    override open func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        if let controller = viewControllerToPresent as? NavigationController {
            controller.navigation_setDismiss({ [weak self] in
                if let strongSelf = self {
                    strongSelf.dismiss(animated: false, completion: nil)
                }
            }, rootController: self.view!.window!.rootViewController)
            self._presentedViewController = controller
            
            self.view.endEditing(true)
            if let validLayout = self.validLayout {
                controller.containerLayoutUpdated(validLayout, transition: .immediate)
            }
            
            var ready: Signal<Bool, NoError> = .single(true)
            
            if let controller = controller.topViewController as? ViewController {
                ready = controller.ready.get()
                |> filter { $0 }
                |> take(1)
                |> deliverOnMainQueue
            }
            
            self.currentPresentDisposable.set(ready.start(next: { [weak self] _ in
                if let strongSelf = self {
                    if flag {
                        controller.view.frame = strongSelf.view.bounds.offsetBy(dx: 0.0, dy: strongSelf.view.bounds.height)
                        strongSelf.view.addSubview(controller.view)
                        UIView.animate(withDuration: 0.3, delay: 0.0, options: UIViewAnimationOptions(rawValue: 7 << 16), animations: {
                            controller.view.frame = strongSelf.view.bounds
                        }, completion: { _ in
                            if let completion = completion {
                                completion()
                            }
                        })
                    } else {
                        controller.view.frame = strongSelf.view.bounds
                        strongSelf.view.addSubview(controller.view)
                        
                        if let completion = completion {
                            completion()
                        }
                    }
                }
            }))
        } else {
            preconditionFailure("NavigationController can't present \(viewControllerToPresent). Only subclasses of NavigationController are allowed.")
        }
    }
    
    override open func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        if let controller = self.presentedViewController {
            if flag {
                UIView.animate(withDuration: 0.3, delay: 0.0, options: UIViewAnimationOptions(rawValue: 7 << 16), animations: {
                    controller.view.frame = self.view.bounds.offsetBy(dx: 0.0, dy: self.view.bounds.height)
                }, completion: { _ in
                    controller.view.removeFromSuperview()
                    self._presentedViewController = nil
                    if let completion = completion {
                        completion()
                    }
                })
            } else {
                controller.view.removeFromSuperview()
                self._presentedViewController = nil
                if let completion = completion {
                    completion()
                }
            }
        }
    }
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if let _ = otherGestureRecognizer as? UIPanGestureRecognizer {
            return true
        }
        return false
    }
    
    public final var currentWindow: WindowHost? {
        if let window = self.view.window as? WindowHost {
            return window
        } else if let superwindow = self.view.window {
            for subview in superwindow.subviews {
                if let subview = subview as? WindowHost {
                    return subview
                }
            }
        }
        return nil
    }
    
    private func scheduleAfterLayout(_ f: @escaping () -> Void) {
        (self.view as? UITracingLayerView)?.schedule(layout: {
            f()
        })
        self.view.setNeedsLayout()
    }
    
    private func scheduleLayoutTransitionRequest(_ transition: ContainedViewLayoutTransition) {
        let requestId = self.scheduledLayoutTransitionRequestId
        self.scheduledLayoutTransitionRequestId += 1
        self.scheduledLayoutTransitionRequest = (requestId, transition)
        (self.view as? UITracingLayerView)?.schedule(layout: { [weak self] in
            if let strongSelf = self {
                if let (currentRequestId, currentRequestTransition) = strongSelf.scheduledLayoutTransitionRequest, currentRequestId == requestId {
                    strongSelf.scheduledLayoutTransitionRequest = nil
                    strongSelf.requestLayout(transition: currentRequestTransition)
                }
            }
        })
        self.view.setNeedsLayout()
    }
    
    private func requestLayout(transition: ContainedViewLayoutTransition) {
        if self.isViewLoaded, let validLayout = self.validLayout {
            self.containerLayoutUpdated(validLayout, transition: transition)
        }
    }
}
