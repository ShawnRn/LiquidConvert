import AppKit
import Quartz
import SwiftUI

struct WordPressGalleryCollectionView: NSViewRepresentable {
    let items: [WordPressMediaItem]
    @Binding var selection: Set<Int>
    @ObservedObject var transferStore: WordPressMediaTransferStore
    let onReachBottom: () -> Void
    let onOpenItem: (WordPressMediaItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        let layout = NSCollectionViewFlowLayout()
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 24, right: 20)
        layout.minimumInteritemSpacing = 18
        layout.minimumLineSpacing = 18
        layout.itemSize = NSSize(width: 228, height: 244)

        let collectionView = GalleryCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(WordPressGalleryCollectionViewItem.self, forItemWithIdentifier: .galleryItem)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.onSpace = {
            context.coordinator.toggleQuickLook()
        }
        collectionView.onOpenSelection = {
            context.coordinator.openFocusedItem()
        }
        collectionView.onClearSelection = {
            context.coordinator.clearSelection()
        }
        collectionView.previewPanelDataSourceProvider = { [weak coordinator = context.coordinator] in
            coordinator
        }
        collectionView.previewPanelDelegateProvider = { [weak coordinator = context.coordinator] in
            coordinator
        }

        scrollView.documentView = collectionView
        context.coordinator.collectionView = collectionView
        context.coordinator.attachScrollObservation(to: scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let collectionView = context.coordinator.collectionView else { return }
        let itemIDs = items.map(\.id)
        let progressSnapshot = Dictionary(uniqueKeysWithValues: items.map { ($0.id, transferStore.progress(for: $0.id)) })
        let itemsChanged = context.coordinator.lastRenderedItemIDs != itemIDs
        let progressChanged = context.coordinator.lastRenderedProgressSnapshot != progressSnapshot

        if itemsChanged {
            context.coordinator.lastRenderedItemIDs = itemIDs
            context.coordinator.lastRenderedProgressSnapshot = progressSnapshot
            collectionView.reloadData()
            collectionView.collectionViewLayout?.invalidateLayout()
        } else if progressChanged {
            context.coordinator.updateVisibleItemsForChangedProgress(progressSnapshot)
            context.coordinator.lastRenderedProgressSnapshot = progressSnapshot
        }

        let selectedIndexPaths = Set(
            items.enumerated()
                .filter { selection.contains($0.element.id) }
                .map { IndexPath(item: $0.offset, section: 0) }
        )

        if collectionView.selectionIndexPaths != selectedIndexPaths {
            collectionView.selectionIndexPaths = selectedIndexPaths
        }

        if QLPreviewPanel.shared()?.isVisible == true,
           context.coordinator.lastQuickLookSelection != selection {
            context.coordinator.lastQuickLookSelection = selection
            context.coordinator.refreshQuickLookIfNeeded()
        }

        context.coordinator.evaluateScrollPosition()
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        var parent: WordPressGalleryCollectionView
        fileprivate weak var collectionView: GalleryCollectionView?
        fileprivate var lastRenderedItemIDs: [Int] = []
        fileprivate var lastRenderedProgressSnapshot: [Int: Double?] = [:]
        fileprivate var lastQuickLookSelection: Set<Int> = []
        private var previewURLs: [URL] = []
        private var previewItems: [WordPressMediaItem] = []
        private var previewSourceFrame: NSRect = .zero
        private var previewTransitionImage: NSImage?
        private var currentPreviewIndex = 0
        private var isRefreshingQuickLook = false
        private weak var observedScrollView: NSScrollView?
        private var scrollObservation: NSObjectProtocol?
        private var quickLookCloseObservation: NSObjectProtocol?
        private var quickLookKeyMonitor: Any?
        private var lastBottomTriggerItemCount = 0

        init(parent: WordPressGalleryCollectionView) {
            self.parent = parent
            super.init()
            quickLookCloseObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard notification.object is QLPreviewPanel else { return }
                self?.removeQuickLookKeyMonitor()
            }
        }

        deinit {
            if let scrollObservation {
                NotificationCenter.default.removeObserver(scrollObservation)
            }
            if let quickLookCloseObservation {
                NotificationCenter.default.removeObserver(quickLookCloseObservation)
            }
            removeQuickLookKeyMonitor()
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: .galleryItem, for: indexPath)
            guard let galleryItem = item as? WordPressGalleryCollectionViewItem else {
                return item
            }

            let mediaItem = parent.items[indexPath.item]
            galleryItem.configure(
                item: mediaItem,
                isSelected: parent.selection.contains(mediaItem.id),
                progress: parent.transferStore.progress(for: mediaItem.id)
            )
            return galleryItem
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            syncSelection(from: collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            syncSelection(from: collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            let mediaItem = parent.items[indexPath.item]
            return parent.transferStore.makeFilePromiseProvider(for: mediaItem)
        }

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            !indexPaths.isEmpty
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func openFocusedItem() {
            guard let mediaItem = selectedItems().first else { return }
            parent.onOpenItem(mediaItem)
        }

        func clearSelection() {
            parent.selection.removeAll()
            collectionView?.selectionIndexPaths = []
        }

        func toggleQuickLook() {
            guard !selectedItems().isEmpty else { return }

            if let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.orderOut(nil)
                return
            }

            Task { @MainActor in
                await presentQuickLook()
            }
        }

        func refreshQuickLookIfNeeded() {
            guard QLPreviewPanel.shared()?.isVisible == true, !isRefreshingQuickLook else { return }
            Task { @MainActor in
                isRefreshingQuickLook = true
                await presentQuickLook(autoUpdate: true)
                isRefreshingQuickLook = false
            }
        }

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
            previewURLs.count
        }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            previewURLs[index] as NSURL
        }

        func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
            previewSourceFrame
        }

        func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
            guard let previewTransitionImage else { return nil }
            if let contentRect {
                contentRect.pointee = NSRect(origin: .zero, size: previewTransitionImage.size)
            }
            return previewTransitionImage
        }

        func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
            guard event.type == .keyDown else { return false }

            switch event.keyCode {
            case 123:
                moveQuickLookSelection(by: -1, panel: panel)
                return true
            case 124:
                moveQuickLookSelection(by: 1, panel: panel)
                return true
            case 126:
                moveQuickLookSelection(by: -quickLookVerticalStride(), panel: panel)
                return true
            case 125:
                moveQuickLookSelection(by: quickLookVerticalStride(), panel: panel)
                return true
            default:
                return false
            }
        }

        private func syncSelection(from collectionView: NSCollectionView) {
            let selectedIDs: Set<Int> = Set(
                collectionView.selectionIndexPaths.compactMap { indexPath in
                    guard indexPath.item < parent.items.count else { return nil }
                    return parent.items[indexPath.item].id
                }
            )
            if parent.selection != selectedIDs {
                parent.selection = selectedIDs
            }
            lastQuickLookSelection = selectedIDs
        }

        private func selectedItems() -> [WordPressMediaItem] {
            parent.items.filter { parent.selection.contains($0.id) }
        }

        private func focusedItemIndex() -> Int? {
            if let firstID = selectedItems().first?.id,
               let index = parent.items.firstIndex(where: { $0.id == firstID }) {
                return index
            }

            guard !parent.items.isEmpty else { return nil }
            return 0
        }

        @MainActor
        private func presentQuickLook(autoUpdate: Bool = false) async {
            guard let focusedIndex = focusedItemIndex(),
                  focusedIndex < parent.items.count else { return }

            do {
                currentPreviewIndex = focusedIndex
                let focusedItem = parent.items[focusedIndex]
                previewItems = [focusedItem]
                previewURLs = [try await parent.transferStore.ensureLocalFile(for: focusedItem)]
                previewSourceFrame = sourceFrameForFirstSelectedItem()
                previewTransitionImage = makePreviewTransitionImage(from: previewURLs.first, targetSize: previewSourceFrame.size)

                if let collectionView,
                   let window = collectionView.window {
                    window.makeFirstResponder(collectionView)
                }

                guard let panel = QLPreviewPanel.shared() else { return }
                panel.dataSource = self
                panel.delegate = self

                if autoUpdate {
                    panel.reloadData()
                    panel.refreshCurrentPreviewItem()
                } else {
                    installQuickLookKeyMonitor()
                    panel.makeKeyAndOrderFront(nil)
                    panel.updateController()
                    panel.reloadData()
                }
            } catch {
                NSSound.beep()
            }
        }

        private func sourceFrameForFirstSelectedItem() -> NSRect {
            guard let collectionView,
                  let firstID = selectedItems().first?.id,
                  let index = parent.items.firstIndex(where: { $0.id == firstID }),
                  let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? WordPressGalleryCollectionViewItem,
                  let window = collectionView.window else {
                return .zero
            }

            let thumbnailFrame = item.thumbnailFrameInCollectionView()
            let frameInWindow = collectionView.convert(thumbnailFrame, to: nil)
            return window.convertToScreen(frameInWindow)
        }

        fileprivate func attachScrollObservation(to scrollView: NSScrollView) {
            guard observedScrollView !== scrollView else { return }

            if let scrollObservation {
                NotificationCenter.default.removeObserver(scrollObservation)
            }

            observedScrollView = scrollView
            scrollObservation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.evaluateScrollPosition()
            }
        }

        fileprivate func evaluateScrollPosition() {
            guard let scrollView = observedScrollView,
                  let documentView = scrollView.documentView,
                  documentView.frame.height > 0,
                  !parent.items.isEmpty else { return }

            let visibleRect = scrollView.contentView.bounds
            let remainingHeight = documentView.frame.maxY - visibleRect.maxY
            guard remainingHeight < 320 else { return }
            guard lastBottomTriggerItemCount != parent.items.count else { return }

            lastBottomTriggerItemCount = parent.items.count
            parent.onReachBottom()
        }

        fileprivate func updateVisibleItemsForChangedProgress(_ newSnapshot: [Int: Double?]) {
            guard let collectionView else { return }

            for visibleItem in collectionView.visibleItems() {
                guard let galleryItem = visibleItem as? WordPressGalleryCollectionViewItem,
                      let mediaItem = galleryItem.mediaItem else { continue }

                let previousProgress = lastRenderedProgressSnapshot[mediaItem.id] ?? nil
                let currentProgress = newSnapshot[mediaItem.id] ?? nil
                guard previousProgress != currentProgress else { continue }

                galleryItem.updateProgress(currentProgress)
            }
        }

        private func makePreviewTransitionImage(from url: URL?, targetSize: NSSize) -> NSImage? {
            guard let url,
                  let sourceImage = NSImage(contentsOf: url) else { return nil }

            let finalSize = NSSize(
                width: max(targetSize.width, 44),
                height: max(targetSize.height, 44)
            )

            let roundedImage = NSImage(size: finalSize, flipped: false) { rect in
                let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
                path.addClip()

                let originalSize = sourceImage.size
                let widthScale = rect.width / max(originalSize.width, 1)
                let heightScale = rect.height / max(originalSize.height, 1)
                let scale = max(widthScale, heightScale)
                let drawWidth = originalSize.width * scale
                let drawHeight = originalSize.height * scale
                let drawRect = NSRect(
                    x: rect.midX - drawWidth / 2,
                    y: rect.midY - drawHeight / 2,
                    width: drawWidth,
                    height: drawHeight
                )
                sourceImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }

            return roundedImage
        }

        private func moveQuickLookSelection(by delta: Int, panel: QLPreviewPanel) {
            guard !parent.items.isEmpty else { return }

            let nextIndex = max(0, min(currentPreviewIndex + delta, parent.items.count - 1))
            guard nextIndex != currentPreviewIndex else { return }

            currentPreviewIndex = nextIndex
            let item = parent.items[nextIndex]
            parent.selection = [item.id]
            lastQuickLookSelection = [item.id]

            if let collectionView,
               let itemIndex = parent.items.firstIndex(where: { $0.id == item.id }) {
                let indexPath = IndexPath(item: itemIndex, section: 0)
                collectionView.selectionIndexPaths = [indexPath]
                collectionView.scrollToItems(at: Set([indexPath]), scrollPosition: .centeredVertically)
                if let galleryItem = collectionView.item(at: indexPath) as? WordPressGalleryCollectionViewItem {
                    let thumbnailFrame = galleryItem.thumbnailFrameInCollectionView()
                    let frameInWindow = collectionView.convert(thumbnailFrame, to: nil)
                    if let window = collectionView.window {
                        previewSourceFrame = window.convertToScreen(frameInWindow)
                    }
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.presentQuickLook(autoUpdate: true)
                panel.refreshCurrentPreviewItem()
            }
        }

        private func quickLookVerticalStride() -> Int {
            guard let collectionView,
                  let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else {
                return 1
            }

            let availableWidth: CGFloat
            if let scrollView = observedScrollView {
                availableWidth = scrollView.contentView.bounds.width
            } else {
                availableWidth = collectionView.bounds.width
            }

            let usableWidth = max(availableWidth - layout.sectionInset.left - layout.sectionInset.right, layout.itemSize.width)
            let slotWidth = max(layout.itemSize.width + layout.minimumInteritemSpacing, 1)
            let columns = Int(floor((usableWidth + layout.minimumInteritemSpacing) / slotWidth))
            return max(columns, 1)
        }

        private func installQuickLookKeyMonitor() {
            guard quickLookKeyMonitor == nil else { return }

            quickLookKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      QLPreviewPanel.sharedPreviewPanelExists(),
                      let panel = QLPreviewPanel.shared(),
                      panel.isVisible,
                      NSApp.isActive else {
                    return event
                }

                switch event.keyCode {
                case 123:
                    self.moveQuickLookSelection(by: -1, panel: panel)
                    return nil
                case 124:
                    self.moveQuickLookSelection(by: 1, panel: panel)
                    return nil
                case 126:
                    self.moveQuickLookSelection(by: -self.quickLookVerticalStride(), panel: panel)
                    return nil
                case 125:
                    self.moveQuickLookSelection(by: self.quickLookVerticalStride(), panel: panel)
                    return nil
                default:
                    return event
                }
            }
        }

        private func removeQuickLookKeyMonitor() {
            if let quickLookKeyMonitor {
                NSEvent.removeMonitor(quickLookKeyMonitor)
                self.quickLookKeyMonitor = nil
            }
        }
    }
}

final class GalleryCollectionView: NSCollectionView {
    var onSpace: (() -> Void)?
    var onOpenSelection: (() -> Void)?
    var onClearSelection: (() -> Void)?
    var previewPanelDataSourceProvider: (() -> (any QLPreviewPanelDataSource)?)?
    var previewPanelDelegateProvider: (() -> (any QLPreviewPanelDelegate)?)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        let clickedIndexPath = indexPathForItem(at: point)
        super.mouseDown(with: event)

        if clickedIndexPath == nil && event.clickCount == 1 {
            onClearSelection?()
        } else if event.clickCount == 2 {
            onOpenSelection?()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:
            onSpace?()
        case 36:
            onOpenSelection?()
        default:
            super.keyDown(with: event)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel?.dataSource = previewPanelDataSourceProvider?()
        panel?.delegate = previewPanelDelegateProvider?()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel?.dataSource = nil
        panel?.delegate = nil
    }
}

private final class WordPressGalleryCollectionViewItem: NSCollectionViewItem {
    private static let cardWidth: CGFloat = 228
    private static let cardHeight: CGFloat = 244
    private static let imageHeight: CGFloat = 148
    private static let horizontalPadding: CGFloat = 12
    private static let cardCornerRadius: CGFloat = 24
    private static let imageCornerRadius: CGFloat = 12
    private static let overlayCornerRadius: CGFloat = 10

    private let cardView = NSView()
    private let imageClipView = NSView()
    private let thumbnailImageView = AspectFillImageView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let filenameLabel = NSTextField(labelWithString: "")
    private let dimensionsLabel = NSTextField(labelWithString: "")
    private let progressOverlay = NSVisualEffectView()
    private let progressIndicator = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private var currentItem: WordPressMediaItem?
    private var currentProgress: Double?
    private var isHighlightedForSelection = false
    private var thumbnailTask: Task<Void, Never>?
    private var currentThumbnailURL: URL?

    var mediaItem: WordPressMediaItem? { currentItem }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        setupViews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        currentThumbnailURL = nil
        performWithoutLayerAnimations {
            thumbnailImageView.image = nil
            spinner.isHidden = false
            spinner.startAnimation(nil)
            placeholderLabel.isHidden = false
        }
    }

    override var isSelected: Bool {
        didSet {
            updateAppearance()
        }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            isHighlightedForSelection = highlightState != .none
            updateAppearance()
        }
    }

    func configure(item: WordPressMediaItem, isSelected: Bool, progress: Double?) {
        currentItem = item
        currentProgress = progress

        titleLabel.stringValue = item.title
        filenameLabel.stringValue = item.filename
        if let width = item.width, let height = item.height {
            dimensionsLabel.stringValue = "\(width) × \(height)"
            dimensionsLabel.isHidden = false
        } else {
            dimensionsLabel.stringValue = ""
            dimensionsLabel.isHidden = true
        }

        isHighlightedForSelection = highlightState != .none
        self.isSelected = isSelected
        updateProgress(progress)
        updateAppearance()
        loadThumbnail(for: item.thumbnailURL ?? item.originalURL)
    }

    func updateProgress(_ progress: Double?) {
        currentProgress = progress
        performWithoutLayerAnimations {
            if let progress {
                progressOverlay.isHidden = false
                progressIndicator.doubleValue = progress * 100
                progressLabel.stringValue = progress >= 1 ? "准备完成" : "拖拽准备中 \(Int(progress * 100))%"
            } else {
                progressOverlay.isHidden = true
                progressIndicator.doubleValue = 0
                progressLabel.stringValue = ""
            }
        }
    }

    func thumbnailFrameInCollectionView() -> NSRect {
        let thumbnailRect = NSRect(
            x: Self.horizontalPadding,
            y: Self.cardHeight - Self.horizontalPadding - Self.imageHeight,
            width: Self.cardWidth - (Self.horizontalPadding * 2),
            height: Self.imageHeight
        )
        return view.convert(thumbnailRect, to: collectionView)
    }

    private func setupViews() {
        view.translatesAutoresizingMaskIntoConstraints = false

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = Self.cardCornerRadius
        cardView.layer?.cornerCurve = .continuous
        view.addSubview(cardView)

        imageClipView.translatesAutoresizingMaskIntoConstraints = false
        imageClipView.wantsLayer = true
        imageClipView.layer?.cornerRadius = Self.imageCornerRadius
        imageClipView.layer?.cornerCurve = .continuous
        imageClipView.layer?.masksToBounds = true
        cardView.addSubview(imageClipView)

        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.wantsLayer = true
        imageClipView.addSubview(thumbnailImageView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.stringValue = "􀏅"
        placeholderLabel.font = .systemFont(ofSize: 28, weight: .regular)
        placeholderLabel.textColor = .secondaryLabelColor
        imageClipView.addSubview(placeholderLabel)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        spinner.startAnimation(nil)
        imageClipView.addSubview(spinner)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        cardView.addSubview(titleLabel)

        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        filenameLabel.font = .systemFont(ofSize: 12)
        filenameLabel.textColor = .secondaryLabelColor
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        cardView.addSubview(filenameLabel)

        dimensionsLabel.translatesAutoresizingMaskIntoConstraints = false
        dimensionsLabel.font = .systemFont(ofSize: 11)
        dimensionsLabel.textColor = .tertiaryLabelColor
        cardView.addSubview(dimensionsLabel)

        progressOverlay.translatesAutoresizingMaskIntoConstraints = false
        progressOverlay.material = .sidebar
        progressOverlay.blendingMode = .withinWindow
        progressOverlay.state = .active
        progressOverlay.wantsLayer = true
        progressOverlay.layer?.cornerRadius = Self.overlayCornerRadius
        progressOverlay.layer?.cornerCurve = .continuous
        progressOverlay.isHidden = true
        imageClipView.addSubview(progressOverlay)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressOverlay.addSubview(progressIndicator)

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = .systemFont(ofSize: 11, weight: .medium)
        progressLabel.textColor = .labelColor
        progressOverlay.addSubview(progressLabel)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cardView.topAnchor.constraint(equalTo: view.topAnchor),
            cardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imageClipView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: Self.horizontalPadding),
            imageClipView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -Self.horizontalPadding),
            imageClipView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: Self.horizontalPadding),
            imageClipView.heightAnchor.constraint(equalToConstant: Self.imageHeight),

            thumbnailImageView.leadingAnchor.constraint(equalTo: imageClipView.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: imageClipView.trailingAnchor),
            thumbnailImageView.topAnchor.constraint(equalTo: imageClipView.topAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: imageClipView.bottomAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: imageClipView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: imageClipView.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: imageClipView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: imageClipView.centerYAnchor, constant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: Self.horizontalPadding),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -Self.horizontalPadding),
            titleLabel.topAnchor.constraint(equalTo: imageClipView.bottomAnchor, constant: 12),

            filenameLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            filenameLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            filenameLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),

            dimensionsLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dimensionsLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            dimensionsLabel.topAnchor.constraint(equalTo: filenameLabel.bottomAnchor, constant: 8),

            progressOverlay.leadingAnchor.constraint(equalTo: imageClipView.leadingAnchor, constant: 10),
            progressOverlay.trailingAnchor.constraint(equalTo: imageClipView.trailingAnchor, constant: -10),
            progressOverlay.bottomAnchor.constraint(equalTo: imageClipView.bottomAnchor, constant: -10),

            progressIndicator.leadingAnchor.constraint(equalTo: progressOverlay.leadingAnchor, constant: 10),
            progressIndicator.trailingAnchor.constraint(equalTo: progressOverlay.trailingAnchor, constant: -10),
            progressIndicator.topAnchor.constraint(equalTo: progressOverlay.topAnchor, constant: 10),

            progressLabel.leadingAnchor.constraint(equalTo: progressIndicator.leadingAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: progressIndicator.trailingAnchor),
            progressLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 6),
            progressLabel.bottomAnchor.constraint(equalTo: progressOverlay.bottomAnchor, constant: -10)
        ])

        updateAppearance()
    }

    private func updateAppearance() {
        let borderColor: NSColor
        let borderWidth: CGFloat

        if isSelected {
            borderColor = .systemBlue.withAlphaComponent(0.9)
            borderWidth = 2
        } else if isHighlightedForSelection {
            borderColor = .systemBlue.withAlphaComponent(0.45)
            borderWidth = 1.6
        } else {
            borderColor = .labelColor.withAlphaComponent(0.06)
            borderWidth = 1
        }

        performWithoutLayerAnimations {
            cardView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            cardView.layer?.borderColor = borderColor.cgColor
            cardView.layer?.borderWidth = borderWidth
            imageClipView.layer?.backgroundColor = (isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18)
                : NSColor.windowBackgroundColor).cgColor
        }
    }

    private func loadThumbnail(for url: URL?) {
        thumbnailTask?.cancel()
        currentThumbnailURL = url
        performWithoutLayerAnimations {
            thumbnailImageView.image = nil
            placeholderLabel.isHidden = false
            spinner.isHidden = false
            spinner.startAnimation(nil)
        }

        guard let url else {
            performWithoutLayerAnimations {
                spinner.stopAnimation(nil)
                spinner.isHidden = true
            }
            return
        }

        thumbnailTask = Task { [weak self] in
            let image = await WordPressGalleryThumbnailLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self,
                      self.currentThumbnailURL == url else { return }
                self.performWithoutLayerAnimations {
                    self.thumbnailImageView.image = image
                    self.placeholderLabel.isHidden = image != nil
                    self.spinner.stopAnimation(nil)
                    self.spinner.isHidden = true
                }
            }
        }
    }

    private func performWithoutLayerAnimations(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updates()
        CATransaction.commit()
    }
}

private final class AspectFillImageView: NSView {
    var image: NSImage? {
        didSet {
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let image else { return }
        let bounds = self.bounds.integral
        guard bounds.width > 0, bounds.height > 0 else { return }

        let sourceSize = image.size
        let widthScale = bounds.width / max(sourceSize.width, 1)
        let heightScale = bounds.height / max(sourceSize.height, 1)
        let scale = max(widthScale, heightScale)

        let drawSize = NSSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let drawRect = NSRect(
            x: bounds.midX - drawSize.width / 2,
            y: bounds.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

private actor WordPressGalleryThumbnailLoader {
    static let shared = WordPressGalleryThumbnailLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache.shared
        configuration.timeoutIntervalForRequest = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: ThumbnailAuthenticatedSessionDelegate(), delegateQueue: nil)
    }()

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        var request = URLRequest(url: url)
        let referer = await MainActor.run { SecureRuntimeConfig.wordPressMediaURL }
        request.setValue(referer, forHTTPHeaderField: "Referer")

        let cookieHeader = await MainActor.run { WordPressCookieManager.shared.cookieHeaderValue }
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, _) = try await session.data(for: request)
            guard let image = NSImage(data: data) else { return nil }
            cache.setObject(image, forKey: url as NSURL)
            return image
        } catch {
            return nil
        }
    }
}

private final class ThumbnailAuthenticatedSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let supportedMethods = [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodDefault
        ]

        guard supportedMethods.contains(method) else {
            Task { @MainActor in
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        if let credential = WordPressHTTPAuthStore.defaultCredential(for: challenge.protectionSpace)
            ?? challenge.proposedCredential {
            Task { @MainActor in
                completionHandler(.useCredential, credential)
            }
        } else {
            Task { @MainActor in
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let galleryItem = NSUserInterfaceItemIdentifier("WordPressGalleryCollectionViewItem")
}
