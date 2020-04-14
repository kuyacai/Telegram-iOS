import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore
import SyncCore
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences
import MergeLists
import StickerPackPreviewUI
import OverlayStatusController
import PresentationDataUtils
import SearchBarNode
import UndoUI

private final class FeaturedInteraction {
    let installPack: (ItemCollectionInfo, Bool) -> Void
    let openPack: (ItemCollectionInfo) -> Void
    let getItemIsPreviewed: (StickerPackItem) -> Bool
    let openSearch: () -> Void
    
    init(installPack: @escaping (ItemCollectionInfo, Bool) -> Void, openPack: @escaping (ItemCollectionInfo) -> Void, getItemIsPreviewed: @escaping (StickerPackItem) -> Bool, openSearch: @escaping () -> Void) {
        self.installPack = installPack
        self.openPack = openPack
        self.getItemIsPreviewed = getItemIsPreviewed
        self.openSearch = openSearch
    }
}

private final class FeaturedPackEntry: Identifiable, Comparable {
    let index: Int
    let info: StickerPackCollectionInfo
    let theme: PresentationTheme
    let strings: PresentationStrings
    let topItems: [StickerPackItem]
    let installed: Bool
    let unread: Bool
    let topSeparator: Bool
    
    init(index: Int, info: StickerPackCollectionInfo, theme: PresentationTheme, strings: PresentationStrings, topItems: [StickerPackItem], installed: Bool, unread: Bool, topSeparator: Bool) {
        self.index = index
        self.info = info
        self.theme = theme
        self.strings = strings
        self.topItems = topItems
        self.installed = installed
        self.unread = unread
        self.topSeparator = topSeparator
    }
    
    var stableId: ItemCollectionId {
        return self.info.id
    }
    
    static func ==(lhs: FeaturedPackEntry, rhs: FeaturedPackEntry) -> Bool {
        if lhs.index != rhs.index {
            return false
        }
        if lhs.info != rhs.info {
            return false
        }
        if lhs.theme !== rhs.theme {
            return false
        }
        if lhs.strings !== rhs.strings {
            return false
        }
        if lhs.topItems != rhs.topItems {
            return false
        }
        if lhs.installed != rhs.installed {
            return false
        }
        if lhs.unread != rhs.unread {
            return false
        }
        if lhs.topSeparator != rhs.topSeparator {
            return false
        }
        return true
    }
    
    static func <(lhs: FeaturedPackEntry, rhs: FeaturedPackEntry) -> Bool {
        return lhs.index < rhs.index
    }
    
    func item(account: Account, interaction: FeaturedInteraction, grid: Bool) -> GridItem {
        let info = self.info
        return StickerPaneSearchGlobalItem(account: account, theme: self.theme, strings: self.strings, info: self.info, topItems: self.topItems, grid: grid, topSeparator: self.topSeparator, installed: self.installed, unread: self.unread, open: {
            interaction.openPack(info)
        }, install: {
            interaction.installPack(info, !self.installed)
        }, getItemIsPreviewed: { item in
            return interaction.getItemIsPreviewed(item)
        })
    }
}

private enum FeaturedEntryId: Hashable {
    case search
    case pack(ItemCollectionId)
}

private enum FeaturedEntry: Identifiable, Comparable {
    case search(theme: PresentationTheme, strings: PresentationStrings)
    case pack(FeaturedPackEntry)
    
    var stableId: FeaturedEntryId {
        switch self {
        case .search:
            return .search
        case let .pack(pack):
            return .pack(pack.stableId)
        }
    }
    
    static func ==(lhs: FeaturedEntry, rhs: FeaturedEntry) -> Bool {
        switch lhs {
        case let .search(lhsTheme, lhsStrings):
            if case let .search(rhsTheme, rhsStrings) = rhs, lhsTheme === rhsTheme, lhsStrings === rhsStrings {
                return true
            } else {
                return false
            }
        case let .pack(pack):
            if case .pack(pack) = rhs {
                return true
            } else {
                return false
            }
        }
    }
    
    static func <(lhs: FeaturedEntry, rhs: FeaturedEntry) -> Bool {
        switch lhs {
        case .search:
            return false
        case let .pack(lhsPack):
            switch rhs {
            case .search:
                return false
            case let .pack(rhsPack):
                return lhsPack < rhsPack
            }
        }
    }
    
    func item(account: Account, interaction: FeaturedInteraction, grid: Bool) -> GridItem {
        switch self {
        case let .search(theme, strings):
            return PaneSearchBarPlaceholderItem(theme: theme, strings: strings, type: .stickers, activate: {
                interaction.openSearch()
            })
        case let .pack(pack):
            return pack.item(account: account, interaction: interaction, grid: grid)
        }
    }
}

private struct FeaturedTransition {
    let deletions: [Int]
    let insertions: [GridNodeInsertItem]
    let updates: [GridNodeUpdateItem]
    let initial: Bool
}

private func preparedTransition(from fromEntries: [FeaturedEntry], to toEntries: [FeaturedEntry], account: Account, interaction: FeaturedInteraction, initial: Bool) -> FeaturedTransition {
    let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: fromEntries, rightList: toEntries)
    
    let deletions = deleteIndices
    let insertions = indicesAndItems.map { GridNodeInsertItem(index: $0.0, item: $0.1.item(account: account, interaction: interaction, grid: false), previousIndex: $0.2) }
    let updates = updateIndices.map { GridNodeUpdateItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(account: account, interaction: interaction, grid: false)) }
    
    return FeaturedTransition(deletions: deletions, insertions: insertions, updates: updates, initial: initial)
}

private func featuredScreenEntries(featuredEntries: [FeaturedStickerPackItem], installedPacks: Set<ItemCollectionId>, theme: PresentationTheme, strings: PresentationStrings, fixedUnread: Set<ItemCollectionId>) -> [FeaturedEntry] {
    var result: [FeaturedEntry] = []
    var index = 0
    for item in featuredEntries {
        result.append(.pack(FeaturedPackEntry(index: index, info: item.info, theme: theme, strings: strings, topItems: item.topItems, installed: installedPacks.contains(item.info.id), unread: item.unread || fixedUnread.contains(item.info.id), topSeparator: index != 0)))
        index += 1
    }
    return result
}

private final class FeaturedStickersScreenNode: ViewControllerTracingNode {
    private let context: AccountContext
    private var presentationData: PresentationData
    private weak var controller: FeaturedStickersScreen?
    private let sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)?
    
    let gridNode: GridNode
    
    private var enqueuedTransitions: [FeaturedTransition] = []
    
    private var validLayout: ContainerViewLayout?
    
    private var disposable: Disposable?
    private let installDisposable = MetaDisposable()
    
    private var searchNode: FeaturedPaneSearchContentNode?
    
    private let _ready = Promise<Bool>()
    var ready: Promise<Bool> {
        return self._ready
    }
    private var didSetReady: Bool = false
    
    init(context: AccountContext, controller: FeaturedStickersScreen, sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)?) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.controller = controller
        self.sendSticker = sendSticker
        
        self.gridNode = GridNode()
        
        super.init()
        
        self.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        
        self.addSubnode(self.gridNode)
        
        self.gridNode.scrollingInitiated = { [weak self] in
            self?.view.endEditing(true)
        }
        
        var processedRead = Set<ItemCollectionId>()
        
        self.gridNode.visibleItemsUpdated = { [weak self] visibleItems in
            guard let strongSelf = self else {
                return
            }
            if let (topIndex, _) = visibleItems.topVisible, let (bottomIndex, _) = visibleItems.bottomVisible {
                var addedRead: [ItemCollectionId] = []
                for i in topIndex ... bottomIndex {
                    if i >= 0 && i < strongSelf.gridNode.items.count {
                        let item = strongSelf.gridNode.items[i]
                        if let item = item as? StickerPaneSearchGlobalItem, item.unread {
                            let info = item.info
                            if !processedRead.contains(info.id) {
                                processedRead.insert(info.id)
                                addedRead.append(info.id)
                            }
                        }
                    }
                }
                if !addedRead.isEmpty {
                    let _ = markFeaturedStickerPacksAsSeenInteractively(postbox: strongSelf.context.account.postbox, ids: addedRead).start()
                }
            }
        }
        
        let inputNodeInteraction = ChatMediaInputNodeInteraction(
            navigateToCollectionId: { _ in
            },
            openSettings: {
            },
            toggleSearch: { _, _ in
            },
            openPeerSpecificSettings: {
            },
            dismissPeerSpecificSettings: {
            },
            clearRecentlyUsedStickers: {
            }
        )
        
        self.searchNode = FeaturedPaneSearchContentNode(
            context: context,
            theme: self.presentationData.theme,
            strings: self.presentationData.strings,
            inputNodeInteraction: inputNodeInteraction,
            controller: controller,
            sendSticker: sendSticker
        )
        self.searchNode?.updateActivity = { [weak self] activity in
            self?.controller?.searchNavigationNode?.setActivity(activity)
        }
        
        let interaction = FeaturedInteraction(
            installPack: { [weak self] info, install in
                guard let strongSelf = self, let info = info as? StickerPackCollectionInfo else {
                    return
                }
                let account = strongSelf.context.account
                if install {
                    var installSignal = loadedStickerPack(postbox: strongSelf.context.account.postbox, network: strongSelf.context.account.network, reference: .id(id: info.id.id, accessHash: info.accessHash), forceActualized: false)
                    |> mapToSignal { result -> Signal<(StickerPackCollectionInfo, [ItemCollectionItem]), NoError> in
                        switch result {
                        case let .result(info, items, installed):
                            if installed {
                                return .complete()
                            } else {
                                return preloadedStickerPackThumbnail(account: account, info: info, items: items)
                                |> filter { $0 }
                                |> ignoreValues
                                |> then(
                                    addStickerPackInteractively(postbox: strongSelf.context.account.postbox, info: info, items: items)
                                    |> ignoreValues
                                )
                                |> mapToSignal { _ -> Signal<(StickerPackCollectionInfo, [ItemCollectionItem]), NoError> in
                                }
                                |> then(.single((info, items)))
                            }
                        case .fetching:
                            break
                        case .none:
                            break
                        }
                        return .complete()
                    }
                    |> deliverOnMainQueue
                    
                    let context = strongSelf.context
                    var cancelImpl: (() -> Void)?
                    let progressSignal = Signal<Never, NoError> { subscriber in
                        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                        let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
                            cancelImpl?()
                        }))
                        self?.controller?.present(controller, in: .window(.root))
                        return ActionDisposable { [weak controller] in
                            Queue.mainQueue().async() {
                                controller?.dismiss()
                            }
                        }
                    }
                    |> runOn(Queue.mainQueue())
                    |> delay(1.0, queue: Queue.mainQueue())
                    let progressDisposable = progressSignal.start()
                    
                    installSignal = installSignal
                    |> afterDisposed {
                        Queue.mainQueue().async {
                            progressDisposable.dispose()
                        }
                    }
                    cancelImpl = {
                        self?.installDisposable.set(nil)
                    }
                        
                    strongSelf.installDisposable.set(installSignal.start(next: { info, items in
                        guard let strongSelf = self else {
                            return
                        }
                        
                        /*var animateInAsReplacement = false
                        if let navigationController = strongSelf.controllerInteraction.navigationController() {
                            for controller in navigationController.overlayControllers {
                                if let controller = controller as? UndoOverlayController {
                                    controller.dismissWithCommitActionAndReplacementAnimation()
                                    animateInAsReplacement = true
                                }
                            }
                        }
                        
                        let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                        strongSelf.controllerInteraction.navigationController()?.presentOverlay(controller: UndoOverlayController(presentationData: presentationData, content: .stickersModified(title: presentationData.strings.StickerPackActionInfo_AddedTitle, text: presentationData.strings.StickerPackActionInfo_AddedText(info.title).0, undo: false, info: info, topItem: items.first, account: strongSelf.context.account), elevatedLayout: false, animateInAsReplacement: animateInAsReplacement, action: { _ in
                            return true
                        }))*/
                    }))
                } else {
                    let _ = (removeStickerPackInteractively(postbox: account.postbox, id: info.id, option: .delete)
                    |> deliverOnMainQueue).start(next: { _ in
                    })
                }
            },
            openPack: { [weak self] info in
                if let strongSelf = self, let info = info as? StickerPackCollectionInfo {
                    strongSelf.view.window?.endEditing(true)
                    let packReference: StickerPackReference = .id(id: info.id.id, accessHash: info.accessHash)
                    let controller = StickerPackScreen(context: strongSelf.context, mainStickerPack: packReference, stickerPacks: [packReference], parentNavigationController: strongSelf.controller?.navigationController as? NavigationController, sendSticker: { fileReference, sourceNode, sourceRect in
                        if let strongSelf = self {
                            return strongSelf.sendSticker?(fileReference, sourceNode, sourceRect) ?? false
                        } else {
                            return false
                        }
                    })
                    strongSelf.controller?.present(controller, in: .window(.root))
                }
            },
            getItemIsPreviewed: { item in
                return false
            },
            openSearch: {
            }
        )
        
        let previousEntries = Atomic<[FeaturedEntry]?>(value: nil)
        let context = self.context
        
        var fixedUnread = Set<ItemCollectionId>()
        
        let mappedFeatured = context.account.viewTracker.featuredStickerPacks()
        |> map { items -> ([FeaturedStickerPackItem], Set<ItemCollectionId>) in
            for item in items {
                if item.unread {
                    fixedUnread.insert(item.info.id)
                }
            }
            return (items, fixedUnread)
        }
        
        self.disposable = (combineLatest(queue: .mainQueue(), mappedFeatured, context.account.postbox.combinedView(keys: [.itemCollectionInfos(namespaces: [Namespaces.ItemCollection.CloudStickerPacks])]), context.sharedContext.presentationData)
        |> map { featuredEntries, view, presentationData -> FeaturedTransition in
            var installedPacks = Set<ItemCollectionId>()
            if let stickerPacksView = view.views[.itemCollectionInfos(namespaces: [Namespaces.ItemCollection.CloudStickerPacks])] as? ItemCollectionInfosView {
                if let packsEntries = stickerPacksView.entriesByNamespace[Namespaces.ItemCollection.CloudStickerPacks] {
                    for entry in packsEntries {
                        installedPacks.insert(entry.id)
                    }
                }
            }
            let entries = featuredScreenEntries(featuredEntries: featuredEntries.0, installedPacks: installedPacks, theme: presentationData.theme, strings: presentationData.strings, fixedUnread: featuredEntries.1)
            let previous = previousEntries.swap(entries)
            
            return preparedTransition(from: previous ?? [], to: entries, account: context.account, interaction: interaction, initial: previous == nil)
        }
        |> deliverOnMainQueue).start(next: { [weak self] transition in
            guard let strongSelf = self else {
                return
            }
            strongSelf.enqueueTransition(transition)
            if !strongSelf.didSetReady {
                strongSelf.didSetReady = true
                strongSelf._ready.set(.single(true))
            }
        })
        
        self.controller?.searchNavigationNode?.setQueryUpdated({ [weak self] query, languageCode in
            guard let strongSelf = self else {
                return
            }
            strongSelf.searchNode?.updateText(query, languageCode: languageCode)
        })
        
        if let searchNode = self.searchNode {
            self.addSubnode(searchNode)
        }
    }
    
    deinit {
        self.disposable?.dispose()
        self.installDisposable.dispose()
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.view.addGestureRecognizer(PeekControllerGestureRecognizer(contentAtPoint: { [weak self] point in
            guard let strongSelf = self else {
                return nil
            }
            if let searchNode = strongSelf.searchNode, searchNode.isActive {
                if let (itemNode, item) = searchNode.itemAt(point: strongSelf.view.convert(point, to: searchNode.view)) {
                    if let item = item as? StickerPreviewPeekItem {
                        return strongSelf.context.account.postbox.transaction { transaction -> Bool in
                            return getIsStickerSaved(transaction: transaction, fileId: item.file.fileId)
                        }
                        |> deliverOnMainQueue
                        |> map { isStarred -> (ASDisplayNode, PeekControllerContent)? in
                            if let strongSelf = self {
                                var menuItems: [PeekControllerMenuItem] = []
                                menuItems = [
                                    PeekControllerMenuItem(title: strongSelf.presentationData.strings.StickerPack_Send, color: .accent, font: .bold, action: { node, rect in
                                        if let strongSelf = self {
                                            return strongSelf.sendSticker?(.standalone(media: item.file), node, rect) ?? false
                                        } else {
                                            return false
                                        }
                                    }),
                                    PeekControllerMenuItem(title: isStarred ? strongSelf.presentationData.strings.Stickers_RemoveFromFavorites : strongSelf.presentationData.strings.Stickers_AddToFavorites, color: isStarred ? .destructive : .accent, action: { _, _ in
                                        if let strongSelf = self {
                                            if isStarred {
                                                let _ = removeSavedSticker(postbox: strongSelf.context.account.postbox, mediaId: item.file.fileId).start()
                                            } else {
                                                let _ = addSavedSticker(postbox: strongSelf.context.account.postbox, network: strongSelf.context.account.network, file: item.file).start()
                                            }
                                        }
                                        return true
                                    }),
                                    PeekControllerMenuItem(title: strongSelf.presentationData.strings.StickerPack_ViewPack, color: .accent, action: { _, _ in
                                        if let strongSelf = self {
                                            loop: for attribute in item.file.attributes {
                                                switch attribute {
                                                case let .Sticker(_, packReference, _):
                                                    if let packReference = packReference {
                                                        let controller = StickerPackScreen(context: strongSelf.context, mainStickerPack: packReference, stickerPacks: [packReference], parentNavigationController: strongSelf.controller?.navigationController as? NavigationController, sendSticker: { file, sourceNode, sourceRect in
                                                            if let strongSelf = self {
                                                                return strongSelf.sendSticker?(file, sourceNode, sourceRect) ?? false
                                                            } else {
                                                                return false
                                                            }
                                                        })
                                                        
                                                        strongSelf.controller?.view.endEditing(true)
                                                        strongSelf.controller?.present(controller, in: .window(.root))
                                                    }
                                                    break loop
                                                default:
                                                    break
                                                }
                                            }
                                        }
                                        return true
                                    }),
                                    PeekControllerMenuItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { _, _ in return true })
                                ]
                                return (itemNode, StickerPreviewPeekContent(account: strongSelf.context.account, item: item, menu: menuItems))
                            } else {
                                return nil
                            }
                        }
                    }
                }
                return nil
            }
            
            let itemNodeAndItem: (ASDisplayNode, StickerPackItem)? = strongSelf.itemAt(point: point)
            if let (itemNode, item) = itemNodeAndItem {
                return strongSelf.context.account.postbox.transaction { transaction -> Bool in
                    return getIsStickerSaved(transaction: transaction, fileId: item.file.fileId)
                }
                |> deliverOnMainQueue
                |> map { isStarred -> (ASDisplayNode, PeekControllerContent)? in
                    if let strongSelf = self {
                        var menuItems: [PeekControllerMenuItem] = []
                        menuItems = [
                            PeekControllerMenuItem(title: strongSelf.presentationData.strings.StickerPack_Send, color: .accent, font: .bold, action: { node, rect in
                                if let strongSelf = self {
                                    return strongSelf.sendSticker?(.standalone(media: item.file), node, rect) ?? false
                                } else {
                                    return false
                                }
                            }),
                            PeekControllerMenuItem(title: isStarred ? strongSelf.presentationData.strings.Stickers_RemoveFromFavorites : strongSelf.presentationData.strings.Stickers_AddToFavorites, color: isStarred ? .destructive : .accent, action: { _, _ in
                                if let strongSelf = self {
                                    if isStarred {
                                        let _ = removeSavedSticker(postbox: strongSelf.context.account.postbox, mediaId: item.file.fileId).start()
                                    } else {
                                        let _ = addSavedSticker(postbox: strongSelf.context.account.postbox, network: strongSelf.context.account.network, file: item.file).start()
                                    }
                                }
                                return true
                            }),
                            PeekControllerMenuItem(title: strongSelf.presentationData.strings.StickerPack_ViewPack, color: .accent, action: { _, _ in
                                if let strongSelf = self {
                                    loop: for attribute in item.file.attributes {
                                        switch attribute {
                                            case let .Sticker(_, packReference, _):
                                                if let packReference = packReference {
                                                    let controller = StickerPackScreen(context: strongSelf.context, mainStickerPack: packReference, stickerPacks: [packReference], parentNavigationController: strongSelf.controller?.navigationController as? NavigationController, sendSticker: { file, sourceNode, sourceRect in
                                                        if let strongSelf = self {
                                                            return strongSelf.sendSticker?(file, sourceNode, sourceRect) ?? false
                                                        } else {
                                                            return false
                                                        }
                                                    })
                                          
                                                    strongSelf.controller?.view.endEditing(true)
                                                    strongSelf.controller?.present(controller, in: .window(.root))
                                                }
                                                break loop
                                            default:
                                                break
                                        }
                                    }
                                }
                                return true
                            }),
                            PeekControllerMenuItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { _, _ in return true })
                        ]
                        return (itemNode, StickerPreviewPeekContent(account: strongSelf.context.account, item: .pack(item), menu: menuItems))
                    } else {
                        return nil
                    }
                }
            }
            return nil
        }, present: { [weak self] content, sourceNode in
            if let strongSelf = self {
                let controller = PeekController(theme: PeekControllerTheme(presentationTheme: strongSelf.presentationData.theme), content: content, sourceNode: {
                    return sourceNode
                })
                strongSelf.controller?.presentInGlobalOverlay(controller)
                return controller
            }
            return nil
        }, updateContent: { [weak self] content in
            if let strongSelf = self {
                var item: StickerPreviewPeekItem?
                if let content = content as? StickerPreviewPeekContent {
                    item = content.item
                }
                //strongSelf.updatePreviewingItem(item: item, animated: true)
            }
        }))
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        let firstTime = self.validLayout == nil
        
        self.validLayout = layout
        
        var insets = layout.insets(options: [.statusBar])
        insets.top += navigationHeight
        
        if let searchNode = self.searchNode {
            let searchNodeFrame = CGRect(origin: CGPoint(x: 0.0, y: insets.top), size: CGSize(width: layout.size.width, height: layout.size.height - insets.top))
            transition.updateFrame(node: searchNode, frame: searchNodeFrame)
            searchNode.updateLayout(size: searchNodeFrame.size, leftInset: layout.safeInsets.left, rightInset: layout.safeInsets.right, bottomInset: insets.bottom, inputHeight: layout.inputHeight ?? 0.0, deviceMetrics: layout.deviceMetrics, transition: transition)
        }
        
        let itemSize: CGSize
        if case .tablet = layout.deviceMetrics.type, layout.size.width > 480.0 {
            itemSize = CGSize(width: floor(layout.size.width / 2.0), height: 128.0)
        } else {
            itemSize = CGSize(width: layout.size.width, height: 128.0)
        }
        
        self.gridNode.transaction(GridNodeTransaction(deleteItems: [], insertItems: [], updateItems: [], scrollToItem: nil, updateLayout: GridNodeUpdateLayout(layout: GridNodeLayout(size: layout.size, insets: UIEdgeInsets(top: insets.top, left: layout.safeInsets.left, bottom: insets.bottom, right: layout.safeInsets.right), preloadSize: 300.0, type: .fixed(itemSize: itemSize, fillWidth: nil, lineSpacing: 0.0, itemSpacing: nil)), transition: transition), itemTransition: .immediate, stationaryItems: .none, updateFirstIndexInSectionOffset: nil), completion: { _ in })
        
        transition.updateFrame(node: self.gridNode, frame: CGRect(origin: CGPoint(), size: CGSize(width: layout.size.width, height: layout.size.height)))
        
        if firstTime {
            while !self.enqueuedTransitions.isEmpty {
                self.dequeueTransition()
            }
            if !self.didSetReady {
                self.didSetReady = true
                self._ready.set(.single(true))
            }
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.bounds.contains(point) {
            return nil
        }
        
        return super.hitTest(point, with: event)
    }
    
    private func enqueueTransition(_ transition: FeaturedTransition) {
        self.enqueuedTransitions.append(transition)
        
        if self.validLayout != nil {
            while !self.enqueuedTransitions.isEmpty {
                self.dequeueTransition()
            }
        }
    }
    
    private func dequeueTransition() {
        if let transition = self.enqueuedTransitions.first {
            self.enqueuedTransitions.remove(at: 0)
            
            let itemTransition: ContainedViewLayoutTransition = .immediate
            self.gridNode.transaction(GridNodeTransaction(deleteItems: transition.deletions, insertItems: transition.insertions, updateItems: transition.updates, scrollToItem: nil, updateLayout: nil, itemTransition: itemTransition, stationaryItems: .none, updateFirstIndexInSectionOffset: nil, synchronousLoads: transition.initial), completion: { _ in })
        }
    }
    
    func itemAt(point: CGPoint) -> (ASDisplayNode, StickerPackItem)? {
        let localPoint = self.view.convert(point, to: self.gridNode.view)
        var resultNode: StickerPaneSearchGlobalItemNode?
        self.gridNode.forEachItemNode { itemNode in
            if itemNode.frame.contains(localPoint), let itemNode = itemNode as? StickerPaneSearchGlobalItemNode {
                resultNode = itemNode
            }
        }
        if let resultNode = resultNode {
            return resultNode.itemAt(point: self.gridNode.view.convert(localPoint, to: resultNode.view))
        }
        return nil
    }
    
    func updatePreviewing(animated: Bool) {
        self.gridNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? StickerPaneSearchGlobalItemNode {
                itemNode.updatePreviewing(animated: animated)
            }
        }
    }
}

final class FeaturedStickersScreen: ViewController {
    private let context: AccountContext
    private let sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)?
    
    private var controllerNode: FeaturedStickersScreenNode {
        return self.displayNode as! FeaturedStickersScreenNode
    }
    
    private var presentationData: PresentationData
    
    private let _ready = Promise<Bool>()
    override public var ready: Promise<Bool> {
        return self._ready
    }
    
    fileprivate var searchNavigationNode: SearchNavigationContentNode?
    
    public init(context: AccountContext, sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)? = nil) {
        self.context = context
        self.sendSticker = sendSticker
        
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        
        self.navigationPresentation = .modal
        
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        
        let searchNavigationNode = SearchNavigationContentNode(theme: self.presentationData.theme, strings: self.presentationData.strings, cancel: { [weak self] in
            self?.dismiss()
        })
        self.searchNavigationNode = searchNavigationNode
        
        self.navigationBar?.setContentNode(searchNavigationNode, animated: false)
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func loadDisplayNode() {
        self.displayNode = FeaturedStickersScreenNode(
            context: self.context,
            controller: self,
            sendSticker: self.sendSticker.flatMap { [weak self] sendSticker in
                return { file, sourceNode, sourceRect in
                    if sendSticker(file, sourceNode, sourceRect) {
                        self?.dismiss()
                        return true
                    } else {
                        return false
                    }
                }
            }
        )
        
        self._ready.set(self.controllerNode.ready.get())
        
        super.displayNodeDidLoad()
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.controllerNode.containerLayoutUpdated(layout, navigationHeight: self.navigationHeight, transition: transition)
    }
}

private final class SearchNavigationContentNode: NavigationBarContentNode {
    private let theme: PresentationTheme
    private let strings: PresentationStrings
    
    private let cancel: () -> Void
    
    private let searchBar: SearchBarNode
    
    private var queryUpdated: ((String, String?) -> Void)?
    
    init(theme: PresentationTheme, strings: PresentationStrings, cancel: @escaping () -> Void) {
        self.theme = theme
        self.strings = strings
        
        self.cancel = cancel
        
        self.searchBar = SearchBarNode(theme: SearchBarNodeTheme(theme: theme), strings: strings, fieldStyle: .modern, cancelText: strings.Common_Done)
        let placeholderText = strings.Common_Search
        let searchBarFont = Font.regular(17.0)
        
        self.searchBar.placeholderString = NSAttributedString(string: placeholderText, font: searchBarFont, textColor: theme.rootController.navigationSearchBar.inputPlaceholderTextColor)
        
        super.init()
        
        self.addSubnode(self.searchBar)
        
        self.searchBar.cancel = { [weak self] in
            //self?.searchBar.deactivate(clear: false)
            self?.cancel()
        }
        
        self.searchBar.textUpdated = { [weak self] query, languageCode in
            self?.queryUpdated?(query, languageCode)
        }
    }
    
    func setQueryUpdated(_ f: @escaping (String, String?) -> Void) {
        self.queryUpdated = f
    }
    
    func setActivity(_ value: Bool) {
        self.searchBar.activity = value
    }
    
    override var nominalHeight: CGFloat {
        return 54.0
    }
    
    override func updateLayout(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition) {
        let searchBarFrame = CGRect(origin: CGPoint(x: 0.0, y: size.height - self.nominalHeight), size: CGSize(width: size.width, height: 54.0))
        self.searchBar.frame = searchBarFrame
        self.searchBar.updateLayout(boundingSize: searchBarFrame.size, leftInset: leftInset, rightInset: rightInset, transition: transition)
    }
    
    func activate() {
        self.searchBar.activate()
    }
    
    func deactivate() {
        self.searchBar.deactivate(clear: false)
    }
}

private enum FeaturedSearchEntryId: Equatable, Hashable {
    case sticker(String?, Int64)
    case global(ItemCollectionId)
}

private enum FeaturedSearchEntry: Identifiable, Comparable {
    case sticker(index: Int, code: String?, stickerItem: FoundStickerItem, theme: PresentationTheme)
    case global(index: Int, info: StickerPackCollectionInfo, topItems: [StickerPackItem], installed: Bool, topSeparator: Bool)
    
    var stableId: FeaturedSearchEntryId {
        switch self {
        case let .sticker(_, code, stickerItem, _):
            return .sticker(code, stickerItem.file.fileId.id)
        case let .global(_, info, _, _, _):
            return .global(info.id)
        }
    }
    
    static func ==(lhs: FeaturedSearchEntry, rhs: FeaturedSearchEntry) -> Bool {
        switch lhs {
        case let .sticker(lhsIndex, lhsCode, lhsStickerItem, lhsTheme):
            if case let .sticker(rhsIndex, rhsCode, rhsStickerItem, rhsTheme) = rhs {
                if lhsIndex != rhsIndex {
                    return false
                }
                if lhsCode != rhsCode {
                    return false
                }
                if lhsStickerItem != rhsStickerItem {
                    return false
                }
                if lhsTheme !== rhsTheme {
                    return false
                }
                return true
            } else {
                return false
            }
        case let .global(index, info, topItems, installed, topSeparator):
            if case .global(index, info, topItems, installed, topSeparator) = rhs {
                return true
            } else {
                return false
            }
        }
    }
    
    static func <(lhs: FeaturedSearchEntry, rhs: FeaturedSearchEntry) -> Bool {
        switch lhs {
        case let .sticker(lhsIndex, _, _, _):
            switch rhs {
            case let .sticker(rhsIndex, _, _, _):
                return lhsIndex < rhsIndex
            default:
                return true
            }
        case let .global(lhsIndex, _, _, _, _):
            switch rhs {
            case .sticker:
                return false
            case let .global(rhsIndex, _, _, _, _):
                return lhsIndex < rhsIndex
            }
        }
    }
    
    func item(account: Account, theme: PresentationTheme, strings: PresentationStrings, interaction: StickerPaneSearchInteraction, inputNodeInteraction: ChatMediaInputNodeInteraction) -> GridItem {
        switch self {
        case let .sticker(_, code, stickerItem, theme):
            return StickerPaneSearchStickerItem(account: account, code: code, stickerItem: stickerItem, inputNodeInteraction: inputNodeInteraction, theme: theme, selected: { node, rect in
                interaction.sendSticker(.standalone(media: stickerItem.file), node, rect)
            })
        case let .global(_, info, topItems, installed, topSeparator):
            return StickerPaneSearchGlobalItem(account: account, theme: theme, strings: strings, info: info, topItems: topItems, grid: false, topSeparator: topSeparator, installed: installed, unread: false, open: {
                interaction.open(info)
            }, install: {
                interaction.install(info, topItems, !installed)
            }, getItemIsPreviewed: { item in
                return interaction.getItemIsPreviewed(item)
            })
        }
    }
}

private struct FeaturedSearchGridTransition {
    let deletions: [Int]
    let insertions: [GridNodeInsertItem]
    let updates: [GridNodeUpdateItem]
    let updateFirstIndexInSectionOffset: Int?
    let stationaryItems: GridNodeStationaryItems
    let scrollToItem: GridNodeScrollToItem?
    let animated: Bool
}

private func preparedFeaturedSearchEntryTransition(account: Account, theme: PresentationTheme, strings: PresentationStrings, from fromEntries: [FeaturedSearchEntry], to toEntries: [FeaturedSearchEntry], interaction: StickerPaneSearchInteraction, inputNodeInteraction: ChatMediaInputNodeInteraction) -> FeaturedSearchGridTransition {
    let stationaryItems: GridNodeStationaryItems = .none
    let scrollToItem: GridNodeScrollToItem? = nil
    var animated = false
    animated = true
    
    let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: fromEntries, rightList: toEntries)
    
    let deletions = deleteIndices
    let insertions = indicesAndItems.map { GridNodeInsertItem(index: $0.0, item: $0.1.item(account: account, theme: theme, strings: strings, interaction: interaction, inputNodeInteraction: inputNodeInteraction), previousIndex: $0.2) }
    let updates = updateIndices.map { GridNodeUpdateItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(account: account, theme: theme, strings: strings, interaction: interaction, inputNodeInteraction: inputNodeInteraction)) }
    
    let firstIndexInSectionOffset = 0
    
    return FeaturedSearchGridTransition(deletions: deletions, insertions: insertions, updates: updates, updateFirstIndexInSectionOffset: firstIndexInSectionOffset, stationaryItems: stationaryItems, scrollToItem: scrollToItem, animated: animated)
}

private final class FeaturedPaneSearchContentNode: ASDisplayNode {
    private let context: AccountContext
    private let inputNodeInteraction: ChatMediaInputNodeInteraction
    private var interaction: StickerPaneSearchInteraction?
    private weak var controller: FeaturedStickersScreen?
    private let sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)?
    
    private var theme: PresentationTheme
    private var strings: PresentationStrings
    
    private let gridNode: GridNode
    private let notFoundNode: ASImageNode
    private let notFoundLabel: ImmediateTextNode
    
    private var validLayout: CGSize?
    
    private var enqueuedTransitions: [FeaturedSearchGridTransition] = []
    
    private let searchDisposable = MetaDisposable()
    
    private let queue = Queue()
    private let currentEntries = Atomic<[FeaturedSearchEntry]?>(value: nil)
    private let currentRemotePacks = Atomic<FoundStickerSets?>(value: nil)
    
    private let _ready = Promise<Void>()
    var ready: Signal<Void, NoError> {
        return self._ready.get()
    }
    
    var deactivateSearchBar: (() -> Void)?
    var updateActivity: ((Bool) -> Void)?
    
    private let installDisposable = MetaDisposable()
    
    var isActive: Bool {
        return !self.gridNode.isHidden
    }
    
    init(context: AccountContext, theme: PresentationTheme, strings: PresentationStrings, inputNodeInteraction: ChatMediaInputNodeInteraction, controller: FeaturedStickersScreen, sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)?) {
        self.context = context
        self.inputNodeInteraction = inputNodeInteraction
        self.controller = controller
        self.sendSticker = sendSticker
        
        self.theme = theme
        self.strings = strings
        
        self.gridNode = GridNode()
        self.gridNode.backgroundColor = theme.list.plainBackgroundColor
        
        self.notFoundNode = ASImageNode()
        self.notFoundNode.displayWithoutProcessing = true
        self.notFoundNode.displaysAsynchronously = false
        self.notFoundNode.clipsToBounds = false
        
        self.notFoundLabel = ImmediateTextNode()
        self.notFoundLabel.displaysAsynchronously = false
        self.notFoundLabel.isUserInteractionEnabled = false
        self.notFoundNode.addSubnode(self.notFoundLabel)
        
        self.gridNode.isHidden = true
        self.notFoundNode.isHidden = true
        
        super.init()
        
        self.addSubnode(self.gridNode)
        self.addSubnode(self.notFoundNode)
        
        self.gridNode.scrollView.alwaysBounceVertical = true
        self.gridNode.scrollingInitiated = { [weak self] in
            self?.deactivateSearchBar?()
        }
        
        self.interaction = StickerPaneSearchInteraction(open: { [weak self] info in
            if let strongSelf = self {
                strongSelf.view.window?.endEditing(true)
                let packReference: StickerPackReference = .id(id: info.id.id, accessHash: info.accessHash)
                let controller = StickerPackScreen(context: strongSelf.context, mainStickerPack: packReference, stickerPacks: [packReference], parentNavigationController: strongSelf.controller?.navigationController as? NavigationController, sendSticker: { [weak self] fileReference, sourceNode, sourceRect in
                    if let strongSelf = self {
                        return strongSelf.sendSticker?(fileReference, sourceNode, sourceRect) ?? false
                    } else {
                        return false
                    }
                })
                strongSelf.controller?.present(controller, in: .window(.root))
            }
        }, install: { [weak self] info, items, install in
            guard let strongSelf = self else {
                return
            }
            let account = strongSelf.context.account
            if install {
                var installSignal = loadedStickerPack(postbox: strongSelf.context.account.postbox, network: strongSelf.context.account.network, reference: .id(id: info.id.id, accessHash: info.accessHash), forceActualized: false)
                |> mapToSignal { result -> Signal<(StickerPackCollectionInfo, [ItemCollectionItem]), NoError> in
                    switch result {
                    case let .result(info, items, installed):
                        if installed {
                            return .complete()
                        } else {
                            return preloadedStickerPackThumbnail(account: account, info: info, items: items)
                            |> filter { $0 }
                            |> ignoreValues
                            |> then(
                                addStickerPackInteractively(postbox: strongSelf.context.account.postbox, info: info, items: items)
                                |> ignoreValues
                            )
                            |> mapToSignal { _ -> Signal<(StickerPackCollectionInfo, [ItemCollectionItem]), NoError> in
                                return .complete()
                            }
                            |> then(.single((info, items)))
                        }
                    case .fetching:
                        break
                    case .none:
                        break
                    }
                    return .complete()
                }
                |> deliverOnMainQueue
                
                let context = strongSelf.context
                var cancelImpl: (() -> Void)?
                let progressSignal = Signal<Never, NoError> { subscriber in
                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                    let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
                        cancelImpl?()
                    }))
                    self?.controller?.present(controller, in: .window(.root))
                    return ActionDisposable { [weak controller] in
                        Queue.mainQueue().async() {
                            controller?.dismiss()
                        }
                    }
                }
                |> runOn(Queue.mainQueue())
                |> delay(0.12, queue: Queue.mainQueue())
                let progressDisposable = progressSignal.start()
                
                installSignal = installSignal
                |> afterDisposed {
                    Queue.mainQueue().async {
                        progressDisposable.dispose()
                    }
                }
                cancelImpl = {
                    self?.installDisposable.set(nil)
                }
                    
                strongSelf.installDisposable.set(installSignal.start(next: { info, items in
                    guard let strongSelf = self else {
                        return
                    }
                    
                    var animateInAsReplacement = false
                    if let navigationController = strongSelf.controller?.navigationController as? NavigationController {
                        for controller in navigationController.overlayControllers {
                            if let controller = controller as? UndoOverlayController {
                                controller.dismissWithCommitActionAndReplacementAnimation()
                                animateInAsReplacement = true
                            }
                        }
                    }
                    
                    let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                    /*strongSelf.controllerInteraction.navigationController()?.presentOverlay(controller: UndoOverlayController(presentationData: presentationData, content: .stickersModified(title: presentationData.strings.StickerPackActionInfo_AddedTitle, text: presentationData.strings.StickerPackActionInfo_AddedText(info.title).0, undo: false, info: info, topItem: items.first, account: strongSelf.context.account), elevatedLayout: false, animateInAsReplacement: animateInAsReplacement, action: { _ in
                        return true
                    }))*/
                }))
            } else {
                let _ = (removeStickerPackInteractively(postbox: account.postbox, id: info.id, option: .delete)
                |> deliverOnMainQueue).start(next: { _ in
                })
            }
        }, sendSticker: { [weak self] file, sourceNode, sourceRect in
            if let strongSelf = self {
                let _ = strongSelf.sendSticker?(file, sourceNode, sourceRect)
            }
        }, getItemIsPreviewed: { item in
            return inputNodeInteraction.previewedStickerPackItem == .pack(item)
        })
        
        self._ready.set(.single(Void()))
    
        self.updateThemeAndStrings(theme: theme, strings: strings)
    }
    
    deinit {
        self.searchDisposable.dispose()
        self.installDisposable.dispose()
    }
    
    func updateText(_ text: String, languageCode: String?) {
        let signal: Signal<([(String?, FoundStickerItem)], FoundStickerSets, Bool, FoundStickerSets?)?, NoError>
        if !text.isEmpty {
            let account = self.context.account
            let stickers: Signal<[(String?, FoundStickerItem)], NoError> = Signal { subscriber in
                var signals: Signal<[Signal<(String?, [FoundStickerItem]), NoError>], NoError> = .single([])
                
                let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if query.isSingleEmoji {
                    signals = .single([searchStickers(account: account, query: text.basicEmoji.0)
                    |> map { (nil, $0) }])
                } else if query.count > 1, let languageCode = languageCode, !languageCode.isEmpty && languageCode != "emoji" {
                    var signal = searchEmojiKeywords(postbox: account.postbox, inputLanguageCode: languageCode, query: query.lowercased(), completeMatch: query.count < 3)
                    if !languageCode.lowercased().hasPrefix("en") {
                        signal = signal
                        |> mapToSignal { keywords in
                            return .single(keywords)
                            |> then(
                                searchEmojiKeywords(postbox: account.postbox, inputLanguageCode: "en-US", query: query.lowercased(), completeMatch: query.count < 3)
                                |> map { englishKeywords in
                                    return keywords + englishKeywords
                                }
                            )
                        }
                    }
                    
                    signals = signal
                    |> map { keywords -> [Signal<(String?, [FoundStickerItem]), NoError>] in
                        var signals: [Signal<(String?, [FoundStickerItem]), NoError>] = []
                        let emoticons = keywords.flatMap { $0.emoticons }
                        for emoji in emoticons {
                            signals.append(searchStickers(account: self.context.account, query: emoji.basicEmoji.0)
                            |> take(1)
                            |> map { (emoji, $0) })
                        }
                        return signals
                    }
                }
                
                return (signals
                |> mapToSignal { signals in
                    return combineLatest(signals)
                }).start(next: { results in
                    var result: [(String?, FoundStickerItem)] = []
                    for (emoji, stickers) in results {
                        for sticker in stickers {
                            result.append((emoji, sticker))
                        }
                    }
                    subscriber.putNext(result)
                }, completed: {
                    subscriber.putCompletion()
                })
            }
            
            let local = searchStickerSets(postbox: context.account.postbox, query: text)
            let remote = searchStickerSetsRemotely(network: context.account.network, query: text)
            |> delay(0.2, queue: Queue.mainQueue())
            let rawPacks = local
            |> mapToSignal { result -> Signal<(FoundStickerSets, Bool, FoundStickerSets?), NoError> in
                var localResult = result
                if let currentRemote = self.currentRemotePacks.with ({ $0 }) {
                    localResult = localResult.merge(with: currentRemote)
                }
                return .single((localResult, false, nil))
                |> then(
                    remote
                    |> map { remote -> (FoundStickerSets, Bool, FoundStickerSets?) in
                        return (result.merge(with: remote), true, remote)
                    }
                )
            }
            
            let installedPackIds = context.account.postbox.combinedView(keys: [.itemCollectionInfos(namespaces: [Namespaces.ItemCollection.CloudStickerPacks])])
            |> map { view -> Set<ItemCollectionId> in
                var installedPacks = Set<ItemCollectionId>()
                if let stickerPacksView = view.views[.itemCollectionInfos(namespaces: [Namespaces.ItemCollection.CloudStickerPacks])] as? ItemCollectionInfosView {
                    if let packsEntries = stickerPacksView.entriesByNamespace[Namespaces.ItemCollection.CloudStickerPacks] {
                        for entry in packsEntries {
                            installedPacks.insert(entry.id)
                        }
                    }
                }
                return installedPacks
            }
            |> distinctUntilChanged
            let packs = combineLatest(rawPacks, installedPackIds)
            |> map { packs, installedPackIds -> (FoundStickerSets, Bool, FoundStickerSets?) in
                var (localPacks, completed, remotePacks) = packs
                
                for i in 0 ..< localPacks.infos.count {
                    let installed = installedPackIds.contains(localPacks.infos[i].0)
                    if installed != localPacks.infos[i].3 {
                        localPacks.infos[i].3 = installed
                    }
                }
                
                if remotePacks != nil {
                    for i in 0 ..< remotePacks!.infos.count {
                        let installed = installedPackIds.contains(remotePacks!.infos[i].0)
                        if installed != remotePacks!.infos[i].3 {
                            remotePacks!.infos[i].3 = installed
                        }
                    }
                }
                
                return (localPacks, completed, remotePacks)
            }
            
            signal = combineLatest(stickers, packs)
            |> map { stickers, packs -> ([(String?, FoundStickerItem)], FoundStickerSets, Bool, FoundStickerSets?)? in
                return (stickers, packs.0, packs.1, packs.2)
            }
            self.updateActivity?(true)
        } else {
            signal = .single(nil)
            self.updateActivity?(false)
        }
        
        self.searchDisposable.set((signal
        |> deliverOn(self.queue)).start(next: { [weak self] result in
            Queue.mainQueue().async {
                guard let strongSelf = self, let interaction = strongSelf.interaction else {
                    return
                }
                
                var displayResults: Bool = false
                
                var entries: [FeaturedSearchEntry] = []
                if let (stickers, packs, final, remote) = result {
                    if let remote = remote {
                        let _ = strongSelf.currentRemotePacks.swap(remote)
                    }
                    
                    if final {
                        strongSelf.updateActivity?(false)
                    }
                    
                    var index = 0
                    var existingStickerIds = Set<MediaId>()
                    var previousCode: String?
                    for (code, sticker) in stickers {
                        if let id = sticker.file.id, !existingStickerIds.contains(id) {
                            entries.append(.sticker(index: index, code: code != previousCode ? code : nil, stickerItem: sticker, theme: strongSelf.theme))
                            index += 1
                            
                            previousCode = code
                            existingStickerIds.insert(id)
                        }
                    }
                    var isFirstGlobal = true
                    for (collectionId, info, _, installed) in packs.infos {
                        if let info = info as? StickerPackCollectionInfo {
                            var topItems: [StickerPackItem] = []
                            for e in packs.entries {
                                if let item = e.item as? StickerPackItem {
                                    if e.index.collectionId == collectionId {
                                        topItems.append(item)
                                    }
                                }
                            }
                            entries.append(.global(index: index, info: info, topItems: topItems, installed: installed, topSeparator: !isFirstGlobal))
                            isFirstGlobal = false
                            index += 1
                        }
                    }
                    
                    if final || !entries.isEmpty {
                        strongSelf.notFoundNode.isHidden = !entries.isEmpty
                    }
                    
                    displayResults = true
                } else {
                    let _ = strongSelf.currentRemotePacks.swap(nil)
                    strongSelf.updateActivity?(false)
                }
                
                let previousEntries = strongSelf.currentEntries.swap(entries)
                let transition = preparedFeaturedSearchEntryTransition(account: strongSelf.context.account, theme: strongSelf.theme, strings: strongSelf.strings, from: previousEntries ?? [], to: entries, interaction: interaction, inputNodeInteraction: strongSelf.inputNodeInteraction)
                strongSelf.enqueueTransition(transition)
                
                if displayResults {
                    strongSelf.gridNode.isHidden = false
                } else {
                    strongSelf.gridNode.isHidden = true
                    strongSelf.notFoundNode.isHidden = true
                }
            }
        }))
    }
    
    func updateThemeAndStrings(theme: PresentationTheme, strings: PresentationStrings) {
        self.notFoundNode.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Media/StickersNotFoundIcon"), color: theme.list.freeMonoIconColor)
        self.notFoundLabel.attributedText = NSAttributedString(string: strings.Stickers_NoStickersFound, font: Font.medium(14.0), textColor: theme.list.freeTextColor)
    }
    
    private func enqueueTransition(_ transition: FeaturedSearchGridTransition) {
        self.enqueuedTransitions.append(transition)
        
        if self.validLayout != nil {
            while !self.enqueuedTransitions.isEmpty {
                self.dequeueTransition()
            }
        }
    }
    
    private func dequeueTransition() {
        if let transition = self.enqueuedTransitions.first {
            self.enqueuedTransitions.remove(at: 0)
            
            let itemTransition: ContainedViewLayoutTransition = .immediate
            self.gridNode.transaction(GridNodeTransaction(deleteItems: transition.deletions, insertItems: transition.insertions, updateItems: transition.updates, scrollToItem: transition.scrollToItem, updateLayout: nil, itemTransition: itemTransition, stationaryItems: .none, updateFirstIndexInSectionOffset: transition.updateFirstIndexInSectionOffset, synchronousLoads: true), completion: { _ in })
            self.gridNode.recursivelyEnsureDisplaySynchronously(true)
        }
    }
    
    func updatePreviewing(animated: Bool) {
        self.gridNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? StickerPaneSearchStickerItemNode {
                itemNode.updatePreviewing(animated: animated)
            } else if let itemNode = itemNode as? StickerPaneSearchGlobalItemNode {
                itemNode.updatePreviewing(animated: animated)
            }
        }
    }
    
    func itemAt(point: CGPoint) -> (ASDisplayNode, Any)? {
        if let itemNode = self.gridNode.itemNodeAtPoint(self.view.convert(point, to: self.gridNode.view)) {
            if let itemNode = itemNode as? StickerPaneSearchStickerItemNode, let stickerItem = itemNode.stickerItem {
                return (itemNode, StickerPreviewPeekItem.found(stickerItem))
            } else if let itemNode = itemNode as? StickerPaneSearchGlobalItemNode {
                if let (node, item) = itemNode.itemAt(point: self.view.convert(point, to: itemNode.view)) {
                    return (node, StickerPreviewPeekItem.pack(item))
                }
            }
        }
        return nil
    }
    
    func updateLayout(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, bottomInset: CGFloat, inputHeight: CGFloat, deviceMetrics: DeviceMetrics, transition: ContainedViewLayoutTransition) {
        let firstLayout = self.validLayout == nil

        self.validLayout = size
        
        if let image = self.notFoundNode.image {
            let areaHeight = size.height - inputHeight
            
            let labelSize = self.notFoundLabel.updateLayout(CGSize(width: size.width, height: CGFloat.greatestFiniteMagnitude))
            
            transition.updateFrame(node: self.notFoundNode, frame: CGRect(origin: CGPoint(x: floor((size.width - image.size.width) / 2.0), y: floor((areaHeight - image.size.height - labelSize.height) / 2.0)), size: image.size))
            transition.updateFrame(node: self.notFoundLabel, frame: CGRect(origin: CGPoint(x: floor((image.size.width - labelSize.width) / 2.0), y: image.size.height + 8.0), size: labelSize))
        }
        
        let contentFrame = CGRect(origin: CGPoint(), size: size)
        self.gridNode.transaction(GridNodeTransaction(deleteItems: [], insertItems: [], updateItems: [], scrollToItem: nil, updateLayout: GridNodeUpdateLayout(layout: GridNodeLayout(size: contentFrame.size, insets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: 4.0 + bottomInset, right: 0.0), preloadSize: 300.0, type: .fixed(itemSize: CGSize(width: 75.0, height: 75.0), fillWidth: nil, lineSpacing: 0.0, itemSpacing: nil)), transition: transition), itemTransition: .immediate, stationaryItems: .none, updateFirstIndexInSectionOffset: nil), completion: { _ in })
        
        transition.updateFrame(node: self.gridNode, frame: contentFrame)
        if firstLayout {
            while !self.enqueuedTransitions.isEmpty {
                self.dequeueTransition()
            }
        }
    }
    
    func animateIn(additivePosition: CGFloat, transition: ContainedViewLayoutTransition) {
        self.gridNode.alpha = 0.0
        transition.updateAlpha(node: self.gridNode, alpha: 1.0, completion: { _ in
        })
    }
    
    func animateOut(transition: ContainedViewLayoutTransition) {
        transition.updateAlpha(node: self.gridNode, alpha: 0.0, completion: { _ in
        })
        transition.updateAlpha(node: self.notFoundNode, alpha: 0.0, completion: { _ in
        })
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.bounds.contains(point) {
            return nil
        }
        
        if self.gridNode.isHidden {
            return nil
        }
        
        return super.hitTest(point, with: event)
    }
}