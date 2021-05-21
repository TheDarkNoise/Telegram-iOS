import Foundation
import UIKit
import Display
import QuickLook
import Postbox
import SwiftSignalKit
import AsyncDisplayKit
import TelegramCore
import SyncCore
import Photos
import TelegramPresentationData
import TelegramUIPreferences
import MediaResources
import AccountContext
import ShareController
import GalleryUI
import HexColor
import CounterContollerTitleView
import UndoUI

public enum WallpaperListType {
    case wallpapers(WallpaperPresentationOptions?)
    case colors
}

public enum WallpaperListSource {
    case list(wallpapers: [TelegramWallpaper], central: TelegramWallpaper, type: WallpaperListType)
    case wallpaper(TelegramWallpaper, WallpaperPresentationOptions?, UIColor?, UIColor?, Int32?, Int32?, Message?)
    case slug(String, TelegramMediaFile?, WallpaperPresentationOptions?, UIColor?, UIColor?, Int32?, Int32?, Message?)
    case asset(PHAsset)
    case contextResult(ChatContextResult)
    case customColor(UInt32?)
}

private func areMessagesEqual(_ lhsMessage: Message?, _ rhsMessage: Message?) -> Bool {
    if lhsMessage == nil && rhsMessage == nil {
        return true
    }
    guard let lhsMessage = lhsMessage, let rhsMessage = rhsMessage else {
        return false
    }
    if lhsMessage.stableVersion != rhsMessage.stableVersion {
        return false
    }
    if lhsMessage.id != rhsMessage.id || lhsMessage.flags != rhsMessage.flags {
        return false
    }
    return true
}

public enum WallpaperGalleryEntry: Equatable {
    case wallpaper(TelegramWallpaper, Message?)
    case asset(PHAsset)
    case contextResult(ChatContextResult)
    
    public static func ==(lhs: WallpaperGalleryEntry, rhs: WallpaperGalleryEntry) -> Bool {
        switch lhs {
            case let .wallpaper(lhsWallpaper, lhsMessage):
                if case let .wallpaper(rhsWallpaper, rhsMessage) = rhs, lhsWallpaper == rhsWallpaper, areMessagesEqual(lhsMessage, rhsMessage) {
                    return true
                } else {
                    return false
                }
            case let .asset(lhsAsset):
                if case let .asset(rhsAsset) = rhs, lhsAsset.localIdentifier == rhsAsset.localIdentifier {
                    return true
                } else {
                    return false
                }
            case let .contextResult(lhsResult):
                if case let .contextResult(rhsResult) = rhs, lhsResult.id == rhsResult.id {
                    return true
                } else {
                    return false
                }
        }
    }
}

class WallpaperGalleryOverlayNode: ASDisplayNode {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if result != self.view {
            return result
        } else {
            return nil
        }
    }
}

class WallpaperGalleryControllerNode: GalleryControllerNode {
    var nativeStatusBar: StatusBar?

    override func updateDistanceFromEquilibrium(_ value: CGFloat) {
        guard let itemNode = self.pager.centralItemNode() as? WallpaperGalleryItemNode else {
            return
        }
        
        itemNode.updateDismissTransition(value)
    }

    override func didLoad() {
        super.didLoad()

        //self.view.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(self.longPressGesture(_:))))
    }

    @objc private func longPressGesture(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            self.setControlsHidden(true, animated: false)

            self.overlayNode?.alpha = 0.0
            self.nativeStatusBar?.updateAlpha(0.0, transition: .immediate)

            if let itemNode = self.pager.centralItemNode() as? WallpaperGalleryItemNode {
                itemNode.updateDismissTransition(self.bounds.size.height)
            }
        case .ended, .cancelled:
            self.setControlsHidden(false, animated: false)

            self.overlayNode?.alpha = 1.0
            self.nativeStatusBar?.updateAlpha(1.0, transition: .immediate)

            if let itemNode = self.pager.centralItemNode() as? WallpaperGalleryItemNode {
                itemNode.updateDismissTransition(0.0)
            }
        default:
            break
        }
    }
}

private func updatedFileWallpaper(wallpaper: TelegramWallpaper, firstColor: UIColor?, secondColor: UIColor?, intensity: Int32?, rotation: Int32?) -> TelegramWallpaper {
    if case let .file(file) = wallpaper {
        return updatedFileWallpaper(id: file.id, accessHash: file.accessHash, slug: file.slug, file: file.file, firstColor: firstColor, secondColor: secondColor, intensity: intensity, rotation: rotation)
    } else {
        return wallpaper
    }
}

private func updatedFileWallpaper(id: Int64? = nil, accessHash: Int64? = nil, slug: String, file: TelegramMediaFile, firstColor: UIColor?, secondColor: UIColor?, intensity: Int32?, rotation: Int32?) -> TelegramWallpaper {
    var isPattern = ["image/png", "image/svg+xml", "application/x-tgwallpattern"].contains(file.mimeType)
    if let fileName = file.fileName, fileName.hasSuffix(".svgbg") {
        isPattern = true
    }
    var firstColorValue: UInt32?
    var secondColorValue: UInt32?
    var intensityValue: Int32?
    if let firstColor = firstColor {
        firstColorValue = firstColor.argb
        intensityValue = intensity
    } else if isPattern {
        firstColorValue = 0xd6e2ee
        intensityValue = 50
    }
    if let secondColor = secondColor {
        secondColorValue = secondColor.argb
    }

    var colors: [UInt32] = []
    if let firstColorValue = firstColorValue {
        colors.append(firstColorValue)
    }
    if let secondColorValue = secondColorValue {
        colors.append(secondColorValue)
    }
    
    return .file(id: id ?? 0, accessHash: accessHash ?? 0, isCreator: false, isDefault: false, isPattern: isPattern, isDark: false, slug: slug, file: file, settings: WallpaperSettings(colors: colors, intensity: intensityValue, rotation: rotation))
}

public class WallpaperGalleryController: ViewController {
    private var galleryNode: GalleryControllerNode {
        return self.displayNode as! GalleryControllerNode
    }
    
    private let context: AccountContext
    private let source: WallpaperListSource
    public var apply: ((WallpaperGalleryEntry, WallpaperPresentationOptions, CGRect?) -> Void)?
    
    private let _ready = Promise<Bool>()
    override public var ready: Promise<Bool> {
        return self._ready
    }
    private var didSetReady = false
    
    private let disposable = MetaDisposable()
    
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    
    private var initialOptions: WallpaperPresentationOptions?
    
    private var initialEntries: [WallpaperGalleryEntry] = []
    private var entries: [WallpaperGalleryEntry] = []
    private var centralEntryIndex: Int?
    private var previousCentralEntryIndex: Int?
    
    private let centralItemSubtitle = Promise<String?>()
    private let centralItemStatus = Promise<MediaResourceStatus>()
    private let centralItemAction = Promise<UIBarButtonItem?>()
    private let centralItemAttributesDisposable = DisposableSet();
    
    private var validLayout: (ContainerViewLayout, CGFloat)?
    
    private var overlayNode: WallpaperGalleryOverlayNode?
    private var toolbarNode: WallpaperGalleryToolbarNode?
    private var patternPanelNode: WallpaperPatternPanelNode?
    private var colorsPanelNode: WallpaperColorPanelNode?

    private var patternInitialWallpaper: TelegramWallpaper?
    private var patternPanelEnabled = false
    private var colorsPanelEnabled = false
    
    public init(context: AccountContext, source: WallpaperListSource) {
        self.context = context
        self.source = source
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        
        self.title = self.presentationData.strings.WallpaperPreview_Title
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        
        var entries: [WallpaperGalleryEntry] = []
        var centralEntryIndex: Int?
        
        switch source {
            case let .list(wallpapers, central, type):
                entries = wallpapers.map { .wallpaper($0, nil) }
                centralEntryIndex = wallpapers.firstIndex(of: central)!
                
                if case let .wallpapers(wallpaperOptions) = type, let options = wallpaperOptions {
                    self.initialOptions = options
                }
            case let .slug(slug, file, options, firstColor, secondColor, intensity, rotation, message):
                if let file = file {
                    let wallpaper = updatedFileWallpaper(slug: slug, file: file, firstColor: firstColor, secondColor: secondColor, intensity: intensity, rotation: rotation)
                    entries = [.wallpaper(wallpaper, message)]
                    centralEntryIndex = 0
                    self.initialOptions = options
                }
            case let .wallpaper(wallpaper, options, firstColor, secondColor, intensity, rotation, message):
                let wallpaper = updatedFileWallpaper(wallpaper: wallpaper, firstColor: firstColor, secondColor: secondColor, intensity: intensity, rotation: rotation)
                entries = [.wallpaper(wallpaper, message)]
                centralEntryIndex = 0
                self.initialOptions = options
            case let .asset(asset):
                entries = [.asset(asset)]
                centralEntryIndex = 0
            case let .contextResult(result):
                entries = [.contextResult(result)]
                centralEntryIndex = 0
            case let .customColor(color):
                let initialColor: UInt32 = color ?? 0x000000
                entries = [.wallpaper(.color(initialColor), nil)]
                centralEntryIndex = 0
        }
        
        self.entries = entries
        self.initialEntries = entries
        self.centralEntryIndex = centralEntryIndex
        
        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            if let strongSelf = self {
                let previousTheme = strongSelf.presentationData.theme
                let previousStrings = strongSelf.presentationData.strings
                
                strongSelf.presentationData = presentationData
                if previousTheme !== presentationData.theme || previousStrings !== presentationData.strings {
                    strongSelf.updateThemeAndStrings()
                }
            }
        })
       
        self.centralItemAttributesDisposable.add(self.centralItemSubtitle.get().start(next: { [weak self] subtitle in
            if let strongSelf = self {
                if let subtitle = subtitle {
                    let titleView = CounterContollerTitleView(theme: strongSelf.presentationData.theme)
                    titleView.title = CounterContollerTitle(title: strongSelf.presentationData.strings.WallpaperPreview_Title, counter: subtitle)
                    strongSelf.navigationItem.titleView = titleView
                    strongSelf.title = nil
                } else {
                    strongSelf.navigationItem.titleView = nil
                    strongSelf.title = strongSelf.presentationData.strings.WallpaperPreview_Title
                }
            }
        }))
        
        self.centralItemAttributesDisposable.add(self.centralItemStatus.get().start(next: { [weak self] status in
            if let strongSelf = self {
                let enabled: Bool
                switch status {
                    case .Local:
                        enabled = true
                    default:
                        enabled = false
                }
                strongSelf.toolbarNode?.setDoneEnabled(enabled)
            }
        }))
        
        self.centralItemAttributesDisposable.add(self.centralItemAction.get().start(next: { [weak self] barButton in
            if let strongSelf = self {
                strongSelf.navigationItem.rightBarButtonItem = barButton
            }
        }))
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.disposable.dispose()
        self.presentationDataDisposable?.dispose()
        self.centralItemAttributesDisposable.dispose()
    }
    
    private func updateThemeAndStrings() {
        if self.title != nil {
            self.title = self.presentationData.strings.WallpaperPreview_Title
        }
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: self.presentationData))
        self.toolbarNode?.updateThemeAndStrings(theme: self.presentationData.theme, strings: self.presentationData.strings)
        self.patternPanelNode?.updateTheme(self.presentationData.theme)
        self.patternPanelNode?.backgroundColors = self.presentationData.theme.overallDarkAppearance ? ([self.presentationData.theme.list.blocksBackgroundColor.rgb], nil) : nil

        self.colorsPanelNode?.updateTheme(self.presentationData.theme)
    }
    
    func dismiss(forceAway: Bool) {
        let completion: () -> Void = { [weak self] in
            self?.presentingViewController?.dismiss(animated: false, completion: nil)
        }
        
        self.galleryNode.modalAnimateOut(completion: completion)
    }
    
    private func updateTransaction(entries: [WallpaperGalleryEntry], arguments: WallpaperGalleryItemArguments) -> GalleryPagerTransaction {
        var i: Int = 0
        var updateItems: [GalleryPagerUpdateItem] = []
        for entry in entries {
            let item = GalleryPagerUpdateItem(index: i, previousIndex: i, item: WallpaperGalleryItem(context: self.context, index: updateItems.count, entry: entry, arguments: arguments, source: self.source))
            updateItems.append(item)
            i += 1
        }
        return GalleryPagerTransaction(deleteItems: [], insertItems: [], updateItems: updateItems, focusOnItem: self.galleryNode.pager.centralItemNode()?.index, synchronous: false)
    }

    private func updateCurrentEntryTransaction(entry: WallpaperGalleryEntry, arguments: WallpaperGalleryItemArguments) -> GalleryPagerTransaction {
        var updateItems: [GalleryPagerUpdateItem] = []
        for index in 0 ..< self.entries.count {
            if index == self.centralEntryIndex {
                let item = GalleryPagerUpdateItem(index: index, previousIndex: index, item: WallpaperGalleryItem(context: self.context, index: index, entry: entry, arguments: arguments, source: self.source))
                updateItems.append(item)
            }
        }
        return GalleryPagerTransaction(deleteItems: [], insertItems: [], updateItems: updateItems, focusOnItem: self.galleryNode.pager.centralItemNode()?.index, synchronous: false)
    }
    
    override public func loadDisplayNode() {
        let controllerInteraction = GalleryControllerInteraction(presentController: { [weak self] controller, arguments in
            if let strongSelf = self {
                strongSelf.present(controller, in: .window(.root), with: arguments, blockInteraction: true)
            }
        }, dismissController: { [weak self] in
                self?.dismiss(forceAway: true)
        }, replaceRootController: { controller, ready in
        }, editMedia: { _ in
        })
        self.displayNode = WallpaperGalleryControllerNode(controllerInteraction: controllerInteraction, pageGap: 0.0)
        self.displayNodeDidLoad()

        (self.displayNode as? WallpaperGalleryControllerNode)?.nativeStatusBar = self.statusBar
        
        self.galleryNode.navigationBar = self.navigationBar
        self.galleryNode.dismiss = { [weak self] in
            self?.presentingViewController?.dismiss(animated: false, completion: nil)
        }
        
        self.galleryNode.pager.centralItemIndexUpdated = { [weak self] index in
            if let strongSelf = self {
                strongSelf.bindCentralItemNode(animated: true)
            }
        }
        
        self.galleryNode.backgroundNode.backgroundColor = nil
        self.galleryNode.backgroundNode.isOpaque = false
        self.galleryNode.isBackgroundExtendedOverNavigationBar = true
        
        switch self.source {
            case .asset, .contextResult, .customColor:
                self.galleryNode.scrollView.isScrollEnabled = false
            default:
                break
        }
        
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let overlayNode = WallpaperGalleryOverlayNode()
        self.overlayNode = overlayNode
        self.galleryNode.overlayNode = overlayNode
        self.galleryNode.addSubnode(overlayNode)
        
        var doneButtonType: WallpaperGalleryToolbarDoneButtonType = .set
        switch self.source {
        case let .wallpaper(wallpaper):
            switch wallpaper.0 {
            case let .file(file):
                if file.id == 0 {
                    doneButtonType = .none
                }
            default:
                break
            }
        default:
            break
        }
                
        let toolbarNode = WallpaperGalleryToolbarNode(theme: presentationData.theme, strings: presentationData.strings, doneButtonType: doneButtonType)
        self.toolbarNode = toolbarNode
        overlayNode.addSubnode(toolbarNode)
        
        toolbarNode.cancel = { [weak self] in
            self?.dismiss(forceAway: true)
        }
        var dismissed = false
        toolbarNode.done = { [weak self] in
            if let strongSelf = self, !dismissed {
                dismissed = true
                if let centralItemNode = strongSelf.galleryNode.pager.centralItemNode() as? WallpaperGalleryItemNode {
                    let options = centralItemNode.options
                    let gradientColors = centralItemNode.colors
                    if !strongSelf.entries.isEmpty {
                        let entry = strongSelf.entries[centralItemNode.index]
                        switch entry {
                            case let .wallpaper(wallpaper, _):
                                var resource: MediaResource?
                                switch wallpaper {
                                    case let .file(file):
                                        resource = file.file.resource
                                    case let .image(representations, _):
                                        if let largestSize = largestImageRepresentation(representations) {
                                            resource = largestSize.resource
                                        }
                                    default:
                                        break
                                }
                                
                                let completion: (TelegramWallpaper) -> Void = { wallpaper in
                                    let baseSettings = wallpaper.settings
                                    let updatedSettings = WallpaperSettings(blur: options.contains(.blur), motion: options.contains(.motion), colors: baseSettings?.colors ?? [], intensity: baseSettings?.intensity)
                                    let wallpaper = wallpaper.withUpdatedSettings(updatedSettings)
                                    
                                    let autoNightModeTriggered = strongSelf.presentationData.autoNightModeTriggered
                                    let _ = (updatePresentationThemeSettingsInteractively(accountManager: strongSelf.context.sharedContext.accountManager, { current in
                                        var themeSpecificChatWallpapers = current.themeSpecificChatWallpapers
                                        let wallpaper = wallpaper.isBasicallyEqual(to: strongSelf.presentationData.theme.chat.defaultWallpaper) ? nil : wallpaper
                                        let themeReference: PresentationThemeReference
                                        if autoNightModeTriggered {
                                            themeReference = current.automaticThemeSwitchSetting.theme
                                        } else {
                                            themeReference = current.theme
                                        }
                                        let accentColor = current.themeSpecificAccentColors[themeReference.index]
                                        if let accentColor = accentColor, accentColor.baseColor == .custom {
                                            themeSpecificChatWallpapers[coloredThemeIndex(reference: themeReference, accentColor: accentColor)] = wallpaper
                                        } else {
                                            themeSpecificChatWallpapers[coloredThemeIndex(reference: themeReference, accentColor: accentColor)] = nil
                                            themeSpecificChatWallpapers[themeReference.index] = wallpaper
                                        }
                                        return current.withUpdatedThemeSpecificChatWallpapers(themeSpecificChatWallpapers)
                                    }) |> deliverOnMainQueue).start(completed: {
                                        self?.dismiss(forceAway: true)
                                    })
                                
                                    switch strongSelf.source {
                                        case .wallpaper, .slug:
                                            let _ = saveWallpaper(account: strongSelf.context.account, wallpaper: wallpaper).start()
                                        default:
                                            break
                                    }
                                    let _ = installWallpaper(account: strongSelf.context.account, wallpaper: wallpaper).start()
                                }
                                
                                let applyWallpaper: (TelegramWallpaper) -> Void = { wallpaper in
                                    if options.contains(.blur) {
                                        if let resource = resource {
                                            let representation = CachedBlurredWallpaperRepresentation()

                                            var data: Data?
                                            if let path = strongSelf.context.account.postbox.mediaBox.completedResourcePath(resource), let maybeData = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedRead) {
                                                data = maybeData
                                            } else if let path = strongSelf.context.sharedContext.accountManager.mediaBox.completedResourcePath(resource), let maybeData = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedRead) {
                                                data = maybeData
                                            }
                                            
                                            if let data = data {
                                                strongSelf.context.sharedContext.accountManager.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
                                                let _ = (strongSelf.context.sharedContext.accountManager.mediaBox.cachedResourceRepresentation(resource, representation: representation, complete: true, fetch: true)
                                                |> filter({ $0.complete })
                                                |> take(1)
                                                |> deliverOnMainQueue).start(next: { _ in
                                                    completion(wallpaper)
                                                })
                                            }
                                        }
                                    } else if case let .file(file) = wallpaper, let resource = resource {
                                        if wallpaper.isPattern, !file.settings.colors.isEmpty, let intensity = file.settings.intensity {
                                            let representation = CachedPatternWallpaperRepresentation(color: file.settings.colors[0], bottomColor: file.settings.colors.count >= 2 ? file.settings.colors[1] : file.settings.colors[0], intensity: intensity, rotation: file.settings.rotation)
                                            
                                            var data: Data?
                                            if let path = strongSelf.context.account.postbox.mediaBox.completedResourcePath(resource), let maybeData = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedRead) {
                                                data = maybeData
                                            } else if let path = strongSelf.context.sharedContext.accountManager.mediaBox.completedResourcePath(resource), let maybeData = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedRead) {
                                                data = maybeData
                                            }
                                            
                                            if let data = data {
                                                strongSelf.context.sharedContext.accountManager.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
                                                let _ = (strongSelf.context.sharedContext.accountManager.mediaBox.cachedResourceRepresentation(resource, representation: representation, complete: true, fetch: true)
                                                |> filter({ $0.complete })
                                                |> take(1)
                                                |> deliverOnMainQueue).start(next: { _ in
                                                    completion(wallpaper)
                                                })
                                            }
                                        } else if let path = strongSelf.context.account.postbox.mediaBox.completedResourcePath(file.file.resource), let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedRead) {
                                                strongSelf.context.sharedContext.accountManager.mediaBox.storeResourceData(file.file.resource.id, data: data)
                                                completion(wallpaper)
                                        }
                                    } else {
                                        completion(wallpaper)
                                    }
                                }
                            
                                if case let .image(currentRepresentations, currentSettings) = wallpaper {
                                    let _ = (strongSelf.context.wallpaperUploadManager!.stateSignal()
                                    |> take(1)
                                    |> deliverOnMainQueue).start(next: { status in
                                        switch status {
                                            case let .uploaded(uploadedWallpaper, resultWallpaper):
                                                if case let .image(uploadedRepresentations, _) = uploadedWallpaper, uploadedRepresentations == currentRepresentations {
                                                    let updatedWallpaper = resultWallpaper.withUpdatedSettings(currentSettings)
                                                    applyWallpaper(updatedWallpaper)
                                                    return
                                                }
                                            case let .uploading(uploadedWallpaper, _):
                                                if case let .image(uploadedRepresentations, uploadedSettings) = uploadedWallpaper, uploadedRepresentations == currentRepresentations, uploadedSettings != currentSettings {
                                                    let updatedWallpaper = uploadedWallpaper.withUpdatedSettings(currentSettings)
                                                    applyWallpaper(updatedWallpaper)
                                                    return
                                                }
                                            default:
                                                break
                                        }
                                        applyWallpaper(wallpaper)
                                    })
                                } else {
                                    var updatedWallpaper = wallpaper
                                    if var settings = wallpaper.settings {
                                        settings.motion = options.contains(.motion)
                                        updatedWallpaper = updatedWallpaper.withUpdatedSettings(settings)
                                    }
                                    applyWallpaper(updatedWallpaper)
                                }
                            default:
                                break
                        }

                        strongSelf.apply?(entry, options, centralItemNode.cropRect)
                    }
                }
            }
        }
        
        let ready = self.galleryNode.pager.ready() |> timeout(2.0, queue: Queue.mainQueue(), alternate: .single(Void())) |> afterNext { [weak self] _ in
            self?.didSetReady = true
        }
        self._ready.set(ready |> map { true })
    }
    
    private func currentEntry() -> WallpaperGalleryEntry? {
        if let centralItemNode = self.galleryNode.pager.centralItemNode() as? WallpaperGalleryItemNode {
            return centralItemNode.entry
        } else if let centralEntryIndex = self.centralEntryIndex {
            return self.entries[centralEntryIndex]
        } else {
            return nil
        }
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.galleryNode.modalAnimateIn()
        self.bindCentralItemNode(animated: false)
    }
    
    private func bindCentralItemNode(animated: Bool) {
        if let node = self.galleryNode.pager.centralItemNode() as? WallpaperGalleryItemNode {
            self.centralItemSubtitle.set(node.subtitle.get())
            self.centralItemStatus.set(node.status.get())
            self.centralItemAction.set(node.actionButton.get())
            node.action = { [weak self] in
                self?.actionPressed()
            }
            node.requestPatternPanel = { [weak self] enabled, initialWallpaper in
                if let strongSelf = self, let (layout, _) = strongSelf.validLayout {
                    strongSelf.colorsPanelEnabled = false

                    strongSelf.patternInitialWallpaper = enabled ? initialWallpaper : nil
                    strongSelf.patternPanelEnabled = enabled
                    strongSelf.galleryNode.scrollView.isScrollEnabled = !enabled
                    if enabled {
                        strongSelf.patternPanelNode?.didAppear()
                    } else {
                        switch initialWallpaper {
                        case .color:
                            strongSelf.updateEntries(pattern: .color(0), preview: false)
                        default:
                            break
                        }
                    }
                    strongSelf.containerLayoutUpdated(layout, transition: .animated(duration: 0.3, curve: .spring))
                }
            }

            node.requestColorsPanel = { [weak self] colors in
                if let strongSelf = self, let (layout, _) = strongSelf.validLayout {
                    strongSelf.patternPanelEnabled = false
                    strongSelf.colorsPanelEnabled = colors != nil
                    strongSelf.galleryNode.scrollView.isScrollEnabled = colors == nil
                    if let colors = colors {
                        strongSelf.colorsPanelNode?.updateState({ _ in
                            return WallpaperColorPanelNodeState(
                                selection: 0,
                                colors: colors.map(\.rgb),
                                maximumNumberOfColors: 4,
                                rotateAvailable: false,
                                rotation: 0,
                                preview: false,
                                simpleGradientGeneration: false
                            )
                        }, animated: false)
                    } else {
                        //strongSelf.updateEntries(pattern: .color(0), preview: false)
                    }
                    strongSelf.containerLayoutUpdated(layout, transition: .animated(duration: 0.3, curve: .spring))
                }
            }
            
            if let entry = self.currentEntry(), case let .wallpaper(wallpaper, _) = entry, case let .file(_, _, _, _, true, _, _, _ , settings) = wallpaper, !settings.colors.isEmpty {
                if self.patternPanelNode?.backgroundColors != nil, let snapshotView = self.patternPanelNode?.scrollNode.view.snapshotContentTree() {
                    self.patternPanelNode?.view.addSubview(snapshotView)
                    snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false) { [weak snapshotView] _ in
                        snapshotView?.removeFromSuperview()
                    }
                }
                self.patternPanelNode?.backgroundColors = ([settings.colors[0]], nil)
            }
        }
    }
    
    private func updateEntries(color: UIColor, preview: Bool = false) {
        guard self.validLayout != nil, let centralEntryIndex = self.galleryNode.pager.centralItemNode()?.index else {
            return
        }
        
        var entries = self.entries
        var currentEntry = entries[centralEntryIndex]
        switch currentEntry {
            case let .wallpaper(wallpaper, _):
                switch wallpaper {
                    case .color:
                        currentEntry = .wallpaper(.color(color.argb), nil)
                    default:
                        break
                }
            default:
                break
        }
        entries[centralEntryIndex] = currentEntry
        self.entries = entries
        
        self.galleryNode.pager.transaction(self.updateTransaction(entries: entries, arguments: WallpaperGalleryItemArguments(colorPreview: preview, isColorsList: false, patternEnabled: self.patternPanelEnabled)))
    }

    private func updateEntries(wallpaper: TelegramWallpaper, preview: Bool = false) {
        guard self.validLayout != nil, let centralEntryIndex = self.galleryNode.pager.centralItemNode()?.index else {
            return
        }

        var entries = self.entries
        var currentEntry = entries[centralEntryIndex]
        switch currentEntry {
            case .wallpaper:
                currentEntry = .wallpaper(wallpaper, nil)
            default:
                break
        }
        entries[centralEntryIndex] = currentEntry
        self.entries = entries

        self.galleryNode.pager.transaction(self.updateCurrentEntryTransaction(entry: currentEntry, arguments: WallpaperGalleryItemArguments(colorPreview: preview, isColorsList: false, patternEnabled: self.patternPanelEnabled)))
    }
    
    private func updateEntries(pattern: TelegramWallpaper?, intensity: Int32? = nil, preview: Bool = false) {
        var updatedEntries: [WallpaperGalleryEntry] = []
        for entry in self.entries {
            var entryColor: UInt32?
            if case let .wallpaper(wallpaper, _) = entry {
                if case let .color(color) = wallpaper {
                    entryColor = color
                } else if case let .file(file) = wallpaper {
                    entryColor = file.settings.colors.first
                }
            }
            
            if let entryColor = entryColor {
                if let pattern = pattern, case let .file(file) = pattern {
                    let newSettings = WallpaperSettings(blur: file.settings.blur, motion: file.settings.motion, colors: [entryColor], intensity: intensity)
                    let newWallpaper = TelegramWallpaper.file(id: file.id, accessHash: file.accessHash, isCreator: file.isCreator, isDefault: file.isDefault, isPattern: pattern.isPattern, isDark: file.isDark, slug: file.slug, file: file.file, settings: newSettings)
                    updatedEntries.append(.wallpaper(newWallpaper, nil))
                } else {
                    let newWallpaper = TelegramWallpaper.color(entryColor)
                    updatedEntries.append(.wallpaper(newWallpaper, nil))
                }
            }
        }
        
        self.entries = updatedEntries
        self.galleryNode.pager.transaction(self.updateTransaction(entries: updatedEntries, arguments: WallpaperGalleryItemArguments(colorPreview: preview, isColorsList: true, patternEnabled: self.patternPanelEnabled)))
    }
    
   
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        let hadLayout = self.validLayout != nil
        
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.galleryNode.frame = CGRect(origin: CGPoint(), size: layout.size)
        self.galleryNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
        self.overlayNode?.frame = self.galleryNode.bounds
        
        transition.updateFrame(node: self.toolbarNode!, frame: CGRect(origin: CGPoint(x: 0.0, y: layout.size.height - 49.0 - layout.intrinsicInsets.bottom), size: CGSize(width: layout.size.width, height: 49.0 + layout.intrinsicInsets.bottom)))
        self.toolbarNode!.updateLayout(size: CGSize(width: layout.size.width, height: 49.0), layout: layout, transition: transition)
        
        var bottomInset = layout.intrinsicInsets.bottom + 49.0
        
        let currentPatternPanelNode: WallpaperPatternPanelNode
        if let patternPanelNode = self.patternPanelNode {
            currentPatternPanelNode = patternPanelNode
        } else {
            let patternPanelNode = WallpaperPatternPanelNode(context: self.context, theme: presentationData.theme, strings: presentationData.strings)
            patternPanelNode.patternChanged = { [weak self] pattern, intensity, preview in
                if let strongSelf = self, strongSelf.validLayout != nil, let patternInitialWallpaper = strongSelf.patternInitialWallpaper {
                    switch patternInitialWallpaper {
                    case .color:
                        strongSelf.updateEntries(pattern: pattern, intensity: intensity, preview: preview)
                    default:
                        break
                    }
                }
            }
            patternPanelNode.backgroundColors = self.presentationData.theme.overallDarkAppearance ? ([self.presentationData.theme.list.blocksBackgroundColor.rgb], nil) : nil
            self.patternPanelNode = patternPanelNode
            currentPatternPanelNode = patternPanelNode
            self.overlayNode?.insertSubnode(patternPanelNode, belowSubnode: self.toolbarNode!)
        }

        let currentColorsPanelNode: WallpaperColorPanelNode
        if let current = self.colorsPanelNode {
            currentColorsPanelNode = current
        } else {
            let colorsPanelNode = WallpaperColorPanelNode(theme: self.presentationData.theme, strings: self.presentationData.strings)
            self.colorsPanelNode = colorsPanelNode
            currentColorsPanelNode = colorsPanelNode
            self.overlayNode?.insertSubnode(colorsPanelNode, belowSubnode: self.toolbarNode!)

            colorsPanelNode.colorsChanged = { [weak self] colors, _ in
                guard let strongSelf = self else {
                    return
                }
                guard let entry = strongSelf.currentEntry(), case let .wallpaper(currentWallpaper, _) = entry else {
                    return
                }

                var wallpaper: TelegramWallpaper = .gradient(colors, WallpaperSettings(blur: false, motion: false, colors: [], intensity: nil, rotation: nil))

                if case .file = currentWallpaper {
                    wallpaper = currentWallpaper.withUpdatedSettings(WallpaperSettings(blur: false, motion: false, colors: colors, intensity: nil, rotation: nil))
                }

                strongSelf.updateEntries(wallpaper: wallpaper)
            }
        }
        
        let panelHeight: CGFloat = 235.0

        var patternPanelFrame = CGRect(x: 0.0, y: layout.size.height, width: layout.size.width, height: panelHeight)
        if self.patternPanelEnabled {
            patternPanelFrame.origin = CGPoint(x: 0.0, y: layout.size.height - bottomInset - panelHeight)
            bottomInset += panelHeight
        }
        
        transition.updateFrame(node: currentPatternPanelNode, frame: patternPanelFrame)
        currentPatternPanelNode.updateLayout(size: patternPanelFrame.size, transition: transition)

        var colorsPanelFrame = CGRect(x: 0.0, y: layout.size.height, width: layout.size.width, height: panelHeight)
        if self.colorsPanelEnabled {
            colorsPanelFrame.origin = CGPoint(x: 0.0, y: layout.size.height - bottomInset - panelHeight)
            bottomInset += panelHeight
        }

        transition.updateFrame(node: currentColorsPanelNode, frame: colorsPanelFrame)
        currentColorsPanelNode.updateLayout(size: colorsPanelFrame.size, transition: transition)

        bottomInset += 66.0
        
        self.validLayout = (layout, bottomInset)
        if !hadLayout {
            var colors = false
            if case let .list(_, _, type) = self.source, case .colors = type {
                colors = true
            }
            
            self.galleryNode.pager.replaceItems(zip(0 ..< self.entries.count, self.entries).map({ WallpaperGalleryItem(context: self.context, index: $0, entry: $1, arguments: WallpaperGalleryItemArguments(isColorsList: colors), source: self.source) }), centralItemIndex: self.centralEntryIndex)
            
            if let initialOptions = self.initialOptions, let itemNode = self.galleryNode.pager.centralItemNode() as? WallpaperGalleryItemNode {
                itemNode.options = initialOptions
            }
        }
    }
    
    private func actionPressed() {
        guard let entry = self.currentEntry(), case let .wallpaper(wallpaper, _) = entry, let itemNode = self.galleryNode.pager.centralItemNode() as? WallpaperGalleryItemNode else {
            return
        }
        
        var controller: ShareController?
        var options: [String] = []
        if (itemNode.options.contains(.blur)) {
            if (itemNode.options.contains(.motion)) {
                options.append("mode=blur+motion")
            } else {
                options.append("mode=blur")
            }
        } else if (itemNode.options.contains(.motion)) {
            options.append("mode=motion")
        }
        
        let context = self.context
        switch wallpaper {
            case .image:
                let _ = (context.wallpaperUploadManager!.stateSignal()
                |> take(1)
                |> filter { status -> Bool in
                    return status.wallpaper == wallpaper
                }).start(next: { [weak self] status in
                    if case let .uploaded(uploadedWallpaper, resultWallpaper) = status, uploadedWallpaper == wallpaper, case let .file(file) = resultWallpaper {
                        var optionsString = ""
                        if !options.isEmpty {
                            optionsString = "?\(options.joined(separator: "&"))"
                        }
                        
                        let shareController = ShareController(context: context, subject: .url("https://t.me/bg/\(file.slug)\(optionsString)"))
                        shareController.actionCompleted = { [weak self] in
                            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                            self?.present(UndoOverlayController(presentationData: presentationData, content: .linkCopied(text: presentationData.strings.Conversation_LinkCopied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
                        }
                        self?.present(shareController, in: .window(.root), blockInteraction: true)
                    }
                })
            case let .file(_, _, _, _, isPattern, _, slug, _, settings):
                if isPattern {
                    if !settings.colors.isEmpty {
                        if settings.colors.count >= 2 {
                            options.append("bg_color=\(UIColor(rgb: settings.colors[0]).hexString)-\(UIColor(rgb: settings.colors[1]).hexString)")
                        } else {
                            options.append("bg_color=\(UIColor(rgb: settings.colors[0]).hexString)")
                        }
                    }
                    if let intensity = settings.intensity {
                        options.append("intensity=\(intensity)")
                    }
                    if let rotation = settings.rotation {
                        options.append("rotation=\(rotation)")
                    }
                }
                
                var optionsString = ""
                if !options.isEmpty {
                    optionsString = "?\(options.joined(separator: "&"))"
                }
                
                controller = ShareController(context: context, subject: .url("https://t.me/bg/\(slug)\(optionsString)"))
            case let .color(color):
                controller = ShareController(context: context, subject: .url("https://t.me/bg/\(UIColor(rgb: color).hexString)"))
            case let .gradient(colors, _):
                controller = ShareController(context: context, subject:. url("https://t.me/bg/\(UIColor(rgb: colors[0]).hexString)-\(UIColor(rgb: colors[1]).hexString)"))
            default:
                break
        }
        if let controller = controller {
            controller.actionCompleted = { [weak self] in
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                self?.present(UndoOverlayController(presentationData: presentationData, content: .linkCopied(text: presentationData.strings.Conversation_LinkCopied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
            }
            self.present(controller, in: .window(.root), blockInteraction: true)
        }
    }
}

private extension GalleryControllerNode {
    func modalAnimateIn(completion: (() -> Void)? = nil) {
        self.layer.animatePosition(from: CGPoint(x: self.layer.position.x, y: self.layer.position.y + self.layer.bounds.size.height), to: self.layer.position, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
    }
    
    func modalAnimateOut(completion: (() -> Void)? = nil) {
        self.layer.animatePosition(from: self.layer.position, to: CGPoint(x: self.layer.position.x, y: self.layer.position.y + self.layer.bounds.size.height), duration: 0.2, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, completion: { _ in
            completion?()
        })
    }
}
