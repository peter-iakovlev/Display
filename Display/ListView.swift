import UIKit
import AsyncDisplayKit
import SwiftSignalKit

private let useBackgroundDeallocation = false

private let infiniteScrollSize: CGFloat = 10000.0
private let insertionAnimationDuration: Double = 0.4

private final class ListViewBackingLayer: CALayer {
    override func setNeedsLayout() {
    }
    
    override func layoutSublayers() {
    }
    
    override func setNeedsDisplay() {
    }
    
    override func displayIfNeeded() {
    }
    
    override func needsDisplay() -> Bool {
        return false
    }
    
    override func display() {
    }
}

final class ListViewBackingView: UIView {
    weak var target: ListView?
    
    override class var layerClass: AnyClass {
        return ListViewBackingLayer.self
    }
    
    override func setNeedsLayout() {
    }
    
    override func layoutSubviews() {
    }
    
    override func setNeedsDisplay() {
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.target?.touchesBegan(touches, with: event)
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>?, with event: UIEvent?) {
        self.target?.touchesCancelled(touches, with: event)
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.target?.touchesMoved(touches, with: event)
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.target?.touchesEnded(touches, with: event)
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.isHidden, let target = self.target {
            if target.limitHitTestToNodes, !target.internalHitTest(point, with: event) {
                return nil
            }
            if let result = target.headerHitTest(point, with: event) {
                return result
            }
        }
        return super.hitTest(point, with: event)
    }
    
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        return self.target?.accessibilityScroll(direction) ?? false
    }
}

private final class ListViewTimerProxy: NSObject {
    private let action: () -> ()
    
    init(_ action: @escaping () -> ()) {
        self.action = action
        super.init()
    }
    
    @objc func timerEvent() {
        self.action()
    }
}

public enum ListViewVisibleContentOffset {
    case known(CGFloat)
    case unknown
    case none
}

public enum ListViewScrollDirection {
    case up
    case down
}

public struct ListViewKeepTopItemOverscrollBackground {
    public let color: UIColor
    public let direction: Bool
    
    public init(color: UIColor, direction: Bool) {
        self.color = color
        self.direction = direction
    }
    
    fileprivate func isEqual(to: ListViewKeepTopItemOverscrollBackground) -> Bool {
        if !self.color.isEqual(to.color) {
            return false
        }
        if self.direction != to.direction {
            return false
        }
        return true
    }
}

public enum GeneralScrollDirection {
    case up
    case down
}

open class ListView: ASDisplayNode, UIScrollViewAccessibilityDelegate, UIGestureRecognizerDelegate {
    private final let scroller: ListViewScroller
    private final var visibleSize: CGSize = CGSize()
    public private(set) final var insets = UIEdgeInsets()
    public final var visualInsets: UIEdgeInsets?
    public private(set) final var headerInsets = UIEdgeInsets()
    public private(set) final var scrollIndicatorInsets = UIEdgeInsets()
    private final var ensureTopInsetForOverlayHighlightedItems: CGFloat?
    private final var lastContentOffset: CGPoint = CGPoint()
    private final var lastContentOffsetTimestamp: CFAbsoluteTime = 0.0
    private final var ignoreScrollingEvents: Bool = false
    
    private final var displayLink: CADisplayLink!
    private final var needsAnimations = false
    
    public final var dynamicBounceEnabled = true
    public final var rotated = false
    public final var experimentalSnapScrollToItem = false
    
    private final var invisibleInset: CGFloat = 500.0
    public var preloadPages: Bool = true {
        didSet {
            if self.preloadPages != oldValue {
                self.invisibleInset = self.preloadPages ? 500.0 : 20.0
                //self.invisibleInset = self.preloadPages ? 20.0 : 20.0
                if self.preloadPages {
                    self.enqueueUpdateVisibleItems(synchronous: false)
                }
            }
        }
    }
    
    public final var stackFromBottom: Bool = false
    public final var stackFromBottomInsetItemFactor: CGFloat = 0.0
    public final var limitHitTestToNodes: Bool = false
    public final var keepTopItemOverscrollBackground: ListViewKeepTopItemOverscrollBackground? {
        didSet {
            if let value = self.keepTopItemOverscrollBackground {
                self.topItemOverscrollBackground?.color = value.color
            }
            self.updateTopItemOverscrollBackground(transition: .immediate)
        }
    }
    public final var keepBottomItemOverscrollBackground: UIColor? {
        didSet {
            if let color = self.keepBottomItemOverscrollBackground {
                self.bottomItemOverscrollBackground?.backgroundColor = color
            }
            self.updateBottomItemOverscrollBackground()
        }
    }
    public final var snapToBottomInsetUntilFirstInteraction: Bool = false
    
    public final var updateFloatingHeaderOffset: ((CGFloat, ContainedViewLayoutTransition) -> Void)? {
        didSet {
            
        }
    }
    
    private var topItemOverscrollBackground: ListViewOverscrollBackgroundNode?
    private var bottomItemOverscrollBackground: ASDisplayNode?
    
    private var itemHighlightOverlayBackground: ASDisplayNode?
    
    private var verticalScrollIndicator: ASImageNode?
    public var verticalScrollIndicatorColor: UIColor? {
        didSet {
            if let fillColor = self.verticalScrollIndicatorColor {
                if self.verticalScrollIndicator == nil {
                    let verticalScrollIndicator = ASImageNode()
                    verticalScrollIndicator.isUserInteractionEnabled = false
                    verticalScrollIndicator.alpha = 0.0
                    verticalScrollIndicator.image = generateStretchableFilledCircleImage(diameter: 3.0, color: fillColor)
                    self.verticalScrollIndicator = verticalScrollIndicator
                    self.addSubnode(verticalScrollIndicator)
                }
            } else {
                self.verticalScrollIndicator?.removeFromSupernode()
                self.verticalScrollIndicator = nil
            }
        }
    }
    public final var verticalScrollIndicatorFollowsOverscroll: Bool = false
    
    private var touchesPosition = CGPoint()
    public private(set) var isTracking = false
    public private(set) var trackingOffset: CGFloat = 0.0
    public private(set) var beganTrackingAtTopOrigin = false
    public private(set) var isDeceleratingAfterTracking = false
    
    private final var transactionQueue: ListViewTransactionQueue
    private final var transactionOffset: CGFloat = 0.0
    
    private final var enqueuedUpdateVisibleItems = false
    
    private final var createdItemNodes = 0
    
    public final var synchronousNodes = false
    public final var debugInfo = false
    
    private final var items: [ListViewItem] = []
    private final var itemNodes: [ListViewItemNode] = []
    private final var itemHeaderNodes: [Int64: ListViewItemHeaderNode] = [:]
    
    public final var displayedItemRangeChanged: (ListViewDisplayedItemRange, Any?) -> Void = { _, _ in }
    public private(set) final var displayedItemRange: ListViewDisplayedItemRange = ListViewDisplayedItemRange(loadedRange: nil, visibleRange: nil)
    
    public private(set) final var opaqueTransactionState: Any?
    
    public final var visibleContentOffsetChanged: (ListViewVisibleContentOffset) -> Void = { _ in }
    public final var visibleBottomContentOffsetChanged: (ListViewVisibleContentOffset) -> Void = { _ in }
    public final var beganInteractiveDragging: () -> Void = { }
    public final var didEndScrolling: (() -> Void)?
    
    private var currentGeneralScrollDirection: GeneralScrollDirection?
    public final var generalScrollDirectionUpdated: (GeneralScrollDirection) -> Void = { _ in }
    
    public final var reorderItem: (Int, Int, Any?) -> Signal<Bool, NoError> = { _, _, _ in return .single(false) }
    
    private final var animations: [ListViewAnimation] = []
    private final var actionsForVSync: [() -> ()] = []
    private final var inVSync = false
    
    private let frictionSlider = UISlider()
    private let springSlider = UISlider()
    private let freeResistanceSlider = UISlider()
    private let scrollingResistanceSlider = UISlider()
    
    private var selectionTouchLocation: CGPoint?
    private var selectionTouchDelayTimer: Foundation.Timer?
    private var selectionLongTapDelayTimer: Foundation.Timer?
    private var flashNodesDelayTimer: Foundation.Timer?
    private var flashScrollIndicatorTimer: Foundation.Timer?
    private var highlightedItemIndex: Int?
    private var scrolledToItem: (Int, ListViewScrollPosition)?
    private var reorderNode: ListViewReorderingItemNode?
    private var reorderFeedback: HapticFeedback?
    private var reorderFeedbackDisposable: MetaDisposable?
    
    private let waitingForNodesDisposable = MetaDisposable()
    
    /*override open var accessibilityElements: [Any]? {
        get {
            var accessibilityElements: [Any] = []
            self.forEachItemNode({ itemNode in
                addAccessibilityChildren(of: itemNode, container: self, to: &accessibilityElements)
            })
            return accessibilityElements
        } set(value) {
        }
    }*/

    override public init() {
        class DisplayLinkProxy: NSObject {
            weak var target: ListView?
            init(target: ListView) {
                self.target = target
            }
            
            @objc func displayLinkEvent() {
                self.target?.displayLinkEvent()
            }
        }
        
        self.transactionQueue = ListViewTransactionQueue()
        
        self.scroller = ListViewScroller()
        
        super.init()
        
        self.isAccessibilityContainer = true
        
        self.setViewBlock({ () -> UIView in
            return ListViewBackingView()
        })
        
        self.clipsToBounds = true
        
        (self.view as! ListViewBackingView).target = self
        
        self.transactionQueue.transactionCompleted = { [weak self] in
            if let strongSelf = self {
                strongSelf.updateVisibleItemRange()
            }
        }
        
        self.scroller.alwaysBounceVertical = true
        self.scroller.contentSize = CGSize(width: 0.0, height: infiniteScrollSize * 2.0)
        self.scroller.isHidden = true
        self.scroller.delegate = self
        self.view.addSubview(self.scroller)
        self.scroller.panGestureRecognizer.cancelsTouchesInView = true
        self.view.addGestureRecognizer(self.scroller.panGestureRecognizer)
        
        let trackingRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.trackingGesture(_:)))
        trackingRecognizer.delegate = self
        self.view.addGestureRecognizer(trackingRecognizer)
        
        self.view.addGestureRecognizer(ListViewReorderingGestureRecognizer(shouldBegin: { [weak self] point in
            if let strongSelf = self {
                if let index = strongSelf.itemIndexAtPoint(point) {
                    for i in 0 ..< strongSelf.itemNodes.count {
                        if strongSelf.itemNodes[i].index == index {
                            let itemNode = strongSelf.itemNodes[i]
                            let itemNodeFrame = itemNode.frame
                            let itemNodeBounds = itemNode.bounds
                            if itemNode.isReorderable(at: point.offsetBy(dx: -itemNodeFrame.minX + itemNodeBounds.minX, dy: -itemNodeFrame.minY + itemNodeBounds.minY)) {
                                strongSelf.beginReordering(itemNode: itemNode)
                                return true
                            }
                            break
                        }
                    }
                }
            }
            return false
        }, ended: { [weak self] in
            self?.endReordering()
        }, moved: { [weak self] offset in
            self?.updateReordering(offset: offset)
        }))
        
        self.displayLink = CADisplayLink(target: DisplayLinkProxy(target: self), selector: #selector(DisplayLinkProxy.displayLinkEvent))
        self.displayLink.add(to: RunLoop.main, forMode: RunLoopMode.commonModes)
        
        if #available(iOS 10.0, *) {
            self.displayLink.preferredFramesPerSecond = 60
        }
        
        self.displayLink.isPaused = true
    }
    
    deinit {
        self.pauseAnimations()
        self.displayLink.invalidate()
        
        if useBackgroundDeallocation {
            assertionFailure()
            /*for itemNode in self.itemNodes {
                ASDeallocQueue.sharedDeallocation.releaseObject(inBackground: UnsafeMutablePointer(itemNode))
            }
            for itemHeaderNode in self.itemHeaderNodes {
                ASDeallocQueue.sharedDeallocatio.releaseObject(inBackground: itemHeaderNode)
            }*/
        } else {
            for i in (0 ..< self.itemNodes.count).reversed() {
                var itemNode: AnyObject? = self.itemNodes[i]
                self.itemNodes.remove(at: i)
                ASPerformMainThreadDeallocation(&itemNode)
            }
            for key in self.itemHeaderNodes.keys {
                var itemHeaderNode: AnyObject? = self.itemHeaderNodes[key]
                self.itemHeaderNodes.removeValue(forKey: key)
                ASPerformMainThreadDeallocation(&itemHeaderNode)
            }
        }
        
        self.waitingForNodesDisposable.dispose()
        self.reorderFeedbackDisposable?.dispose()
    }
    
    private func displayLinkEvent() {
        self.updateAnimations()
    }
    
    private func setNeedsAnimations() {
        if !self.needsAnimations {
            self.needsAnimations = true
            self.displayLink.isPaused = false
        }
    }
    
    private func pauseAnimations() {
        if self.needsAnimations {
            self.needsAnimations = false
            self.displayLink.isPaused = true
        }
    }
    
    private func dispatchOnVSync(forceNext: Bool = false, action: @escaping () -> ()) {
        Queue.mainQueue().async {
            if !forceNext && self.inVSync {
                action()
            } else {
                action()
                //self.actionsForVSync.append(action)
                //self.setNeedsAnimations()
            }
        }
    }
    
    private func beginReordering(itemNode: ListViewItemNode) {
        if let reorderNode = self.reorderNode {
            reorderNode.removeFromSupernode()
        }
        let reorderNode = ListViewReorderingItemNode(itemNode: itemNode, initialLocation: itemNode.frame.origin)
        self.reorderNode = reorderNode
        if let verticalScrollIndicator = self.verticalScrollIndicator {
            self.insertSubnode(reorderNode, belowSubnode: verticalScrollIndicator)
        } else {
            self.addSubnode(reorderNode)
        }
        itemNode.isHidden = true
    }
    
    private func endReordering() {
        if let reorderNode = self.reorderNode {
            self.reorderNode = nil
            if let itemNode = reorderNode.itemNode, itemNode.supernode == self {
                self.reorderItemNodeToFront(itemNode)
                reorderNode.animateCompletion(completion: { [weak itemNode, weak reorderNode] in
                    //itemNode?.isHidden = false
                    reorderNode?.removeFromSupernode()
                })
                self.setNeedsAnimations()
            } else {
                reorderNode.removeFromSupernode()
            }
        }
    }
    
    private func updateReordering(offset: CGFloat) {
        if let reorderNode = self.reorderNode {
            reorderNode.updateOffset(offset: offset)
            self.checkItemReordering()
        }
    }
    
    private func checkItemReordering() {
        if let reorderNode = self.reorderNode, let reorderItemNode = reorderNode.itemNode, let reorderItemIndex = reorderItemNode.index, reorderItemNode.supernode == self {
            guard let verticalTopOffset = reorderNode.currentOffset() else {
                return
            }
            let verticalOffset = verticalTopOffset
            var closestIndex: (Int, CGFloat)?
            for i in 0 ..< self.itemNodes.count {
                if let itemNodeIndex = self.itemNodes[i].index, itemNodeIndex != reorderItemIndex {
                    let itemFrame = self.itemNodes[i].apparentContentFrame
                    let itemOffset = itemFrame.midY
                    let deltaOffset = itemOffset - verticalOffset
                    if let (_, closestOffset) = closestIndex {
                        if abs(deltaOffset) < abs(closestOffset) {
                            closestIndex = (itemNodeIndex, deltaOffset)
                        }
                    } else {
                        closestIndex = (itemNodeIndex, deltaOffset)
                    }
                }
            }
            if let (closestIndexValue, offset) = closestIndex {
                //print("closest \(closestIndexValue) offset \(offset)")
                var toIndex: Int
                if offset > 0 {
                    toIndex = closestIndexValue
                    if toIndex > reorderItemIndex {
                        toIndex -= 1
                    }
                } else {
                    toIndex = closestIndexValue + 1
                    if toIndex > reorderItemIndex {
                        toIndex -= 1
                    }
                }
                if toIndex != reorderItemNode.index {
                    if reorderNode.currentState?.0 != reorderItemIndex || reorderNode.currentState?.1 != toIndex {
                        reorderNode.currentState = (reorderItemIndex, toIndex)
                        //print("reorder \(reorderItemIndex) to \(toIndex) offset \(offset)")
                        if self.reorderFeedbackDisposable == nil {
                            self.reorderFeedbackDisposable = MetaDisposable()
                        }
                        self.reorderFeedbackDisposable?.set((self.reorderItem(reorderItemIndex, toIndex, self.opaqueTransactionState)
                        |> deliverOnMainQueue).start(next: { [weak self] value in
                            guard let strongSelf = self, value else {
                                return
                            }
                            if strongSelf.reorderFeedback == nil {
                                strongSelf.reorderFeedback = HapticFeedback()
                            }
                            strongSelf.reorderFeedback?.tap()
                        }))
                    }
                }
            }
            
            self.setNeedsAnimations()
        }
    }
    
    public func flashHeaderItems(duration: Double = 2.0) {
        self.resetHeaderItemsFlashTimer(start: true, duration: duration)
    }
    
    private func resetHeaderItemsFlashTimer(start: Bool, duration: Double = 0.3) {
        if let flashNodesDelayTimer = self.flashNodesDelayTimer {
            flashNodesDelayTimer.invalidate()
            self.flashNodesDelayTimer = nil
        }
        
        if start {
            let timer = Timer(timeInterval: duration, target: ListViewTimerProxy { [weak self] in
                if let strongSelf = self {
                    if let flashNodesDelayTimer = strongSelf.flashNodesDelayTimer {
                        flashNodesDelayTimer.invalidate()
                        strongSelf.flashNodesDelayTimer = nil
                        strongSelf.updateHeaderItemsFlashing(animated: true)
                    }
                }
            }, selector: #selector(ListViewTimerProxy.timerEvent), userInfo: nil, repeats: false)
            self.flashNodesDelayTimer = timer
            RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
            self.updateHeaderItemsFlashing(animated: true)
        }
    }
    
    private func resetScrollIndicatorFlashTimer(start: Bool) {
        if let flashScrollIndicatorTimer = self.flashScrollIndicatorTimer {
            flashScrollIndicatorTimer.invalidate()
            self.flashScrollIndicatorTimer = nil
        }
        
        if start {
            let timer = Timer(timeInterval: 0.1, target: ListViewTimerProxy { [weak self] in
                if let strongSelf = self {
                    if let flashScrollIndicatorTimer = strongSelf.flashScrollIndicatorTimer {
                        flashScrollIndicatorTimer.invalidate()
                        strongSelf.flashScrollIndicatorTimer = nil
                        strongSelf.verticalScrollIndicator?.alpha = 0.0
                        strongSelf.verticalScrollIndicator?.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3)
                    }
                }
            }, selector: #selector(ListViewTimerProxy.timerEvent), userInfo: nil, repeats: false)
            self.flashScrollIndicatorTimer = timer
            RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
        } else {
            self.verticalScrollIndicator?.layer.removeAnimation(forKey: "opacity")
            self.verticalScrollIndicator?.alpha = 1.0
        }
    }
    
    private func headerItemsAreFlashing() -> Bool {
        //print("\(self.scroller.isDragging) || (\(self.scroller.isDecelerating) && \(self.isDeceleratingAfterTracking)) || \(self.flashNodesDelayTimer != nil)")
        return self.scroller.isDragging || (self.isDeceleratingAfterTracking) || self.flashNodesDelayTimer != nil
    }
    
    private func updateHeaderItemsFlashing(animated: Bool) {
        let flashing = self.headerItemsAreFlashing()
        for (_, headerNode) in self.itemHeaderNodes {
            headerNode.updateFlashingOnScrolling(flashing, animated: animated)
        }
    }
    
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.lastContentOffsetTimestamp = 0.0
        self.resetHeaderItemsFlashTimer(start: false)
        self.updateHeaderItemsFlashing(animated: true)
        self.resetScrollIndicatorFlashTimer(start: false)
        
        if self.snapToBottomInsetUntilFirstInteraction {
            self.snapToBottomInsetUntilFirstInteraction = false
        }
        self.scrolledToItem = nil
        
        self.beganInteractiveDragging()
    }
    
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate {
            self.lastContentOffsetTimestamp = CACurrentMediaTime()
            self.isDeceleratingAfterTracking = true
            self.updateHeaderItemsFlashing(animated: true)
            self.resetScrollIndicatorFlashTimer(start: false)
        } else {
            self.isDeceleratingAfterTracking = false
            self.resetHeaderItemsFlashTimer(start: true)
            self.updateHeaderItemsFlashing(animated: true)
            self.resetScrollIndicatorFlashTimer(start: true)
            
            self.lastContentOffsetTimestamp = 0.0
            self.didEndScrolling?()
        }
    }
    
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.lastContentOffsetTimestamp = 0.0
        self.isDeceleratingAfterTracking = false
        self.resetHeaderItemsFlashTimer(start: true)
        self.updateHeaderItemsFlashing(animated: true)
        self.resetScrollIndicatorFlashTimer(start: true)
        self.didEndScrolling?()
    }
    
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateScrollViewDidScroll(scrollView, synchronous: false)
    }
    
    private var generalAccumulatedDeltaY: CGFloat = 0.0
    
    private func updateScrollViewDidScroll(_ scrollView: UIScrollView, synchronous: Bool) {
        if self.ignoreScrollingEvents || scroller !== self.scroller {
            return
        }
            
        //CATransaction.begin()
        //CATransaction.setDisableActions(true)
        
        let deltaY = scrollView.contentOffset.y - self.lastContentOffset.y
        self.generalAccumulatedDeltaY += deltaY
        if abs(self.generalAccumulatedDeltaY) > 14.0 {
            let direction: GeneralScrollDirection = self.generalAccumulatedDeltaY < 0 ? .up : .down
            self.generalAccumulatedDeltaY = 0.0
            if self.currentGeneralScrollDirection != direction {
                self.currentGeneralScrollDirection = direction
                self.generalScrollDirectionUpdated(direction)
            }
        }
        
        self.lastContentOffset = scrollView.contentOffset
        if !self.lastContentOffsetTimestamp.isZero {
            self.lastContentOffsetTimestamp = CACurrentMediaTime()
        }
        
        self.transactionOffset += -deltaY
        
        if self.isTracking {
            self.trackingOffset += -deltaY
        }
        
        self.enqueueUpdateVisibleItems(synchronous: synchronous)
        
        var useScrollDynamics = false
        
        let anchor: CGFloat
        if self.isTracking {
            anchor = self.touchesPosition.y
        } else if deltaY < 0.0 {
            anchor = self.visibleSize.height
        } else {
            anchor = 0.0
        }
        
        for itemNode in self.itemNodes {
            let position = itemNode.position
            itemNode.position = CGPoint(x: position.x, y: position.y - deltaY)
            
            if self.dynamicBounceEnabled && itemNode.wantsScrollDynamics {
                useScrollDynamics = true
                
                var distance: CGFloat
                let itemFrame = itemNode.apparentFrame
                if anchor < itemFrame.origin.y {
                    distance = abs(itemFrame.origin.y - anchor)
                } else if anchor > itemFrame.origin.y + itemFrame.size.height {
                    distance = abs(anchor - (itemFrame.origin.y + itemFrame.size.height))
                } else {
                    distance = 0.0
                }
                
                let factor: CGFloat = max(0.08, abs(distance) / self.visibleSize.height)
                
                let resistance: CGFloat = testSpringFreeResistance

                itemNode.addScrollingOffset(deltaY * factor * resistance)
            }
        }
        
        if !self.snapToBounds(snapTopItem: false, stackFromBottom: self.stackFromBottom).offset.isZero {
            self.updateVisibleContentOffset()
        }
        self.updateScroller(transition: .immediate)
        
        self.updateItemHeaders(leftInset: self.insets.left, rightInset: self.insets.right)
        
        for (_, headerNode) in self.itemHeaderNodes {
            if self.dynamicBounceEnabled && headerNode.wantsScrollDynamics {
                useScrollDynamics = true
                
                var distance: CGFloat
                let itemFrame = headerNode.frame
                if anchor < itemFrame.origin.y {
                    distance = abs(itemFrame.origin.y - anchor)
                } else if anchor > itemFrame.origin.y + itemFrame.size.height {
                    distance = abs(anchor - (itemFrame.origin.y + itemFrame.size.height))
                } else {
                    distance = 0.0
                }
                
                let factor: CGFloat = max(0.08, abs(distance) / self.visibleSize.height)
                
                let resistance: CGFloat = testSpringFreeResistance
                
                headerNode.addScrollingOffset(deltaY * factor * resistance)
            }
        }
        
        if useScrollDynamics {
            self.setNeedsAnimations()
        }
        
        self.updateVisibleContentOffset()
        self.updateVisibleItemRange()
        self.updateItemNodesVisibilities(onlyPositive: false)
        
        //CATransaction.commit()
    }
    
    private func calculateAdditionalTopInverseInset() -> CGFloat {
        var additionalInverseTopInset: CGFloat = 0.0
        if !self.stackFromBottomInsetItemFactor.isZero {
            var remainingFactor = self.stackFromBottomInsetItemFactor
            for itemNode in self.itemNodes {
                if remainingFactor.isLessThanOrEqualTo(0.0) {
                    break
                }
                
                let itemFactor: CGFloat
                if CGFloat(1.0).isLessThanOrEqualTo(remainingFactor) {
                    itemFactor = 1.0
                } else {
                    itemFactor = remainingFactor
                }
                
                additionalInverseTopInset += floor(itemNode.apparentBounds.height * itemFactor)
                
                remainingFactor -= 1.0
            }
        }
        return additionalInverseTopInset
    }
    
    private func snapToBounds(snapTopItem: Bool, stackFromBottom: Bool, updateSizeAndInsets: ListViewUpdateSizeAndInsets? = nil, scrollToItem: ListViewScrollToItem? = nil) -> (snappedTopInset: CGFloat, offset: CGFloat) {
        if self.itemNodes.count == 0 {
            return (0.0, 0.0)
        }
        
        var overscroll: CGFloat = 0.0
        if self.scroller.contentOffset.y < 0.0 {
            overscroll = self.scroller.contentOffset.y
        } else if self.scroller.contentOffset.y > max(0.0, self.scroller.contentSize.height - self.scroller.bounds.size.height) {
            overscroll = self.scroller.contentOffset.y - max(0.0, (self.scroller.contentSize.height - self.scroller.bounds.size.height))
        }
        
        var completeHeight: CGFloat = 0.0
        var topItemFound = false
        var bottomItemFound = false
        var topItemEdge: CGFloat = 0.0
        var bottomItemEdge: CGFloat = 0.0
        
        for i in 0 ..< self.itemNodes.count {
            if let index = itemNodes[i].index {
                if index == 0 {
                    topItemFound = true
                }
                break
            }
        }
        
        var effectiveInsets = self.insets
        if topItemFound && !self.stackFromBottomInsetItemFactor.isZero {
            let additionalInverseTopInset = self.calculateAdditionalTopInverseInset()
            effectiveInsets.top = max(effectiveInsets.top, self.visibleSize.height - additionalInverseTopInset)
        }
        
        if topItemFound {
            topItemEdge = itemNodes[0].apparentFrame.origin.y
        }
        
        var bottomItemNode: ListViewItemNode?
        for i in (0 ..< self.itemNodes.count).reversed() {
            if let index = itemNodes[i].index {
                if index == self.items.count - 1 {
                    bottomItemNode = itemNodes[i]
                    bottomItemFound = true
                }
                break
            }
        }
        
        if bottomItemFound {
            bottomItemEdge = itemNodes[itemNodes.count - 1].apparentFrame.maxY
        }
        
        if topItemFound && bottomItemFound {
            for itemNode in self.itemNodes {
                completeHeight += itemNode.apparentBounds.height
            }
        }
        
        var transition: ContainedViewLayoutTransition = .immediate
        if let updateSizeAndInsets = updateSizeAndInsets {
            if !updateSizeAndInsets.duration.isZero {
                switch updateSizeAndInsets.curve {
                    case let .Spring(duration):
                        transition = .animated(duration: duration, curve: .spring)
                    case let .Default(duration):
                        transition = .animated(duration: max(updateSizeAndInsets.duration, duration ?? 0.3), curve: .easeInOut)
                }
            }
        } else if let scrollToItem = scrollToItem {
            switch scrollToItem.curve {
                case let .Spring(duration):
                    transition = .animated(duration: duration, curve: .spring)
                case let .Default(duration):
                    if let duration = duration, duration.isZero {
                        transition = .immediate
                    } else {
                        transition = .animated(duration: duration ?? 0.3, curve: .easeInOut)
                    }
            }
        }
        
        var offset: CGFloat = 0.0
        if topItemFound && bottomItemFound {
            let visibleAreaHeight = self.visibleSize.height - effectiveInsets.bottom - effectiveInsets.top
            if self.stackFromBottom {
                if visibleAreaHeight > completeHeight {
                    let areaHeight = completeHeight
                    if topItemEdge < self.visibleSize.height - effectiveInsets.bottom - areaHeight - overscroll {
                        offset = self.visibleSize.height - effectiveInsets.bottom - areaHeight - overscroll - topItemEdge
                    } else if bottomItemEdge > self.visibleSize.height - effectiveInsets.bottom - overscroll {
                        offset = self.visibleSize.height - effectiveInsets.bottom - overscroll - bottomItemEdge
                    }
                } else {
                    let areaHeight = min(completeHeight, visibleAreaHeight)
                    if bottomItemEdge < effectiveInsets.top + areaHeight - overscroll {
                        offset = effectiveInsets.top + areaHeight - overscroll - bottomItemEdge
                    } else if topItemEdge > effectiveInsets.top - overscroll {
                        offset = (effectiveInsets.top - overscroll) - topItemEdge
                    }
                }
            } else {
                let areaHeight = min(completeHeight, visibleAreaHeight)
                if bottomItemEdge < effectiveInsets.top + areaHeight - overscroll {
                    if snapTopItem && topItemEdge < effectiveInsets.top {
                        offset = (effectiveInsets.top - overscroll) - topItemEdge
                    } else {
                        offset = effectiveInsets.top + areaHeight - overscroll - bottomItemEdge
                    }
                } else if topItemEdge > effectiveInsets.top - overscroll && /*snapTopItem*/ true {
                    offset = (effectiveInsets.top - overscroll) - topItemEdge
                }
            }
            
            if visibleAreaHeight > completeHeight {
                if let itemNode = bottomItemNode, itemNode.wantsTrailingItemSpaceUpdates {
                    itemNode.updateTrailingItemSpace(visibleAreaHeight - completeHeight, transition: transition)
                }
            } else {
                if let itemNode = bottomItemNode, itemNode.wantsTrailingItemSpaceUpdates {
                    itemNode.updateTrailingItemSpace(0.0, transition: transition)
                }
            }
        } else {
            if let itemNode = bottomItemNode, itemNode.wantsTrailingItemSpaceUpdates {
                itemNode.updateTrailingItemSpace(0.0, transition: transition)
            }
            if topItemFound {
                if topItemEdge > effectiveInsets.top - overscroll && /*snapTopItem*/ true {
                    offset = (effectiveInsets.top - overscroll) - topItemEdge
                }
            } else if bottomItemFound {
                if bottomItemEdge < self.visibleSize.height - effectiveInsets.bottom - overscroll {
                    offset = self.visibleSize.height - effectiveInsets.bottom - overscroll - bottomItemEdge
                }
            }
        }
        
        if abs(offset) > CGFloat.ulpOfOne {
            for itemNode in self.itemNodes {
                var frame = itemNode.frame
                frame.origin.y += offset
                itemNode.frame = frame
                if let accessoryItemNode = itemNode.accessoryItemNode {
                    itemNode.layoutAccessoryItemNode(accessoryItemNode, leftInset: self.insets.left, rightInset: self.insets.right)
                }
            }
        }
        
        var snappedTopInset: CGFloat = 0.0
        if !self.stackFromBottomInsetItemFactor.isZero && topItemFound {
            snappedTopInset = max(0.0, (effectiveInsets.top - self.insets.top) - (topItemEdge + offset))
        }
        
        return (snappedTopInset, offset)
    }
    
    public func visibleContentOffset() -> ListViewVisibleContentOffset {
        var offset: ListViewVisibleContentOffset = .unknown
        var topItemIndexAndMinY: (Int, CGFloat) = (-1, 0.0)
        
        var currentMinY: CGFloat?
        for itemNode in self.itemNodes {
            if let index = itemNode.index {
                let updatedMinY: CGFloat
                if let currentMinY = currentMinY {
                    if itemNode.apparentFrame.minY < currentMinY {
                        updatedMinY = itemNode.apparentFrame.minY
                    } else {
                        updatedMinY = currentMinY
                    }
                } else {
                    updatedMinY = itemNode.apparentFrame.minY
                }
                topItemIndexAndMinY = (index, updatedMinY)
                break
            } else if currentMinY == nil {
                currentMinY = itemNode.apparentFrame.minY
            }
        }
        if topItemIndexAndMinY.0 == 0 {
            offset = .known(-(topItemIndexAndMinY.1 - self.insets.top))
        } else if topItemIndexAndMinY.0 == -1 {
            offset = .none
        }
        return offset
    }
    
    public func visibleBottomContentOffset() -> ListViewVisibleContentOffset {
        var offset: ListViewVisibleContentOffset = .unknown
        var bottomItemIndexAndFrame: (Int, CGRect) = (-1, CGRect())
        for itemNode in self.itemNodes.reversed() {
            if let index = itemNode.index {
                bottomItemIndexAndFrame = (index, itemNode.apparentFrame)
                break
            }
        }
        if bottomItemIndexAndFrame.0 == self.items.count - 1 {
            offset = .known(bottomItemIndexAndFrame.1.maxY - (self.visibleSize.height - self.insets.bottom))
        } else if bottomItemIndexAndFrame.0 == -1 {
            offset = .none
        }
        return offset
    }
    
    private func updateVisibleContentOffset() {
        self.visibleContentOffsetChanged(self.visibleContentOffset())
        self.visibleBottomContentOffsetChanged(self.visibleBottomContentOffset())
    }
    
    private func stopScrolling() {
        let wasIgnoringScrollingEvents = self.ignoreScrollingEvents
        self.ignoreScrollingEvents = true
        self.scroller.setContentOffset(self.scroller.contentOffset, animated: false)
        self.ignoreScrollingEvents = wasIgnoringScrollingEvents
    }
    
    private func updateTopItemOverscrollBackground(transition: ContainedViewLayoutTransition) {
        if let value = self.keepTopItemOverscrollBackground {
            var applyTransition = transition
            
            let topItemOverscrollBackground: ListViewOverscrollBackgroundNode
            if let current = self.topItemOverscrollBackground {
                topItemOverscrollBackground = current
            } else {
                applyTransition = .immediate
                topItemOverscrollBackground = ListViewOverscrollBackgroundNode(color: value.color)
                topItemOverscrollBackground.isLayerBacked = true
                self.topItemOverscrollBackground = topItemOverscrollBackground
                self.insertSubnode(topItemOverscrollBackground, at: 0)
            }
            var topItemFound = false
            var topItemNodeIndex: Int?
            if !self.itemNodes.isEmpty {
                topItemNodeIndex = self.itemNodes[0].index
            }
            if topItemNodeIndex == 0 {
                topItemFound = true
            }
            
            var backgroundFrame: CGRect
            
            if topItemFound {
                let realTopItemEdge = itemNodes.first!.apparentFrame.origin.y
                let realTopItemEdgeOffset = max(0.0, realTopItemEdge)
                backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: self.visibleSize.width, height: realTopItemEdgeOffset))
                if value.direction {
                    backgroundFrame.origin.y = 0.0
                    backgroundFrame.size.height = realTopItemEdgeOffset
                } else {
                    backgroundFrame.origin.y = min(self.insets.top, realTopItemEdgeOffset)
                    backgroundFrame.size.height = max(0.0, self.visibleSize.height - backgroundFrame.origin.y) + 400.0
                }
            } else {
                backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: self.visibleSize.width, height: 0.0))
                if value.direction {
                    backgroundFrame.origin.y = 0.0
                } else {
                    backgroundFrame.origin.y = 0.0
                    backgroundFrame.size.height = self.visibleSize.height
                }
            }
            
            let previousFrame = topItemOverscrollBackground.frame
            if !previousFrame.equalTo(backgroundFrame) {
                topItemOverscrollBackground.frame = backgroundFrame
                
                let positionDelta = CGPoint(x: backgroundFrame.minX - previousFrame.minX, y: backgroundFrame.minY - previousFrame.minY)
                
                applyTransition.animateOffsetAdditive(node: topItemOverscrollBackground, offset: positionDelta.y)
            }
            
            topItemOverscrollBackground.updateLayout(size: backgroundFrame.size, transition: applyTransition)
        } else if let topItemOverscrollBackground = self.topItemOverscrollBackground {
            self.topItemOverscrollBackground = nil
            topItemOverscrollBackground.removeFromSupernode()
        }
    }
    
    private func updateFloatingHeaderNode(transition: ContainedViewLayoutTransition) {
        guard let updateFloatingHeaderOffset = self.updateFloatingHeaderOffset else {
            return
        }
        
        var topItemFound = false
        var topItemNodeIndex: Int?
        if !self.itemNodes.isEmpty {
            topItemNodeIndex = self.itemNodes[0].index
        }
        if topItemNodeIndex == 0 {
            topItemFound = true
        }
        
        var topOffset: CGFloat
        
        if topItemFound {
            let realTopItemEdge = itemNodes.first!.apparentFrame.origin.y
            let realTopItemEdgeOffset = max(0.0, realTopItemEdge)

            topOffset = realTopItemEdgeOffset
        } else {
            if !self.itemNodes.isEmpty {
                if self.stackFromBottom {
                    topOffset = 0.0
                } else {
                    topOffset = self.visibleSize.height
                }
            } else {
                if self.stackFromBottom {
                    topOffset = self.visibleSize.height
                } else {
                    topOffset = 0.0
                }
            }
        }
        
        updateFloatingHeaderOffset(topOffset, transition)
    }
    
    private func updateBottomItemOverscrollBackground() {
        if let color = self.keepBottomItemOverscrollBackground {
            var bottomItemFound = false
            var lastItemNodeIndex: Int?
            if !itemNodes.isEmpty {
                lastItemNodeIndex = self.itemNodes[itemNodes.count - 1].index
            }
            if lastItemNodeIndex == self.items.count - 1 {
                bottomItemFound = true
            }
            
            let bottomItemOverscrollBackground: ASDisplayNode
            if let currentBottomItemOverscrollBackground = self.bottomItemOverscrollBackground {
                bottomItemOverscrollBackground = currentBottomItemOverscrollBackground
            } else {
                bottomItemOverscrollBackground = ASDisplayNode()
                bottomItemOverscrollBackground.backgroundColor = color
                bottomItemOverscrollBackground.isLayerBacked = true
                self.insertSubnode(bottomItemOverscrollBackground, at: 0)
                self.bottomItemOverscrollBackground = bottomItemOverscrollBackground
            }
            
            if bottomItemFound {
                let realBottomItemEdge = itemNodes.last!.apparentFrame.origin.y
                let realBottomItemEdgeOffset = max(0.0, self.visibleSize.height - realBottomItemEdge)
                let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: self.visibleSize.height - realBottomItemEdgeOffset), size: CGSize(width: self.visibleSize.width, height: self.visibleSize.height))
                if !backgroundFrame.equalTo(bottomItemOverscrollBackground.frame) {
                    bottomItemOverscrollBackground.frame = backgroundFrame
                }
            } else {
                let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: self.visibleSize.height), size: CGSize(width: self.visibleSize.width, height: self.visibleSize.height))
                if !backgroundFrame.equalTo(bottomItemOverscrollBackground.frame) {
                    bottomItemOverscrollBackground.frame = backgroundFrame
                }
            }
        } else if let bottomItemOverscrollBackground = self.bottomItemOverscrollBackground {
            self.bottomItemOverscrollBackground = nil
            bottomItemOverscrollBackground.removeFromSupernode()
        }
    }
    
    private func updateOverlayHighlight(transition: ContainedViewLayoutTransition) {
        var lowestOverlayNode: ListViewItemNode?
        
        for itemNode in self.itemNodes {
            if itemNode.isHighlightedInOverlay {
                lowestOverlayNode = itemNode
                itemNode.view.superview?.bringSubview(toFront: itemNode.view)
                if let verticalScrollIndicator = self.verticalScrollIndicator {
                    verticalScrollIndicator.view.superview?.bringSubview(toFront: verticalScrollIndicator.view)
                }
            }
        }
        
        if let lowestOverlayNode = lowestOverlayNode {
            let itemHighlightOverlayBackground: ASDisplayNode
            if let current = self.itemHighlightOverlayBackground {
                itemHighlightOverlayBackground = current
            } else {
                itemHighlightOverlayBackground = ASDisplayNode()
                itemHighlightOverlayBackground.frame = CGRect(origin: CGPoint(x: 0.0, y: -self.visibleSize.height), size: CGSize(width: self.visibleSize.width, height: self.visibleSize.height * 3.0))
                itemHighlightOverlayBackground.backgroundColor = UIColor(white: 0.0, alpha: 0.5)
                self.itemHighlightOverlayBackground = itemHighlightOverlayBackground
                self.insertSubnode(itemHighlightOverlayBackground, belowSubnode: lowestOverlayNode)
                itemHighlightOverlayBackground.alpha = 0.0
                transition.updateAlpha(node: itemHighlightOverlayBackground, alpha: 1.0)
            }
        } else if let itemHighlightOverlayBackground = self.itemHighlightOverlayBackground {
            self.itemHighlightOverlayBackground = nil
            for (_, headerNode) in self.itemHeaderNodes {
                //self.view.bringSubview(toFront: headerNode.view)
            }
            //self.view.bringSubview(toFront: itemHighlightOverlayBackground.view)
            for itemNode in self.itemNodes {
                //self.view.bringSubview(toFront: itemNode.view)
            }
            transition.updateAlpha(node: itemHighlightOverlayBackground, alpha: 0.0, completion: { [weak itemHighlightOverlayBackground] _ in
                itemHighlightOverlayBackground?.removeFromSupernode()
            })
            if let verticalScrollIndicator = self.verticalScrollIndicator {
                verticalScrollIndicator.view.superview?.bringSubview(toFront: verticalScrollIndicator.view)
            }
        }
    }
    
    private func updateScroller(transition: ContainedViewLayoutTransition) {
        self.updateOverlayHighlight(transition: transition)
        
        if self.itemNodes.count == 0 {
            return
        }
        
        var topItemFound: Bool = false
        var bottomItemFound: Bool = false
        var topItemEdge: CGFloat = 0.0
        var bottomItemEdge: CGFloat = 0.0
        
        for i in 0 ..< self.itemNodes.count {
            if let index = itemNodes[i].index {
                if index == 0 {
                    topItemFound = true
                    topItemEdge = itemNodes[0].apparentFrame.origin.y
                    break
                }
            }
        }
        
        var effectiveInsets = self.insets
        if topItemFound && !self.stackFromBottomInsetItemFactor.isZero {
            let additionalInverseTopInset = self.calculateAdditionalTopInverseInset()
            effectiveInsets.top = max(effectiveInsets.top, self.visibleSize.height - additionalInverseTopInset)
        }
        
        var completeHeight = effectiveInsets.top + effectiveInsets.bottom
        
        if let index = itemNodes[itemNodes.count - 1].index, index == self.items.count - 1 {
            bottomItemFound = true
            bottomItemEdge = itemNodes[itemNodes.count - 1].apparentFrame.maxY
        }
        
        topItemEdge -= effectiveInsets.top
        bottomItemEdge += effectiveInsets.bottom
        
        if topItemFound && bottomItemFound {
            for itemNode in self.itemNodes {
                completeHeight += itemNode.apparentBounds.height
            }
            
            if self.stackFromBottom {
                let updatedCompleteHeight = max(completeHeight, self.visibleSize.height)
                let deltaCompleteHeight = updatedCompleteHeight - completeHeight
                topItemEdge -= deltaCompleteHeight
                bottomItemEdge -= deltaCompleteHeight
                completeHeight = updatedCompleteHeight
            }
        }
        
        self.updateTopItemOverscrollBackground(transition: transition)
        self.updateBottomItemOverscrollBackground()
        self.updateFloatingHeaderNode(transition: transition)
        
        let wasIgnoringScrollingEvents = self.ignoreScrollingEvents
        self.ignoreScrollingEvents = true
        if topItemFound && bottomItemFound {
            if self.stackFromBottom {
                self.lastContentOffset = CGPoint(x: 0.0, y: -topItemEdge)
            } else {
                self.lastContentOffset = CGPoint(x: 0.0, y: -topItemEdge)
            }
            self.scroller.contentSize = CGSize(width: self.visibleSize.width, height: completeHeight)
            self.scroller.contentOffset = self.lastContentOffset
        } else if topItemFound {
            self.scroller.contentSize = CGSize(width: self.visibleSize.width, height: infiniteScrollSize * 2.0)
            self.lastContentOffset = CGPoint(x: 0.0, y: -topItemEdge)
            self.scroller.contentOffset = self.lastContentOffset
        } else if bottomItemFound {
            self.scroller.contentSize = CGSize(width: self.visibleSize.width, height: infiniteScrollSize * 2.0)
            self.lastContentOffset = CGPoint(x: 0.0, y: infiniteScrollSize * 2.0 - bottomItemEdge)
            self.scroller.contentOffset = self.lastContentOffset
        }
        else
        {
            self.scroller.contentSize = CGSize(width: self.visibleSize.width, height: infiniteScrollSize * 2.0)
            self.lastContentOffset = CGPoint(x: 0.0, y: infiniteScrollSize)
            self.scroller.contentOffset = self.lastContentOffset
        }
        self.ignoreScrollingEvents = wasIgnoringScrollingEvents
    }
    
    private func async(_ f: @escaping () -> Void) {
        DispatchQueue.global().async(execute: f)
    }
    
    private func nodeForItem(synchronous: Bool, synchronousLoads: Bool, item: ListViewItem, previousNode: QueueLocalObject<ListViewItemNode>?, index: Int, previousItem: ListViewItem?, nextItem: ListViewItem?, params: ListViewItemLayoutParams, updateAnimation: ListViewItemUpdateAnimation, completion: @escaping (QueueLocalObject<ListViewItemNode>, ListViewItemNodeLayout, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        if let previousNode = previousNode {
            item.updateNode(async: { f in
                if synchronous {
                    f()
                } else {
                    self.async(f)
                }
            }, node: {
                assert(Queue.mainQueue().isCurrent())
                return previousNode.syncWith({ $0 })!
            }, params: params, previousItem: previousItem, nextItem: nextItem, animation: updateAnimation, completion: { (layout, apply) in
                if Thread.isMainThread {
                    if synchronous {
                        completion(previousNode, layout, {
                            return (nil, { info in
                                assert(Queue.mainQueue().isCurrent())
                                previousNode.with({ $0.index = index })
                                apply(info)
                            })
                        })
                    } else {
                        self.async {
                            completion(previousNode, layout, {
                                return (nil, { info in
                                    assert(Queue.mainQueue().isCurrent())
                                    previousNode.with({ $0.index = index })
                                    apply(info)
                                })
                            })
                        }
                    }
                } else {
                    completion(previousNode, layout, {
                        return (nil, { info in
                            assert(Queue.mainQueue().isCurrent())
                            previousNode.with({ $0.index = index })
                            apply(info)
                        })
                    })
                }
            })
        } else {
            item.nodeConfiguredForParams(async: { f in
                if synchronous {
                    f()
                } else {
                    self.async(f)
                }
            }, params: params, synchronousLoads: synchronousLoads, previousItem: previousItem, nextItem: nextItem, completion: { itemNode, apply in
                itemNode.index = index
                completion(QueueLocalObject(queue: Queue.mainQueue(), generate: { return itemNode }), ListViewItemNodeLayout(contentSize: itemNode.contentSize, insets: itemNode.insets), apply)
            })
        }
    }
    
    private func currentState() -> ListViewState {
        var nodes: [ListViewStateNode] = []
        nodes.reserveCapacity(self.itemNodes.count)
        for node in self.itemNodes {
            if let index = node.index {
                nodes.append(.Node(index: index, frame: node.apparentFrame, referenceNode: QueueLocalObject(queue: Queue.mainQueue(), generate: {
                    return node
                })))
            } else {
                nodes.append(.Placeholder(frame: node.apparentFrame))
            }
        }
        return ListViewState(insets: self.insets, visibleSize: self.visibleSize, invisibleInset: self.invisibleInset, nodes: nodes, scrollPosition: nil, stationaryOffset: nil, stackFromBottom: self.stackFromBottom)
    }
    
    public func transaction(deleteIndices: [ListViewDeleteItem], insertIndicesAndItems: [ListViewInsertItem], updateIndicesAndItems: [ListViewUpdateItem], options: ListViewDeleteAndInsertOptions, scrollToItem: ListViewScrollToItem? = nil, additionalScrollDistance: CGFloat = 0.0, updateSizeAndInsets: ListViewUpdateSizeAndInsets? = nil, stationaryItemRange: (Int, Int)? = nil, updateOpaqueState: Any?, completion: @escaping (ListViewDisplayedItemRange) -> Void = { _ in }) {
        if deleteIndices.isEmpty && insertIndicesAndItems.isEmpty && updateIndicesAndItems.isEmpty && scrollToItem == nil && updateSizeAndInsets == nil && additionalScrollDistance.isZero {
            if let updateOpaqueState = updateOpaqueState {
                self.opaqueTransactionState = updateOpaqueState
            }
            completion(self.immediateDisplayedItemRange())
            return
        }
        
        self.transactionQueue.addTransaction({ [weak self] transactionCompletion in
            if let strongSelf = self {
                strongSelf.transactionOffset = 0.0
                strongSelf.deleteAndInsertItemsTransaction(deleteIndices: deleteIndices, insertIndicesAndItems: insertIndicesAndItems, updateIndicesAndItems: updateIndicesAndItems, options: options, scrollToItem: scrollToItem, additionalScrollDistance: additionalScrollDistance, updateSizeAndInsets: updateSizeAndInsets, stationaryItemRange: stationaryItemRange, updateOpaqueState: updateOpaqueState, completion: { [weak strongSelf] in
                    completion(strongSelf?.immediateDisplayedItemRange() ?? ListViewDisplayedItemRange(loadedRange: nil, visibleRange: nil))
                    
                    transactionCompletion()
                })
            }
        })
    }

    private func deleteAndInsertItemsTransaction(deleteIndices: [ListViewDeleteItem], insertIndicesAndItems: [ListViewInsertItem], updateIndicesAndItems: [ListViewUpdateItem], options: ListViewDeleteAndInsertOptions, scrollToItem: ListViewScrollToItem?, additionalScrollDistance: CGFloat, updateSizeAndInsets: ListViewUpdateSizeAndInsets?, stationaryItemRange: (Int, Int)?, updateOpaqueState: Any?, completion: @escaping () -> Void) {
        if deleteIndices.isEmpty && insertIndicesAndItems.isEmpty && updateIndicesAndItems.isEmpty && scrollToItem == nil {
            if let updateSizeAndInsets = updateSizeAndInsets , (self.items.count == 0 || (updateSizeAndInsets.size == self.visibleSize && updateSizeAndInsets.insets == self.insets)) {
                self.visibleSize = updateSizeAndInsets.size
                self.insets = updateSizeAndInsets.insets
                self.headerInsets = updateSizeAndInsets.headerInsets ?? self.insets
                self.scrollIndicatorInsets = updateSizeAndInsets.scrollIndicatorInsets ?? self.insets
                self.ensureTopInsetForOverlayHighlightedItems = updateSizeAndInsets.ensureTopInsetForOverlayHighlightedItems
                
                let wasIgnoringScrollingEvents = self.ignoreScrollingEvents
                self.ignoreScrollingEvents = true
                self.scroller.frame = CGRect(origin: CGPoint(), size: updateSizeAndInsets.size)
                self.scroller.contentSize = CGSize(width: updateSizeAndInsets.size.width, height: infiniteScrollSize * 2.0)
                self.lastContentOffset = CGPoint(x: 0.0, y: infiniteScrollSize)
                self.scroller.contentOffset = self.lastContentOffset
                self.ignoreScrollingEvents = wasIgnoringScrollingEvents
                
                self.updateScroller(transition: .immediate)
                
                if let updateOpaqueState = updateOpaqueState {
                    self.opaqueTransactionState = updateOpaqueState
                }
                
                completion()
                return
            }
        }
        
        if !deleteIndices.isEmpty || !insertIndicesAndItems.isEmpty || !updateIndicesAndItems.isEmpty {
            self.scrolledToItem = nil
        }
        
        let startTime = CACurrentMediaTime()
        var state = self.currentState()
        
        let widthUpdated: Bool
        if let updateSizeAndInsets = updateSizeAndInsets {
            widthUpdated = abs(state.visibleSize.width - updateSizeAndInsets.size.width) > CGFloat.ulpOfOne
            
            state.visibleSize = updateSizeAndInsets.size
            state.insets = updateSizeAndInsets.insets
        } else {
            widthUpdated = false
        }
        
        let sortedDeleteIndices = deleteIndices.sorted(by: {$0.index < $1.index})
        for deleteItem in sortedDeleteIndices.reversed() {
            self.items.remove(at: deleteItem.index)
        }
        
        let sortedIndicesAndItems = insertIndicesAndItems.sorted(by: { $0.index < $1.index })
        if self.items.count == 0 && !sortedIndicesAndItems.isEmpty {
            if sortedIndicesAndItems[0].index != 0 {
                fatalError("deleteAndInsertItems: invalid insert into empty list")
            }
        }
        
        var previousNodes: [Int: QueueLocalObject<ListViewItemNode>] = [:]
        for insertedItem in sortedIndicesAndItems {
            if insertedItem.index < 0 || insertedItem.index > self.items.count {
                fatalError("insertedItem.index \(insertedItem.index) is out of bounds 0 ... \(self.items.count)")
            }
            self.items.insert(insertedItem.item, at: insertedItem.index)
            if let previousIndex = insertedItem.previousIndex {
                for itemNode in self.itemNodes {
                    if itemNode.index == previousIndex {
                        previousNodes[insertedItem.index] = QueueLocalObject(queue: Queue.mainQueue(), generate: { return itemNode })
                    }
                }
            }
        }
        
        for updatedItem in updateIndicesAndItems {
            self.items[updatedItem.index] = updatedItem.item
            for itemNode in self.itemNodes {
                if itemNode.index == updatedItem.previousIndex {
                    previousNodes[updatedItem.index] = QueueLocalObject(queue: Queue.mainQueue(), generate: { return itemNode })
                    break
                }
            }
        }
        
        if let scrollToItem = scrollToItem {
            state.scrollPosition = (scrollToItem.index, scrollToItem.position)
        }
        let itemsCount = self.items.count
        state.fixScrollPosition(itemsCount)
        
        let actions = {
            var previousFrames: [Int: CGRect] = [:]
            for i in 0 ..< state.nodes.count {
                if let index = state.nodes[i].index {
                    previousFrames[index] = state.nodes[i].frame
                }
            }
            
            var operations: [ListViewStateOperation] = []
            
            var deleteDirectionHints: [Int: ListViewItemOperationDirectionHint] = [:]
            var insertDirectionHints: [Int: ListViewItemOperationDirectionHint] = [:]
            
            var deleteIndexSet = Set<Int>()
            for deleteItem in deleteIndices {
                deleteIndexSet.insert(deleteItem.index)
                if let directionHint = deleteItem.directionHint {
                    deleteDirectionHints[deleteItem.index] = directionHint
                }
            }
            
            var insertedIndexSet = Set<Int>()
            for insertedItem in sortedIndicesAndItems {
                insertedIndexSet.insert(insertedItem.index)
                if let directionHint = insertedItem.directionHint {
                    insertDirectionHints[insertedItem.index] = directionHint
                }
            }
            
            let animated = options.contains(.AnimateInsertion)
            
            var remapDeletion: [Int: Int] = [:]
            var updateAdjacentItemsIndices = Set<Int>()
            
            var i = 0
            while i < state.nodes.count {
                if let index = state.nodes[i].index {
                    var indexOffset = 0
                    for deleteIndex in sortedDeleteIndices {
                        if deleteIndex.index < index {
                            indexOffset += 1
                        } else {
                            break
                        }
                    }
                    
                    if deleteIndexSet.contains(index) {
                        previousFrames.removeValue(forKey: index)
                        state.removeNodeAtIndex(i, direction: deleteDirectionHints[index], animated: animated, operations: &operations)
                    } else {
                        let updatedIndex = index - indexOffset
                        if index != updatedIndex {
                            remapDeletion[index] = updatedIndex
                        }
                        if let previousFrame = previousFrames[index] {
                            previousFrames.removeValue(forKey: index)
                            previousFrames[updatedIndex] = previousFrame
                        }
                        if deleteIndexSet.contains(index - 1) || deleteIndexSet.contains(index + 1) {
                            updateAdjacentItemsIndices.insert(updatedIndex)
                        }
                        
                        switch state.nodes[i] {
                            case let .Node(_, frame, referenceNode):
                                state.nodes[i] = .Node(index: updatedIndex, frame: frame, referenceNode: referenceNode)
                            case .Placeholder:
                                break
                        }
                        i += 1
                    }
                } else {
                    i += 1
                }
            }
            
            if !remapDeletion.isEmpty {
                if self.debugInfo {
                    //print("remapDeletion \(remapDeletion)")
                }
                operations.append(.Remap(remapDeletion))
            }
            
            var remapInsertion: [Int: Int] = [:]
            
            for i in 0 ..< state.nodes.count {
                if let index = state.nodes[i].index {
                    var indexOffset = 0
                    for insertedItem in sortedIndicesAndItems {
                        if insertedItem.index <= index + indexOffset {
                            indexOffset += 1
                        }
                    }
                    if indexOffset != 0 {
                        let updatedIndex = index + indexOffset
                        remapInsertion[index] = updatedIndex
                        
                        if let previousFrame = previousFrames[index] {
                            previousFrames.removeValue(forKey: index)
                            previousFrames[updatedIndex] = previousFrame
                        }
                        
                        switch state.nodes[i] {
                            case let .Node(_, frame, referenceNode):
                                state.nodes[i] = .Node(index: updatedIndex, frame: frame, referenceNode: referenceNode)
                            case .Placeholder:
                                break
                        }
                    }
                }
            }
            
            if !remapInsertion.isEmpty {
                if self.debugInfo {
                    print("remapInsertion \(remapInsertion)")
                }
                operations.append(.Remap(remapInsertion))
                
                var remappedUpdateAdjacentItemsIndices = Set<Int>()
                for index in updateAdjacentItemsIndices {
                    if let remappedIndex = remapInsertion[index] {
                        remappedUpdateAdjacentItemsIndices.insert(remappedIndex)
                    } else {
                        remappedUpdateAdjacentItemsIndices.insert(index)
                    }
                }
                updateAdjacentItemsIndices = remappedUpdateAdjacentItemsIndices
            }
            
            if self.debugInfo {
                //print("state \(state.nodes.map({$0.index ?? -1}))")
            }
            
            for node in state.nodes {
                if let index = node.index {
                    if insertedIndexSet.contains(index - 1) || insertedIndexSet.contains(index + 1) {
                        updateAdjacentItemsIndices.insert(index)
                    }
                }
            }
            
            if let (index, boundary) = stationaryItemRange {
                state.setupStationaryOffset(index, boundary: boundary, frames: previousFrames)
            }
            
            if let _ = scrollToItem {
                state.fixScrollPosition(itemsCount)
            }
            
            if self.debugInfo {
                print("deleteAndInsertItemsTransaction prepare \((CACurrentMediaTime() - startTime) * 1000.0) ms")
            }
            
            self.fillMissingNodes(synchronous: options.contains(.Synchronous), synchronousLoads: options.contains(.PreferSynchronousResourceLoading), animated: animated, inputAnimatedInsertIndices: animated ? insertedIndexSet : Set<Int>(), insertDirectionHints: insertDirectionHints, inputState: state, inputPreviousNodes: previousNodes, inputOperations: operations, inputCompletion: { updatedState, operations in
                
                if self.debugInfo {
                    print("fillMissingNodes completion \((CACurrentMediaTime() - startTime) * 1000.0) ms")
                }
                
                var updateIndices = updateAdjacentItemsIndices
                if widthUpdated {
                    for case let .Node(index, _, _) in updatedState.nodes {
                        updateIndices.insert(index)
                    }
                }
                
                /*if !insertedIndexSet.intersection(updateIndices).isEmpty {
                    print("int")
                }*/
                let explicitelyUpdateIndices = Set(updateIndicesAndItems.map({$0.index}))
                /*if !explicitelyUpdateIndices.intersection(updateIndices).isEmpty {
                    print("int")
                }*/
                
                updateIndices.subtract(explicitelyUpdateIndices)
                
                self.updateNodes(synchronous: options.contains(.Synchronous), synchronousLoads: options.contains(.PreferSynchronousResourceLoading), animated: animated, updateIndicesAndItems: updateIndicesAndItems, inputState: updatedState, previousNodes: previousNodes, inputOperations: operations, completion: { updatedState, operations in
                    self.updateAdjacent(synchronous: options.contains(.Synchronous), animated: animated, state: updatedState, updateAdjacentItemsIndices: updateIndices, operations: operations, completion: { state, operations in
                        var updatedState = state
                        var updatedOperations = operations
                        updatedState.removeInvisibleNodes(&updatedOperations)
                        
                        if self.debugInfo {
                            print("updateAdjacent completion \((CACurrentMediaTime() - startTime) * 1000.0) ms")
                        }
                        
                        let stationaryItemIndex = updatedState.stationaryOffset?.0
                        
                        let next = {
                            var updatedOperations = updatedOperations
                            
                            var readySignals: [Signal<Void, NoError>]?
                            
                            if options.contains(.PreferSynchronousResourceLoading) {
                                var currentReadySignals: [Signal<Void, NoError>] = []
                                for i in 0 ..< updatedOperations.count {
                                    if case let .InsertNode(index, offsetDirection, nodeAnimated, node, layout, apply) = updatedOperations[i] {
                                        let (ready, commitApply) = apply()
                                        updatedOperations[i] = .InsertNode(index: index, offsetDirection: offsetDirection, animated: nodeAnimated, node: node, layout: layout, apply: {
                                            return (nil, commitApply)
                                        })
                                        if let ready = ready {
                                            currentReadySignals.append(ready)
                                        }
                                    }
                                }
                                readySignals = currentReadySignals
                            }
                            
                            let beginReplay = { [weak self] in
                                if let strongSelf = self {
                                    strongSelf.replayOperations(animated: animated, animateAlpha: options.contains(.AnimateAlpha), animateCrossfade: options.contains(.AnimateCrossfade), animateTopItemVerticalOrigin: options.contains(.AnimateTopItemPosition), operations: updatedOperations, requestItemInsertionAnimationsIndices: options.contains(.RequestItemInsertionAnimations) ? insertedIndexSet : Set(), scrollToItem: scrollToItem, additionalScrollDistance: additionalScrollDistance, updateSizeAndInsets: updateSizeAndInsets, stationaryItemIndex: stationaryItemIndex, updateOpaqueState: updateOpaqueState, completion: {
                                        if options.contains(.PreferSynchronousDrawing) {
                                            let startTime = CACurrentMediaTime()
                                            self?.recursivelyEnsureDisplaySynchronously(true)
                                            let deltaTime = CACurrentMediaTime() - startTime
                                            if false {
                                                print("ListView: waited \(deltaTime * 1000.0) ms for nodes to display")
                                            }
                                        }
                                        completion()
                                    })
                                }
                            }
                            
                            if let readySignals = readySignals, !readySignals.isEmpty && false {
                                let readyWithTimeout = combineLatest(readySignals)
                                    |> deliverOnMainQueue
                                    |> timeout(0.2, queue: Queue.mainQueue(), alternate: .single([]))
                                let startTime = CACurrentMediaTime()
                                self.waitingForNodesDisposable.set(readyWithTimeout.start(completed: {
                                    let deltaTime = CACurrentMediaTime() - startTime
                                    if false {
                                        print("ListView: waited \(deltaTime * 1000.0) ms for nodes to load")
                                    }
                                    beginReplay()
                                }))
                            } else {
                                beginReplay()
                            }
                        }
                        
                        if options.contains(.LowLatency) || options.contains(.Synchronous) {
                            Queue.mainQueue().async {
                                if self.debugInfo {
                                    print("updateAdjacent LowLatency enqueue \((CACurrentMediaTime() - startTime) * 1000.0) ms")
                                }
                                next()
                            }
                        } else {
                            self.dispatchOnVSync {
                                next()
                            }
                        }
                    })
                })
            })
        }
        
        if options.contains(.Synchronous) {
            actions()
        } else {
            self.async(actions)
        }
    }
    
    private func updateAdjacent(synchronous: Bool, animated: Bool, state: ListViewState, updateAdjacentItemsIndices: Set<Int>, operations: [ListViewStateOperation], completion: @escaping (ListViewState, [ListViewStateOperation]) -> Void) {
        if updateAdjacentItemsIndices.isEmpty {
            completion(state, operations)
        } else {
            let updateAnimation: ListViewItemUpdateAnimation = animated ? .System(duration: insertionAnimationDuration) : .None
            
            var updatedUpdateAdjacentItemsIndices = updateAdjacentItemsIndices
            
            let nodeIndex = updateAdjacentItemsIndices.first!
            updatedUpdateAdjacentItemsIndices.remove(nodeIndex)
            
            var continueWithoutNode = true
            
            var i = 0
            for node in state.nodes {
                if case let .Node(index, _, referenceNode) = node , index == nodeIndex {
                    if let referenceNode = referenceNode {
                        continueWithoutNode = false
                        self.items[index].updateNode(async: { f in
                            if synchronous {
                                f()
                            } else {
                                self.async(f)
                            }
                        }, node: {
                            assert(Queue.mainQueue().isCurrent())
                            return referenceNode.syncWith({ $0 })!
                        }, params: ListViewItemLayoutParams(width: state.visibleSize.width, leftInset: state.insets.left, rightInset: state.insets.right), previousItem: index == 0 ? nil : self.items[index - 1], nextItem: index == self.items.count - 1 ? nil : self.items[index + 1], animation: updateAnimation, completion: { layout, apply in
                            var updatedState = state
                            var updatedOperations = operations
                            
                            let heightDelta = layout.size.height - updatedState.nodes[i].frame.size.height
                            
                            updatedOperations.append(.UpdateLayout(index: i, layout: layout, apply: {
                                return (nil, apply)
                            }))
                            
                            if !animated {
                                let previousFrame = updatedState.nodes[i].frame
                                updatedState.nodes[i].frame = CGRect(origin: previousFrame.origin, size: layout.size)
                                if previousFrame.minY < updatedState.insets.top {
                                    for j in 0 ... i {
                                        updatedState.nodes[j].frame = updatedState.nodes[j].frame.offsetBy(dx: 0.0, dy: -heightDelta)
                                    }
                                } else {
                                    if i != updatedState.nodes.count {
                                        for j in i + 1 ..< updatedState.nodes.count {
                                            updatedState.nodes[j].frame = updatedState.nodes[j].frame.offsetBy(dx: 0.0, dy: heightDelta)
                                        }
                                    }
                                }
                            }
                            
                            self.updateAdjacent(synchronous: synchronous, animated: animated, state: updatedState, updateAdjacentItemsIndices: updatedUpdateAdjacentItemsIndices, operations: updatedOperations, completion: completion)
                        })
                    }
                    break
                }
                i += 1
            }
            
            if continueWithoutNode {
                updateAdjacent(synchronous: synchronous, animated: animated, state: state, updateAdjacentItemsIndices: updatedUpdateAdjacentItemsIndices, operations: operations, completion: completion)
            }
        }
    }
    
    private func fillMissingNodes(synchronous: Bool, synchronousLoads: Bool, animated: Bool, inputAnimatedInsertIndices: Set<Int>, insertDirectionHints: [Int: ListViewItemOperationDirectionHint], inputState: ListViewState, inputPreviousNodes: [Int: QueueLocalObject<ListViewItemNode>], inputOperations: [ListViewStateOperation], inputCompletion: @escaping (ListViewState, [ListViewStateOperation]) -> Void) {
        let animatedInsertIndices = inputAnimatedInsertIndices
        var state = inputState
        var previousNodes = inputPreviousNodes
        var operations = inputOperations
        let completion = inputCompletion
        let updateAnimation: ListViewItemUpdateAnimation = animated ? .System(duration: insertionAnimationDuration) : .None
        
        if state.nodes.count > 1000 {
            print("state.nodes.count > 1000")
        }
        
        while true {
            if self.items.count == 0 {
                completion(state, operations)
                break
            } else {
                var insertionItemIndexAndDirection: (Int, ListViewInsertionOffsetDirection)?
                
                if self.debugInfo {
                    assert(true)
                }
                
                if let insertionPoint = state.insertionPoint(insertDirectionHints, itemCount: self.items.count) {
                    insertionItemIndexAndDirection = (insertionPoint.index, insertionPoint.direction)
                }
                
                if self.debugInfo {
                    print("insertionItemIndexAndDirection \(String(describing: insertionItemIndexAndDirection))")
                }
                
                if let insertionItemIndexAndDirection = insertionItemIndexAndDirection {
                    let index = insertionItemIndexAndDirection.0
                    let threadId = pthread_self()
                    var tailRecurse = false
                    self.nodeForItem(synchronous: synchronous, synchronousLoads: synchronousLoads, item: self.items[index], previousNode: previousNodes[index], index: index, previousItem: index == 0 ? nil : self.items[index - 1], nextItem: self.items.count == index + 1 ? nil : self.items[index + 1], params: ListViewItemLayoutParams(width: state.visibleSize.width, leftInset: state.insets.left, rightInset: state.insets.right), updateAnimation: updateAnimation, completion: { (node, layout, apply) in
                        
                        if pthread_equal(pthread_self(), threadId) != 0 && !tailRecurse {
                            tailRecurse = true
                            state.insertNode(index, node: node, layout: layout, apply: apply, offsetDirection: insertionItemIndexAndDirection.1, animated: animated && animatedInsertIndices.contains(index), operations: &operations, itemCount: self.items.count)
                        } else {
                            var updatedState = state
                            var updatedOperations = operations
                            updatedState.insertNode(index, node: node, layout: layout, apply: apply, offsetDirection: insertionItemIndexAndDirection.1, animated: animated && animatedInsertIndices.contains(index), operations: &updatedOperations, itemCount: self.items.count)
                            self.fillMissingNodes(synchronous: synchronous, synchronousLoads: synchronousLoads, animated: animated, inputAnimatedInsertIndices: animatedInsertIndices, insertDirectionHints: insertDirectionHints, inputState: updatedState, inputPreviousNodes: previousNodes, inputOperations: updatedOperations, inputCompletion: completion)
                        }
                    })
                    if !tailRecurse {
                        tailRecurse = true
                        break
                    }
                } else {
                    completion(state, operations)
                    break
                }
            }
        }
    }
    
    private func updateNodes(synchronous: Bool, synchronousLoads: Bool, animated: Bool, updateIndicesAndItems: [ListViewUpdateItem], inputState: ListViewState, previousNodes: [Int: QueueLocalObject<ListViewItemNode>], inputOperations: [ListViewStateOperation], completion: @escaping (ListViewState, [ListViewStateOperation]) -> Void) {
        var state = inputState
        var operations = inputOperations
        var updateIndicesAndItems = updateIndicesAndItems
        
        while true {
            if updateIndicesAndItems.isEmpty {
                completion(state, operations)
                break
            } else {
                let updateItem = updateIndicesAndItems[0]
                if let previousNode = previousNodes[updateItem.index] {
                    self.nodeForItem(synchronous: synchronous, synchronousLoads: synchronousLoads, item: updateItem.item, previousNode: previousNode, index: updateItem.index, previousItem: updateItem.index == 0 ? nil : self.items[updateItem.index - 1], nextItem: updateItem.index == (self.items.count - 1) ? nil : self.items[updateItem.index + 1], params: ListViewItemLayoutParams(width: state.visibleSize.width, leftInset: state.insets.left, rightInset: state.insets.right), updateAnimation: animated ? .System(duration: insertionAnimationDuration) : .None, completion: { _, layout, apply in
                        state.updateNodeAtItemIndex(updateItem.index, layout: layout, direction: updateItem.directionHint, animation: animated ? .System(duration: insertionAnimationDuration) : .None, apply: apply, operations: &operations)
                        
                        updateIndicesAndItems.remove(at: 0)
                        self.updateNodes(synchronous: synchronous, synchronousLoads: synchronousLoads, animated: animated, updateIndicesAndItems: updateIndicesAndItems, inputState: state, previousNodes: previousNodes, inputOperations: operations, completion: completion)
                    })
                    break
                } else {
                    updateIndicesAndItems.remove(at: 0)
                    //self.updateNodes(synchronous: synchronous, animated: animated, updateIndicesAndItems: updateIndicesAndItems, inputState: state, previousNodes: previousNodes, inputOperations: operations, completion: completion)
                }
            }
        }
    }
    
    private func referencePointForInsertionAtIndex(_ nodeIndex: Int) -> CGPoint {
        var index = 0
        for itemNode in self.itemNodes {
            if index == nodeIndex {
                return itemNode.apparentFrame.origin
            }
            index += 1
        }
        if self.itemNodes.count == 0 {
            return CGPoint(x: 0.0, y: self.insets.top)
        } else {
            return CGPoint(x: 0.0, y: self.itemNodes[self.itemNodes.count - 1].apparentFrame.maxY)
        }
    }
    
    private func insertNodeAtIndex(animated: Bool, animateAlpha: Bool, forceAnimateInsertion: Bool, previousFrame: CGRect?, nodeIndex: Int, offsetDirection: ListViewInsertionOffsetDirection, node: ListViewItemNode, layout: ListViewItemNodeLayout, apply: () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void), timestamp: Double, listInsets: UIEdgeInsets, visibleBounds: CGRect) {
        let insertionOrigin = self.referencePointForInsertionAtIndex(nodeIndex)
        
        let nodeOrigin: CGPoint
        switch offsetDirection {
            case .Up:
                nodeOrigin = CGPoint(x: insertionOrigin.x, y: insertionOrigin.y - (animated ? 0.0 : layout.size.height))
            case .Down:
                nodeOrigin = insertionOrigin
        }
        
        let nodeFrame = CGRect(origin: nodeOrigin, size: CGSize(width: layout.size.width, height: layout.size.height))
        
        let previousApparentHeight = node.apparentHeight
        let previousInsets = node.insets
        
        node.contentSize = layout.contentSize
        node.insets = layout.insets
        node.apparentHeight = animated ? 0.0 : layout.size.height
        node.frame = nodeFrame
        if let accessoryItemNode = node.accessoryItemNode {
            node.layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
        }
        apply().1(ListViewItemApply(isOnScreen: visibleBounds.intersects(nodeFrame)))
        self.itemNodes.insert(node, at: nodeIndex)
        
        var offsetHeight = node.apparentHeight
        var takenAnimation = false
        
        if let _ = previousFrame, animated && node.index != nil && nodeIndex != self.itemNodes.count - 1 {
            let nextNode = self.itemNodes[nodeIndex + 1]
            if nextNode.index == nil && nextNode.subnodes == nil || nextNode.subnodes!.isEmpty {
                let nextHeight = nextNode.apparentHeight
                if abs(nextHeight - previousApparentHeight) < CGFloat.ulpOfOne {
                    if let animation = nextNode.animationForKey("apparentHeight") {
                        node.apparentHeight = previousApparentHeight
                        
                        offsetHeight = 0.0
                        
                        var offsetPosition = nextNode.position
                        offsetPosition.y += nextHeight
                        nextNode.position = offsetPosition
                        nextNode.apparentHeight = 0.0
                        
                        nextNode.removeApparentHeightAnimation()
                        
                        takenAnimation = true
                        
                        if abs(layout.size.height - previousApparentHeight) > CGFloat.ulpOfOne {
                            node.addApparentHeightAnimation(layout.size.height, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp, update: { [weak node] progress, currentValue in
                                if let node = node {
                                    node.animateFrameTransition(progress, currentValue)
                                }
                            })
                            if node.rotated {
                                node.transitionOffset += previousApparentHeight - layout.size.height
                                node.addTransitionOffsetAnimation(0.0, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
                            }
                        }
                    }
                }
            }
        }
        
        if node.index == nil {
            if node.animationForKey("height") == nil || !(node is ListViewTempItemNode) {
                node.addHeightAnimation(0.0, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
            }
            if node.animationForKey("apparentHeight") == nil || !(node is ListViewTempItemNode) {
                node.addApparentHeightAnimation(0.0, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
            }
            node.animateRemoved(timestamp, duration: insertionAnimationDuration * UIView.animationDurationFactor())
        } else if animated {
            if takenAnimation {
                if let previousFrame = previousFrame {
                    if self.debugInfo {
                        assert(true)
                    }
                    
                    let transitionOffsetDelta = nodeFrame.origin.y - previousFrame.origin.y
                    if node.rotated {
                        node.transitionOffset -= transitionOffsetDelta - previousApparentHeight + layout.size.height
                    } else {
                        node.transitionOffset += transitionOffsetDelta
                    }
                    node.addTransitionOffsetAnimation(0.0, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
                    if previousInsets != layout.insets {
                        node.insets = previousInsets
                        node.addInsetsAnimationToValue(layout.insets, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
                    }
                }
            } else {
                if !nodeFrame.size.height.isEqual(to: node.apparentHeight) {
                    node.addApparentHeightAnimation(nodeFrame.size.height, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp, update: { [weak node] progress, currentValue in
                        if let node = node {
                            node.animateFrameTransition(progress, currentValue)
                        }
                    })
                }
            
                if let previousFrame = previousFrame {
                    if self.debugInfo {
                        assert(true)
                    }
                    
                    let transitionOffsetDelta = nodeFrame.origin.y - previousFrame.origin.y
                    if node.rotated {
                        node.transitionOffset -= transitionOffsetDelta - previousApparentHeight + layout.size.height
                    } else {
                        node.transitionOffset += transitionOffsetDelta
                    }
                    node.addTransitionOffsetAnimation(0.0, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
                    if previousInsets != layout.insets {
                        node.insets = previousInsets
                        node.addInsetsAnimationToValue(layout.insets, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
                    }
                } else {
                    if self.debugInfo {
                        assert(true)
                    }
                    if !node.rotated {
                        if !node.insets.top.isZero {
                            node.transitionOffset += node.insets.top
                            node.addTransitionOffsetAnimation(0.0, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
                        }
                    }
                    node.animateInsertion(timestamp, duration: insertionAnimationDuration * UIView.animationDurationFactor(), short: false)
                }
            }
        } else if animateAlpha && previousFrame == nil {
            if forceAnimateInsertion {
                node.animateInsertion(timestamp, duration: insertionAnimationDuration * UIView.animationDurationFactor(), short: true)
            } else {
                node.animateAdded(timestamp, duration: insertionAnimationDuration * UIView.animationDurationFactor())
            }
        }
        
        if node.apparentHeight > CGFloat.ulpOfOne {
            switch offsetDirection {
            case .Up:
                var i = nodeIndex - 1
                while i >= 0 {
                    var frame = self.itemNodes[i].frame
                    frame.origin.y -= offsetHeight
                    self.itemNodes[i].frame = frame
                    if let accessoryItemNode = self.itemNodes[i].accessoryItemNode {
                        self.itemNodes[i].layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                    }
                    i -= 1
                }
            case .Down:
                var i = nodeIndex + 1
                while i < self.itemNodes.count {
                    var frame = self.itemNodes[i].frame
                    frame.origin.y += offsetHeight
                    self.itemNodes[i].frame = frame
                    if let accessoryItemNode = self.itemNodes[i].accessoryItemNode {
                        self.itemNodes[i].layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                    }
                    i += 1
                }
            }
        }
    }
    
    private func lowestNodeToInsertBelow() -> ASDisplayNode? {
        if let itemNode = self.reorderNode?.itemNode, itemNode.supernode == self {
            //return itemNode
        }
        var lowestHeaderNode: ASDisplayNode?
        lowestHeaderNode = self.verticalScrollIndicator
        var lowestHeaderNodeIndex: Int?
        for (_, headerNode) in self.itemHeaderNodes {
            if let index = self.view.subviews.index(of: headerNode.view) {
                if lowestHeaderNodeIndex == nil || index < lowestHeaderNodeIndex! {
                    lowestHeaderNodeIndex = index
                    lowestHeaderNode = headerNode
                }
            }
        }
        return lowestHeaderNode
    }
    
    private func topItemVerticalOrigin() -> CGFloat? {
        var topItemFound = false
        
        for i in 0 ..< self.itemNodes.count {
            if let index = itemNodes[i].index {
                if index == 0 {
                    topItemFound = true
                }
                break
            }
        }
        
        if topItemFound {
            return itemNodes[0].apparentFrame.origin.y
        } else {
            return nil
        }
    }
    
    private func bottomItemMaxY() -> CGFloat? {
        var bottomItemFound = false
        
        for i in (0 ..< self.itemNodes.count).reversed() {
            if let index = itemNodes[i].index {
                if index == self.items.count - 1 {
                    bottomItemFound = true
                    break
                }
            }
        }
        
        if bottomItemFound {
            return itemNodes.last!.apparentFrame.maxY
        } else {
            return nil
        }
    }
    
    private func replayOperations(animated: Bool, animateAlpha: Bool, animateCrossfade: Bool, animateTopItemVerticalOrigin: Bool, operations: [ListViewStateOperation], requestItemInsertionAnimationsIndices: Set<Int>, scrollToItem originalScrollToItem: ListViewScrollToItem?, additionalScrollDistance: CGFloat, updateSizeAndInsets: ListViewUpdateSizeAndInsets?, stationaryItemIndex: Int?, updateOpaqueState: Any?, completion: () -> Void) {
        var scrollToItem: ListViewScrollToItem?
        var isExperimentalSnapToScrollToItem = false
        if let originalScrollToItem = originalScrollToItem {
            scrollToItem = originalScrollToItem
            if self.experimentalSnapScrollToItem {
                self.scrolledToItem = (originalScrollToItem.index, originalScrollToItem.position)
            }
        } else if let scrolledToItem = self.scrolledToItem, self.experimentalSnapScrollToItem {
            var curve: ListViewAnimationCurve = .Default(duration: nil)
            var animated = false
            if let updateSizeAndInsets = updateSizeAndInsets {
                curve = updateSizeAndInsets.curve
                animated = !updateSizeAndInsets.duration.isZero
            }
            scrollToItem = ListViewScrollToItem(index: scrolledToItem.0, position: scrolledToItem.1, animated: animated, curve: curve, directionHint: .Down)
            isExperimentalSnapToScrollToItem = true
        }
        
        weak var highlightedItemNode: ListViewItemNode?
        if let highlightedItemIndex = self.highlightedItemIndex {
            for itemNode in self.itemNodes {
                if itemNode.index == highlightedItemIndex {
                    highlightedItemNode = itemNode
                    break
                }
            }
        }
        
        let timestamp = CACurrentMediaTime()
        
        let listInsets = updateSizeAndInsets?.insets ?? self.insets
        
        if let updateOpaqueState = updateOpaqueState {
            self.opaqueTransactionState = updateOpaqueState
        }
        
        var previousTopItemVerticalOrigin: CGFloat?
        var snapshotView: UIView?
        if animateCrossfade {
            snapshotView = self.view.snapshotView(afterScreenUpdates: false)
        }
        if animateTopItemVerticalOrigin {
            previousTopItemVerticalOrigin = self.topItemVerticalOrigin()
        }
        
        var previousApparentFrames: [(ListViewItemNode, CGRect)] = []
        for itemNode in self.itemNodes {
            previousApparentFrames.append((itemNode, itemNode.apparentFrame))
        }
        
        var takenPreviousNodes = Set<ListViewItemNode>()
        for operation in operations {
            if case let .InsertNode(_, _, _, node, _, _) = operation {
                takenPreviousNodes.insert(node.syncWith({ $0 })!)
            }
        }
        
        let lowestNodeToInsertBelow = self.lowestNodeToInsertBelow()
        var hadInserts = false
        
        let visibleBounds = CGRect(origin: CGPoint(), size: self.visibleSize)
        
        for operation in operations {
            switch operation {
                case let .InsertNode(index, offsetDirection, nodeAnimated, nodeObject, layout, apply):
                    let node = nodeObject.syncWith({ $0 })!
                    var previousFrame: CGRect?
                    for (previousNode, frame) in previousApparentFrames {
                        if previousNode === node {
                            previousFrame = frame
                            break
                        }
                    }
                    var forceAnimateInsertion = false
                    if let index = node.index, requestItemInsertionAnimationsIndices.contains(index) {
                        forceAnimateInsertion = true
                    }
                    var updatedPreviousFrame = previousFrame
                    if let previousFrame = previousFrame, previousFrame.minY >= self.visibleSize.height || previousFrame.maxY < 0.0 {
                        updatedPreviousFrame = nil
                    }
                    
                    self.insertNodeAtIndex(animated: nodeAnimated, animateAlpha: animateAlpha, forceAnimateInsertion: forceAnimateInsertion, previousFrame: updatedPreviousFrame, nodeIndex: index, offsetDirection: offsetDirection, node: node, layout: layout, apply: apply, timestamp: timestamp, listInsets: listInsets, visibleBounds: visibleBounds)
                    hadInserts = true
                    if let _ = updatedPreviousFrame {
                        if let itemNode = self.reorderNode?.itemNode, itemNode.supernode == self {
                            self.insertSubnode(node, belowSubnode: itemNode)
                        } else if let lowestNodeToInsertBelow = lowestNodeToInsertBelow {
                            self.insertSubnode(node, belowSubnode: lowestNodeToInsertBelow)
                        } else if let verticalScrollIndicator = self.verticalScrollIndicator {
                            self.insertSubnode(node, belowSubnode: verticalScrollIndicator)
                        } else {
                            self.addSubnode(node)
                        }
                    } else {
                        if animated {
                            if let topItemOverscrollBackground = self.topItemOverscrollBackground {
                                self.insertSubnode(node, aboveSubnode: topItemOverscrollBackground)
                            } else {
                                self.insertSubnode(node, at: 0)
                            }
                        } else {
                            if let itemNode = self.reorderNode?.itemNode, itemNode.supernode == self {
                                self.insertSubnode(node, belowSubnode: itemNode)
                            } else if let lowestNodeToInsertBelow = lowestNodeToInsertBelow {
                                self.insertSubnode(node, belowSubnode: lowestNodeToInsertBelow)
                            } else if let verticalScrollIndicator = self.verticalScrollIndicator {
                                self.insertSubnode(node, belowSubnode: verticalScrollIndicator)
                            } else {
                                self.addSubnode(node)
                            }
                        }
                    }
                case let .InsertDisappearingPlaceholder(index, referenceNodeObject, offsetDirection):
                    var height: CGFloat?
                    var previousLayout: ListViewItemNodeLayout?
                    
                    let referenceNode = referenceNodeObject.syncWith({ $0 })!
                    
                    for (node, previousFrame) in previousApparentFrames {
                        if node === referenceNode {
                            height = previousFrame.size.height
                            previousLayout = ListViewItemNodeLayout(contentSize: node.contentSize, insets: node.insets)
                            break
                        }
                    }
                    
                    if let height = height, let previousLayout = previousLayout {
                        if takenPreviousNodes.contains(referenceNode) {
                            let tempNode = ListViewTempItemNode(layerBacked: true)
                            self.insertNodeAtIndex(animated: false, animateAlpha: false, forceAnimateInsertion: false, previousFrame: nil, nodeIndex: index, offsetDirection: offsetDirection, node: tempNode, layout: ListViewItemNodeLayout(contentSize: CGSize(width: self.visibleSize.width, height: height), insets: UIEdgeInsets()), apply: { return (nil, { _ in }) }, timestamp: timestamp, listInsets: listInsets, visibleBounds: visibleBounds)
                        } else {
                            referenceNode.index = nil
                            self.insertNodeAtIndex(animated: false, animateAlpha: false, forceAnimateInsertion: false, previousFrame: nil, nodeIndex: index, offsetDirection: offsetDirection, node: referenceNode, layout: previousLayout, apply: { return (nil, { _ in }) }, timestamp: timestamp, listInsets: listInsets, visibleBounds: visibleBounds)
                            if let verticalScrollIndicator = self.verticalScrollIndicator {
                                self.insertSubnode(referenceNode, belowSubnode: verticalScrollIndicator)
                            } else {
                                self.addSubnode(referenceNode)
                            }
                        }
                    } else {
                        assertionFailure()
                    }
                case let .Remap(mapping):
                    for node in self.itemNodes {
                        if let index = node.index {
                            if let mapped = mapping[index] {
                                node.index = mapped
                            }
                        }
                    }
                case let .Remove(index, offsetDirection):
                    let apparentFrame = self.itemNodes[index].apparentFrame
                    let height = apparentFrame.size.height
                    switch offsetDirection {
                        case .Up:
                            if index != self.itemNodes.count - 1 {
                                for i in index + 1 ..< self.itemNodes.count {
                                    var frame = self.itemNodes[i].frame
                                    frame.origin.y -= height
                                    self.itemNodes[i].frame = frame
                                    if let accessoryItemNode = self.itemNodes[i].accessoryItemNode {
                                        self.itemNodes[i].layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                                    }
                                }
                            }
                        case .Down:
                            if index != 0 {
                                for i in (0 ..< index).reversed() {
                                    var frame = self.itemNodes[i].frame
                                    frame.origin.y += height
                                    self.itemNodes[i].frame = frame
                                    if let accessoryItemNode = self.itemNodes[i].accessoryItemNode {
                                        self.itemNodes[i].layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                                    }
                                }
                            }
                    }
                    
                    self.removeItemNodeAtIndex(index)
                case let .UpdateLayout(index, layout, apply):
                    let node = self.itemNodes[index]
                    
                    let previousApparentHeight = node.apparentHeight
                    let previousInsets = node.insets
                    
                    node.contentSize = layout.contentSize
                    node.insets = layout.insets
                    
                    let updatedApparentHeight = node.bounds.size.height
                    let updatedInsets = node.insets
                    
                    var apparentFrame = node.apparentFrame
                    apparentFrame.size.height = updatedApparentHeight
                    
                    apply().1(ListViewItemApply(isOnScreen: visibleBounds.intersects(apparentFrame)))
                    
                    var offsetRanges = OffsetRanges()
                    
                    if animated {
                        if updatedInsets != previousInsets {
                            node.insets = previousInsets
                            node.addInsetsAnimationToValue(updatedInsets, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
                        }
                        
                        if !abs(updatedApparentHeight - previousApparentHeight).isZero {
                            let currentAnimation = node.animationForKey("apparentHeight")
                            if let currentAnimation = currentAnimation, let toFloat = currentAnimation.to as? CGFloat, toFloat.isEqual(to: updatedApparentHeight) {
                            } else {
                                node.apparentHeight = previousApparentHeight
                                node.animateFrameTransition(0.0, previousApparentHeight)
                                node.addApparentHeightAnimation(updatedApparentHeight, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp, update: { [weak node] progress, currentValue in
                                    if let node = node {
                                        node.animateFrameTransition(progress, currentValue)
                                    }
                                })
                                
                                if node.rotated && currentAnimation == nil {
                                    let insetPart: CGFloat = previousInsets.bottom - layout.insets.bottom
                                    node.transitionOffset += previousApparentHeight - layout.size.height - insetPart
                                    node.addTransitionOffsetAnimation(0.0, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp)
                                }
                            }
                        } else {
                            if node.shouldAnimateHorizontalFrameTransition() {
                                node.addApparentHeightAnimation(updatedApparentHeight, duration: insertionAnimationDuration * UIView.animationDurationFactor(), beginAt: timestamp, update: { [weak node] progress, currentValue in
                                    if let node = node {
                                        node.animateFrameTransition(progress, currentValue)
                                    }
                                })
                            }
                        }
                    } else {
                        node.apparentHeight = updatedApparentHeight
                        
                        let apparentHeightDelta = updatedApparentHeight - previousApparentHeight
                        if apparentHeightDelta != 0.0 {
                            var apparentFrame = node.apparentFrame
                            apparentFrame.origin.y += offsetRanges.offsetForIndex(index)
                            if apparentFrame.maxY < self.insets.top {
                                offsetRanges.offset(IndexRange(first: 0, last: index), offset: -apparentHeightDelta)
                            } else {
                                offsetRanges.offset(IndexRange(first: index + 1, last: Int.max), offset: apparentHeightDelta)
                            }
                        }
                    }
                    
                    if let accessoryItemNode = node.accessoryItemNode {
                        node.layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                    }
                    
                    var index = 0
                    for itemNode in self.itemNodes {
                        let offset = offsetRanges.offsetForIndex(index)
                        if offset != 0.0 {
                            var frame = itemNode.frame
                            frame.origin.y += offset
                            itemNode.frame = frame
                        }
                        
                        index += 1
                    }
            }
            
            if self.debugInfo {
                //print("operation \(self.itemNodes.map({"\($0.index) \(unsafeAddressOf($0))"}))")
            }
        }
        
        if hadInserts, let reorderNode = self.reorderNode, reorderNode.supernode != nil {
            self.view.bringSubview(toFront: reorderNode.view)
            if let verticalScrollIndicator = self.verticalScrollIndicator {
                verticalScrollIndicator.view.superview?.bringSubview(toFront: verticalScrollIndicator.view)
            }
        }
        
        if self.debugInfo {
            //print("replay after \(self.itemNodes.map({"\($0.index) \(unsafeAddressOf($0))"}))")
        }
        
        if let scrollToItem = scrollToItem {
            self.stopScrolling()
            
            for itemNode in self.itemNodes {
                if let index = itemNode.index, index == scrollToItem.index {
                    let insets = self.insets// updateSizeAndInsets?.insets ?? self.insets
                    
                    let offset: CGFloat
                    switch scrollToItem.position {
                        case let .bottom(additionalOffset):
                            offset = (self.visibleSize.height - insets.bottom) - itemNode.apparentFrame.maxY + itemNode.scrollPositioningInsets.bottom + additionalOffset
                        case let .top(additionalOffset):
                            offset = insets.top - itemNode.apparentFrame.minY - itemNode.scrollPositioningInsets.top + additionalOffset
                        case let .center(overflow):
                            let contentAreaHeight = self.visibleSize.height - insets.bottom - insets.top
                            if itemNode.apparentFrame.size.height <= contentAreaHeight + CGFloat.ulpOfOne {
                                offset = insets.top + floor(((self.visibleSize.height - insets.bottom - insets.top) - itemNode.frame.size.height) / 2.0) - itemNode.apparentFrame.minY
                            } else {
                                switch overflow {
                                    case .top:
                                        offset = insets.top - itemNode.apparentFrame.minY
                                    case .bottom:
                                        offset = (self.visibleSize.height - insets.bottom) - itemNode.apparentFrame.maxY
                                }
                            }
                        case .visible:
                            if itemNode.apparentFrame.size.height > self.visibleSize.height - insets.top - insets.bottom {
                                if itemNode.apparentFrame.maxY > self.visibleSize.height - insets.bottom {
                                    offset = (self.visibleSize.height - insets.bottom) - itemNode.apparentFrame.maxY + itemNode.scrollPositioningInsets.bottom
                                } else {
                                    offset = 0.0
                                }
                            } else {
                                if itemNode.apparentFrame.maxY > self.visibleSize.height - insets.bottom {
                                    offset = (self.visibleSize.height - insets.bottom) - itemNode.apparentFrame.maxY + itemNode.scrollPositioningInsets.bottom
                                } else if itemNode.apparentFrame.minY < insets.top {
                                    offset = insets.top - itemNode.apparentFrame.minY - itemNode.scrollPositioningInsets.top
                                } else {
                                    offset = 0.0
                                }
                            }
                    }
                    
                    for itemNode in self.itemNodes {
                        var frame = itemNode.frame
                        frame.origin.y += offset
                        itemNode.frame = frame
                        if let accessoryItemNode = itemNode.accessoryItemNode {
                            itemNode.layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                        }
                    }
                    
                    break
                }
            }
        } else if let stationaryItemIndex = stationaryItemIndex {
            for itemNode in self.itemNodes {
                if let index = itemNode.index , index == stationaryItemIndex {
                    for (previousNode, previousFrame) in previousApparentFrames {
                        if previousNode === itemNode {
                            let offset = previousFrame.minY - itemNode.frame.minY
                            
                            if abs(offset) > CGFloat.ulpOfOne {
                                for itemNode in self.itemNodes {
                                    var frame = itemNode.frame
                                    frame.origin.y += offset
                                    itemNode.frame = frame
                                    if let accessoryItemNode = itemNode.accessoryItemNode {
                                        itemNode.layoutAccessoryItemNode(accessoryItemNode, leftInset: listInsets.left, rightInset: listInsets.right)
                                    }
                                }
                            }
                            
                            break
                        }
                    }
                    break
                }
            }
        } else if !additionalScrollDistance.isZero {
            self.stopScrolling()
        }
        
        self.debugCheckMonotonity()
        
        var sizeAndInsetsOffset: CGFloat = 0.0
        
        var headerNodesTransition: (ContainedViewLayoutTransition, Bool, CGFloat) = (.immediate, false, 0.0)
        
        var deferredUpdateVisible = false
        var insetTransitionOffset: CGFloat = 0.0
        
        if let updateSizeAndInsets = updateSizeAndInsets {
            if self.insets != updateSizeAndInsets.insets || self.headerInsets != updateSizeAndInsets.headerInsets || !self.visibleSize.height.isEqual(to: updateSizeAndInsets.size.height) {
                let previousVisibleSize = self.visibleSize
                self.visibleSize = updateSizeAndInsets.size
                
                var offsetFix: CGFloat
                if self.isTracking || isExperimentalSnapToScrollToItem {
                    offsetFix = 0.0
                } else if self.snapToBottomInsetUntilFirstInteraction {
                    offsetFix = -updateSizeAndInsets.insets.bottom + self.insets.bottom
                } else {
                    offsetFix = updateSizeAndInsets.insets.top - self.insets.top
                }
                
                offsetFix += additionalScrollDistance
                
                self.insets = updateSizeAndInsets.insets
                self.headerInsets = updateSizeAndInsets.headerInsets ?? self.insets
                self.scrollIndicatorInsets = updateSizeAndInsets.scrollIndicatorInsets ?? self.insets
                self.ensureTopInsetForOverlayHighlightedItems = updateSizeAndInsets.ensureTopInsetForOverlayHighlightedItems
                self.visibleSize = updateSizeAndInsets.size
                
                for itemNode in self.itemNodes {
                    let position = itemNode.position
                    itemNode.position = CGPoint(x: position.x, y: position.y + offsetFix)
                }
                
                let (snappedTopInset, snapToBoundsOffset) = self.snapToBounds(snapTopItem: scrollToItem != nil, stackFromBottom: self.stackFromBottom, updateSizeAndInsets: updateSizeAndInsets)
                
                if !snappedTopInset.isZero && (previousVisibleSize.height.isZero || previousApparentFrames.isEmpty) {
                    offsetFix += snappedTopInset
                    
                    for itemNode in self.itemNodes {
                        let position = itemNode.position
                        itemNode.position = CGPoint(x: position.x, y: position.y + snappedTopInset)
                    }
                }
                
                var completeOffset = offsetFix
                
                if !snapToBoundsOffset.isZero {
                    self.updateVisibleContentOffset()
                }
                
                sizeAndInsetsOffset = offsetFix
                completeOffset += snapToBoundsOffset
                
                if !updateSizeAndInsets.duration.isZero {
                    let animation: CABasicAnimation
                    switch updateSizeAndInsets.curve {
                        case let .Spring(duration):
                            headerNodesTransition = (.animated(duration: duration, curve: .spring), false, -completeOffset)
                            let springAnimation = makeSpringAnimation("sublayerTransform")
                            springAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -completeOffset, 0.0))
                            springAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                            springAnimation.isRemovedOnCompletion = true
                            
                            let k = Float(UIView.animationDurationFactor())
                            var speed: Float = 1.0
                            if k != 0 && k != 1 {
                                speed = Float(1.0) / k
                            }
                            if !duration.isZero {
                                springAnimation.speed = speed * Float(springAnimation.duration / duration)
                            }
                            
                            springAnimation.isAdditive = true
                            animation = springAnimation
                        case let .Default(duration):
                            headerNodesTransition = (.animated(duration: max(duration ?? 0.3, updateSizeAndInsets.duration), curve: .easeInOut), false, -completeOffset)
                            let basicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                            basicAnimation.timingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseInEaseOut)
                            basicAnimation.duration = updateSizeAndInsets.duration * UIView.animationDurationFactor()
                            basicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -completeOffset, 0.0))
                            basicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                            basicAnimation.isRemovedOnCompletion = true
                            basicAnimation.isAdditive = true
                            animation = basicAnimation
                    }
                    
                    deferredUpdateVisible = true
                    animation.completion = { [weak self] _ in
                        self?.updateItemNodesVisibilities(onlyPositive: false)
                    }
                    self.layer.add(animation, forKey: nil)
                }
            } else {
                self.visibleSize = updateSizeAndInsets.size
                
                if !self.snapToBounds(snapTopItem: scrollToItem != nil, stackFromBottom: self.stackFromBottom).offset.isZero {
                    self.updateVisibleContentOffset()
                }
            }
            
            if let updatedTopItemVerticalOrigin = self.topItemVerticalOrigin(), let previousTopItemVerticalOrigin = previousTopItemVerticalOrigin, animateTopItemVerticalOrigin, !updatedTopItemVerticalOrigin.isEqual(to: previousTopItemVerticalOrigin) {
                self.stopScrolling()
                
                let completeOffset = updatedTopItemVerticalOrigin - previousTopItemVerticalOrigin
                let duration: Double = 0.4
                
                if let snapshotView = snapshotView {
                    snapshotView.frame = CGRect(origin: CGPoint(x: 0.0, y: completeOffset), size: snapshotView.frame.size)
                    self.view.addSubview(snapshotView)
                    snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.12, removeOnCompletion: false, completion: { [weak snapshotView] _ in
                        snapshotView?.removeFromSuperview()
                    })
                }
                
                let springAnimation = makeSpringAnimation("sublayerTransform")
                springAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -completeOffset, 0.0))
                springAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                springAnimation.isRemovedOnCompletion = true
                
                let k = Float(UIView.animationDurationFactor())
                var speed: Float = 1.0
                if k != 0 && k != 1 {
                    speed = Float(1.0) / k
                }
                springAnimation.speed = speed * Float(springAnimation.duration / duration)
                
                springAnimation.isAdditive = true
                self.layer.add(springAnimation, forKey: nil)
            } else {
                if let snapshotView = snapshotView {
                    snapshotView.frame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: snapshotView.frame.size)
                    self.view.addSubview(snapshotView)
                    snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.12, removeOnCompletion: false, completion: { [weak snapshotView] _ in
                        snapshotView?.removeFromSuperview()
                    })
                }
            }
            
            let wasIgnoringScrollingEvents = self.ignoreScrollingEvents
            self.ignoreScrollingEvents = true
            self.scroller.frame = CGRect(origin: CGPoint(), size: self.visibleSize)
            self.scroller.contentSize = CGSize(width: self.visibleSize.width, height: infiniteScrollSize * 2.0)
            self.lastContentOffset = CGPoint(x: 0.0, y: infiniteScrollSize)
            self.scroller.contentOffset = self.lastContentOffset
            self.ignoreScrollingEvents = wasIgnoringScrollingEvents
        } else {
            let (snappedTopInset, snapToBoundsOffset) = self.snapToBounds(snapTopItem: scrollToItem != nil, stackFromBottom: self.stackFromBottom, updateSizeAndInsets: updateSizeAndInsets, scrollToItem: scrollToItem)
            
            if !snappedTopInset.isZero && previousApparentFrames.isEmpty {
                let offsetFix = snappedTopInset
                
                for itemNode in self.itemNodes {
                    let position = itemNode.position
                    itemNode.position = CGPoint(x: position.x, y: position.y + snappedTopInset)
                }
            }
            
            if !snapToBoundsOffset.isZero {
                self.updateVisibleContentOffset()
            }
            
            if let snapshotView = snapshotView {
                snapshotView.frame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: snapshotView.frame.size)
                self.view.addSubview(snapshotView)
                snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.12, removeOnCompletion: false, completion: { [weak snapshotView] _ in
                    snapshotView?.removeFromSuperview()
                })
            }
        }
        
        var accessoryNodesTransition: ContainedViewLayoutTransition = .immediate
        if let scrollToItem = scrollToItem, scrollToItem.animated {
            accessoryNodesTransition = .animated(duration: 0.3, curve: .easeInOut)
        }
        
        self.updateAccessoryNodes(transition: accessoryNodesTransition, currentTimestamp: timestamp, leftInset: listInsets.left, rightInset: listInsets.right)
        
        if let highlightedItemNode = highlightedItemNode {
            if highlightedItemNode.index != self.highlightedItemIndex {
                highlightedItemNode.setHighlighted(false, at: CGPoint(), animated: false)
                self.highlightedItemIndex = nil
            }
        } else if self.highlightedItemIndex != nil {
            self.highlightedItemIndex = nil
        }
        
        if let scrollToItem = scrollToItem, scrollToItem.animated {
            if self.itemNodes.count != 0 {
                var offset: CGFloat?
                
                var temporaryPreviousNodes: [ListViewItemNode] = []
                var previousUpperBound: CGFloat?
                var previousLowerBound: CGFloat?
                if case .visible = scrollToItem.position {
                    for (previousNode, previousFrame) in previousApparentFrames {
                        if previousNode.supernode == nil {
                            temporaryPreviousNodes.append(previousNode)
                            previousNode.frame = previousFrame
                            if previousUpperBound == nil || previousUpperBound! > previousFrame.minY {
                                previousUpperBound = previousFrame.minY
                            }
                            if previousLowerBound == nil || previousLowerBound! < previousFrame.maxY {
                                previousLowerBound = previousFrame.maxY
                            }
                        } else {
                            if previousNode.canBeUsedAsScrollToItemAnchor {
                                offset = previousNode.apparentFrame.minY - previousFrame.minY
                                break
                            }
                        }
                    }
                } else {
                    for (previousNode, previousFrame) in previousApparentFrames {
                        if previousNode.supernode == nil {
                            temporaryPreviousNodes.append(previousNode)
                            previousNode.frame = previousFrame
                            if previousUpperBound == nil || previousUpperBound! > previousFrame.minY {
                                previousUpperBound = previousFrame.minY
                            }
                            if previousLowerBound == nil || previousLowerBound! < previousFrame.maxY {
                                previousLowerBound = previousFrame.maxY
                            }
                        } else {
                            if previousNode.canBeUsedAsScrollToItemAnchor {
                                offset = previousNode.apparentFrame.minY - previousFrame.minY
                            }
                        }
                    }
                
                    if offset == nil {
                        let updatedUpperBound = self.itemNodes[0].apparentFrame.minY
                        let updatedLowerBound = max(self.itemNodes[self.itemNodes.count - 1].apparentFrame.maxY, self.visibleSize.height)
                        
                        switch scrollToItem.directionHint {
                            case .Up:
                                offset = updatedLowerBound - (previousUpperBound ?? 0.0)
                            case .Down:
                                offset = updatedUpperBound - (previousLowerBound ?? self.visibleSize.height)
                        }
                    }
                }
                
                if let offsetValue = offset {
                    offset = offsetValue - sizeAndInsetsOffset
                }
                
                var previousItemHeaderNodes: [ListViewItemHeaderNode] = []
                let offsetOrZero: CGFloat = offset ?? 0.0
                switch scrollToItem.curve {
                    case let .Spring(duration):
                        headerNodesTransition = (.animated(duration: duration, curve: .spring), headerNodesTransition.1, headerNodesTransition.2 - offsetOrZero)
                    case let .Default(duration):
                        headerNodesTransition = (.animated(duration: duration ?? 0.3, curve: .easeInOut), true, headerNodesTransition.2 - offsetOrZero)
                }
                for (_, headerNode) in self.itemHeaderNodes {
                    previousItemHeaderNodes.append(headerNode)
                }
                
                self.updateItemHeaders(leftInset: listInsets.left, rightInset: listInsets.right, transition: headerNodesTransition, animateInsertion: animated || !requestItemInsertionAnimationsIndices.isEmpty)
                
                if let offset = offset, !offset.isZero {
                    let lowestNodeToInsertBelow = self.lowestNodeToInsertBelow()
                    for itemNode in temporaryPreviousNodes {
                        itemNode.frame = itemNode.frame.offsetBy(dx: 0.0, dy: offset)
                        if let lowestNodeToInsertBelow = lowestNodeToInsertBelow {
                            self.insertSubnode(itemNode, belowSubnode: lowestNodeToInsertBelow)
                        } else if let verticalScrollIndicator = self.verticalScrollIndicator {
                            self.insertSubnode(itemNode, belowSubnode: verticalScrollIndicator)
                        } else {
                            self.addSubnode(itemNode)
                        }
                    }
                    
                    var temporaryHeaderNodes: [ListViewItemHeaderNode] = []
                    for headerNode in previousItemHeaderNodes {
                        if headerNode.supernode == nil {
                            headerNode.frame = headerNode.frame.offsetBy(dx: 0.0, dy: offset)
                            temporaryHeaderNodes.append(headerNode)
                            if let verticalScrollIndicator = self.verticalScrollIndicator {
                                self.insertSubnode(headerNode, belowSubnode: verticalScrollIndicator)
                            } else {
                                self.addSubnode(headerNode)
                            }
                        }
                    }
                    
                    let animation: CABasicAnimation
                    let reverseAnimation: CABasicAnimation
                    switch scrollToItem.curve {
                        case let .Spring(duration):
                            let springAnimation = makeSpringAnimation("sublayerTransform")
                            springAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -offset, 0.0))
                            springAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                            springAnimation.isRemovedOnCompletion = true
                            springAnimation.isAdditive = true
                            springAnimation.fillMode = kCAFillModeForwards
                            
                            let k = Float(UIView.animationDurationFactor())
                            var speed: Float = 1.0
                            if k != 0 && k != 1 {
                                speed = Float(1.0) / k
                            }
                            if !duration.isZero {
                                springAnimation.speed = speed * Float(springAnimation.duration / duration)
                            }
                            
                            let reverseSpringAnimation = makeSpringAnimation("sublayerTransform")
                            reverseSpringAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, offset, 0.0))
                            reverseSpringAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                            reverseSpringAnimation.isRemovedOnCompletion = true
                            reverseSpringAnimation.isAdditive = true
                            reverseSpringAnimation.fillMode = kCAFillModeForwards
                            
                            reverseSpringAnimation.speed = speed * Float(reverseSpringAnimation.duration / duration)
                            
                            animation = springAnimation
                            reverseAnimation = reverseSpringAnimation
                        case let .Default(duration):
                            if let duration = duration {
                                let basicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                                basicAnimation.timingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseInEaseOut)
                                basicAnimation.duration = duration * UIView.animationDurationFactor()
                                basicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -offset, 0.0))
                                basicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                                basicAnimation.isRemovedOnCompletion = true
                                basicAnimation.isAdditive = true
                                
                                let reverseBasicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                                reverseBasicAnimation.timingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseInEaseOut)
                                reverseBasicAnimation.duration = duration * UIView.animationDurationFactor()
                                reverseBasicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, offset, 0.0))
                                reverseBasicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                                reverseBasicAnimation.isRemovedOnCompletion = true
                                reverseBasicAnimation.isAdditive = true
                                
                                animation = basicAnimation
                                reverseAnimation = reverseBasicAnimation
                            } else {
                                let basicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                                basicAnimation.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 0.52, 0.25, 0.99)
                                basicAnimation.duration = (duration ?? 0.3) * UIView.animationDurationFactor()
                                basicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, -offset, 0.0))
                                basicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                                basicAnimation.isRemovedOnCompletion = true
                                basicAnimation.isAdditive = true
                                
                                let reverseBasicAnimation = CABasicAnimation(keyPath: "sublayerTransform")
                                reverseBasicAnimation.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 0.52, 0.25, 0.99)
                                reverseBasicAnimation.duration = (duration ?? 0.3) * UIView.animationDurationFactor()
                                reverseBasicAnimation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0.0, offset, 0.0))
                                reverseBasicAnimation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                                reverseBasicAnimation.isRemovedOnCompletion = true
                                reverseBasicAnimation.isAdditive = true
                                
                                animation = basicAnimation
                                reverseAnimation = reverseBasicAnimation
                            }
                    }
                    animation.completion = { _ in
                        for itemNode in temporaryPreviousNodes {
                            itemNode.removeFromSupernode()
                            if useBackgroundDeallocation {
                                assertionFailure()
                                //ASDeallocQueue.sharedDeallocation().releaseObject(inBackground: itemNode)
                            } else {
                                //ASPerformMainThreadDeallocation(itemNode)
                            }
                        }
                        for headerNode in temporaryHeaderNodes {
                            headerNode.removeFromSupernode()
                            if useBackgroundDeallocation {
                                assertionFailure()
                                //ASDeallocQueue.sharedDeallocation().releaseObject(inBackground: headerNode)
                            } else {
                                //ASPerformMainThreadDeallocation(headerNode)
                            }
                        }
                    }
                    self.layer.add(animation, forKey: nil)
                    if let verticalScrollIndicator = self.verticalScrollIndicator {
                        verticalScrollIndicator.layer.add(reverseAnimation, forKey: nil)
                    }
                } else {
                    if useBackgroundDeallocation {
                        assertionFailure()
                        /*for itemNode in temporaryPreviousNodes {
                            ASDeallocQueue.sharedDeallocation().releaseObject(inBackground: itemNode)
                        }*/
                    } else {
                        for itemNode in temporaryPreviousNodes {
                            //ASPerformMainThreadDeallocation(itemNode)
                        }
                    }
                }
            }
            
            self.updateItemNodesVisibilities(onlyPositive: deferredUpdateVisible)
            
            self.updateScroller(transition: headerNodesTransition.0)
            
            if let topItemOverscrollBackground = self.topItemOverscrollBackground {
                headerNodesTransition.0.animatePositionAdditive(node: topItemOverscrollBackground, offset: CGPoint(x: 0.0, y: -headerNodesTransition.2))
            }
            
            self.setNeedsAnimations()
            
            self.updateVisibleContentOffset()
            
            if self.debugInfo {
                //let delta = CACurrentMediaTime() - timestamp
                //print("replayOperations \(delta * 1000.0) ms")
            }
            
            completion()
        } else {
            self.updateItemHeaders(leftInset: listInsets.left, rightInset: listInsets.right, transition: headerNodesTransition, animateInsertion: animated || !requestItemInsertionAnimationsIndices.isEmpty)
            self.updateItemNodesVisibilities(onlyPositive: deferredUpdateVisible)
            
            if animated {
                self.setNeedsAnimations()
            }
            
            self.updateScroller(transition: headerNodesTransition.0)
            
            if let topItemOverscrollBackground = self.topItemOverscrollBackground {
                headerNodesTransition.0.animatePositionAdditive(node: topItemOverscrollBackground, offset: CGPoint(x: 0.0, y: -headerNodesTransition.2))
            }
            
            self.updateVisibleContentOffset()
            
            if self.debugInfo {
                //let delta = CACurrentMediaTime() - timestamp
                //print("replayOperations \(delta * 1000.0) ms")
            }
            
            for (previousNode, _) in previousApparentFrames {
                if previousNode.supernode == nil {
                    if useBackgroundDeallocation {
                        assertionFailure()
                        //ASDeallocQueue.sharedDeallocatio.releaseObject(inBackground: previousNode)
                    } else {
                        //ASPerformMainThreadDeallocation(previousNode)
                    }
                }
            }
            
            completion()
        }
    }
    
    private func debugCheckMonotonity() {
        if self.debugInfo {
            var previousMaxY: CGFloat?
            for node in self.itemNodes {
                if let previousMaxY = previousMaxY , abs(previousMaxY - node.apparentFrame.minY) > CGFloat.ulpOfOne {
                    print("monotonity violated")
                    break
                }
                previousMaxY = node.apparentFrame.maxY
            }
        }
    }
    
    private func removeItemNodeAtIndex(_ index: Int) {
        let node = self.itemNodes[index]
        self.itemNodes.remove(at: index)
        node.removeFromSupernode()
        
        node.accessoryItemNode?.removeFromSupernode()
        node.setAccessoryItemNode(nil, leftInset: self.insets.left, rightInset: self.insets.right)
        node.headerAccessoryItemNode?.removeFromSupernode()
        node.headerAccessoryItemNode = nil
    }
    
    private func updateItemHeaders(leftInset: CGFloat, rightInset: CGFloat, transition: (ContainedViewLayoutTransition, Bool, CGFloat) = (.immediate, false, 0.0), animateInsertion: Bool = false) {
        let upperDisplayBound = self.headerInsets.top
        let lowerDisplayBound = self.visibleSize.height - self.insets.bottom
        var visibleHeaderNodes = Set<Int64>()
        
        let flashing = self.headerItemsAreFlashing()
        
        let addHeader: (_ id: Int64, _ upperBound: CGFloat, _ lowerBound: CGFloat, _ item: ListViewItemHeader, _ hasValidNodes: Bool) -> Void = { id, upperBound, lowerBound, item, hasValidNodes in
            let itemHeaderHeight: CGFloat = item.height
            
            let headerFrame: CGRect
            let stickLocationDistanceFactor: CGFloat
            let stickLocationDistance: CGFloat
            switch item.stickDirection {
                case .top:
                    headerFrame = CGRect(origin: CGPoint(x: 0.0, y: min(max(upperDisplayBound, upperBound), lowerBound - itemHeaderHeight)), size: CGSize(width: self.visibleSize.width, height: itemHeaderHeight))
                    stickLocationDistance = 0.0
                    stickLocationDistanceFactor = 0.0
                case .bottom:
                    headerFrame = CGRect(origin: CGPoint(x: 0.0, y: max(upperBound, min(lowerBound, lowerDisplayBound) - itemHeaderHeight)), size: CGSize(width: self.visibleSize.width, height: itemHeaderHeight))
                    stickLocationDistance = lowerBound - headerFrame.maxY
                    stickLocationDistanceFactor = max(0.0, min(1.0, stickLocationDistance / itemHeaderHeight))
            }
            visibleHeaderNodes.insert(id)
            if let headerNode = self.itemHeaderNodes[id] {
                switch transition.0 {
                    case .immediate:
                        headerNode.frame = headerFrame
                    case let .animated(duration, curve):
                        let previousFrame = headerNode.frame
                        headerNode.frame = headerFrame
                        var offset = headerFrame.minY - previousFrame.minY + transition.2
                        if headerNode.isRotated {
                            offset = -offset
                        }
                        switch curve {
                            case .spring:
                                transition.0.animateOffsetAdditive(node: headerNode, offset: offset)
                            case let .custom(p1, p2, p3, p4):
                                headerNode.layer.animateBoundsOriginYAdditive(from: offset, to: 0.0, duration: duration, mediaTimingFunction: CAMediaTimingFunction(controlPoints: p1, p2, p3, p4))
                            case .easeInOut:
                                if transition.1 {
                                    headerNode.layer.animateBoundsOriginYAdditive(from: offset, to: 0.0, duration: duration, mediaTimingFunction: CAMediaTimingFunction(controlPoints: 0.33, 0.52, 0.25, 0.99))
                                } else {
                                    headerNode.layer.animateBoundsOriginYAdditive(from: offset, to: 0.0, duration: duration, mediaTimingFunction: CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseInEaseOut))
                                }
                        }
                }
                
                headerNode.updateLayoutInternal(size: headerFrame.size, leftInset: leftInset, rightInset: rightInset)
                headerNode.updateInternalStickLocationDistanceFactor(stickLocationDistanceFactor, animated: true)
                headerNode.internalStickLocationDistance = stickLocationDistance
                if !hasValidNodes && !headerNode.alpha.isZero {
                    if animateInsertion {
                        headerNode.animateRemoved(duration: 0.2)
                    }
                } else if hasValidNodes && headerNode.alpha.isZero {
                    headerNode.alpha = 1.0
                    if animateInsertion {
                        headerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                        headerNode.layer.animateScale(from: 0.2, to: 1.0, duration: 0.2)
                    }
                }
                headerNode.updateStickDistanceFactor(stickLocationDistanceFactor, transition: transition.0)
            } else {
                let headerNode = item.node()
                headerNode.updateFlashingOnScrolling(flashing, animated: false)
                headerNode.frame = headerFrame
                headerNode.updateLayoutInternal(size: headerFrame.size, leftInset: leftInset, rightInset: rightInset)
                headerNode.updateInternalStickLocationDistanceFactor(stickLocationDistanceFactor, animated: false)
                self.itemHeaderNodes[id] = headerNode
                if let verticalScrollIndicator = self.verticalScrollIndicator {
                    self.insertSubnode(headerNode, belowSubnode: verticalScrollIndicator)
                } else {
                    self.addSubnode(headerNode)
                }
                if animateInsertion {
                    headerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
                    headerNode.layer.animateScale(from: 0.2, to: 1.0, duration: 0.3)
                }
                headerNode.updateStickDistanceFactor(stickLocationDistanceFactor, transition: .immediate)
            }
        }
        
        var previousHeader: (Int64, CGFloat, CGFloat, ListViewItemHeader, Bool)?
        for itemNode in self.itemNodes {
            let itemFrame = itemNode.apparentFrame
            if let itemHeader = itemNode.header() {
                if let (previousHeaderId, previousUpperBound, previousLowerBound, previousHeaderItem, hasValidNodes) = previousHeader {
                    if previousHeaderId == itemHeader.id {
                        previousHeader = (previousHeaderId, previousUpperBound, itemFrame.maxY, previousHeaderItem, hasValidNodes || itemNode.index != nil)
                    } else {
                        addHeader(previousHeaderId, previousUpperBound, previousLowerBound, previousHeaderItem, hasValidNodes)
                        
                        previousHeader = (itemHeader.id, itemFrame.minY, itemFrame.maxY, itemHeader, itemNode.index != nil)
                    }
                } else {
                    previousHeader = (itemHeader.id, itemFrame.minY, itemFrame.maxY, itemHeader, itemNode.index != nil)
                }
            } else {
                if let (previousHeaderId, previousUpperBound, previousLowerBound, previousHeaderItem, hasValidNodes) = previousHeader {
                    addHeader(previousHeaderId, previousUpperBound, previousLowerBound, previousHeaderItem, hasValidNodes)
                }
                previousHeader = nil
            }
        }
        
        if let (previousHeaderId, previousUpperBound, previousLowerBound, previousHeaderItem, hasValidNodes) = previousHeader {
            addHeader(previousHeaderId, previousUpperBound, previousLowerBound, previousHeaderItem, hasValidNodes)
        }
        
        let currentIds = Set(self.itemHeaderNodes.keys)
        for id in currentIds.subtracting(visibleHeaderNodes) {
            if let headerNode = self.itemHeaderNodes.removeValue(forKey: id) {
                headerNode.removeFromSupernode()
            }
        }
    }
    
    private func updateItemNodesVisibilities(onlyPositive: Bool) {
        let visibilityRect = CGRect(origin: CGPoint(x: 0.0, y: self.insets.top), size: CGSize(width: self.visibleSize.width, height: self.visibleSize.height - self.insets.top - self.insets.bottom))
        for itemNode in self.itemNodes {
            let itemFrame = itemNode.apparentFrame
            var visibility: ListViewItemNodeVisibility = .none
            if visibilityRect.intersects(itemFrame) {
                let itemContentFrame = itemNode.apparentContentFrame
                let intersection = itemContentFrame.intersection(visibilityRect)
                let fraction = intersection.height / itemContentFrame.height
                visibility = .visible(fraction)
            }
            var updateVisibility = false
            if !onlyPositive {
                updateVisibility = true
            }
            if case .visible = visibility {
                updateVisibility = true
            }
            if updateVisibility {
                if visibility != itemNode.visibility {
                    itemNode.visibility = visibility
                }
            }
        }
    }
    
    private func updateAccessoryNodes(transition: ContainedViewLayoutTransition, currentTimestamp: Double, leftInset: CGFloat, rightInset: CGFloat) {
        var totalVisibleHeight: CGFloat = 0.0
        var index = -1
        let count = self.itemNodes.count
        for itemNode in self.itemNodes {
            index += 1
            totalVisibleHeight += itemNode.apparentHeight
            
            guard let itemNodeIndex = itemNode.index else {
                continue
            }
            
            if let accessoryItem = self.items[itemNodeIndex].accessoryItem {
                let previousItem: ListViewItem? = itemNodeIndex == 0 ? nil : self.items[itemNodeIndex - 1]
                let previousAccessoryItem = previousItem?.accessoryItem
                
                if (previousAccessoryItem == nil || !previousAccessoryItem!.isEqualToItem(accessoryItem)) {
                    if itemNode.accessoryItemNode == nil {
                        var didStealAccessoryNode = false
                        if index != count - 1 {
                            for i in index + 1 ..< count {
                                let nextItemNode = self.itemNodes[i]
                                if let nextItemNodeIndex = nextItemNode.index {
                                    let nextItem = self.items[nextItemNodeIndex]
                                    if let nextAccessoryItem = nextItem.accessoryItem , nextAccessoryItem.isEqualToItem(accessoryItem) {
                                        if let nextAccessoryItemNode = nextItemNode.accessoryItemNode {
                                            didStealAccessoryNode = true
                                            
                                            var previousAccessoryItemNodeOrigin = nextAccessoryItemNode.frame.origin
                                            let previousParentOrigin = nextItemNode.frame.origin
                                            previousAccessoryItemNodeOrigin.x += previousParentOrigin.x
                                            previousAccessoryItemNodeOrigin.y += previousParentOrigin.y
                                            previousAccessoryItemNodeOrigin.y -= nextItemNode.bounds.origin.y
                                            previousAccessoryItemNodeOrigin.y -= nextAccessoryItemNode.transitionOffset.y
                                            nextAccessoryItemNode.transitionOffset = CGPoint()
                                            
                                            nextAccessoryItemNode.removeFromSupernode()
                                            itemNode.addSubnode(nextAccessoryItemNode)
                                            
                                            itemNode.setAccessoryItemNode(nextAccessoryItemNode, leftInset: leftInset, rightInset: rightInset)
                                            self.itemNodes[i].setAccessoryItemNode(nil, leftInset: leftInset, rightInset: rightInset)
                                            
                                            var updatedAccessoryItemNodeOrigin = nextAccessoryItemNode.frame.origin
                                            let updatedParentOrigin = itemNode.apparentFrame.origin
                                            updatedAccessoryItemNodeOrigin.x += updatedParentOrigin.x
                                            updatedAccessoryItemNodeOrigin.y += updatedParentOrigin.y
                                            updatedAccessoryItemNodeOrigin.y -= itemNode.bounds.origin.y
                                            //updatedAccessoryItemNodeOrigin.y += itemNode.transitionOffset
                                            
                                            var deltaHeight = itemNode.frame.size.height - nextItemNode.frame.size.height
                                            //deltaHeight = 0.0
                                            nextAccessoryItemNode.animateTransitionOffset(CGPoint(x: 0.0, y: updatedAccessoryItemNodeOrigin.y - previousAccessoryItemNodeOrigin.y - deltaHeight), beginAt: currentTimestamp, duration: insertionAnimationDuration * UIView.animationDurationFactor(), curve: listViewAnimationCurveSystem)
                                            
                                        }
                                    } else {
                                        break
                                    }
                                }
                            }
                        }
                        
                        if !didStealAccessoryNode {
                            let accessoryNode = accessoryItem.node()
                            itemNode.addSubnode(accessoryNode)
                            itemNode.setAccessoryItemNode(accessoryNode, leftInset: leftInset, rightInset: rightInset)
                        }
                    }
                } else {
                    itemNode.accessoryItemNode?.removeFromSupernode()
                    itemNode.setAccessoryItemNode(nil, leftInset: leftInset, rightInset: rightInset)
                }
            }
            
            if let headerAccessoryItem = self.items[itemNodeIndex].headerAccessoryItem {
                let previousItem: ListViewItem? = itemNodeIndex == 0 ? nil : self.items[itemNodeIndex - 1]
                let previousHeaderAccessoryItem = previousItem?.headerAccessoryItem
                
                if (previousHeaderAccessoryItem == nil || !previousHeaderAccessoryItem!.isEqualToItem(headerAccessoryItem)) {
                    if itemNode.headerAccessoryItemNode == nil {
                        var didStealHeaderAccessoryNode = false
                        if index != count - 1 {
                            for i in index + 1 ..< count {
                                let nextItemNode = self.itemNodes[i]
                                if let nextItemNodeIndex = nextItemNode.index {
                                    let nextItem = self.items[nextItemNodeIndex]
                                    if let nextHeaderAccessoryItem = nextItem.headerAccessoryItem , nextHeaderAccessoryItem.isEqualToItem(headerAccessoryItem) {
                                        if let nextHeaderAccessoryItemNode = nextItemNode.headerAccessoryItemNode {
                                            didStealHeaderAccessoryNode = true
                                            
                                            var previousHeaderAccessoryItemNodeOrigin = nextHeaderAccessoryItemNode.frame.origin
                                            let previousParentOrigin = nextItemNode.frame.origin
                                            previousHeaderAccessoryItemNodeOrigin.x += previousParentOrigin.x
                                            previousHeaderAccessoryItemNodeOrigin.y += previousParentOrigin.y
                                            previousHeaderAccessoryItemNodeOrigin.y -= nextItemNode.bounds.origin.y
                                            previousHeaderAccessoryItemNodeOrigin.y -= nextHeaderAccessoryItemNode.transitionOffset.y
                                            nextHeaderAccessoryItemNode.transitionOffset = CGPoint()
                                            
                                            nextHeaderAccessoryItemNode.removeFromSupernode()
                                            itemNode.addSubnode(nextHeaderAccessoryItemNode)
                                            itemNode.headerAccessoryItemNode = nextHeaderAccessoryItemNode
                                            self.itemNodes[i].headerAccessoryItemNode = nil
                                            
                                            var updatedHeaderAccessoryItemNodeOrigin = nextHeaderAccessoryItemNode.frame.origin
                                            let updatedParentOrigin = itemNode.frame.origin
                                            updatedHeaderAccessoryItemNodeOrigin.x += updatedParentOrigin.x
                                            updatedHeaderAccessoryItemNodeOrigin.y += updatedParentOrigin.y
                                            updatedHeaderAccessoryItemNodeOrigin.y -= itemNode.bounds.origin.y
                                            
                                            let deltaHeight = itemNode.frame.size.height - nextItemNode.frame.size.height
                                            
                                            nextHeaderAccessoryItemNode.animateTransitionOffset(CGPoint(x: 0.0, y: updatedHeaderAccessoryItemNodeOrigin.y - previousHeaderAccessoryItemNodeOrigin.y - deltaHeight), beginAt: currentTimestamp, duration: insertionAnimationDuration * UIView.animationDurationFactor(), curve: listViewAnimationCurveSystem)
                                        }
                                    } else {
                                        break
                                    }
                                }
                            }
                        }
                        
                        if !didStealHeaderAccessoryNode {
                            let headerAccessoryNode = headerAccessoryItem.node()
                            itemNode.addSubnode(headerAccessoryNode)
                            itemNode.headerAccessoryItemNode = headerAccessoryNode
                        }
                    }
                } else {
                    itemNode.headerAccessoryItemNode?.removeFromSupernode()
                    itemNode.headerAccessoryItemNode = nil
                }
            }
        }
        
        if let verticalScrollIndicator = self.verticalScrollIndicator {
            var topIndexAndBoundary: (Int, CGFloat, CGFloat)?
            var bottomIndexAndBoundary: (Int, CGFloat, CGFloat)?
            for itemNode in self.itemNodes {
                if itemNode.apparentFrame.maxY >= self.insets.top, let index = itemNode.index {
                    topIndexAndBoundary = (index, itemNode.apparentFrame.minY, itemNode.apparentFrame.height)
                    break
                }
            }
            for itemNode in self.itemNodes.reversed() {
                if itemNode.apparentFrame.minY <= self.visibleSize.height - self.insets.bottom, let index = itemNode.index {
                    bottomIndexAndBoundary = (index, itemNode.apparentFrame.maxY, itemNode.apparentFrame.height)
                    break
                }
            }
            if let topIndexAndBoundary = topIndexAndBoundary, let bottomIndexAndBoundary = bottomIndexAndBoundary {
                let averageRangeItemHeight: CGFloat = 44.0
                
                var upperItemsHeight = floor(averageRangeItemHeight * CGFloat(topIndexAndBoundary.0))
                var approximateContentHeight = CGFloat(self.items.count) * averageRangeItemHeight
                if topIndexAndBoundary.0 >= 0 && self.items[topIndexAndBoundary.0].approximateHeight.isZero {
                    upperItemsHeight -= averageRangeItemHeight
                    approximateContentHeight -= averageRangeItemHeight
                }
                
                var convertedTopBoundary: CGFloat
                if topIndexAndBoundary.1 < self.insets.top {
                    convertedTopBoundary = (topIndexAndBoundary.1 - self.insets.top) * averageRangeItemHeight / topIndexAndBoundary.2
                } else {
                    convertedTopBoundary = topIndexAndBoundary.1 - self.insets.top
                }
                convertedTopBoundary -= upperItemsHeight
                
                let approximateOffset = -convertedTopBoundary
                
                var convertedBottomBoundary: CGFloat = 0.0
                if bottomIndexAndBoundary.1 > self.visibleSize.height - self.insets.bottom {
                    convertedBottomBoundary = ((self.visibleSize.height - self.insets.bottom) - bottomIndexAndBoundary.1) * averageRangeItemHeight / bottomIndexAndBoundary.2
                } else {
                    convertedBottomBoundary = (self.visibleSize.height - self.insets.bottom) - bottomIndexAndBoundary.1
                }
                convertedBottomBoundary += CGFloat(bottomIndexAndBoundary.0 + 1) * averageRangeItemHeight
                
                let approximateVisibleHeight = max(0.0, convertedBottomBoundary - approximateOffset)
                
                let approximateScrollingProgress = approximateOffset / (approximateContentHeight - approximateVisibleHeight)
                
                let indicatorSideInset: CGFloat = 3.0
                var indicatorTopInset: CGFloat = 3.0
                if self.verticalScrollIndicatorFollowsOverscroll {
                    if topIndexAndBoundary.0 == 0 {
                        indicatorTopInset = max(topIndexAndBoundary.1 + 3.0 - self.insets.top, 3.0)
                    }
                }
                let indicatorBottomInset: CGFloat = 3.0
                let minIndicatorContentHeight: CGFloat = 12.0
                let minIndicatorHeight: CGFloat = 6.0
                
                let visibleHeightWithoutIndicatorInsets = self.visibleSize.height - self.scrollIndicatorInsets.top - self.scrollIndicatorInsets.bottom - indicatorTopInset - indicatorBottomInset
                let indicatorHeight: CGFloat
                if approximateContentHeight <= 0 {
                    indicatorHeight = 0.0
                } else {
                    indicatorHeight = max(minIndicatorContentHeight, floor(visibleHeightWithoutIndicatorInsets * (self.visibleSize.height - self.insets.top - self.insets.bottom) / approximateContentHeight))
                }
                
                let upperBound = self.scrollIndicatorInsets.top + indicatorTopInset
                let lowerBound = self.visibleSize.height - self.scrollIndicatorInsets.bottom - indicatorTopInset - indicatorBottomInset - indicatorHeight
                
                let indicatorOffset = ceilToScreenPixels(upperBound * (1.0 - approximateScrollingProgress) + lowerBound * approximateScrollingProgress)
                
                var indicatorFrame = CGRect(origin: CGPoint(x: self.rotated ? indicatorSideInset : (self.visibleSize.width - 3.0 - indicatorSideInset), y: indicatorOffset), size: CGSize(width: 3.0, height: indicatorHeight))
                if indicatorFrame.minY < self.scrollIndicatorInsets.top + indicatorTopInset {
                    indicatorFrame.size.height -= self.scrollIndicatorInsets.top + indicatorTopInset - indicatorFrame.minY
                    indicatorFrame.origin.y = self.scrollIndicatorInsets.top + indicatorTopInset
                    indicatorFrame.size.height = max(minIndicatorHeight, indicatorFrame.height)
                }
                if indicatorFrame.maxY > self.visibleSize.height - (self.scrollIndicatorInsets.bottom + indicatorTopInset + indicatorBottomInset) {
                    indicatorFrame.size.height -= indicatorFrame.maxY - (self.visibleSize.height - (self.scrollIndicatorInsets.bottom + indicatorTopInset))
                    indicatorFrame.size.height = max(minIndicatorHeight, indicatorFrame.height)
                    indicatorFrame.origin.y = self.visibleSize.height - (self.scrollIndicatorInsets.bottom + indicatorBottomInset) - indicatorFrame.height
                }
                
                if indicatorHeight >= visibleHeightWithoutIndicatorInsets {
                    verticalScrollIndicator.isHidden = true
                    verticalScrollIndicator.frame = indicatorFrame
                } else {
                    if verticalScrollIndicator.isHidden {
                        verticalScrollIndicator.isHidden = false
                        verticalScrollIndicator.frame = indicatorFrame
                    } else {
                        verticalScrollIndicator.frame = indicatorFrame
                    }
                }
            } else {
                verticalScrollIndicator.isHidden = true
            }
        }
    }
    
    private func enqueueUpdateVisibleItems(synchronous: Bool) {
        if !self.enqueuedUpdateVisibleItems {
            self.enqueuedUpdateVisibleItems = true
            
            self.transactionQueue.addTransaction({ [weak self] completion in
                if let strongSelf = self {
                    strongSelf.transactionOffset = 0.0
                    strongSelf.updateVisibleItemsTransaction(synchronous: synchronous, completion: {
                        var repeatUpdate = false
                        if let strongSelf = self {
                            repeatUpdate = abs(strongSelf.transactionOffset) > 0.00001
                            strongSelf.transactionOffset = 0.0
                            strongSelf.enqueuedUpdateVisibleItems = false
                        }
                        
                        completion()
                    
                        if repeatUpdate {
                            strongSelf.enqueueUpdateVisibleItems(synchronous: false)
                        }
                    })
                }
            })
        }
    }
    
    private func updateVisibleItemsTransaction(synchronous: Bool, completion: @escaping () -> Void) {
        if self.items.count == 0 && self.itemNodes.count == 0 {
            completion()
            return
        }
        var i = 0
        while i < self.itemNodes.count {
            let node = self.itemNodes[i]
            if node.index == nil && node.apparentHeight <= CGFloat.ulpOfOne {
                self.removeItemNodeAtIndex(i)
                if useBackgroundDeallocation {
                    assertionFailure()
                    //ASDeallocQueue.sharedDeallocation().releaseObject(inBackground: node)
                } else {
                    //ASPerformMainThreadDeallocation(node)
                }
            } else {
                i += 1
            }
        }
        
        let state = self.currentState()
        
        let begin: () -> Void = {
            self.fillMissingNodes(synchronous: synchronous, synchronousLoads: false, animated: false, inputAnimatedInsertIndices: [], insertDirectionHints: [:], inputState: state, inputPreviousNodes: [:], inputOperations: []) { state, operations in
                var updatedState = state
                var updatedOperations = operations
                updatedState.removeInvisibleNodes(&updatedOperations)
                self.dispatchOnVSync {
                    self.replayOperations(animated: false, animateAlpha: false, animateCrossfade: false, animateTopItemVerticalOrigin: false, operations: updatedOperations, requestItemInsertionAnimationsIndices: Set(), scrollToItem: nil, additionalScrollDistance: 0.0, updateSizeAndInsets: nil, stationaryItemIndex: nil, updateOpaqueState: nil, completion: completion)
                }
            }
        }
        if synchronous {
            begin()
        } else {
            self.async {
                begin()
            }
        }
    }
    
    private func updateVisibleItemRange(force: Bool = false) {
        let currentRange = self.immediateDisplayedItemRange()
        
        if currentRange != self.displayedItemRange || force {
            self.displayedItemRange = currentRange
            self.displayedItemRangeChanged(currentRange, self.opaqueTransactionState)
        }
    }
    
    private func immediateDisplayedItemRange() -> ListViewDisplayedItemRange {
        var loadedRange: ListViewItemRange?
        var visibleRange: ListViewVisibleItemRange?
        if self.itemNodes.count != 0 {
            var firstIndex: (nodeIndex: Int, index: Int)?
            var lastIndex: (nodeIndex: Int, index: Int)?
            
            var i = 0
            while i < self.itemNodes.count {
                if let index = self.itemNodes[i].index {
                    firstIndex = (i, index)
                    break
                }
                i += 1
            }
            i = self.itemNodes.count - 1
            while i >= 0 {
                if let index = self.itemNodes[i].index {
                    lastIndex = (i, index)
                    break
                }
                i -= 1
            }
            if let firstIndex = firstIndex, let lastIndex = lastIndex {
                var firstVisibleIndex: (Int, Bool)?
                for i in firstIndex.nodeIndex ... lastIndex.nodeIndex {
                    if let index = self.itemNodes[i].index {
                        let frame = self.itemNodes[i].apparentFrame
                        if frame.maxY >= self.insets.top && frame.minY < self.visibleSize.height + self.insets.bottom {
                            firstVisibleIndex = (index, frame.minY >= self.insets.top - 10.0)
                            break
                        }
                    }
                }
                
                if let firstVisibleIndex = firstVisibleIndex {
                    var lastVisibleIndex: Int?
                    for i in (firstIndex.nodeIndex ... lastIndex.nodeIndex).reversed() {
                        if let index = self.itemNodes[i].index {
                            let frame = self.itemNodes[i].apparentFrame
                            if frame.maxY >= self.insets.top && frame.minY < self.visibleSize.height - self.insets.bottom {
                                lastVisibleIndex = index
                                break
                            }
                        }
                    }
                    
                    if let lastVisibleIndex = lastVisibleIndex {
                        visibleRange = ListViewVisibleItemRange(firstIndex: firstVisibleIndex.0, firstIndexFullyVisible: firstVisibleIndex.1, lastIndex: lastVisibleIndex)
                    }
                }
                
                loadedRange = ListViewItemRange(firstIndex: firstIndex.index, lastIndex: lastIndex.index)
            }
        }
        
        return ListViewDisplayedItemRange(loadedRange: loadedRange, visibleRange: visibleRange)
    }
    
    private func updateAnimations() {
        self.inVSync = true
        let actionsForVSync = self.actionsForVSync
        self.actionsForVSync.removeAll()
        for action in actionsForVSync {
            action()
        }
        self.inVSync = false
        
        let timestamp: Double = CACurrentMediaTime()
        
        var continueAnimations = false
        
        if !self.actionsForVSync.isEmpty {
            continueAnimations = true
        }
        
        var i = 0
        var animationCount = self.animations.count
        while i < animationCount {
            let animation = self.animations[i]
            animation.applyAt(timestamp)
            
            if animation.completeAt(timestamp) {
                animations.remove(at: i)
                animationCount -= 1
                i -= 1
            } else {
                continueAnimations = true
            }
            
            i += 1
        }
        
        var offsetRanges = OffsetRanges()
        
        if let reorderOffset = self.reorderNode?.currentOffset(), !self.itemNodes.isEmpty {
            if reorderOffset < self.insets.top + 10.0 {
                if self.itemNodes[0].apparentFrame.minY < self.insets.top {
                    continueAnimations = true
                    offsetRanges.offset(IndexRange(first: 0, last: Int.max), offset: 6.0)
                }
            } else if reorderOffset > self.visibleSize.height - self.insets.bottom - 10.0 {
                if self.itemNodes[self.itemNodes.count - 1].apparentFrame.maxY > self.visibleSize.height - self.insets.bottom {
                    continueAnimations = true
                    offsetRanges.offset(IndexRange(first: 0, last: Int.max), offset: -6.0)
                }
            }
        }
        
        var requestUpdateVisibleItems = false
        var index = 0
        while index < self.itemNodes.count {
            let itemNode = self.itemNodes[index]
            
            let previousApparentHeight = itemNode.apparentHeight
            if itemNode.animate(timestamp) {
                continueAnimations = true
            }
            let updatedApparentHeight = itemNode.apparentHeight
            let apparentHeightDelta = updatedApparentHeight - previousApparentHeight
            if abs(apparentHeightDelta) > CGFloat.ulpOfOne {
                let visualInsets = self.visualInsets ?? self.insets
                
                if itemNode.apparentFrame.maxY <= visualInsets.top {
                    offsetRanges.offset(IndexRange(first: 0, last: index), offset: -apparentHeightDelta)
                } else {
                    var offsetDelta = apparentHeightDelta
                    if offsetDelta < 0.0 {
                        let maxDelta = visualInsets.top - itemNode.apparentFrame.maxY
                        if maxDelta > offsetDelta {
                            let remainingOffset = maxDelta - offsetDelta
                            offsetRanges.offset(IndexRange(first: 0, last: index), offset: remainingOffset)
                            offsetDelta = maxDelta
                        }
                    }
                    
                    offsetRanges.offset(IndexRange(first: index + 1, last: Int.max), offset: offsetDelta)
                }
                
                if let accessoryItemNode = itemNode.accessoryItemNode {
                    itemNode.layoutAccessoryItemNode(accessoryItemNode, leftInset: self.insets.left, rightInset: self.insets.right)
                }
            }
            
            if itemNode.index == nil && updatedApparentHeight <= CGFloat.ulpOfOne {
                requestUpdateVisibleItems = true
            }
            
            index += 1
        }
        
        for (_, headerNode) in self.itemHeaderNodes {
            if headerNode.animate(timestamp) {
                continueAnimations = true
            }
        }
        
        if !offsetRanges.offsets.isEmpty {
            requestUpdateVisibleItems = true
            var index = 0
            for itemNode in self.itemNodes {
                let offset = offsetRanges.offsetForIndex(index)
                if offset != 0.0 {
                    var position = itemNode.position
                    position.y += offset
                    itemNode.position = position
                }
                
                index += 1
            }
            
            if !self.snapToBounds(snapTopItem: false, stackFromBottom: self.stackFromBottom).offset.isZero {
                self.updateVisibleContentOffset()
            }
        }
        
        self.debugCheckMonotonity()
        
        if !continueAnimations {
            self.pauseAnimations()
        }
        
        if requestUpdateVisibleItems {
            self.enqueueUpdateVisibleItems(synchronous: false)
        }
        
        self.checkItemReordering()
    }
    
    override open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let touchesPosition = touches.first!.location(in: self.view)
        
        if let index = self.itemIndexAtPoint(touchesPosition) {
            for i in 0 ..< self.itemNodes.count {
                if self.itemNodes[i].preventsTouchesToOtherItems {
                    if index != self.itemNodes[i].index {
                        self.itemNodes[i].touchesToOtherItemsPrevented()
                        return
                    }
                    break
                }
            }
        }
        
        let offset = self.visibleContentOffset()
        switch offset {
            case let .known(value) where value <= 10.0:
                self.beganTrackingAtTopOrigin = true
            default:
                self.beganTrackingAtTopOrigin = false
        }
        
        self.touchesPosition = touchesPosition
        self.selectionTouchLocation = touches.first!.location(in: self.view)
        
        self.selectionTouchDelayTimer?.invalidate()
        self.selectionLongTapDelayTimer?.invalidate()
        self.selectionLongTapDelayTimer = nil
        let timer = Timer(timeInterval: 0.08, target: ListViewTimerProxy { [weak self] in
            if let strongSelf = self, strongSelf.selectionTouchLocation != nil {
                strongSelf.clearHighlightAnimated(false)
                
                if let index = strongSelf.itemIndexAtPoint(strongSelf.touchesPosition) {
                    var canBeSelectedOrLongTapped = false
                    for itemNode in strongSelf.itemNodes {
                        if itemNode.index == index && (strongSelf.items[index].selectable && itemNode.canBeSelected) || itemNode.canBeLongTapped {
                            canBeSelectedOrLongTapped = true
                        }
                    }
                    
                    if canBeSelectedOrLongTapped {
                        strongSelf.highlightedItemIndex = index
                        for itemNode in strongSelf.itemNodes {
                            if itemNode.index == index && itemNode.canBeSelected {
                                if true {
                                    if !itemNode.isLayerBacked {
                                        strongSelf.reorderItemNodeToFront(itemNode)
                                        for (_, headerNode) in strongSelf.itemHeaderNodes {
                                            strongSelf.reorderHeaderNodeToFront(headerNode)
                                        }
                                    }
                                    let itemNodeFrame = itemNode.frame
                                    let itemNodeBounds = itemNode.bounds
                                    if strongSelf.items[index].selectable {
                                        itemNode.setHighlighted(true, at: strongSelf.touchesPosition.offsetBy(dx: -itemNodeFrame.minX + itemNodeBounds.minX, dy: -itemNodeFrame.minY + itemNodeBounds.minY), animated: false)
                                    }
                                    
                                    if itemNode.canBeLongTapped {
                                        let timer = Timer(timeInterval: 0.3, target: ListViewTimerProxy {
                                            if let strongSelf = self, strongSelf.highlightedItemIndex == index {
                                                for itemNode in strongSelf.itemNodes {
                                                    if itemNode.index == index && itemNode.canBeLongTapped {
                                                        itemNode.longTapped()
                                                        strongSelf.clearHighlightAnimated(true)
                                                        strongSelf.selectionTouchLocation = nil
                                                        break
                                                    }
                                                }
                                            }
                                        }, selector: #selector(ListViewTimerProxy.timerEvent), userInfo: nil, repeats: false)
                                        strongSelf.selectionLongTapDelayTimer = timer
                                        RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
                                    }
                                }
                                break
                            }
                        }
                    }
                }
            }
        }, selector: #selector(ListViewTimerProxy.timerEvent), userInfo: nil, repeats: false)
        self.selectionTouchDelayTimer = timer
        RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
        
        super.touchesBegan(touches, with: event)
        
        self.updateScroller(transition: .immediate)
    }
    
    public func clearHighlightAnimated(_ animated: Bool) {
        if let highlightedItemIndex = self.highlightedItemIndex {
            for itemNode in self.itemNodes {
                if itemNode.index == highlightedItemIndex {
                    itemNode.setHighlighted(false, at: CGPoint(), animated: animated)
                    break
                }
            }
        }
        self.highlightedItemIndex = nil
    }
    
    open func updateHiglightPercent(_ percent: CGFloat) {
    }
    
    public func updateNodeHighlightsAnimated(_ animated: Bool) {
        let transition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.35, curve: .spring) : .immediate
        self.updateOverlayHighlight(transition: transition)
    }
    
    private func itemIndexAtPoint(_ point: CGPoint) -> Int? {
        for itemNode in self.itemNodes {
            if itemNode.apparentContentFrame.contains(point) {
                return itemNode.index
            }
        }
        return nil
    }
    
    public func itemNodeAtIndex(_ index: Int) -> ListViewItemNode? {
        for itemNode in self.itemNodes {
            if itemNode.index == index {
                return itemNode
            }
        }
        return nil
    }
    
    public func forEachItemNode(_ f: (ASDisplayNode) -> Void) {
        for itemNode in self.itemNodes {
            if itemNode.index != nil {
                f(itemNode)
            }
        }
    }
    
    public func forEachVisibleItemNode(_ f: (ASDisplayNode) -> Void) {
        for itemNode in self.itemNodes {
            if itemNode.index != nil && itemNode.frame.maxY > self.insets.top && itemNode.frame.minY < self.visibleSize.height - self.insets.bottom {
                f(itemNode)
            }
        }
    }
    
    public func forEachItemHeaderNode(_ f: (ListViewItemHeaderNode) -> Void) {
        for (_, itemNode) in self.itemHeaderNodes {
            f(itemNode)
        }
    }
    
    public func forEachAccessoryItemNode(_ f: (ListViewAccessoryItemNode) -> Void) {
        for itemNode in self.itemNodes {
            if let accessoryItemNode = itemNode.accessoryItemNode {
                f(accessoryItemNode)
            }
        }
    }
    
    public func ensureItemNodeVisible(_ node: ListViewItemNode, animated: Bool = true, overflow: CGFloat = 0.0) {
        if let index = node.index {
            if node.apparentHeight > self.visibleSize.height - self.insets.top - self.insets.bottom {
                if node.frame.maxY > self.visibleSize.height - self.insets.bottom {
                    self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.bottom(-overflow), animated: animated, curve: ListViewAnimationCurve.Default(duration: 0.25), directionHint: ListViewScrollToItemDirectionHint.Down), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                }/* else if node.frame.minY < self.insets.top {
                    self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.top(0.0), animated: true, curve: ListViewAnimationCurve.Default(duration: 0.25), directionHint: ListViewScrollToItemDirectionHint.Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                }*/
            } else {
                if self.experimentalSnapScrollToItem {
                    self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.visible, animated: animated, curve: ListViewAnimationCurve.Default(duration: nil), directionHint: ListViewScrollToItemDirectionHint.Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                } else {
                    if node.frame.minY < self.insets.top {
                        self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.top(overflow), animated: animated, curve: ListViewAnimationCurve.Default(duration: 0.25), directionHint: ListViewScrollToItemDirectionHint.Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                    } else if node.frame.maxY > self.visibleSize.height - self.insets.bottom {
                        self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.bottom(-overflow), animated: animated, curve: ListViewAnimationCurve.Default(duration: 0.25), directionHint: ListViewScrollToItemDirectionHint.Down), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
                    }
                }
            }
        }
    }
    
    public func ensureItemNodeVisibleAtTopInset(_ node: ListViewItemNode) {
        if let index = node.index {
            if node.frame.minY != self.insets.top {
                self.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: ListViewDeleteAndInsertOptions(), scrollToItem: ListViewScrollToItem(index: index, position: ListViewScrollPosition.top(0.0), animated: true, curve: ListViewAnimationCurve.Default(duration: 0.25), directionHint: ListViewScrollToItemDirectionHint.Up), updateSizeAndInsets: nil, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
            }
        }
    }
    
    public func itemNodeRelativeOffset(_ node: ListViewItemNode) -> CGFloat? {
        if let _ = node.index {
            return node.frame.minY - self.insets.top
        }
        return nil
    }
    
    public func itemNodeVisibleInsideInsets(_ node: ListViewItemNode) -> Bool {
        if let _ = node.index {
            if node.frame.maxY > self.insets.top && node.frame.minY < self.visibleSize.height - self.insets.bottom {
                return true
            }
        }
        return false
    }

    override open func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let selectionTouchLocation = self.selectionTouchLocation {
            let location = touches.first!.location(in: self.view)
            let distance = CGPoint(x: selectionTouchLocation.x - location.x, y: selectionTouchLocation.y - location.y)
            let maxMovementDistance: CGFloat = 4.0
            if distance.x * distance.x + distance.y * distance.y > maxMovementDistance * maxMovementDistance {
                self.selectionTouchLocation = nil
                self.selectionTouchDelayTimer?.invalidate()
                self.selectionLongTapDelayTimer?.invalidate()
                self.selectionTouchDelayTimer = nil
                self.selectionLongTapDelayTimer = nil
                self.clearHighlightAnimated(false)
            }
        }
        
        super.touchesMoved(touches, with: event)
    }
    
    override open func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let selectionTouchLocation = self.selectionTouchLocation {
            let index = self.itemIndexAtPoint(selectionTouchLocation)
            if index != self.highlightedItemIndex {
                self.clearHighlightAnimated(false)
            }
            
            if let index = index {
                if self.items[index].selectable {
                    self.highlightedItemIndex = index
                    for itemNode in self.itemNodes {
                        if itemNode.index == index {
                            if itemNode.canBeSelected {
                                if !itemNode.isLayerBacked {
                                    self.reorderItemNodeToFront(itemNode)
                                    for (_, headerNode) in self.itemHeaderNodes {
                                        self.reorderHeaderNodeToFront(headerNode)
                                    }
                                }
                                let itemNodeFrame = itemNode.frame
                                itemNode.setHighlighted(true, at: selectionTouchLocation.offsetBy(dx: -itemNodeFrame.minX, dy: -itemNodeFrame.minY), animated: false)
                            } else {
                                self.highlightedItemIndex = nil
                                itemNode.tapped()
                            }
                            break
                        }
                    }
                }
            }
        }
        
        if let highlightedItemIndex = self.highlightedItemIndex {
            self.items[highlightedItemIndex].selected(listView: self)
        }
        self.selectionTouchLocation = nil
        
        super.touchesEnded(touches, with: event)
    }
    
    override open func touchesCancelled(_ touches: Set<UITouch>?, with event: UIEvent?) {
        self.selectionTouchLocation = nil
        self.selectionTouchDelayTimer?.invalidate()
        self.selectionTouchDelayTimer = nil
        self.selectionLongTapDelayTimer?.invalidate()
        self.selectionLongTapDelayTimer = nil
        self.clearHighlightAnimated(false)
        
        super.touchesCancelled(touches, with: event)
    }
    
    @objc func trackingGesture(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
            case .began:
                self.isTracking = true
                self.trackingOffset = 0.0
            case .changed:
                self.touchesPosition = recognizer.location(in: self.view)
            case .ended, .cancelled:
                self.isTracking = false
            default:
                break
        }
    }
    
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    
    public func withTransaction(_ f: @escaping () -> Void) {
        self.transactionQueue.addTransaction { completion in
            f()
            completion()
        }
    }

    fileprivate func internalHitTest(_ point: CGPoint, with event: UIEvent?) -> Bool {
        if self.limitHitTestToNodes {
            var foundHit = false
            for itemNode in self.itemNodes {
                if itemNode.frame.contains(point) {
                    foundHit = true
                    break
                }
            }
            if !foundHit {
                return false
            }
        }
        return true
    }
    
    fileprivate func headerHitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for (_, headerNode) in self.itemHeaderNodes {
            let headerNodeFrame = headerNode.frame
            if headerNodeFrame.contains(point) {
                return headerNode.hitTest(point.offsetBy(dx: -headerNodeFrame.minX, dy: -headerNodeFrame.minY), with: event)
            }
        }
        return nil
    }
    
    private func reorderItemNodeToFront(_ itemNode: ListViewItemNode) {
        itemNode.view.superview?.bringSubview(toFront: itemNode.view)
        if let itemHighlightOverlayBackground = self.itemHighlightOverlayBackground {
            itemHighlightOverlayBackground.view.superview?.bringSubview(toFront: itemHighlightOverlayBackground.view)
        }
        if let verticalScrollIndicator = self.verticalScrollIndicator {
            verticalScrollIndicator.view.superview?.bringSubview(toFront: verticalScrollIndicator.view)
        }
    }
    
    private func reorderHeaderNodeToFront(_ headerNode: ListViewItemHeaderNode) {
        headerNode.view.superview?.bringSubview(toFront: headerNode.view)
        if let itemHighlightOverlayBackground = self.itemHighlightOverlayBackground {
            itemHighlightOverlayBackground.view.superview?.bringSubview(toFront: itemHighlightOverlayBackground.view)
        }
        if let verticalScrollIndicator = self.verticalScrollIndicator {
            verticalScrollIndicator.view.superview?.bringSubview(toFront: verticalScrollIndicator.view)
        }
    }
    
    public func scrollWithDirection(_ direction: ListViewScrollDirection, distance: CGFloat) -> Bool {
        var accessibilityFocusedNode: (ASDisplayNode, CGRect)?
        for itemNode in self.itemNodes {
            if findAccessibilityFocus(itemNode) {
                accessibilityFocusedNode = (itemNode, itemNode.frame)
                break
            }
        }
        let initialOffset = self.scroller.contentOffset
        switch direction {
            case .up:
                var contentOffset = initialOffset
                contentOffset.y -= distance
                contentOffset.y = max(self.scroller.contentInset.top, contentOffset.y)
                if contentOffset.y < initialOffset.y {
                    self.ignoreScrollingEvents = true
                    self.scroller.setContentOffset(contentOffset, animated: false)
                    self.ignoreScrollingEvents = false
                    self.updateScrollViewDidScroll(self.scroller, synchronous: true)
                } else {
                    return false
                }
            case .down:
                var contentOffset = initialOffset
                contentOffset.y += distance
                contentOffset.y = max(self.scroller.contentInset.top, min(contentOffset.y, self.scroller.contentSize.height - self.visibleSize.height - self.insets.bottom - self.insets.top))
                if contentOffset.y > initialOffset.y {
                    self.ignoreScrollingEvents = true
                    self.scroller.setContentOffset(contentOffset, animated: false)
                    self.ignoreScrollingEvents = false
                    self.updateScrollViewDidScroll(self.scroller, synchronous: true)
                } else {
                    return false
                }
        }
        if let (_, frame) = accessibilityFocusedNode {
            for itemNode in self.itemNodes {
                if frame.intersects(itemNode.frame) {
                    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, itemNode.view)
                    if let index = itemNode.index {
                        let scrollStatus = "Row \(index + 1) of \(self.items.count)"
                        UIAccessibilityPostNotification(UIAccessibilityPageScrolledNotification, scrollStatus)
                    }
                    break
                }
            }
        }
        return true
    }
    
    override open func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let distance = floor((self.visibleSize.height - self.insets.top - self.insets.bottom) / 2.0)
        let scrollDirection: ListViewScrollDirection
        switch direction {
            case .down:
                scrollDirection = .down
            default:
                scrollDirection = .up
        }
        return self.scrollWithDirection(scrollDirection, distance: distance)
    }
}

private func findAccessibilityFocus(_ node: ASDisplayNode) -> Bool {
    if node.view.accessibilityElementIsFocused() {
        return true
    }
    return false
}
