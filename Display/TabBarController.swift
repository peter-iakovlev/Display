import Foundation
import UIKit
import AsyncDisplayKit
import SwiftSignalKit

public final class TabBarControllerTheme {
    public let backgroundColor: UIColor
    public let tabBarBackgroundColor: UIColor
    public let tabBarSeparatorColor: UIColor
    public let tabBarTextColor: UIColor
    public let tabBarSelectedTextColor: UIColor
    public let tabBarBadgeBackgroundColor: UIColor
    public let tabBarBadgeStrokeColor: UIColor
    public let tabBarBadgeTextColor: UIColor
    
    public init(backgroundColor: UIColor, tabBarBackgroundColor: UIColor, tabBarSeparatorColor: UIColor, tabBarTextColor: UIColor, tabBarSelectedTextColor: UIColor, tabBarBadgeBackgroundColor: UIColor, tabBarBadgeStrokeColor: UIColor, tabBarBadgeTextColor: UIColor) {
        self.backgroundColor = backgroundColor
        self.tabBarBackgroundColor = tabBarBackgroundColor
        self.tabBarSeparatorColor = tabBarSeparatorColor
        self.tabBarTextColor = tabBarTextColor
        self.tabBarSelectedTextColor = tabBarSelectedTextColor
        self.tabBarBadgeBackgroundColor = tabBarBadgeBackgroundColor
        self.tabBarBadgeStrokeColor = tabBarBadgeStrokeColor
        self.tabBarBadgeTextColor = tabBarBadgeTextColor
    }
}

public final class TabBarItemInfo: NSObject {
    public let previewing: Bool
    
    public init(previewing: Bool) {
        self.previewing = previewing
        
        super.init()
    }
    
    override public func isEqual(_ object: Any?) -> Bool {
        if let object = object as? TabBarItemInfo {
            if self.previewing != object.previewing {
                return false
            }
            return true
        } else {
            return false
        }
    }
    
    public static func ==(lhs: TabBarItemInfo, rhs: TabBarItemInfo) -> Bool {
        if lhs.previewing != rhs.previewing {
            return false
        }
        return true
    }
}

public enum TabBarContainedControllerPresentationUpdate {
    case dismiss
    case present
    case progress(CGFloat)
}

public protocol TabBarContainedController {
    func presentTabBarPreviewingController(sourceNodes: [ASDisplayNode])
    func updateTabBarPreviewingControllerPresentation(_ update: TabBarContainedControllerPresentationUpdate)
}

open class TabBarController: ViewController {
    private var validLayout: ContainerViewLayout?
    
    private var tabBarControllerNode: TabBarControllerNode {
        get {
            return super.displayNode as! TabBarControllerNode
        }
    }
    
    public private(set) var controllers: [ViewController] = []
    
    private let _ready = Promise<Bool>()
    override open var ready: Promise<Bool> {
        return self._ready
    }
    
    private var _selectedIndex: Int?
    public var selectedIndex: Int {
        get {
            if let _selectedIndex = self._selectedIndex {
                return _selectedIndex
            } else {
                return 0
            }
        } set(value) {
            let index = max(0, min(self.controllers.count - 1, value))
            if _selectedIndex != index {
                _selectedIndex = index
                
                self.updateSelectedIndex()
            }
        }
    }
    
    var currentController: ViewController?
    
    private let pendingControllerDisposable = MetaDisposable()
    
    private var theme: TabBarControllerTheme
    
    public init(navigationBarPresentationData: NavigationBarPresentationData, theme: TabBarControllerTheme) {
        self.theme = theme
        
        super.init(navigationBarPresentationData: navigationBarPresentationData)
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.pendingControllerDisposable.dispose()
    }
    
    public func updateTheme(navigationBarPresentationData: NavigationBarPresentationData, theme: TabBarControllerTheme) {
        self.navigationBar?.updatePresentationData(navigationBarPresentationData)
        if self.theme !== theme {
            self.theme = theme
            if self.isNodeLoaded {
                self.tabBarControllerNode.updateTheme(theme)
            }
        }
    }
    
    private var debugTapCounter: (Double, Int) = (0.0, 0)
    
    public func sourceNodesForController(at index: Int) -> [ASDisplayNode]? {
        return self.tabBarControllerNode.tabBarNode.sourceNodesForController(at: index)
    }
    
    override open func navigationAlongsideTransition(type: NavigationTransition) -> ((CGFloat) -> ())? {
        return currentController?.navigationAlongsideTransition(type: type)
    }
    
    override open func loadDisplayNode() {
        self.displayNode = TabBarControllerNode(theme: self.theme, navigationBar: self.navigationBar, itemSelected: { [weak self] index, longTap, itemNodes in
            if let strongSelf = self {
                if longTap, let controller = strongSelf.controllers[index] as? TabBarContainedController {
                    controller.presentTabBarPreviewingController(sourceNodes: itemNodes)
                    return
                }
                
                if strongSelf.selectedIndex == index {
                    let timestamp = CACurrentMediaTime()
                    if strongSelf.debugTapCounter.0 < timestamp - 0.4 {
                        strongSelf.debugTapCounter.0 = timestamp
                        strongSelf.debugTapCounter.1 = 0
                    }
                        
                    if strongSelf.debugTapCounter.0 >= timestamp - 0.4 {
                        strongSelf.debugTapCounter.0 = timestamp
                        strongSelf.debugTapCounter.1 += 1
                    }
                    
                    if strongSelf.debugTapCounter.1 >= 10 {
                        strongSelf.debugTapCounter.1 = 0
                        
                        strongSelf.controllers[index].tabBarItemDebugTapAction?()
                    }
                }
                if let validLayout = strongSelf.validLayout {
                    strongSelf.controllers[index].containerLayoutUpdated(validLayout.addedInsets(insets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: 49.0, right: 0.0)), transition: .immediate)
                }
                let startTime = CFAbsoluteTimeGetCurrent()
                strongSelf.pendingControllerDisposable.set((strongSelf.controllers[index].ready.get()
                |> deliverOnMainQueue).start(next: { _ in
                    if let strongSelf = self {
                        let readyTime = CFAbsoluteTimeGetCurrent() - startTime
                        if readyTime > 0.5 {
                            print("TabBarController: controller took \(readyTime) to become ready")
                        }
                        
                        if strongSelf.selectedIndex == index {
                            if let controller = strongSelf.currentController {
                                if longTap {
                                    controller.longTapWithTabBar?()
                                } else {
                                    controller.scrollToTopWithTabBar?()
                                }
                            }
                        } else {
                            strongSelf.selectedIndex = index
                        }
                    }
                }))
            }
        }, toolbarActionSelected: { [weak self] action in
            self?.currentController?.toolbarActionSelected(action: action)
        })
        
        self.updateSelectedIndex()
        self.displayNodeDidLoad()
    }
    
    private func updateSelectedIndex() {
        if !self.isNodeLoaded {
            return
        }
        
        self.tabBarControllerNode.tabBarNode.selectedIndex = self.selectedIndex
        
        if let currentController = self.currentController {
            currentController.willMove(toParentViewController: nil)
            self.tabBarControllerNode.currentControllerNode = nil
            currentController.removeFromParentViewController()
            currentController.didMove(toParentViewController: nil)
            
            self.currentController = nil
        }
        
        if let _selectedIndex = self._selectedIndex, _selectedIndex < self.controllers.count {
            self.currentController = self.controllers[_selectedIndex]
        }
        
        var displayNavigationBar = false
        if let currentController = self.currentController {
            currentController.willMove(toParentViewController: self)
            self.tabBarControllerNode.currentControllerNode = currentController.displayNode
            currentController.navigationBar?.isHidden = true
            self.addChildViewController(currentController)
            currentController.didMove(toParentViewController: self)
            
            currentController.navigationBar?.layoutSuspended = true
            currentController.navigationItem.setTarget(self.navigationItem)
            displayNavigationBar = currentController.displayNavigationBar
            self.navigationBar?.setContentNode(currentController.navigationBar?.contentNode, animated: false)
            currentController.displayNode.recursivelyEnsureDisplaySynchronously(true)
            self.statusBar.statusBarStyle = currentController.statusBar.statusBarStyle
        } else {
            self.navigationItem.title = nil
            self.navigationItem.leftBarButtonItem = nil
            self.navigationItem.rightBarButtonItem = nil
            self.navigationItem.titleView = nil
            self.navigationItem.backBarButtonItem = nil
            self.navigationBar?.setContentNode(nil, animated: false)
            displayNavigationBar = false
        }
        if self.displayNavigationBar != displayNavigationBar {
            self.setDisplayNavigationBar(displayNavigationBar)
        }
        
        if let validLayout = self.validLayout {
            self.containerLayoutUpdated(validLayout, transition: .immediate)
        }
    }
    
    override open func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.validLayout = layout
        
        self.tabBarControllerNode.containerLayoutUpdated(layout, toolbar: self.currentController?.toolbar, transition: transition)
        
        if let currentController = self.currentController {
            currentController.view.frame = CGRect(origin: CGPoint(), size: layout.size)
            
            currentController.containerLayoutUpdated(layout.addedInsets(insets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: 49.0, right: 0.0)), transition: transition)
        }
    }
    
    override open func navigationStackConfigurationUpdated(next: [ViewController]) {
        super.navigationStackConfigurationUpdated(next: next)
        for controller in self.controllers {
            controller.navigationStackConfigurationUpdated(next: next)
        }
    }
    
    override open func viewWillDisappear(_ animated: Bool) {
        if let currentController = self.currentController {
            currentController.viewWillDisappear(animated)
        }
    }
    
    override open func viewWillAppear(_ animated: Bool) {
        if let currentController = self.currentController {
            currentController.viewWillAppear(animated)
        }
    }
    
    override open func viewDidAppear(_ animated: Bool) {
        if let currentController = self.currentController {
            currentController.viewDidAppear(animated)
        }
    }
    
    override open func viewDidDisappear(_ animated: Bool) {
        if let currentController = self.currentController {
            currentController.viewDidDisappear(animated)
        }
    }
    
    public func setControllers(_ controllers: [ViewController], selectedIndex: Int?) {
        var updatedSelectedIndex: Int? = selectedIndex
        if updatedSelectedIndex == nil, let selectedIndex = self._selectedIndex, selectedIndex < self.controllers.count {
            if let index = controllers.index(where: { $0 === self.controllers[selectedIndex] }) {
                updatedSelectedIndex = index
            } else {
                updatedSelectedIndex = 0
            }
        }
        self.controllers = controllers
        self.tabBarControllerNode.tabBarNode.tabBarItems = self.controllers.map({ $0.tabBarItem })
        
        let signals = combineLatest(self.controllers.map({ $0.tabBarItem }).map { tabBarItem -> Signal<Bool, NoError> in
            if let tabBarItem = tabBarItem, tabBarItem.image == nil {
                return Signal { [weak tabBarItem] subscriber in
                    let index = tabBarItem?.addSetImageListener({ image in
                        if image != nil {
                            subscriber.putNext(true)
                            subscriber.putCompletion()
                        }
                    })
                    return ActionDisposable {
                        Queue.mainQueue().async {
                            if let index = index {
                                tabBarItem?.removeSetImageListener(index)
                            }
                        }
                    }
                }
                |> runOn(.mainQueue())
            } else {
                return .single(true)
            }
        })
        |> map { items -> Bool in
            for item in items {
                if !item {
                    return false
                }
            }
            return true
        }
        |> filter { $0 }
        |> take(1)
        
        let allReady = signals
        |> deliverOnMainQueue
        |> mapToSignal { _ -> Signal<Bool, NoError> in
            // wait for tab bar items to be applied
            return .single(true)
            |> delay(0.0, queue: Queue.mainQueue())
        }
        
        self._ready.set(allReady)
        
        if let updatedSelectedIndex = updatedSelectedIndex {
            self.selectedIndex = updatedSelectedIndex
            self.updateSelectedIndex()
        }
    }
}
