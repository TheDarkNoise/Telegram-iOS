import Foundation
import AsyncDisplayKit
import Display
import TelegramPresentationData
import SwiftSignalKit
import TelegramCore
import ReactionSelectionNode
import ComponentFlow
import TabSelectorComponent
import ComponentDisplayAdapters

final class ContextSourceContainer: ASDisplayNode {
    final class Source {
        weak var controller: ContextController?
        
        let id: AnyHashable
        let title: String
        let source: ContextContentSource
        
        private var _presentationNode: ContextControllerPresentationNode?
        var presentationNode: ContextControllerPresentationNode {
            return self._presentationNode!
        }
        
        var currentPresentationStateTransition: ContextControllerPresentationNodeStateTransition?
        
        var validLayout: ContainerViewLayout?
        var presentationData: PresentationData?
        var delayLayoutUpdate: Bool = false
        var isAnimatingOut: Bool = false
        
        let itemsDisposable = MetaDisposable()
        
        let ready = Promise<Bool>()
        private let contentReady = Promise<Bool>()
        private let actionsReady = Promise<Bool>()
        
        init(
            controller: ContextController,
            id: AnyHashable,
            title: String,
            source: ContextContentSource,
            items: Signal<ContextController.Items, NoError>
        ) {
            self.controller = controller
            self.id = id
            self.title = title
            self.source = source
            
            self.ready.set(combineLatest(queue: .mainQueue(), self.contentReady.get(), self.actionsReady.get())
            |> map { a, b -> Bool in
                return a && b
            }
            |> distinctUntilChanged)
            
            switch source {
            case let .location(source):
                self.contentReady.set(.single(true))
                
                let presentationNode = ContextControllerExtractedPresentationNode(
                    getController: { [weak self] in
                        guard let self else {
                            return nil
                        }
                        return self.controller
                    },
                    requestUpdate: { [weak self] transition in
                        guard let self else {
                            return
                        }
                        self.update(transition: transition)
                    },
                    requestUpdateOverlayWantsToBeBelowKeyboard: { [weak self] transition in
                        guard let self else {
                            return
                        }
                        if let controller = self.controller {
                            controller.overlayWantsToBeBelowKeyboardUpdated(transition: transition)
                        }
                    },
                    requestDismiss: { [weak self] result in
                        guard let self, let controller = self.controller else {
                            return
                        }
                        controller.controllerNode.dismissedForCancel?()
                        controller.controllerNode.beginDismiss(result)
                    },
                    requestAnimateOut: { [weak self] result, completion in
                        guard let self, let controller = self.controller else {
                            return
                        }
                        controller.controllerNode.animateOut(result: result, completion: completion)
                    },
                    source: .location(source)
                )
                self._presentationNode = presentationNode
            case let .reference(source):
                self.contentReady.set(.single(true))
                
                let presentationNode = ContextControllerExtractedPresentationNode(
                    getController: { [weak self] in
                        guard let self else {
                            return nil
                        }
                        return self.controller
                    },
                    requestUpdate: { [weak self] transition in
                        guard let self else {
                            return
                        }
                        self.update(transition: transition)
                    },
                    requestUpdateOverlayWantsToBeBelowKeyboard: { [weak self] transition in
                        guard let self else {
                            return
                        }
                        if let controller = self.controller {
                            controller.overlayWantsToBeBelowKeyboardUpdated(transition: transition)
                        }
                    },
                    requestDismiss: { [weak self] result in
                        guard let self, let controller = self.controller else {
                            return
                        }
                        controller.controllerNode.dismissedForCancel?()
                        controller.controllerNode.beginDismiss(result)
                    },
                    requestAnimateOut: { [weak self] result, completion in
                        guard let self, let controller = self.controller else {
                            return
                        }
                        controller.controllerNode.animateOut(result: result, completion: completion)
                    },
                    source: .reference(source)
                )
                self._presentationNode = presentationNode
            case let .extracted(source):
                self.contentReady.set(.single(true))
                
                let presentationNode = ContextControllerExtractedPresentationNode(
                    getController: { [weak self] in
                        guard let self else {
                            return nil
                        }
                        return self.controller
                    },
                    requestUpdate: { [weak self] transition in
                        guard let self else {
                            return
                        }
                        self.update(transition: transition)
                    },
                    requestUpdateOverlayWantsToBeBelowKeyboard: { [weak self] transition in
                        guard let self else {
                            return
                        }
                        if let controller = self.controller {
                            controller.overlayWantsToBeBelowKeyboardUpdated(transition: transition)
                        }
                    },
                    requestDismiss: { [weak self] result in
                        guard let self, let controller = self.controller else {
                            return
                        }
                        controller.controllerNode.dismissedForCancel?()
                        controller.controllerNode.beginDismiss(result)
                    },
                    requestAnimateOut: { [weak self] result, completion in
                        guard let self, let controller = self.controller else {
                            return
                        }
                        controller.controllerNode.animateOut(result: result, completion: completion)
                    },
                    source: .extracted(source)
                )
                self._presentationNode = presentationNode
            case let .controller(source):
                self.contentReady.set(source.controller.ready.get())
                
                let presentationNode = ContextControllerExtractedPresentationNode(
                    getController: { [weak self] in
                        guard let self else {
                            return nil
                        }
                        return self.controller
                    },
                    requestUpdate: { [weak self] transition in
                        guard let self else {
                            return
                        }
                        self.update(transition: transition)
                    },
                    requestUpdateOverlayWantsToBeBelowKeyboard: { [weak self] transition in
                        guard let self else {
                            return
                        }
                        if let controller = self.controller {
                            controller.overlayWantsToBeBelowKeyboardUpdated(transition: transition)
                        }
                    },
                    requestDismiss: { [weak self] result in
                        guard let self, let controller = self.controller else {
                            return
                        }
                        controller.controllerNode.dismissedForCancel?()
                        controller.controllerNode.beginDismiss(result)
                    },
                    requestAnimateOut: { [weak self] result, completion in
                        guard let self, let controller = self.controller else {
                            return
                        }
                        controller.controllerNode.animateOut(result: result, completion: completion)
                    },
                    source: .controller(source)
                )
                self._presentationNode = presentationNode
            }
            
            self.itemsDisposable.set((items |> deliverOnMainQueue).start(next: { [weak self] items in
                guard let self else {
                    return
                }
                
                self.setItems(items: items, animated: false)
                self.actionsReady.set(.single(true))
            }))
        }
        
        deinit {
            self.itemsDisposable.dispose()
        }
        
        func animateIn() {
            self.currentPresentationStateTransition = .animateIn
            self.update(transition: .animated(duration: 0.5, curve: .spring))
        }
        
        func animateOut(result: ContextMenuActionResult, completion: @escaping () -> Void) {
            self.currentPresentationStateTransition = .animateOut(result: result, completion: completion)
            if let _ = self.validLayout {
                if case let .custom(transition) = result {
                    self.delayLayoutUpdate = true
                    Queue.mainQueue().after(0.1) {
                        self.delayLayoutUpdate = false
                        self.update(transition: transition)
                        self.isAnimatingOut = true
                    }
                } else {
                    self.update(transition: .animated(duration: 0.35, curve: .easeInOut))
                }
            }
        }
        
        func addRelativeContentOffset(_ offset: CGPoint, transition: ContainedViewLayoutTransition) {
            self.presentationNode.addRelativeContentOffset(offset, transition: transition)
        }
        
        func cancelReactionAnimation() {
            self.presentationNode.cancelReactionAnimation()
        }
        
        func animateOutToReaction(value: MessageReaction.Reaction, targetView: UIView, hideNode: Bool, animateTargetContainer: UIView?, addStandaloneReactionAnimation: ((StandaloneReactionAnimation) -> Void)?, reducedCurve: Bool, completion: @escaping () -> Void) {
            self.presentationNode.animateOutToReaction(value: value, targetView: targetView, hideNode: hideNode, animateTargetContainer: animateTargetContainer, addStandaloneReactionAnimation: addStandaloneReactionAnimation, reducedCurve: reducedCurve, completion: completion)
        }
        
        func setItems(items: Signal<ContextController.Items, NoError>, animated: Bool) {
            self.itemsDisposable.set((items
            |> deliverOnMainQueue).start(next: { [weak self] items in
                guard let self else {
                    return
                }
                self.setItems(items: items, animated: animated)
            }))
        }
        
        func setItems(items: ContextController.Items, animated: Bool) {
            self.presentationNode.replaceItems(items: items, animated: animated)
        }
        
        func pushItems(items: Signal<ContextController.Items, NoError>) {
            self.itemsDisposable.set((items
            |> deliverOnMainQueue).start(next: { [weak self] items in
                guard let self else {
                    return
                }
                self.presentationNode.pushItems(items: items)
            }))
        }
        
        func popItems() {
            self.presentationNode.popItems()
        }
        
        func update(transition: ContainedViewLayoutTransition) {
            guard let validLayout = self.validLayout else {
                return
            }
            guard let presentationData = self.presentationData else {
                return
            }
            self.update(presentationData: presentationData, layout: validLayout, transition: transition)
        }
        
        func update(
            presentationData: PresentationData,
            layout: ContainerViewLayout,
            transition: ContainedViewLayoutTransition
        ) {
            if self.isAnimatingOut || self.delayLayoutUpdate {
                return
            }
            
            self.validLayout = layout
            self.presentationData = presentationData
            
            let presentationStateTransition = self.currentPresentationStateTransition
            self.currentPresentationStateTransition = .none
            
            self.presentationNode.update(
                presentationData: presentationData,
                layout: layout,
                transition: transition,
                stateTransition: presentationStateTransition
            )
        }
    }
    
    private struct PanState {
        var fraction: CGFloat
        
        init(fraction: CGFloat) {
            self.fraction = fraction
        }
    }
    
    private weak var controller: ContextController?
    
    var sources: [Source] = []
    var activeIndex: Int = 0
    
    private var tabSelector: ComponentView<Empty>?
    
    private var presentationData: PresentationData?
    private var validLayout: ContainerViewLayout?
    private var panState: PanState?
    
    let ready = Promise<Bool>()
    
    var activeSource: Source? {
        if self.activeIndex >= self.sources.count {
            return nil
        }
        return self.sources[self.activeIndex]
    }
    
    var overlayWantsToBeBelowKeyboard: Bool {
        return self.activeSource?.presentationNode.wantsDisplayBelowKeyboard() ?? false
    }
    
    init(controller: ContextController, configuration: ContextController.Configuration) {
        self.controller = controller
        
        super.init()
        
        for i in 0 ..< configuration.sources.count {
            let source = configuration.sources[i]
            
            let mappedSource = Source(
                controller: controller,
                id: source.id,
                title: source.title,
                source: source.source,
                items: source.items
            )
            self.sources.append(mappedSource)
            self.addSubnode(mappedSource.presentationNode)
            
            if source.id == configuration.initialId {
                self.activeIndex = i
            }
        }
        
        self.ready.set(self.sources[self.activeIndex].ready.get())
        
        self.view.addGestureRecognizer(InteractiveTransitionGestureRecognizer(target: self, action: #selector(self.panGesture(_:)), allowedDirections: { [weak self] _ in
            guard let self else {
                return []
            }
            if self.sources.count <= 1 {
                return []
            }
            return [.left, .right]
        }))
    }
    
    @objc private func panGesture(_ recognizer: InteractiveTransitionGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            if let validLayout = self.validLayout {
                var translationX = recognizer.translation(in: self.view).x
                if self.activeIndex == 0 && translationX > 0.0 {
                    translationX = scrollingRubberBandingOffset(offset: abs(translationX), bandingStart: 0.0, range: 20.0)
                } else if self.activeIndex == self.sources.count - 1 && translationX < 0.0 {
                    translationX = -scrollingRubberBandingOffset(offset: abs(translationX), bandingStart: 0.0, range: 20.0)
                }
                
                self.panState = PanState(fraction: translationX / validLayout.size.width)
                self.update(transition: .immediate)
            }
        case .cancelled, .ended:
            if let panState = self.panState {
                self.panState = nil
                
                let velocity = recognizer.velocity(in: self.view)
                
                var nextIndex = self.activeIndex
                if panState.fraction < -0.4 {
                    nextIndex += 1
                } else if panState.fraction > 0.4 {
                    nextIndex -= 1
                } else if abs(velocity.x) >= 200.0 {
                    if velocity.x < 0.0 {
                        nextIndex += 1
                    } else {
                        nextIndex -= 1
                    }
                }
                if nextIndex < 0 {
                    nextIndex = 0
                }
                if nextIndex > self.sources.count - 1 {
                    nextIndex = self.sources.count - 1
                }
                if nextIndex != self.activeIndex {
                    self.activeIndex = nextIndex
                }
                
                self.update(transition: .animated(duration: 0.4, curve: .spring))
            }
        default:
            break
        }
    }
    
    func animateIn() {
        if let activeSource = self.activeSource {
            activeSource.animateIn()
        }
        if let tabSelectorView = self.tabSelector?.view {
            tabSelectorView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        }
    }
    
    func animateOut(result: ContextMenuActionResult, completion: @escaping () -> Void) {
        if let tabSelectorView = self.tabSelector?.view {
            tabSelectorView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
        }
        
        if let activeSource = self.activeSource {
            activeSource.animateOut(result: result, completion: completion)
        } else {
            completion()
        }
    }
    
    func highlightGestureMoved(location: CGPoint, hover: Bool) {
        if self.activeIndex >= self.sources.count {
            return
        }
        self.sources[self.activeIndex].presentationNode.highlightGestureMoved(location: location, hover: hover)
    }
    
    func highlightGestureFinished(performAction: Bool) {
        if self.activeIndex >= self.sources.count {
            return
        }
        self.sources[self.activeIndex].presentationNode.highlightGestureFinished(performAction: performAction)
    }
    
    func performHighlightedAction() {
        self.activeSource?.presentationNode.highlightGestureFinished(performAction: true)
    }
    
    func decreaseHighlightedIndex() {
        self.activeSource?.presentationNode.decreaseHighlightedIndex()
    }
    
    func increaseHighlightedIndex() {
        self.activeSource?.presentationNode.increaseHighlightedIndex()
    }
    
    func addRelativeContentOffset(_ offset: CGPoint, transition: ContainedViewLayoutTransition) {
        if let activeSource = self.activeSource {
            activeSource.addRelativeContentOffset(offset, transition: transition)
        }
    }
    
    func cancelReactionAnimation() {
        if let activeSource = self.activeSource {
            activeSource.cancelReactionAnimation()
        }
    }
    
    func animateOutToReaction(value: MessageReaction.Reaction, targetView: UIView, hideNode: Bool, animateTargetContainer: UIView?, addStandaloneReactionAnimation: ((StandaloneReactionAnimation) -> Void)?, reducedCurve: Bool, completion: @escaping () -> Void) {
        if let activeSource = self.activeSource {
            activeSource.animateOutToReaction(value: value, targetView: targetView, hideNode: hideNode, animateTargetContainer: animateTargetContainer, addStandaloneReactionAnimation: addStandaloneReactionAnimation, reducedCurve: reducedCurve, completion: completion)
        } else {
            completion()
        }
    }
    
    func setItems(items: Signal<ContextController.Items, NoError>, animated: Bool) {
        if let activeSource = self.activeSource {
            activeSource.setItems(items: items, animated: animated)
        }
    }
    
    func pushItems(items: Signal<ContextController.Items, NoError>) {
        if let activeSource = self.activeSource {
            activeSource.pushItems(items: items)
        }
    }
    
    func popItems() {
        if let activeSource = self.activeSource {
            activeSource.popItems()
        }
    }
    
    private func update(transition: ContainedViewLayoutTransition) {
        if let presentationData = self.presentationData, let validLayout = self.validLayout {
            self.update(presentationData: presentationData, layout: validLayout, transition: transition)
        }
    }
    
    func update(
        presentationData: PresentationData,
        layout: ContainerViewLayout,
        transition: ContainedViewLayoutTransition
    ) {
        self.presentationData = presentationData
        self.validLayout = layout
        
        var childLayout = layout
        
        if self.sources.count > 1 {
            let tabSelector: ComponentView<Empty>
            if let current = self.tabSelector {
                tabSelector = current
            } else {
                tabSelector = ComponentView()
                self.tabSelector = tabSelector
            }
            let mappedItems = self.sources.map { source -> TabSelectorComponent.Item in
                return TabSelectorComponent.Item(id: source.id, title: source.title)
            }
            let tabSelectorSize = tabSelector.update(
                transition: Transition(transition),
                component: AnyComponent(TabSelectorComponent(
                    colors: TabSelectorComponent.Colors(
                        foreground: presentationData.theme.contextMenu.primaryColor.withMultipliedAlpha(0.8),
                        selection: presentationData.theme.contextMenu.primaryColor.withMultipliedAlpha(0.1)
                    ),
                    items: mappedItems,
                    selectedId: self.activeSource?.id,
                    setSelectedId: { [weak self] id in
                        guard let self else {
                            return
                        }
                        if let index = self.sources.firstIndex(where: { $0.id == id }) {
                            self.activeIndex = index
                            self.update(transition: .animated(duration: 0.4, curve: .spring))
                        }
                    }
                )),
                environment: {},
                containerSize: CGSize(width: layout.size.width, height: 44.0)
            )
            childLayout.intrinsicInsets.bottom += 44.0
            
            if let tabSelectorView = tabSelector.view {
                if tabSelectorView.superview == nil {
                    self.view.addSubview(tabSelectorView)
                }
                transition.updateFrame(view: tabSelectorView, frame: CGRect(origin: CGPoint(x: floor((layout.size.width - tabSelectorSize.width) * 0.5), y: layout.size.height - layout.intrinsicInsets.bottom - tabSelectorSize.height), size: tabSelectorSize))
            }
        } else if let tabSelector = self.tabSelector {
            self.tabSelector = nil
            tabSelector.view?.removeFromSuperview()
        }
        
        for i in 0 ..< self.sources.count {
            var itemFrame = CGRect(origin: CGPoint(), size: childLayout.size)
            itemFrame.origin.x += CGFloat(i - self.activeIndex) * childLayout.size.width
            if let panState = self.panState {
                itemFrame.origin.x += panState.fraction * childLayout.size.width
            }
            
            let itemTransition = transition
            itemTransition.updateFrame(node: self.sources[i].presentationNode, frame: itemFrame)
            self.sources[i].update(
                presentationData: presentationData,
                layout: childLayout,
                transition: itemTransition
            )
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let tabSelectorView = self.tabSelector?.view {
            if let result = tabSelectorView.hitTest(self.view.convert(point, to: tabSelectorView), with: event) {
                return result
            }
        }
        
        guard let activeSource = self.activeSource else {
            return nil
        }
        return activeSource.presentationNode.view.hitTest(point, with: event)
    }
}
