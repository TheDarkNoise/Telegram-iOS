import Foundation
import UIKit
import AsyncDisplayKit
import Display
import Postbox
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import RadialStatusNode
import ScreenCaptureDetection
import AppBundle
import LocalizedPeerData
import TooltipUI

private func galleryMediaForMedia(media: Media) -> Media? {
    if let media = media as? TelegramMediaImage {
        return media
    } else if let file = media as? TelegramMediaFile {
        if file.mimeType.hasPrefix("audio/") {
            return nil
        } else if !file.isVideo && file.mimeType.hasPrefix("video/") {
            return file
        } else {
            return file
        }
    }
    return nil
}

private func mediaForMessage(message: Message) -> Media? {
    for media in message.media {
        if let result = galleryMediaForMedia(media: media) {
            return result
        } else if let webpage = media as? TelegramMediaWebpage {
            switch webpage.content {
            case let .Loaded(content):
                if let embedUrl = content.embedUrl, !embedUrl.isEmpty {
                    return webpage
                } else if let image = content.image {
                    if let result = galleryMediaForMedia(media: image) {
                        return result
                    }
                } else if let file = content.file {
                    if let result = galleryMediaForMedia(media: file) {
                        return result
                    }
                }
            case .Pending:
                break
            }
        }
    }
    return nil
}

private final class SecretMediaPreviewControllerNode: GalleryControllerNode {
    private var timeoutNode: RadialStatusNode?
    
    private var validLayout: (ContainerViewLayout, CGFloat)?
        
    var beginTimeAndTimeout: (Double, Double)? {
        didSet {
            if let (beginTime, timeout) = self.beginTimeAndTimeout {
                var beginTime = beginTime
                if self.timeoutNode == nil {
                    let timeoutNode = RadialStatusNode(backgroundNodeColor: UIColor(white: 0.0, alpha: 0.5))
                    self.timeoutNode = timeoutNode
                    let icon: RadialStatusNodeState.SecretTimeoutIcon
                    let timeoutValue = Int32(timeout)
                    if timeoutValue == viewOnceTimeout || "".isEmpty {
                        beginTime = CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970
                        
                        if let image = generateImage(CGSize(width: 28.0, height: 28.0), rotatedContext: { size, context in
                            let bounds = CGRect(origin: .zero, size: size)
                            context.clear(bounds)
                            
                            let string = "1"
                            let attributedString = NSAttributedString(string: string, attributes: [NSAttributedString.Key.font: Font.with(size: 14.0, design: .round), NSAttributedString.Key.foregroundColor: UIColor.white])
                            
                            let line = CTLineCreateWithAttributedString(attributedString)
                            let lineBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                            
                            let lineOffset = CGPoint(x: -1.0, y: 0.0)
                            let lineOrigin = CGPoint(x: floorToScreenPixels(-lineBounds.origin.x + (bounds.size.width - lineBounds.size.width) / 2.0) + lineOffset.x, y: floorToScreenPixels(-lineBounds.origin.y + (bounds.size.height - lineBounds.size.height) / 2.0))
                            
                            context.translateBy(x: bounds.size.width / 2.0, y: bounds.size.height / 2.0)
                            context.scaleBy(x: 1.0, y: -1.0)
                            context.translateBy(x: -bounds.size.width / 2.0, y: -bounds.size.height / 2.0)
                            
                            context.translateBy(x: lineOrigin.x, y: lineOrigin.y)
                            CTLineDraw(line, context)
                            context.translateBy(x: -lineOrigin.x, y: -lineOrigin.y)
                        }) {
                            icon = .image(image)
                        } else {
                            icon = .flame
                        }
                    } else {
                        icon = .flame
                    }
                    timeoutNode.transitionToState(.secretTimeout(color: .white, icon: icon, beginTime: beginTime, timeout: timeout, sparks: true), completion: {})
                    self.addSubnode(timeoutNode)
  
                    timeoutNode.addTarget(self, action: #selector(self.statusTapGesture), forControlEvents: .touchUpInside)
                    
//                    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(self.statusTapGesture))
//                    timeoutNode.view.addGestureRecognizer(tapGesture)
                    
                    if let (layout, navigationHeight) = self.validLayout {
                        self.layoutTimeoutNode(layout, navigationBarHeight: navigationHeight, transition: .immediate)
                    }
                }
            } else if let timeoutNode = self.timeoutNode {
                self.timeoutNode = nil
                timeoutNode.removeFromSupernode()
            }
        }
    }
    
    var statusPressed: (UIView) -> Void = { _ in }
    @objc private func statusTapGesture() {
        if let sourceView = self.timeoutNode?.view {
            self.statusPressed(sourceView)
        }
    }
    
    override func animateIn(animateContent: Bool, useSimpleAnimation: Bool) {
        super.animateIn(animateContent: animateContent, useSimpleAnimation: useSimpleAnimation)
        
        self.timeoutNode?.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }
    
    override func animateOut(animateContent: Bool, completion: @escaping () -> Void) {
        super.animateOut(animateContent: animateContent, completion: completion)
        
        if let timeoutNode = self.timeoutNode {
            timeoutNode.layer.animateAlpha(from: timeoutNode.alpha, to: 0.0, duration: 0.2, removeOnCompletion: false)
        }
    }
    
    override func updateDismissTransition(_ value: CGFloat) {
        self.timeoutNode?.alpha = value
    }
    
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: transition)
        
        self.validLayout = (layout, navigationBarHeight)
        self.layoutTimeoutNode(layout, navigationBarHeight: navigationBarHeight, transition: transition)
    }
    
    private func layoutTimeoutNode(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        if let timeoutNode = self.timeoutNode {
            let diameter: CGFloat = 28.0
            transition.updateFrame(node: timeoutNode, frame: CGRect(origin: CGPoint(x: layout.size.width - layout.safeInsets.right - diameter - 9.0, y: navigationBarHeight - 9.0 - diameter), size: CGSize(width: diameter, height: diameter)))
        }
    }
}

public final class SecretMediaPreviewController: ViewController {
    private let context: AccountContext
    private let messageId: MessageId
    
    private let _ready = Promise<Bool>()
    override public var ready: Promise<Bool> {
        return self._ready
    }
    private var didSetReady = false
    
    private let disposable = MetaDisposable()
    private let markMessageAsConsumedDisposable = MetaDisposable()
    
    private var controllerNode: SecretMediaPreviewControllerNode {
        return self.displayNode as! SecretMediaPreviewControllerNode
    }
    
    private var messageView: MessageView?
    private var currentNodeMessageId: MessageId?
    private var currentNodeMessageIsVideo = false
    private var currentNodeMessageIsViewOnce = false
    private var tempFile: TempBoxFile?
    
    private let _hiddenMedia = Promise<(MessageId, Media)?>(nil)
    private var hiddenMediaManagerIndex: Int?
    
    private let presentationData: PresentationData
    
    private var screenCaptureEventsDisposable: Disposable?
    
    private weak var tooltipController: TooltipScreen?
    
    public init(context: AccountContext, messageId: MessageId) {
        self.context = context
        self.messageId = messageId
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: GalleryController.darkNavigationTheme, strings: NavigationBarStrings(presentationStrings: self.presentationData.strings)))
        
        let backItem = UIBarButtonItem(backButtonAppearanceWithTitle: presentationData.strings.Common_Back, target: self, action: #selector(self.donePressed))
        self.navigationItem.leftBarButtonItem = backItem
        
        self.statusBar.statusBarStyle = .White
        
        self.disposable.set((context.account.postbox.messageView(messageId) |> deliverOnMainQueue).start(next: { [weak self] view in
            if let strongSelf = self {
                strongSelf.messageView = view
                if strongSelf.isViewLoaded {
                    strongSelf.applyMessageView()
                }
            }
        }))
        
        self.hiddenMediaManagerIndex = self.context.sharedContext.mediaManager.galleryHiddenMediaManager.addSource(self._hiddenMedia.get()
        |> map { messageIdAndMedia in
            if let (messageId, media) = messageIdAndMedia {
                return .chat(context.account.id, messageId, media)
            } else {
                return nil
            }
        })
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.disposable.dispose()
        self.markMessageAsConsumedDisposable.dispose()
        if let hiddenMediaManagerIndex = self.hiddenMediaManagerIndex {
            self.context.sharedContext.mediaManager.galleryHiddenMediaManager.removeSource(hiddenMediaManagerIndex)
        }
        self.screenCaptureEventsDisposable?.dispose()
        if let tempFile = self.tempFile {
            TempBox.shared.dispose(tempFile)
        }
    }
    
    @objc func donePressed() {
        self.dismiss(forceAway: false)
    }
    
    public override func loadDisplayNode() {
        let controllerInteraction = GalleryControllerInteraction(presentController: { [weak self] controller, arguments in
            if let strongSelf = self {
                strongSelf.present(controller, in: .window(.root), with: arguments, blockInteraction: true)
            }
        }, pushController: { _ in
        }, dismissController: { [weak self] in
            self?.dismiss(forceAway: true)
        }, replaceRootController: { _, _ in
        }, editMedia: { _ in
        })
        self.displayNode = SecretMediaPreviewControllerNode(controllerInteraction: controllerInteraction)
        self.displayNodeDidLoad()
        
        self.controllerNode.statusPressed = { [weak self] sourceView in
            if let self {
                self.presentViewOnceTooltip(sourceView: sourceView)
            }
        }
        
        self.controllerNode.statusBar = self.statusBar
        self.controllerNode.navigationBar = self.navigationBar
        
        self.controllerNode.transitionDataForCentralItem = { [weak self] in
            if let strongSelf = self {
                if let _ = strongSelf.controllerNode.pager.centralItemNode(), let presentationArguments = strongSelf.presentationArguments as? GalleryControllerPresentationArguments {
                    if let message = strongSelf.messageView?.message {
                        if let media = mediaForMessage(message: message), let transitionArguments = presentationArguments.transitionArguments(message.id, media) {
                            return (transitionArguments.transitionNode, transitionArguments.addToTransitionSurface)
                        }
                    }
                }
            }
            return nil
        }
        self.controllerNode.dismiss = { [weak self] in
            self?._hiddenMedia.set(.single(nil))
            self?.presentingViewController?.dismiss(animated: false, completion: nil)
        }
        
        self.controllerNode.beginCustomDismiss = { [weak self] _ in
            if let strongSelf = self {
                strongSelf._hiddenMedia.set(.single(nil))
                
                let animatedOutNode = true
                
                strongSelf.controllerNode.animateOut(animateContent: animatedOutNode, completion: {
                })
            }
        }
        
        self.controllerNode.completeCustomDismiss = { [weak self] in
            self?._hiddenMedia.set(.single(nil))
            self?.presentingViewController?.dismiss(animated: false, completion: nil)
        }
        
        self.controllerNode.pager.centralItemIndexUpdated = { [weak self] index in
            if let strongSelf = self {
                var hiddenItem: (MessageId, Media)?
                if let _ = index {
                    if let message = strongSelf.messageView?.message, let media = mediaForMessage(message: message) {
                        var beginTimeAndTimeout: (Double, Double)?
                        var videoDuration: Double?
                        for media in message.media {
                            if let file = media as? TelegramMediaFile {
                                videoDuration = file.duration
                            }
                        }
                        
                        if let attribute = message.autoclearAttribute {
                            strongSelf.currentNodeMessageIsViewOnce = attribute.timeout == viewOnceTimeout
                            
                            if let countdownBeginTime = attribute.countdownBeginTime {
                                if let videoDuration = videoDuration {
                                    beginTimeAndTimeout = (CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970, videoDuration)
                                } else {
                                    beginTimeAndTimeout = (Double(countdownBeginTime), Double(attribute.timeout))
                                }
                            }
                        } else if let attribute = message.autoremoveAttribute {
                            strongSelf.currentNodeMessageIsViewOnce = attribute.timeout == viewOnceTimeout
                            
                            if let countdownBeginTime = attribute.countdownBeginTime {
                                if let videoDuration = videoDuration {
                                    beginTimeAndTimeout = (CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970, videoDuration)
                                } else {
                                    beginTimeAndTimeout = (Double(countdownBeginTime), Double(attribute.timeout))
                                }
                            }
                        }
                        
                        if let file = media as? TelegramMediaFile {
                            if file.isAnimated {
                                strongSelf.title = strongSelf.presentationData.strings.SecretGif_Title
                            } else {
                                if strongSelf.currentNodeMessageIsViewOnce {
                                    strongSelf.title = strongSelf.presentationData.strings.SecretVideo_ViewOnce_Title
                                } else {
                                    strongSelf.title = strongSelf.presentationData.strings.SecretVideo_Title
                                }
                            }
                        } else {
                            if strongSelf.currentNodeMessageIsViewOnce {
                                strongSelf.title = strongSelf.presentationData.strings.SecretImage_ViewOnce_Title
                            } else {
                                strongSelf.title = strongSelf.presentationData.strings.SecretImage_Title
                            }
                        }
                        
                        if let beginTimeAndTimeout = beginTimeAndTimeout {
                            strongSelf.controllerNode.beginTimeAndTimeout = beginTimeAndTimeout
                        }
                        
                        if !message.flags.contains(.Incoming) {
                            if let _ = beginTimeAndTimeout {
                                strongSelf.controllerNode.updatePresentationState({
                                    $0.withUpdatedFooterContentNode(nil)
                                }, transition: .immediate)
                            } else {
                                let contentNode = SecretMediaPreviewFooterContentNode()
                                let peerTitle = messageMainPeer(EngineMessage(message))?.compactDisplayTitle ?? ""
                                let text: String
                                if let file = media as? TelegramMediaFile {
                                    if file.isAnimated {
                                        text = strongSelf.presentationData.strings.SecretGIF_NotViewedYet(peerTitle).string
                                    } else {
                                        text = strongSelf.presentationData.strings.SecretVideo_NotViewedYet(peerTitle).string
                                    }
                                } else {
                                    text = strongSelf.presentationData.strings.SecretImage_NotViewedYet(peerTitle).string
                                }
                                contentNode.setText(text)
                                strongSelf.controllerNode.updatePresentationState({
                                    $0.withUpdatedFooterContentNode(contentNode)
                                }, transition: .immediate)
                            }
                        }
                        hiddenItem = (message.id, media)
                    }
                }
                if strongSelf.didSetReady {
                    strongSelf._hiddenMedia.set(.single(hiddenItem))
                }
            }
        }
        
        if let _ = self.messageView {
            self.applyMessageView()
        }
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if self.screenCaptureEventsDisposable == nil {
            self.screenCaptureEventsDisposable = (screenCaptureEvents()
            |> deliverOnMainQueue).start(next: { [weak self] _ in
                if let strongSelf = self, strongSelf.traceVisibility() {
                    if strongSelf.messageId.peerId.namespace == Namespaces.Peer.CloudUser {
                        let _ = enqueueMessages(account: strongSelf.context.account, peerId: strongSelf.messageId.peerId, messages: [.message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: TelegramMediaAction(action: TelegramMediaActionType.historyScreenshot)), replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]).start()
                    } else if strongSelf.messageId.peerId.namespace == Namespaces.Peer.SecretChat {
                        let _ = strongSelf.context.engine.messages.addSecretChatMessageScreenshot(peerId: strongSelf.messageId.peerId).start()
                    }
                }
            })
        }
        
        var nodeAnimatesItself = false
        
        if let centralItemNode = self.controllerNode.pager.centralItemNode(), let message = self.messageView?.message {
            if let media = mediaForMessage(message: message) {
                if let presentationArguments = self.presentationArguments as? GalleryControllerPresentationArguments, let transitionArguments = presentationArguments.transitionArguments(message.id, media) {
                    nodeAnimatesItself = true
                    centralItemNode.activateAsInitial()
                    
                    if presentationArguments.animated {
                        centralItemNode.animateIn(from: transitionArguments.transitionNode, addToTransitionSurface: transitionArguments.addToTransitionSurface, completion: {})
                    }
                    
                    self._hiddenMedia.set(.single((message.id, media)))
                } else if self.isPresentedInPreviewingContext() {
                    centralItemNode.activateAsInitial()
                }
            }
        }
        
        self.controllerNode.setControlsHidden(false, animated: false)
        if let presentationArguments = self.presentationArguments as? GalleryControllerPresentationArguments {
            if presentationArguments.animated {
                self.controllerNode.animateIn(animateContent: !nodeAnimatesItself, useSimpleAnimation: false)
            }
        }
    }
    
    private func dismiss(forceAway: Bool) {
        var animatedOutNode = true
        var animatedOutInterface = false
        
        let completion = { [weak self] in
            if animatedOutNode && animatedOutInterface {
                self?._hiddenMedia.set(.single(nil))
                self?.presentingViewController?.dismiss(animated: false, completion: nil)
            }
        }
        
        if let centralItemNode = self.controllerNode.pager.centralItemNode(), let presentationArguments = self.presentationArguments as? GalleryControllerPresentationArguments, let message = self.messageView?.message {
            if let media = mediaForMessage(message: message), let transitionArguments = presentationArguments.transitionArguments(message.id, media), !forceAway {
                animatedOutNode = false
                centralItemNode.animateOut(to: transitionArguments.transitionNode, addToTransitionSurface: transitionArguments.addToTransitionSurface, completion: {
                    animatedOutNode = true
                    completion()
                })
            }
        }
        
        self.controllerNode.animateOut(animateContent: animatedOutNode, completion: {
            animatedOutInterface = true
            completion()
        })
    }
    
    private func applyMessageView() {
        var message: Message?
        if let messageView = self.messageView, let m = messageView.message {
            message = m
            for media in m.media {
                if media is TelegramMediaExpiredContent {
                    message = nil
                    break
                }
            }
        }
        if let message = message {
            if self.currentNodeMessageId != message.id {
                self.currentNodeMessageId = message.id
                var tempFilePath: String?
                for media in message.media {
                    if let file = media as? TelegramMediaFile {
                        if let path = self.context.account.postbox.mediaBox.completedResourcePath(file.resource) {
                            let tempFile = TempBox.shared.file(path: path, fileName: file.fileName ?? "file")
                            self.tempFile = tempFile
                            tempFilePath = tempFile.path
                            self.currentNodeMessageIsVideo = true
                        }
                        break
                    }
                }
                
                guard let item = galleryItemForEntry(context: self.context, presentationData: self.presentationData, entry: MessageHistoryEntry(message: message, isRead: false, location: nil, monthLocation: nil, attributes: MutableMessageHistoryEntryAttributes(authorIsContact: false)), streamVideos: false, hideControls: true, isSecret: true, playbackRate: { nil }, tempFilePath: tempFilePath, playbackCompleted: { [weak self] in
                    self?.dismiss(forceAway: false)
                }, present: { _, _ in }) else {
                    self._ready.set(.single(true))
                    return
                }
                
                self.controllerNode.pager.replaceItems([item], centralItemIndex: 0)
                let ready = self.controllerNode.pager.ready() |> timeout(2.0, queue: Queue.mainQueue(), alternate: .single(Void())) |> afterNext { [weak self] _ in
                    self?.didSetReady = true
                }
                self._ready.set(ready |> map { true })
                self.markMessageAsConsumedDisposable.set(self.context.engine.messages.markMessageContentAsConsumedInteractively(messageId: message.id).start())
            } else {
                var beginTimeAndTimeout: (Double, Double)?
                var videoDuration: Double?
                for media in message.media {
                    if let file = media as? TelegramMediaFile {
                        videoDuration = file.duration
                    }
                }
                if let attribute = message.autoclearAttribute {
                    if let countdownBeginTime = attribute.countdownBeginTime {
                        if let videoDuration = videoDuration {
                            beginTimeAndTimeout = (CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970, videoDuration)
                        } else {
                            beginTimeAndTimeout = (Double(countdownBeginTime), Double(attribute.timeout))
                        }
                    }
                } else if let attribute = message.autoremoveAttribute {
                    if let countdownBeginTime = attribute.countdownBeginTime {
                        if let videoDuration = videoDuration {
                            beginTimeAndTimeout = (CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970, videoDuration)
                        } else {
                            beginTimeAndTimeout = (Double(countdownBeginTime), Double(attribute.timeout))
                        }
                    }
                }
                
                if self.isNodeLoaded {
                    if let beginTimeAndTimeout = beginTimeAndTimeout {
                        self.controllerNode.beginTimeAndTimeout = beginTimeAndTimeout
                    }
                }
            }
        } else {
            if !self.didSetReady {
                self._ready.set(.single(true))
            }
            if !(self.currentNodeMessageIsVideo || self.currentNodeMessageIsViewOnce) {
                self.dismiss()
            }
        }
    }
    
    private func presentViewOnceTooltip(sourceView: UIView) {
        if let tooltipController = self.tooltipController {
            self.tooltipController = nil
            tooltipController.dismiss()
        }
        
        let absoluteFrame = sourceView.convert(sourceView.bounds, to: nil)
        let location = CGRect(origin: CGPoint(x: absoluteFrame.midX, y: absoluteFrame.maxY + 2.0), size: CGSize())
        
        let iconName = "anim_autoremove_on"
        let text: String
        if self.currentNodeMessageIsVideo {
            text = "This video can only be viewed once"
        } else {
            text = "This photo can only be viewed once"
        }
        
        let tooltipController = TooltipScreen(
            account: self.context.account,
            sharedContext: self.context.sharedContext,
            text: .plain(text: text),
            balancedTextLayout: true,
            style: .customBlur(UIColor(rgb: 0x18181a), 0.0),
            arrowStyle: .small,
            icon: .animation(name: iconName, delay: 0.1, tintColor: nil),
            location: .point(location, .top),
            displayDuration: .default,
            inset: 8.0,
            shouldDismissOnTouch: { _, _ in
                return .ignore
            }
        )
        self.tooltipController = tooltipController
        self.present(tooltipController, in: .window(.root))
    }
    
    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.controllerNode.frame = CGRect(origin: CGPoint(), size: layout.size)
        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
    
    override public func dismiss(completion: (() -> Void)? = nil) {
        self.presentingViewController?.dismiss(animated: false, completion: completion)
    }
}
