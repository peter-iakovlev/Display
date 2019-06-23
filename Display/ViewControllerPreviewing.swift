import Foundation
import UIKit
import SwiftSignalKit

@available(iOSApplicationExtension 9.0, *)
private final class ViewControllerPeekContent: PeekControllerContent {
    private let controller: ViewController
    private let menu: [PeekControllerMenuItem]
    
    init(controller: ViewController) {
        self.controller = controller
        var menu: [PeekControllerMenuItem] = []
        for item in controller.previewActionItems {
            menu.append(PeekControllerMenuItem(title: item.title, color: .accent, action: { [weak controller] in
                if let controller = controller, let item = item as? UIPreviewAction {
                    item.handler(item, controller)
                }
            }))
        }
        self.menu = menu
    }
    
    func presentation() -> PeekControllerContentPresentation {
        return .contained(userInterfaceEnabled: false)
    }
    
    func menuActivation() -> PeerkControllerMenuActivation {
        return .drag
    }
    
    func menuItems() -> [PeekControllerMenuItem] {
        return self.menu
    }
    
    func node() -> PeekControllerContentNode & ASDisplayNode {
        return ViewControllerPeekContentNode(controller: self.controller)
    }
    
    func topAccessoryNode() -> ASDisplayNode? {
        return nil
    }
    
    func isEqual(to: PeekControllerContent) -> Bool {
        if let to = to as? ViewControllerPeekContent {
            return self.controller === to.controller
        } else {
            return false
        }
    }
}

private final class ViewControllerPeekContentNode: ASDisplayNode, PeekControllerContentNode {
    private let controller: ViewController
    private var hasValidLayout = false
    
    init(controller: ViewController) {
        self.controller = controller
        
        super.init()
    }
    
    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) -> CGSize {
        if !self.hasValidLayout {
            self.hasValidLayout = true
            self.controller.view.frame = CGRect(origin: CGPoint(), size: size)
            self.controller.containerLayoutUpdated(ContainerViewLayout(size: size, metrics: LayoutMetrics(), intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: nil, standardInputHeight: 216.0, inputHeightIsInteractivellyChanging: false, inVoiceOver: false), transition: .immediate)
            self.controller.setIgnoreAppearanceMethodInvocations(true)
            self.view.addSubview(self.controller.view)
            self.controller.setIgnoreAppearanceMethodInvocations(false)
            self.controller.viewWillAppear(false)
            self.controller.viewDidAppear(false)
        } else {
            self.controller.containerLayoutUpdated(ContainerViewLayout(size: size, metrics: LayoutMetrics(), intrinsicInsets: UIEdgeInsets(), safeInsets: UIEdgeInsets(), statusBarHeight: nil, inputHeight: nil, standardInputHeight: 216.0, inputHeightIsInteractivellyChanging: false, inVoiceOver: false), transition: transition)
        }
        
        return size
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.bounds.contains(point) {
            return self.view
        }
        return nil
    }
}

@available(iOSApplicationExtension 9.0, *)
final class SimulatedViewControllerPreviewing: NSObject, UIViewControllerPreviewing {
    weak var delegateImpl: UIViewControllerPreviewingDelegate?
    var delegate: UIViewControllerPreviewingDelegate {
        return self.delegateImpl!
    }
    let recognizer: PeekControllerGestureRecognizer
    var previewingGestureRecognizerForFailureRelationship: UIGestureRecognizer {
        return self.recognizer
    }
    let sourceView: UIView
    let node: ASDisplayNode
    
    var sourceRect: CGRect = CGRect()
    
    init(theme: PeekControllerTheme, delegate: UIViewControllerPreviewingDelegate, sourceView: UIView, node: ASDisplayNode, present: @escaping (ViewController, Any?) -> Void) {
        self.delegateImpl = delegate
        self.sourceView = sourceView
        self.node = node
        var contentAtPointImpl: ((CGPoint) -> Signal<(ASDisplayNode, PeekControllerContent)?, NoError>?)?
        self.recognizer = PeekControllerGestureRecognizer(contentAtPoint: { point in
            return contentAtPointImpl?(point)
        }, present: { content, sourceNode in
            let controller = PeekController(theme: theme, content: content, sourceNode: {
                return sourceNode
            })
            present(controller, nil)
            return controller
        })
        
        node.view.addGestureRecognizer(self.recognizer)
        
        super.init()
        
        contentAtPointImpl = { [weak self] point in
            if let strongSelf = self, let delegate = strongSelf.delegateImpl {
                if let controller = delegate.previewingContext(strongSelf, viewControllerForLocation: point) as? ViewController {
                    return .single((strongSelf.node, ViewControllerPeekContent(controller: controller)))
                }
            }
            return nil
        }
    }
}
